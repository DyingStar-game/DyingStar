"""Python twin of scenes/planet/rock_field_relief.gd — the rocky-terrain relief.

The runtime evaluates the rock fields in Godot; QGIS never bakes them. This
module exists for the GOLDEN values of test/unit/test_rock_field_relief.gd:
the Voronoi blocks, the buttes and the stepped strata must be bit-identical
here, in GDScript and in C# (scenes/planet/native/RockFieldNative.cs), which
is what proves the relief is the same on every machine (integer hash only, no
sine, no libm call but sqrt).

Keep every formula in the same order as the GDScript: IEEE doubles evaluate
identically as long as the operations are the same.

``f`` below is a dict of the record fields as Godot prepares them
(RockFieldRelief.prepare): cell_m, step_m, riser, joint_depth_m,
joint_width_m, butte_rate, butte_height_m, butte_cell_m, butte_wall_m, seed,
cx/cy/cz (unit centre), wx/wy/wz (unit wind), k (1 - 1/elongation),
dpx/dpy/dpz (dip direction × tan(dip)), lump_m / lump_wavelength_m (the soft
knobs of the chalk style; absent = none), joint_mean_m / butte_mean_m (the
area means of the joint and butte terms, measured at export by
:func:`term_means` and subtracted at runtime, so dropping a term at a coarser
LOD never moves the mean ground).
"""
import math

try:
    from .mountain_noise import cell, terrace, snoise, _smoothstep
except ImportError:  # imported as a top-level module (test/unit/*_py.py)
    from mountain_noise import cell, terrace, snoise, _smoothstep

#: A term is dropped (never faded) once the grid pitch reaches its cell / this.
GATE_DIV = 3.0
#: Seeds offsets — the same in the three twins.
SEED_JX, SEED_JY, SEED_JZ = 1, 2, 3
SEED_PHASE = 31
SEED_BJX, SEED_BJY, SEED_BJZ = 41, 42, 43
SEED_BPICK = 59
SEED_BRADIUS = 61
SEED_BHEIGHT = 63
SEED_WX, SEED_WY, SEED_WZ = 71, 72, 73
SEED_LUMP, SEED_LUMP2 = 81, 82
#: Block edges meander: the lattice input is warped by this share of a block,
#: over this many blocks (slope 0.25 × 3.75 / 2 < 1: the warp never folds).
WARP_AMP = 0.25
WARP_WAVELENGTH = 2.0


def warp(qx, qy, qz, cell_m, seed):
    """The lattice input bent so the block edges meander instead of running
    dead straight for a hundred metres."""
    lam = cell_m * WARP_WAVELENGTH
    amp = cell_m * WARP_AMP
    sx, sy, sz = qx / lam, qy / lam, qz / lam
    return (qx + amp * snoise(sx, sy, sz, seed + SEED_WX),
            qy + amp * snoise(sx, sy, sz, seed + SEED_WY),
            qz + amp * snoise(sx, sy, sz, seed + SEED_WZ))


def voronoi(x, y, z, seed):
    """Nearest feature cell, the cell across its nearest edge, and the
    distance to that edge (cell units) — Inigo Quilez's Voronoi edges, both
    passes 3×3×3, integer-hash jitter. Returns (c1, c2, edge) with c1/c2
    integer triples."""
    fx0, fy0, fz0 = math.floor(x), math.floor(y), math.floor(z)
    ix, iy, iz = int(fx0), int(fy0), int(fz0)
    fx, fy, fz = x - fx0, y - fy0, z - fz0
    md = 1.0e9
    mrx = mry = mrz = 0.0
    mgx = mgy = mgz = 0
    for k in (-1, 0, 1):
        for j in (-1, 0, 1):
            for i in (-1, 0, 1):
                rx = i + cell(ix + i, iy + j, iz + k, seed + SEED_JX) - fx
                ry = j + cell(ix + i, iy + j, iz + k, seed + SEED_JY) - fy
                rz = k + cell(ix + i, iy + j, iz + k, seed + SEED_JZ) - fz
                d = rx * rx + ry * ry + rz * rz
                if d < md:
                    md = d
                    mrx, mry, mrz = rx, ry, rz
                    mgx, mgy, mgz = i, j, k
    edge = 1.0e9
    nbx, nby, nbz = mgx, mgy, mgz
    for k in (-1, 0, 1):
        for j in (-1, 0, 1):
            for i in (-1, 0, 1):
                gx, gy, gz = mgx + i, mgy + j, mgz + k
                rx = gx + cell(ix + gx, iy + gy, iz + gz, seed + SEED_JX) - fx
                ry = gy + cell(ix + gx, iy + gy, iz + gz, seed + SEED_JY) - fy
                rz = gz + cell(ix + gx, iy + gy, iz + gz, seed + SEED_JZ) - fz
                dx, dy, dz = rx - mrx, ry - mry, rz - mrz
                dd = dx * dx + dy * dy + dz * dz
                if dd > 1.0e-5:
                    e = ((0.5 * (mrx + rx)) * dx + (0.5 * (mry + ry)) * dy
                         + (0.5 * (mrz + rz)) * dz) / math.sqrt(dd)
                    if e < edge:
                        edge = e
                        nbx, nby, nbz = gx, gy, gz
    return ((ix + mgx, iy + mgy, iz + mgz), (ix + nbx, iy + nby, iz + nbz), edge)


