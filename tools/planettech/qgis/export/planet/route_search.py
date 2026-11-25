"""A road route over a terrain grid that keeps to a max grade — numpy + scipy, no QGIS.

The terrain is a zone terrain grid (terrain_grid.Grid, row 0 north). Each node links to its 16
neighbours — the 8 around it and the 8 knight's moves, whose headings (26.6° apart) let a route
cross a slope at a gentle grade, which is what a hairpin road does. A step costs its length in
metres while its grade stays under the max; past it, the length times
    1 + structure_weight × (grade / max_grade − 1)
— the cutting, tunnel or viaduct the game would build there, priced by how far over the grade it
is. So climbing a hillside in bends is cheaper than straight up it, and a cliff is crossed by a
structure only when no bend can avoid it. A node over a corundum chasm adds crack_weight ×
length (a bridge). The cheapest path between consecutive waypoints is scipy's Dijkstra on that
graph (C speed: a Python priority queue would take minutes on a few hundred thousand nodes).

The grid is first cut to a corridor round the waypoints, then subsampled until it holds at most
max_nodes: the route's resolution is the cell it ends up with (reported). The road the game
builds is then checked by its longitudinal profile (grade_profile.py) — the search only prices
grades between neighbouring nodes, not the 200 m windows of the profile.
"""
import math

import numpy as np

from . import grade_profile as gp
from . import modifier_geom
from . import terrain_grid as tg

#: The 8 forward offsets (dy, dx); the graph is undirected, so these give all 16 neighbours.
OFFSETS = ((0, 1), (1, 0), (1, 1), (1, -1), (1, 2), (2, 1), (1, -2), (2, -1))


class NoRoute(RuntimeError):
    pass


def corridor(grid, waypoints, margin_m, radius_m):
    """(row0, row1, col0, col1) of the grid nodes within margin_m of the waypoints' box."""
    lons = [p[0] for p in waypoints]
    lats = [p[1] for p in waypoints]
    m_per_deg = radius_m * math.pi / 180.0
    clat = max(math.cos(math.radians(sum(lats) / len(lats))), 0.05)
    dlat = margin_m / m_per_deg
    dlon = dlat / clat
    c0 = int(math.floor((min(lons) - dlon - grid.lon0) / grid.dlon))
    c1 = int(math.ceil((max(lons) + dlon - grid.lon0) / grid.dlon))
    r0 = int(math.floor((grid.lat_top - (max(lats) + dlat)) / grid.dlat))
    r1 = int(math.ceil((grid.lat_top - (min(lats) - dlat)) / grid.dlat))
    return (max(r0, 0), min(r1, grid.ny - 1), max(c0, 0), min(c1, grid.nx - 1))


