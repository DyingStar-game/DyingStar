"""Preview of the procedural mountains' relief, for QGIS — numpy, no QGIS import.
================================================================================

The relief of a ``mountain_range`` polygon or a ``ridge`` line is generated in
Godot (scenes/planet/mountain_relief.gd); QGIS only holds the intent, so the
person who places a road across a massif cannot see how high it goes.  This
module evaluates the same offset on a lon/lat grid, so
preview_mountain_contours.py can draw its elevation contours in QGIS.

It is a vectorised port of MountainRelief.offset (zones + ridges; volcanoes
and rocky terrain are not included), written in the same order of operations
as the GDScript, on the presets of mountains.py (resolve_style): at a given
grid pitch it gives the surface the game builds at that vertex pitch — the
octaves finer than the pitch are dropped, exactly like a coarser LOD.

The noise is MountainNoise's integer hash on uint64 arrays: the products wrap
modulo 2**64 and are masked to their low 32 bits, the same number as the
GDScript's int64 and the scalar twin's unbounded ints (mountain_noise.py).
test/unit/test_mountain_preview_py.py pins the arrays to the scalar twin.
"""

import math

import numpy as np

from . import mountain_noise as mn
from .mountains import FEATHER_MIN_M, PRESETS, RIDGE_PRESETS, resolve_style

_M32 = np.uint64(0xFFFFFFFF)
_HX = np.uint64(0x8DA6B343)
_HY = np.uint64(0xD8163841)
_HZ = np.uint64(0xCB1AB31F)
_HM1 = np.uint64(0x7FEB352D)
_HM2 = np.uint64(0x846CA68B)
_S8 = np.uint64(8)
_S15 = np.uint64(15)
_S16 = np.uint64(16)

#: Samples evaluated per numpy batch — bounds the temporaries (~40 arrays).
BATCH = 131072


# ── Noise (MountainNoise, vectorised) ──────────────────────────────────────────
def hash_v(ix, iy, iz, seed):
    """MountainNoise.hash_i on int64 arrays; [seed] is a Python int."""
    s = np.uint64((seed * 0x9E3779B1 ^ 0x27D4EB2F) & 0xFFFFFFFF)
    with np.errstate(over="ignore"):
        h = ((ix.astype(np.uint64) * _HX) ^ (iy.astype(np.uint64) * _HY)
             ^ (iz.astype(np.uint64) * _HZ)) & _M32
        h ^= s
        h ^= h >> _S16
        h = (h * _HM1) & _M32
        h ^= h >> _S15
        h = (h * _HM2) & _M32
        h ^= h >> _S16
    return h


def _cell(ix, iy, iz, seed):
    return (hash_v(ix, iy, iz, seed) >> _S8).astype(np.float64) / 16777216.0


def _lerp(a, b, t):
    return a + (b - a) * t


def vnoise_v(x, y, z, seed):
    """MountainNoise.vnoise on float64 arrays."""
    fx, fy, fz = np.floor(x), np.floor(y), np.floor(z)
    ix, iy, iz = fx.astype(np.int64), fy.astype(np.int64), fz.astype(np.int64)
    tx, ty, tz = x - fx, y - fy, z - fz
    wx = tx * tx * tx * (tx * (tx * 6.0 - 15.0) + 10.0)
    wy = ty * ty * ty * (ty * (ty * 6.0 - 15.0) + 10.0)
    wz = tz * tz * tz * (tz * (tz * 6.0 - 15.0) + 10.0)
    ix1, iy1, iz1 = ix + 1, iy + 1, iz + 1
    x00 = _lerp(_cell(ix, iy, iz, seed), _cell(ix1, iy, iz, seed), wx)
    x10 = _lerp(_cell(ix, iy1, iz, seed), _cell(ix1, iy1, iz, seed), wx)
    x01 = _lerp(_cell(ix, iy, iz1, seed), _cell(ix1, iy, iz1, seed), wx)
    x11 = _lerp(_cell(ix, iy1, iz1, seed), _cell(ix1, iy1, iz1, seed), wx)
    return _lerp(_lerp(x00, x10, wy), _lerp(x01, x11, wy), wz)


def snoise_v(x, y, z, seed):
    return vnoise_v(x, y, z, seed) * 2.0 - 1.0


def _smoothstep_v(a, b, x):
    if a == b:
        return np.where(x < a, 0.0, 1.0)
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _pow_fast_v(x, e):
    if e == 1.0:
        return x
    if e == 2.0:
        return x * x
    if e == 3.0:
        return x * x * x
    if e == 1.5:
        return x * np.sqrt(x)
    if e == 0.5:
        return np.sqrt(x)
    return np.power(x, e)