def buttes(x, y, z, f, eff_spacing_m):
    """Height (m) of the tallest butte reaching (x, y, z) — butte-cell units."""
    fx0, fy0, fz0 = math.floor(x), math.floor(y), math.floor(z)
    ix, iy, iz = int(fx0), int(fy0), int(fz0)
    fx, fy, fz = x - fx0, y - fy0, z - fz0
    seed = int(f["seed"])
    bc = f["butte_cell_m"]
    wall = max(f["butte_wall_m"], eff_spacing_m)
    best = 0.0
    for k in (-1, 0, 1):
        for j in (-1, 0, 1):
            for i in (-1, 0, 1):
                cx, cy, cz = ix + i, iy + j, iz + k
                if cell(cx, cy, cz, seed + SEED_BPICK) >= f["butte_rate"]:
                    continue
                rx = i + cell(cx, cy, cz, seed + SEED_BJX) - fx
                ry = j + cell(cx, cy, cz, seed + SEED_BJY) - fy
                rz = k + cell(cx, cy, cz, seed + SEED_BJZ) - fz
                d_m = math.sqrt(rx * rx + ry * ry + rz * rz) * bc
                r0 = bc * (0.12 + 0.13 * cell(cx, cy, cz, seed + SEED_BRADIUS))
                if d_m >= r0 + wall:
                    continue
                hgt = f["butte_height_m"] * (0.6 + 0.4 * cell(cx, cy, cz, seed + SEED_BHEIGHT))
                b = hgt * (1.0 - _smoothstep(r0, r0 + wall, d_m))
                if b > best:
                    best = b
    return best


def field_offset(dx, dy, dz, radius, f, eff_spacing_m, h_below):
    """RockFieldRelief.field_offset without the envelope: the offset (m) the
    field adds at unit direction (dx, dy, dz) over a ground at h_below (m)."""
    cell_m = f["cell_m"]
    bcell = f["butte_cell_m"]
    blocks_on = eff_spacing_m < cell_m / GATE_DIV
    buttes_on = f["butte_rate"] > 0.0 and f["butte_height_m"] > 0.0 \
        and eff_spacing_m < bcell / GATE_DIV
    lump_m = f.get("lump_m", 0.0)
    lump_wl = f.get("lump_wavelength_m", 0.0)
    lumps_on = lump_m > 0.0 and eff_spacing_m < lump_wl * 0.5
    if not blocks_on and not buttes_on and not lumps_on:
        return 0.0
    px, py, pz = dx * radius, dy * radius, dz * radius
    wx, wy, wz = f["wx"], f["wy"], f["wz"]
    kd = f["k"] * (px * wx + py * wy + pz * wz)
    qx, qy, qz = px - wx * kd, py - wy * kd, pz - wz * kd
    qx, qy, qz = warp(qx, qy, qz, cell_m, int(f["seed"]))
    bump = 0.0
    out = 0.0
    if buttes_on:
        bump = buttes(qx / bcell, qy / bcell, qz / bcell, f, eff_spacing_m)
        out = bump - f["butte_mean_m"]
    if lumps_on:
        # Soft knobs (chalk): two octaves of zero-mean value noise, the
        # second dropped below a quarter wavelength.
        sx, sy, sz = qx / lump_wl, qy / lump_wl, qz / lump_wl
        n = snoise(sx, sy, sz, int(f["seed"]) + SEED_LUMP)
        if eff_spacing_m < lump_wl * 0.25:
            n = n + 0.5 * snoise(sx * 2.0, sy * 2.0, sz * 2.0, int(f["seed"]) + SEED_LUMP2)
        out = out + lump_m * n
    if not blocks_on:
        return out
    step = f["step_m"]
    jd = f["joint_depth_m"]
    if step <= 0.0 and jd <= 0.0:
        return out
    seed = int(f["seed"])
    c1, c2, e = voronoi(qx / cell_m, qy / cell_m, qz / cell_m, seed)
    e_m = e * cell_m
    jw = f["joint_width_m"]
    if step > 0.0:
        # Each block is the ground terraced with its own phase; within
        # max(joint width, pitch) of the edge the two blocks' TERRACED values
        # blend to their mean on the edge — continuous, and zero-mean since
        # both are (blending the phases instead would bias the mean).
        s = ((dx - f["cx"]) * f["dpx"] + (dy - f["cy"]) * f["dpy"]
             + (dz - f["cz"]) * f["dpz"]) * radius
        x0 = h_below + bump + s
        riser = f["riser"]
        lift = step * (1.0 - riser) * 0.5
        x1 = x0 + (cell(c1[0], c1[1], c1[2], seed + SEED_PHASE) - 0.5) * step
        x2 = x0 + (cell(c2[0], c2[1], c2[2], seed + SEED_PHASE) - 0.5) * step
        g1 = terrace(x1, step, riser) - x1 + lift
        g2 = terrace(x2, step, riser) - x2 + lift
        bw = max(jw, eff_spacing_m)
        t = 0.5 * (1.0 - _smoothstep(0.0, bw, e_m))
        out = out + (g1 + (g2 - g1) * t)
    if jd > 0.0 and eff_spacing_m < jw:
        out = out - (jd * (1.0 - _smoothstep(0.0, jw, e_m)) - f["joint_mean_m"])
    return out