def plan(z, grid, radius_m, waypoints, max_grade, structure_weight=6.0, cracks=None,
         crack_weight=4.0, max_nodes=1_000_000, margin_m=None, avoid=None):
    """The route through [waypoints] [(lon, lat), …] over heights z[ny, nx] on [grid].
    [avoid]: an extra cost per metre on each node (same shape as z), how plan_with_limits keeps
    the search away from a structure it found too long.

    Returns {line: [(lon, lat), …] (the waypoints themselves at both ends), length_m, cost,
    cell_m, steep_share (length share of steps past the grade), nodes}. Raises NoRoute."""
    if len(waypoints) < 2:
        raise NoRoute("a start and an end are needed")
    if max_grade <= 0.0:
        raise NoRoute("the max grade must be positive")
    span = max(_dist_m(waypoints[i], waypoints[i + 1], radius_m)
               for i in range(len(waypoints) - 1))
    margin = margin_m if margin_m is not None else max(2000.0, 0.6 * span)
    r0, r1, c0, c1 = corridor(grid, waypoints, margin, radius_m)
    for p in waypoints:
        if not (grid.lon0 <= p[0] <= grid.lon0 + grid.dlon * (grid.nx - 1)
                and grid.lat_top - grid.dlat * (grid.ny - 1) <= p[1] <= grid.lat_top):
            raise NoRoute("a point is outside the zone terrain: compute it over the whole route")
    ny, nx = r1 - r0 + 1, c1 - c0 + 1
    k = max(1, int(math.ceil(math.sqrt(ny * nx / float(max_nodes)))))
    zz = np.asarray(z, dtype=np.float64)[r0:r1 + 1:k, c0:c1 + 1:k]
    cr = None if cracks is None else np.asarray(cracks, dtype=np.float64)[r0:r1 + 1:k, c0:c1 + 1:k]
    av = None if avoid is None else np.asarray(avoid, dtype=np.float64)[r0:r1 + 1:k, c0:c1 + 1:k]
    sub = tg.Grid(grid.lon0 + c0 * grid.dlon, grid.dlon * k, zz.shape[1],
                  grid.lat_top - r0 * grid.dlat, grid.dlat * k, zz.shape[0])
    graph = _graph(zz, sub, radius_m, max_grade, structure_weight, cr, crack_weight, av)
    nodes = [_nearest(sub, p) for p in waypoints]
    from scipy.sparse.csgraph import dijkstra
    path = [nodes[0]]
    cost = 0.0
    for a, b in zip(nodes, nodes[1:]):
        dist, pred = dijkstra(graph, directed=False, indices=a, return_predecessors=True)
        if not np.isfinite(dist[b]):
            raise NoRoute("no route between two points (no data between them?)")
        cost += float(dist[b])
        leg = [b]
        while leg[-1] != a:
            leg.append(int(pred[leg[-1]]))
        path.extend(reversed(leg[:-1]))
    rows, cols = np.divmod(np.array(path), sub.nx)
    line = [(float(sub.lon0 + c * sub.dlon), float(sub.lat_top - r * sub.dlat))
            for r, c in zip(rows, cols)]
    line[0] = tuple(waypoints[0])
    line[-1] = tuple(waypoints[-1])
    cell_m = sub.dlat * math.pi / 180.0 * radius_m
    line = simplify(line, 0.5 * cell_m, radius_m)
    steep_share = _steep_share(path, zz, sub, radius_m, max_grade)
    return {"line": line, "length_m": _length_m(line, radius_m), "cost": cost, "cell_m": cell_m,
            "steep_share": steep_share, "nodes": sub.nx * sub.ny}


def _graph(z, grid, radius_m, max_grade, w, cracks, crack_weight, avoid=None):
    """Sparse symmetric cost matrix of the 16-neighbour graph."""
    from scipy.sparse import coo_matrix
    ny, nx = z.shape
    idx = np.arange(ny * nx).reshape(ny, nx)
    dx_row = _dx_row(grid, radius_m)
    dy_m = math.radians(grid.dlat) * radius_m
    src, dst, cost = [], [], []
    for dy, dx in OFFSETS:
        cs = slice(max(0, -dx), nx - max(0, dx))
        cd = slice(cs.start + dx, cs.stop + dx)
        rs = slice(0, ny - dy)
        rd = slice(dy, ny)
        za = z[rs, cs]
        zb = z[rd, cd]
        dxm = 0.5 * (dx_row[rs] + dx_row[rd])[:, None] * abs(dx)
        length = np.hypot(dxm, dy * dy_m) * np.ones_like(za)
        over = np.maximum(np.abs(zb - za) / length / max_grade - 1.0, 0.0)
        c = length * (1.0 + w * over)
        if cracks is not None:
            crack = (cracks[rs, cs] > 0.0) | (cracks[rd, cd] > 0.0)
            c = c + np.where(crack, crack_weight * length, 0.0)
        if avoid is not None:
            c = c + length * 0.5 * (avoid[rs, cs] + avoid[rd, cd])
        ok = np.isfinite(c)
        src.append(idx[rs, cs][ok])
        dst.append(idx[rd, cd][ok])
        cost.append(c[ok])
    n = ny * nx
    return coo_matrix((np.concatenate(cost), (np.concatenate(src), np.concatenate(dst))),
                      shape=(n, n)).tocsr()


def _dx_row(grid, radius_m):
    """East-west metres of one column step, per row."""
    return np.radians(grid.dlon) * radius_m * np.maximum(np.cos(np.radians(grid.lats)), 1e-6)