def terrace_v(h_m, step_m, width):
    """MountainNoise.terrace on an array of heights."""
    if step_m <= 0.0:
        return h_m
    q = h_m / step_m
    k = np.floor(q)
    return (k + _smoothstep_v(1.0 - width, 1.0, q - k)) * step_m


def shape_v(dx, dy, dz, radius, prm, eff_spacing_m):
    """MountainNoise.shape on unit-direction arrays; None when not even the
    first octave fits the pitch (the runtime's -1: the zone keeps its lift)."""
    wl = prm["wavelength_m"]
    if eff_spacing_m >= wl * 0.5:
        return None
    s = radius / wl
    px, py, pz = dx * s, dy * s, dz * s
    seed = prm["seed"]
    warp = prm["warp"]
    if warp > 0.0:
        px, py, pz = (px + warp * snoise_v(px, py, pz, seed + 101),
                      py + warp * snoise_v(px, py, pz, seed + 202),
                      pz + warp * snoise_v(px, py, pz, seed + 303))
    ridge = prm["ridge"]
    total = np.zeros_like(px)
    amp, freq = 1.0, 1.0
    for k in range(prm["octaves"]):
        if k > 0 and eff_spacing_m >= (wl / freq) * 0.5:
            break
        v = vnoise_v(px * freq, py * freq, pz * freq, seed + k) * 2.0 - 1.0
        if ridge > 0.0:
            r = 1.0 - np.abs(v)
            r = r * r * 2.0 - 1.0
            v = _lerp(v, r, ridge)
        total += v * amp
        amp *= prm["persistence"]
        freq *= mn.LACUNARITY
    h = np.clip(0.5 + 0.5 * total / prm["norm"], 0.0, 1.0)
    return _pow_fast_v(h, prm["exponent"])


# ── Features (MountainRelief.prepare_zone / prepare_ridge) ────────────────────
def _clamp(v, lo, hi):
    return min(max(v, lo), hi)


def prepare_zone(ring, props):
    """A mountain_range feature as the runtime reads it: the exporter's preset
    resolution (resolve_style + the feather floor), then Params.from_zone's
    clamps. [ring] is [(lon, lat), …] without the closing vertex."""
    f = resolve_style(props, PRESETS, "alpine")
    octaves = _clamp(int(f["octaves"]), 1, mn.MAX_OCTAVES)
    persistence = _clamp(float(f["persistence"]), 0.05, 0.95)
    lons = [p[0] for p in ring]
    lats = [p[1] for p in ring]
    return {
        "kind": "zone",
        "name": str(f.get("name") or ""),
        "ring": np.asarray(ring, dtype=np.float64),
        "bbox": (min(lons), max(lons), min(lats), max(lats)),
        "lift_m": float(f["lift_m"]),
        "amplitude_m": float(f["amplitude_m"]),
        "wavelength_m": max(float(f["wavelength_m"]), 1.0),
        "octaves": octaves,
        "persistence": persistence,
        "norm": mn.norm_of(octaves, persistence),
        "ridge": _clamp(float(f["ridge"]), 0.0, 1.0),
        "exponent": max(float(f["exponent"]), 0.1),
        "terrace_step_m": max(float(f["terrace_step_m"]), 0.0),
        "terrace_width": _clamp(float(f["terrace_width"]), 0.01, 1.0),
        "warp": max(float(f["warp"]), 0.0),
        "feather_m": max(float(f["feather_m"]), FEATHER_MIN_M),
        "seed": int(f["seed"]),
    }


def _seg_len_m(a, b, m_per_deg):
    lat_scale = math.cos(math.radians(_clamp((a[1] + b[1]) * 0.5, -89.5, 89.5)))
    dx = (b[0] - a[0]) * lat_scale
    dy = b[1] - a[1]
    return math.sqrt(dx * dx + dy * dy) * m_per_deg