#: Samples per side of the grid term_means averages over.
MEAN_GRID = 48


def term_means(f, radius):
    """(joint_mean_m, butte_mean_m): the area means of the joint groove and of
    the buttes over a MEAN_GRID² grid around the record's centre — a fixed
    grid, so the export is reproducible. The grid spans 24 cells of each term
    (the field is statistically the same everywhere in the zone)."""
    seed = int(f["seed"])
    cx, cy, cz = f["cx"], f["cy"], f["cz"]
    # A tangent frame at the centre (any one: the means are local averages).
    ax, ay, az = (0.0, 1.0, 0.0) if abs(cy) < 0.9 else (1.0, 0.0, 0.0)
    ux, uy, uz = cy * az - cz * ay, cz * ax - cx * az, cx * ay - cy * ax
    n = math.sqrt(ux * ux + uy * uy + uz * uz)
    ux, uy, uz = ux / n, uy / n, uz / n
    vx, vy, vz = cy * uz - cz * uy, cz * ux - cx * uz, cx * uy - cy * ux

    def samples(span_m):
        for a in range(MEAN_GRID):
            for b in range(MEAN_GRID):
                su = ((a + 0.5) / MEAN_GRID - 0.5) * span_m / radius
                sv = ((b + 0.5) / MEAN_GRID - 0.5) * span_m / radius
                px, py, pz = cx + ux * su + vx * sv, cy + uy * su + vy * sv, cz + uz * su + vz * sv
                ln = math.sqrt(px * px + py * py + pz * pz)
                px, py, pz = px / ln, py / ln, pz / ln
                wx, wy, wz = f["wx"], f["wy"], f["wz"]
                qx, qy, qz = px * radius, py * radius, pz * radius
                kd = f["k"] * (qx * wx + qy * wy + qz * wz)
                yield warp(qx - wx * kd, qy - wy * kd, qz - wz * kd, f["cell_m"], seed)

    jm = 0.0
    if f["joint_depth_m"] > 0.0:
        cell_m = f["cell_m"]
        acc = 0.0
        for qx, qy, qz in samples(24.0 * cell_m):
            e = voronoi(qx / cell_m, qy / cell_m, qz / cell_m, seed)[2] * cell_m
            acc += f["joint_depth_m"] * (1.0 - _smoothstep(0.0, f["joint_width_m"], e))
        jm = acc / (MEAN_GRID * MEAN_GRID)
    bm = 0.0
    if f["butte_rate"] > 0.0 and f["butte_height_m"] > 0.0:
        bc = f["butte_cell_m"]
        acc = 0.0
        for qx, qy, qz in samples(24.0 * bc):
            acc += buttes(qx / bc, qy / bc, qz / bc, f, 0.0)
        bm = acc / (MEAN_GRID * MEAN_GRID)
    return jm, bm