def _steep_share(path, z, grid, radius_m, max_grade):
    """Length share of the path's steps whose grade is past the max."""
    rows, cols = np.divmod(np.asarray(path), grid.nx)
    dx_row = _dx_row(grid, radius_m)
    dy_m = math.radians(grid.dlat) * radius_m
    total = steep = 0.0
    for i in range(len(path) - 1):
        r0, c0, r1, c1 = rows[i], cols[i], rows[i + 1], cols[i + 1]
        length = math.hypot(0.5 * (dx_row[r0] + dx_row[r1]) * (c1 - c0), dy_m * (r1 - r0))
        total += length
        if abs(z[r1, c1] - z[r0, c0]) > max_grade * length:
            steep += length
    return steep / total if total > 0 else 0.0


def _nearest(grid, p):
    c = int(round((p[0] - grid.lon0) / grid.dlon))
    r = int(round((grid.lat_top - p[1]) / grid.dlat))
    c = min(max(c, 0), grid.nx - 1)
    r = min(max(r, 0), grid.ny - 1)
    return r * grid.nx + c


def _dist_m(a, b, radius_m):
    clat = math.cos(math.radians(0.5 * (a[1] + b[1])))
    m = radius_m * math.pi / 180.0
    return math.hypot((b[0] - a[0]) * clat * m, (b[1] - a[1]) * m)


def _length_m(line, radius_m):
    return sum(_dist_m(line[i], line[i + 1], radius_m) for i in range(len(line) - 1))


def simplify(line, tol_m, radius_m):
    """Douglas-Peucker in local metres; keeps both ends."""
    if len(line) < 3:
        return list(line)
    lat0 = sum(p[1] for p in line) / len(line)
    m = radius_m * math.pi / 180.0
    clat = math.cos(math.radians(lat0))
    pts = [((p[0] - line[0][0]) * clat * m, (p[1] - line[0][1]) * m) for p in line]
    keep = [False] * len(line)
    keep[0] = keep[-1] = True
    stack = [(0, len(line) - 1)]
    while stack:
        i, j = stack.pop()
        (x0, y0), (x1, y1) = pts[i], pts[j]
        dx, dy = x1 - x0, y1 - y0
        norm = math.hypot(dx, dy) or 1e-12
        best, at = -1.0, -1
        for k in range(i + 1, j):
            d = abs(dy * (pts[k][0] - x0) - dx * (pts[k][1] - y0)) / norm
            if d > best:
                best, at = d, k
        if at >= 0 and best > tol_m:
            keep[at] = True
            stack.append((i, at))
            stack.append((at, j))
    return [p for p, k in zip(line, keep) if k]


# ── Structure lengths ─────────────────────────────────────────────────────────
def profile_over_grid(line, z, grid, radius_m, max_grade, climb=True):
    """The game's longitudinal profile (grade_profile.py) of [line] over the grid's terrain, the
    along-distance as the road exporter measures it. None when too short; NaN stations when the
    line leaves the grid."""
    mpd = radius_m * math.pi / 180.0
    cum = modifier_geom.cumulative_lengths(line, mpd)
    stations = gp.station_alongs(cum[0], cum[-1])
    ll = np.array([gp.lonlat_at(line, cum, a) for a in stations])
    st = tg.bilinear(z, grid, ll[:, 0], ll[:, 1])

    def terrain(along):
        lon, lat = gp.lonlat_at(line, cum, along)
        return float(tg.bilinear(z, grid, np.array([lon]), np.array([lat]))[0])
    prof = gp.compute(cum[0], cum[-1], terrain, max_grade, climb,
                      stations_terrain=[float(v) for v in st])
    if prof is not None:
        prof["cum"] = cum
    return prof


def overlong(profile, max_bridge_m=0.0, max_tunnel_m=0.0):
    """The viaducts longer than max_bridge_m and the tunnels longer than max_tunnel_m (0 = no
    limit) of a profile: [segment, …] with its `kind`, `lo`, `hi`."""
    out = []
    for s in profile["segments"]:
        length = s["hi"] - s["lo"]
        if s["kind"] == gp.BRIDGE and max_bridge_m > 0 and length > max_bridge_m:
            out.append(s)
        elif s["kind"] == gp.TUNNEL and max_tunnel_m > 0 and length > max_tunnel_m:
            out.append(s)
    return out