def prepare_ridge(points, props, radius_m):
    """A ridge feature as MountainRelief.prepare_ridge reads it."""
    f = resolve_style(props, RIDGE_PRESETS, "sharp")
    m_per_deg = radius_m * math.pi / 180.0
    cl = [(float(p[0]), float(p[1])) for p in points]
    cum = [0.0]
    for i in range(1, len(cl)):
        cum.append(cum[-1] + _seg_len_m(cl[i - 1], cl[i], m_per_deg))
    out = {
        "kind": "ridge",
        "name": str(f.get("name") or ""),
        "cl": np.asarray(cl, dtype=np.float64),
        "cum": np.asarray(cum, dtype=np.float64),
        "length_m": cum[-1],
        "height_m": float(f["height_m"]),
        "width_m": max(float(f["width_m"]), 1.0),
        "sharpness": _clamp(float(f["sharpness"]), 0.0, 1.0),
        "roughness": _clamp(float(f["roughness"]), 0.0, 0.9),
        "warp_m": max(float(f["warp_m"]), 0.0),
        "asymmetry": _clamp(float(f["asymmetry"]), -0.9, 0.9),
        "terrace_step_m": max(float(f["terrace_step_m"]), 0.0),
        "terrace_width": _clamp(float(f["terrace_width"]), 0.01, 1.0),
        "seed": int(f["seed"]),
    }
    out["reach_m"] = out["width_m"] * (1.0 + abs(out["asymmetry"])) + out["warp_m"]
    # The runtime's cheap reject box: the line padded by its reach, the longitude
    # scaled at the FIRST vertex's latitude (kept as is, so the preview cuts where
    # the game cuts).
    lat_c = math.cos(math.radians(_clamp(cl[0][1], -89.5, 89.5)))
    pad = out["reach_m"] / m_per_deg / max(lat_c, 0.05)
    lons = [p[0] for p in cl]
    lats = [p[1] for p in cl]
    out["bbox"] = (min(lons) - pad, max(lons) + pad, min(lats) - pad, max(lats) + pad)
    return out


# ── Geometry helpers (RoadTerrain._dist_sq_to_segment, _point_in_polygon) ─────
def _lat_scale(lat):
    return np.maximum(np.cos(np.radians(np.clip(lat, -89.5, 89.5))), 1e-6)


def _dist_sq_to_segment(lon, lat, a, b, lat_scale):
    ax = a[0] * lat_scale
    bx = b[0] * lat_scale
    px = lon * lat_scale
    dx = bx - ax
    dy = b[1] - a[1]
    seg_sq = dx * dx + dy * dy
    with np.errstate(divide="ignore", invalid="ignore"):
        t = np.where(seg_sq > 1e-24,
                     np.clip(((px - ax) * dx + (lat - a[1]) * dy) / seg_sq, 0.0, 1.0), 0.0)
    cx = px - (ax + t * dx)
    cy = lat - (a[1] + t * dy)
    return cx * cx + cy * cy


def _point_in_polygon(lon, lat, ring):
    inside = np.zeros(lon.shape, dtype=bool)
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if yi != yj:
            cond = ((yi > lat) != (yj > lat)) & (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi)
            inside ^= cond
        j = i
    return inside


def _in_box(lon, lat, box):
    return (lon >= box[0]) & (lon <= box[1]) & (lat >= box[2]) & (lat <= box[3])


def envelope_v(lon, lat, zone, m_per_deg):
    """MountainRelief.envelope: 0 outside the ring, 1 deeper than feather_m."""
    ring = zone["ring"]
    env = np.zeros(lon.shape)
    hit = _in_box(lon, lat, zone["bbox"])
    if not hit.any():
        return env
    idx = np.nonzero(hit)[0]
    lo, la = lon[idx], lat[idx]
    inside = _point_in_polygon(lo, la, ring)
    idx, lo, la = idx[inside], lo[inside], la[inside]
    if idx.size == 0:
        return env
    ls = _lat_scale(la)
    best = np.full(lo.shape, np.inf)
    n = len(ring)
    j = n - 1
    for i in range(n):
        best = np.minimum(best, _dist_sq_to_segment(lo, la, ring[j], ring[i], ls))
        j = i
    feather = zone["feather_m"]
    feather_deg = feather / m_per_deg
    env[idx] = np.where(best >= feather_deg * feather_deg, 1.0,
                        _smoothstep_v(0.0, feather, np.sqrt(best) * m_per_deg))
    return env