def plan_with_limits(z, grid, radius_m, waypoints, max_grade, max_bridge_m=0.0,
                     max_tunnel_m=0.0, climb=True, tries=6, avoid_cost=40.0, **kw):
    """plan(), then the game's profile of the result; while a viaduct or a tunnel is longer than
    its max, the nodes under it (and a band of a few cells round them) get [avoid_cost] per metre
    more and the search runs again, in a corridor 1.5× wider each time — the route goes round the
    valley head or up the ridge in bends instead. A viaduct marks the whole depression it spans
    (every node under its deck connected to it), so the next search does not bridge the same
    canyon a little further along. At most [tries] searches; the one with the least overlong
    length is kept.

    Returns plan()'s dict plus `profile`, `overlong` (what is still too long) and `tries`."""
    avoid = np.zeros(np.shape(z))
    best = None
    margin = kw.pop("margin_m", None)
    if margin is None:
        span = max(_dist_m(waypoints[i], waypoints[i + 1], radius_m)
                   for i in range(len(waypoints) - 1))
        margin = max(2000.0, 0.6 * span)
    for n in range(1, tries + 1):
        # A wider corridor at each try: the way round may be past the first one.
        route = plan(z, grid, radius_m, waypoints, max_grade, avoid=avoid,
                     margin_m=margin * 1.5 ** (n - 1), **kw)
        prof = profile_over_grid(route["line"], z, grid, radius_m, max_grade, climb)
        bad = overlong(prof, max_bridge_m, max_tunnel_m) if prof is not None else []
        excess = sum(s["hi"] - s["lo"] for s in bad)
        route.update(profile=prof, overlong=bad, tries=n)
        if best is None or excess < best[0]:
            best = (excess, route)
        if not bad:
            break
        mask = np.zeros(np.shape(z), dtype=bool)
        for s in bad:
            band = max(3.0 * route["cell_m"], 150.0, 0.5 * (s["hi"] - s["lo"]))
            near = np.zeros_like(mask)
            _mark(near, grid, route["line"], prof["cum"], s["lo"], s["hi"], band, radius_m)
            if s["kind"] == gp.BRIDGE:
                near |= _depression(z, near, prof, s)
            mask |= near
        avoid[mask] += avoid_cost
    return best[1]


def _depression(z, near, prof, seg):
    """The nodes lower than the viaduct's deck and connected to those under it: the whole valley
    or canyon it spans, so the next search does not just bridge it a little further along."""
    from scipy import ndimage
    ka, kz = prof["knots_along"], prof["knots_z"]
    deck = max(gp.z_track_at(ka, kz, seg["lo"]), gp.z_track_at(ka, kz, seg["hi"]))
    low = np.asarray(z) < deck - gp.BED_THICKNESS_M
    labels, _n = ndimage.label(low)
    hit = np.unique(labels[near & low])
    hit = hit[hit > 0]
    return np.isin(labels, hit) if hit.size else np.zeros_like(near)


def _mark(mask, grid, line, cum, lo, hi, band_m, radius_m):
    """Mark the nodes within ~band_m of the line between along lo and hi."""
    m_per_deg = radius_m * math.pi / 180.0
    step = max(0.5 * band_m, 10.0)
    a = lo
    while a <= hi + 1e-6:
        lon, lat = gp.lonlat_at(line, cum, a)
        dlat = band_m / m_per_deg
        dlon = dlat / max(math.cos(math.radians(lat)), 0.05)
        c0 = max(int(math.floor((lon - dlon - grid.lon0) / grid.dlon)), 0)
        c1 = min(int(math.ceil((lon + dlon - grid.lon0) / grid.dlon)), grid.nx - 1)
        r0 = max(int(math.floor((grid.lat_top - lat - dlat) / grid.dlat)), 0)
        r1 = min(int(math.ceil((grid.lat_top - lat + dlat) / grid.dlat)), grid.ny - 1)
        if c0 <= c1 and r0 <= r1:
            mask[r0:r1 + 1, c0:c1 + 1] = True
        a += step