def ridge_height_v(lon, lat, dx, dy, dz, radius, rd):
    """MountainRelief.ridge_height (through _ridge_profile) on arrays."""
    out = np.zeros(lon.shape)
    cl = rd["cl"]
    if len(cl) < 2:
        return out
    hit = _in_box(lon, lat, rd["bbox"])
    if not hit.any():
        return out
    idx = np.nonzero(hit)[0]
    lo, la = lon[idx], lat[idx]
    m_per_deg = radius * math.pi / 180.0
    ls = _lat_scale(la)
    best = np.full(lo.shape, np.inf)
    best_i = np.zeros(lo.shape, dtype=np.int64)
    for i in range(len(cl) - 1):
        dsq = _dist_sq_to_segment(lo, la, cl[i], cl[i + 1], ls)
        closer = dsq < best
        best = np.where(closer, dsq, best)
        best_i = np.where(closer, i, best_i)
    d_m = np.sqrt(best) * m_per_deg
    keep = d_m < rd["reach_m"]
    idx, lo, la, ls, d_m, best_i = idx[keep], lo[keep], la[keep], ls[keep], d_m[keep], best_i[keep]
    if idx.size == 0:
        return out
    a = cl[best_i]
    b = cl[best_i + 1]
    ex = (b[:, 0] - a[:, 0]) * ls
    ey = b[:, 1] - a[:, 1]
    px = (lo - a[:, 0]) * ls
    py = la - a[:, 1]
    cross = ex * py - ey * px
    w = rd["width_m"]
    w_side = np.where(cross > 0.0, w * (1.0 + rd["asymmetry"]), w * (1.0 - rd["asymmetry"]))
    sdx, sdy, sdz = dx[idx], dy[idx], dz[idx]
    if rd["warp_m"] > 0.0:
        s = radius / (4.0 * w)
        d_m = np.maximum(d_m + rd["warp_m"] * snoise_v(sdx * s, sdy * s, sdz * s, rd["seed"] + 7), 0.0)
    t = d_m / w_side
    bell = 1.0 - _smoothstep_v(0.0, 1.0, t)
    knife = 1.0 - t
    prof = _lerp(bell, knife, rd["sharpness"])
    seg_sq = ex * ex + ey * ey
    with np.errstate(divide="ignore", invalid="ignore"):
        ts = np.where(seg_sq > 1e-24, np.clip((px * ex + py * ey) / seg_sq, 0.0, 1.0), 0.0)
    cum = rd["cum"]
    s_along = cum[best_i] + ts * (cum[best_i + 1] - cum[best_i])
    end_d = np.minimum(s_along, rd["length_m"] - s_along)
    taper = _smoothstep_v(0.0, min(w, rd["length_m"] * 0.5), end_d)
    h = rd["height_m"] * prof * taper
    if rd["roughness"] > 0.0:
        s = radius / (2.0 * w)
        h = h * (1.0 + rd["roughness"] * snoise_v(sdx * s, sdy * s, sdz * s, rd["seed"] + 11))
    h = terrace_v(h, rd["terrace_step_m"], rd["terrace_width"])
    out[idx] = np.where(t < 1.0, h, 0.0)
    return out


def lonlat_to_dir(lon, lat):
    """HEALPix.lonlat2vec on arrays: (cos·cos, sin, -cos·sin)."""
    lo = np.radians(lon)
    la = np.radians(lat)
    cl = np.cos(la)
    return cl * np.cos(lo), np.sin(la), -cl * np.sin(lo)


def offset_v(lon, lat, radius, features, eff_spacing_m):
    """MountainRelief.offset at every (lon, lat) — flat float64 arrays, degrees."""
    m_per_deg = radius * math.pi / 180.0
    dx, dy, dz = lonlat_to_dir(lon, lat)
    # The runtime reads lon/lat back from the direction (HEALPix.vec2lonlat): the
    # round trip moves them by an ulp, which decides the flank of a point lying
    # exactly on a crest. It normalises first, as Vector3.normalized() does.
    ln = np.sqrt(dx * dx + dy * dy + dz * dz)
    lat = np.degrees(np.arcsin(np.clip(dy / ln, -1.0, 1.0)))
    lon = np.degrees(np.arctan2(-(dz / ln), dx / ln))
    total = np.zeros(lon.shape)
    for z in (f for f in features if f["kind"] == "zone"):
        env = envelope_v(lon, lat, z, m_per_deg)
        idx = np.nonzero(env > 0.0)[0]
        if idx.size == 0:
            continue
        h = np.full(idx.shape, z["lift_m"])
        s = shape_v(dx[idx], dy[idx], dz[idx], radius, z, eff_spacing_m)
        if s is not None:
            h = h + terrace_v(z["amplitude_m"] * s, z["terrace_step_m"], z["terrace_width"])
        total[idx] += env[idx] * h
    for rd in (f for f in features if f["kind"] == "ridge"):
        if eff_spacing_m >= rd["width_m"]:
            continue
        total += ridge_height_v(lon, lat, dx, dy, dz, radius, rd)
    return total


# ── Grid ───────────────────────────────────────────────────────────────────────
def cluster_boxes(features, radius_m, pad_m):
    """Groups of features whose boxes (grown by pad_m) overlap, as
    [(box, [feature, …]), …] — one grid each, so scattered massifs do not ask
    for one planet-wide grid, and overlapping ones are summed on the same grid."""
    m_per_deg = radius_m * math.pi / 180.0
    groups = []
    for f in features:
        # A zone adds nothing outside its ring, a ridge nothing outside its reject box.
        lo0, lo1, la0, la1 = f["bbox"]
        pad_lat = pad_m / m_per_deg
        clat = max(math.cos(math.radians(min(max(abs(la0), abs(la1)), 89.5))), 0.05)
        box = [lo0 - pad_lat / clat, lo1 + pad_lat / clat, la0 - pad_lat, la1 + pad_lat]
        groups.append([box, [f]])
    merged = True
    while merged:
        merged = False
        for i in range(len(groups)):
            for j in range(i + 1, len(groups)):
                a, b = groups[i][0], groups[j][0]
                if a[0] <= b[1] and b[0] <= a[1] and a[2] <= b[3] and b[2] <= a[3]:
                    groups[i][0] = [min(a[0], b[0]), max(a[1], b[1]),
                                    min(a[2], b[2]), max(a[3], b[3])]
                    groups[i][1].extend(groups[j][1])
                    del groups[j]
                    merged = True
                    break
            if merged:
                break
    return [(tuple(g[0]), g[1]) for g in groups]


def intersect_boxes(a, b):
    """The overlap of two (lon_min, lon_max, lat_min, lat_max) boxes, None if empty."""
    out = (max(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), min(a[3], b[3]))
    if out[0] >= out[1] or out[2] >= out[3]:
        return None
    return out


def grid_for_box(box, radius_m, spacing_m, max_samples):
    """A lon/lat sample grid over [box] at ~spacing_m (east-west spacing taken at
    the box's mid latitude), coarsened until it holds at most max_samples.
    Returns (lons[nx], lats[ny] north → south, spacing_m actually used)."""
    m_per_deg = radius_m * math.pi / 180.0
    lo0, lo1, la0, la1 = box
    clat = max(math.cos(math.radians((la0 + la1) * 0.5)), 0.05)
    width_m = (lo1 - lo0) * m_per_deg * clat
    height_m = (la1 - la0) * m_per_deg
    spacing = float(spacing_m)
    while (width_m / spacing + 1.0) * (height_m / spacing + 1.0) > max_samples:
        spacing *= 1.25
    dlat = spacing / m_per_deg
    dlon = dlat / clat
    nx = int(math.ceil((lo1 - lo0) / dlon)) + 1
    ny = int(math.ceil((la1 - la0) / dlat)) + 1
    lons = lo0 + dlon * np.arange(nx)
    lats = la1 - dlat * np.arange(ny)
    return lons, lats, spacing


def evaluate_grid(lons, lats, radius_m, features, eff_spacing_m, ground=None, progress=None):
    """Offset (m) on the grid, shape (len(lats), len(lons)), row 0 = north.
    [ground] — optional callable (lon[], lat[]) -> base height (m) added."""
    glon, glat = np.meshgrid(lons, lats)
    flon = glon.ravel()
    flat = glat.ravel()
    out = np.empty(flon.shape)
    n = flon.size
    for start in range(0, n, BATCH):
        sl = slice(start, min(start + BATCH, n))
        h = offset_v(flon[sl], flat[sl], radius_m, features, eff_spacing_m)
        if ground is not None:
            h = h + ground(flon[sl], flat[sl])
        out[sl] = h
        if progress is not None:
            progress(min(start + BATCH, n), n)
    return out.reshape(glon.shape)


def bilinear_equirect(array, geotransform, lon, lat):
    """Bilinear read of a north-up lon/lat raster (GDAL geotransform), the
    longitude wrapped, the latitude clamped to the raster."""
    h, w = array.shape
    x0, px_w, _, y0, _, px_h = geotransform
    fx = (np.mod(lon - x0, 360.0) / px_w) - 0.5
    fy = ((lat - y0) / px_h) - 0.5
    fy = np.clip(fy, 0.0, h - 1.0)
    ix = np.floor(fx).astype(np.int64)
    iy = np.minimum(np.floor(fy).astype(np.int64), h - 2) if h > 1 else np.zeros_like(fx, np.int64)
    tx = fx - ix
    ty = fy - iy
    ix0 = np.mod(ix, w)
    ix1 = np.mod(ix + 1, w)
    iy1 = np.minimum(iy + 1, h - 1)
    a = array[iy, ix0] * (1.0 - tx) + array[iy, ix1] * tx
    b = array[iy1, ix0] * (1.0 - tx) + array[iy1, ix1] * tx
    return a * (1.0 - ty) + b * ty
