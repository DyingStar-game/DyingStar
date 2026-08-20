"""
Geometry for the terrain-modifier export: tile assignment, clipping, decimation.

Two DIFFERENT assignment strategies live here, and picking the wrong one for a
kind reintroduces the very bug this pipeline exists to kill.

  ── Exact pixel partition (ROAD) ─────────────────────────────────────────
  A road is standalone geometry: planet_chunk.gd extrudes a ribbon straight
  from the centerline it is given. If two tiles both carried the same stretch
  of road, two chunks would both extrude it — and because each chunk samples
  terrain height at its own pyramid level, the two ribbons would sit at
  different altitudes. That is exactly the "two roads, one 2 m above the other"
  bug. So roads are PARTITIONED: every point of a road belongs to exactly one
  pixel, pieces are split at the pixel boundary, and the two pieces meeting at
  a boundary share a bit-identical vertex. Union of all tiles == the original
  road, once.

  ── Influence-margin duplication (CRATER, RADIAL, LINEAR, POPULATE) ──────
  These DISPLACE terrain: a crater whose centre is in the next pixel still
  pushes vertices down inside this one. A tile must therefore carry every
  feature that can move any of its vertices, so features are written into every
  tile their influence radius reaches, deliberately duplicated. Because both
  tiles get the same bytes, the displacement agrees across the seam — which is
  what lets PlanetData.get_chunk_craters() drop its 8-neighbour merge.

Pure stdlib + numpy + healpix_utils, no QGIS import, so it is unit-testable
with plain python3 (test/unit/test_modifier_pack_py.py).
"""
import math
import os
import sys

try:
    import healpix_utils as hpx
except ImportError:  # pragma: no cover - depends on how the caller set sys.path
    _tools_dir = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", ".."))
    if _tools_dir not in sys.path:
        sys.path.insert(0, _tools_dir)
    import healpix_utils as hpx


#: Deepest nside each kind is baked at, expressed as a rule rather than a
#: constant because it depends on the planet. See level_policy().
#:
#: ROAD must reach max_quadtree_depth: chunks finer than the deepest baked level
#: share an ancestor tile, and a shared tile means a shared road, which is the
#: doubling bug again. LINEAR goes deep purely for cost (a clipped river piece
#: is ~10 points instead of ~1000 per vertex test). CRATER / RADIAL / POPULATE
#: stay at export_nside: they are point and polygon QUERIES, never emitted
#: geometry, so there is no doubling risk — and baking a biome polygon that
#: covers a quarter of a planet down to n8192 would need ~200 million tiles.
_DEEP_KINDS = ("road", "linear")

#: One unit of the packed i32 coordinate encoding (dsmp.COORD_SCALE), ~1.1 cm.
#: Clipping finer than this is meaningless — the value would not survive the
#: round trip through the pack.
COORD_QUANTUM_DEG = 1.0e-7


def level_policy(export_nside, max_quadtree_nside, min_nside=1):
    """{kind: {"min": nside, "max": nside}} for this planet."""
    out = {}
    for kind in ("crater", "linear", "radial", "populate", "road"):
        deep = kind in _DEEP_KINDS
        out[kind] = {
            "min": min_nside,
            "max": int(max_quadtree_nside if deep else export_nside),
        }
    return out


def levels_for(policy_entry):
    """Ascending powers of two from min to max, inclusive."""
    out = []
    ns = int(policy_entry["min"])
    top = int(policy_entry["max"])
    while ns <= top:
        out.append(ns)
        ns *= 2
    return out


# ── Scale helpers ───────────────────────────────────────────────────────

def pixel_side_m(nside, radius_m):
    """Side of a HEALPix pixel in metres: R x sqrt(pi/3) / nside."""
    return radius_m * math.sqrt(math.pi / 3.0) / float(nside)


def pixel_side_deg(nside):
    return math.degrees(math.sqrt(math.pi / 3.0) / float(nside))


def m_per_deg(radius_m):
    return radius_m * math.pi / 180.0


def decim_eps_m(nside, radius_m, influence_r_m, res_max=32):
    """Douglas-Peucker tolerance in metres for [nside].

    Two terms, and the second one matters: a chunk's vertex spacing at n8192 is
    ~25 m while road centerlines are sampled every ~11 m, so tolerating a
    quarter of the vertex spacing alone (6 m) would already visibly flatten
    curves on a 6 m wide road. Clamping to half the feature's own influence
    radius keeps the deviation under half a ribbon width, which is invisible.
    """
    vertex_spacing = pixel_side_m(nside, radius_m) / float(max(res_max, 1))
    eps = 0.25 * vertex_spacing
    if influence_r_m and influence_r_m > 0.0:
        eps = min(eps, 0.5 * influence_r_m)
    return max(eps, 0.0)


# ── Cumulative length ───────────────────────────────────────────────────

def cumulative_lengths(points, mpd):
    """[(lon, lat), …] -> [cumulative metres], cos(lat)-corrected."""
    cum = [0.0]
    for i in range(1, len(points)):
        lon0, lat0 = points[i - 1][0], points[i - 1][1]
        lon1, lat1 = points[i][0], points[i][1]
        clat = math.cos(math.radians(0.5 * (lat0 + lat1)))
        dx = (lon1 - lon0) * clat * mpd
        dy = (lat1 - lat0) * mpd
        cum.append(cum[-1] + math.hypot(dx, dy))
    return cum


def with_cumulative(points, mpd):
    """[(lon, lat), …] -> [(lon, lat, cum_m), …] starting at 0."""
    cum = cumulative_lengths(points, mpd)
    return [(p[0], p[1], cum[i]) for i, p in enumerate(points)]


# ── Douglas-Peucker ─────────────────────────────────────────────────────

def douglas_peucker(points, eps_deg, lat_scale=None):
    """Decimate [(lon, lat, along), …], PINNING both endpoints.

    Endpoints are pinned because on a partitioned road they ARE the pixel
    boundary crossings: moving one would open a gap between two chunks that must
    meet exactly. The `along` value rides along on surviving vertices and is
    never recomputed — it refers to the unclipped parent feature.

    Longitude is scaled by cos(lat) so the tolerance is metric-ish rather than
    degrees-of-longitude, which shrink towards the poles.
    """
    n = len(points)
    if n <= 2 or eps_deg <= 0.0:
        return list(points)
    if lat_scale is None:
        lat_scale = math.cos(math.radians(
            0.5 * (points[0][1] + points[-1][1]))) or 1e-6

    keep = [False] * n
    keep[0] = True
    keep[n - 1] = True
    stack = [(0, n - 1)]
    while stack:
        i0, i1 = stack.pop()
        if i1 <= i0 + 1:
            continue
        ax = points[i0][0] * lat_scale
        ay = points[i0][1]
        bx = points[i1][0] * lat_scale
        by = points[i1][1]
        dx = bx - ax
        dy = by - ay
        seg_sq = dx * dx + dy * dy
        best_d = -1.0
        best_i = -1
        for i in range(i0 + 1, i1):
            px = points[i][0] * lat_scale
            py = points[i][1]
            if seg_sq <= 1e-24:
                d = math.hypot(px - ax, py - ay)
            else:
                t = ((px - ax) * dx + (py - ay) * dy) / seg_sq
                t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
                d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if d > best_d:
                best_d = d
                best_i = i
        if best_d > eps_deg:
            keep[best_i] = True
            stack.append((i0, best_i))
            stack.append((best_i, i1))
    return [points[i] for i in range(n) if keep[i]]


# ── Pixel lookup ────────────────────────────────────────────────────────

def pix_of(nside, lon, lat):
    """HEALPix NESTED pixel containing (lon, lat), in healpix_utils' convention."""
    lat_r = math.radians(lat)
    lon_r = math.radians(lon)
    clat = math.cos(lat_r)
    return int(hpx.vec2pix_nest(
        nside, clat * math.cos(lon_r), math.sin(lat_r), clat * math.sin(lon_r)))


def dilate(nside, pixels, rings=1):
    """Grow a pixel set by [rings] rings of HEALPix neighbours."""
    out = set(pixels)
    for _ in range(max(rings, 0)):
        grown = set(out)
        for p in out:
            grown.update(hpx.get_neighbor_pixels(nside, p))
        if grown == out:
            break
        out = grown
    return out


def _rings_for(nside, radius_m, influence_m):
    """How many neighbour rings cover [influence_m] at this level."""
    side = pixel_side_m(nside, radius_m)
    if side <= 0.0 or influence_m <= 0.0:
        return 0
    return int(math.ceil(influence_m / side))


def _lonlat_dist_to_bbox_m(lon, lat, box, radius_m):
    """Shortest distance from a point to a lon/lat box, in metres. 0 when inside."""
    lon_min, lon_max, lat_min, lat_max = box
    dlon = max(lon_min - lon, 0.0, lon - lon_max)
    dlat = max(lat_min - lat, 0.0, lat - lat_max)
    mpd = m_per_deg(radius_m)
    clat = math.cos(math.radians(max(-89.5, min(89.5, lat))))
    return math.hypot(dlon * clat * mpd, dlat * mpd)


def tiles_for_point(nside, lon, lat, influence_m, radius_m):
    """Tiles a point feature with an influence radius can affect.

    Dilation works in whole neighbour rings, so a 20 m crater would otherwise
    land in all 9 tiles around it. The bbox distance test prunes that back to
    the tiles the influence really reaches. It can only ever REMOVE tiles the
    feature could not affect, never the ones it can.
    """
    candidates = dilate(nside, {pix_of(nside, lon, lat)},
                        _rings_for(nside, radius_m, influence_m))
    if len(candidates) <= 1:
        return candidates
    home = pix_of(nside, lon, lat)
    out = set()
    for p in candidates:
        if p == home or _lonlat_dist_to_bbox_m(
                lon, lat, tile_bbox(nside, p), radius_m) <= influence_m:
            out.add(p)
    return out


def _densify(points, step_deg):
    """Insert intermediate samples so no gap exceeds [step_deg]."""
    if len(points) < 2 or step_deg <= 0.0:
        return list(points)
    out = [points[0]]
    for i in range(1, len(points)):
        a = points[i - 1]
        b = points[i]
        d = math.hypot(b[0] - a[0], b[1] - a[1])
        n = int(math.ceil(d / step_deg))
        for j in range(1, n):
            t = float(j) / n
            out.append(tuple(a[k] + (b[k] - a[k]) * t for k in range(len(a))))
        out.append(b)
    return out


def tiles_for_polyline(nside, points, influence_m, radius_m):
    """Tiles a linear feature with an influence radius can affect."""
    samples = _densify(points, 0.5 * pixel_side_deg(nside))
    seeds = {pix_of(nside, p[0], p[1]) for p in samples}
    return dilate(nside, seeds, _rings_for(nside, radius_m, influence_m))


def tiles_for_polygon(nside, ring, influence_m, radius_m):
    """Tiles a polygon (its boundary AND interior) can affect."""
    step = 0.5 * pixel_side_deg(nside)
    closed = list(ring) + [ring[0]]
    seeds = {pix_of(nside, p[0], p[1]) for p in _densify(closed, step)}
    lons = [p[0] for p in ring]
    lats = [p[1] for p in ring]
    lon0, lon1 = min(lons), max(lons)
    lat0, lat1 = min(lats), max(lats)
    ny = max(int(math.ceil((lat1 - lat0) / step)), 1)
    nx = max(int(math.ceil((lon1 - lon0) / step)), 1)
    # Cap the interior sampling grid: a whole-planet biome would otherwise
    # sample forever. Above the cap the boundary seeds plus dilation still give
    # a superset, and clipping drops anything that does not really overlap.
    if nx * ny <= 4_000_000:
        for iy in range(ny + 1):
            lat = lat0 + (lat1 - lat0) * iy / ny
            for ix in range(nx + 1):
                lon = lon0 + (lon1 - lon0) * ix / nx
                if point_in_ring(lon, lat, ring):
                    seeds.add(pix_of(nside, lon, lat))
    return dilate(nside, seeds, _rings_for(nside, radius_m, influence_m))


def point_in_ring(lon, lat, ring):
    """Ray-casting point-in-polygon, matching PlanetChunk._point_in_polygon_lonlat."""
    n = len(ring)
    if n < 3:
        return False
    inside = False
    j = n - 1
    for i in range(n):
        yi = ring[i][1]
        yj = ring[j][1]
        if (yi > lat) != (yj > lat):
            x = (ring[j][0] - ring[i][0]) * (lat - yi) / (yj - yi) + ring[i][0]
            if lon < x:
                inside = not inside
        j = i
    return inside


# ── Exact pixel partition (roads) ───────────────────────────────────────

def _boundary_split(nside, a, b, pa, pb, tol_deg):
    """Bisect segment a->b for the point where the pixel changes from pa to pb.

    Returns the interpolated (lon, lat, along) on the boundary. Both sides of
    the split compute it from the SAME endpoints with the same tolerance, so
    the two pieces share a bit-identical vertex and no gap can open.
    """
    lo, hi = 0.0, 1.0
    for _ in range(60):
        if math.hypot((b[0] - a[0]) * (hi - lo), (b[1] - a[1]) * (hi - lo)) <= tol_deg:
            break
        mid = 0.5 * (lo + hi)
        pm = pix_of(nside,
                    a[0] + (b[0] - a[0]) * mid,
                    a[1] + (b[1] - a[1]) * mid)
        if pm == pa:
            lo = mid
        elif pm == pb:
            hi = mid
        else:
            # A third pixel in between (a corner crossing): treat it as the
            # far side so the walk keeps making progress.
            hi = mid
            pb = pm
    t = 0.5 * (lo + hi)
    return tuple(a[k] + (b[k] - a[k]) * t for k in range(len(a)))


def partition_polyline(nside, points, tol_deg=None):
    """Split [(lon, lat, along), …] into per-pixel pieces with NO duplication.

    Returns {ipix: [piece, …]} where each piece is a list of >= 2 points. A
    feature that leaves and re-enters a pixel yields several pieces for it.

    Every input point lands in exactly one piece, and each boundary crossing
    adds one shared vertex to the two pieces that meet there — so concatenating
    all pieces reproduces the input polyline exactly once. This is what makes
    it impossible for two chunks to draw the same stretch of road.
    """
    if len(points) < 2:
        return {}
    if tol_deg is None:
        # The coordinate quantum (1e-7 deg, ~1.1 cm) — the finest the format can
        # represent. A tolerance scaled to the pixel size instead would leave
        # ~10 m of slack at n64: two adjacent chunks would disagree by that much
        # about where the road is cut, opening a visible gap or overlap at the
        # seam, and the same road would measure differently at different levels.
        tol_deg = COORD_QUANTUM_DEG
    step = 0.25 * pixel_side_deg(nside)
    dense = _densify(points, step)

    out = {}
    cur_pix = pix_of(nside, dense[0][0], dense[0][1])
    cur = [dense[0]]
    for i in range(1, len(dense)):
        p = dense[i]
        pix = pix_of(nside, p[0], p[1])
        if pix == cur_pix:
            cur.append(p)
            continue
        cut = _boundary_split(nside, dense[i - 1], p, cur_pix, pix, tol_deg)
        cur.append(cut)
        if len(cur) >= 2:
            out.setdefault(cur_pix, []).append(cur)
        cur_pix = pix
        cur = [cut, p]
    if len(cur) >= 2:
        out.setdefault(cur_pix, []).append(cur)
    return out


# ── Clipping to a tile bbox (margin-based kinds) ────────────────────────

def tile_bbox(nside, ipix, margin_deg=0.0):
    return hpx.get_tile_lonlat_bbox(nside, ipix, margin_deg=margin_deg)


def _inside(p, edge, box):
    lon_min, lon_max, lat_min, lat_max = box
    if edge == 0:
        return p[0] >= lon_min
    if edge == 1:
        return p[0] <= lon_max
    if edge == 2:
        return p[1] >= lat_min
    return p[1] <= lat_max


def _intersect(a, b, edge, box):
    lon_min, lon_max, lat_min, lat_max = box
    if edge in (0, 1):
        x = lon_min if edge == 0 else lon_max
        t = 0.0 if b[0] == a[0] else (x - a[0]) / (b[0] - a[0])
    else:
        y = lat_min if edge == 2 else lat_max
        t = 0.0 if b[1] == a[1] else (y - a[1]) / (b[1] - a[1])
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return tuple(a[k] + (b[k] - a[k]) * t for k in range(len(a)))


def clip_polyline_to_bbox(points, box):
    """Split a polyline at a lon/lat box, keeping the inside pieces.

    Extra tuple slots (the `along` value) are interpolated at every cut, never
    recomputed — see dsmp.py on why cum_length_m must stay parent-relative.
    """
    lon_min, lon_max, lat_min, lat_max = box

    def contains(p):
        return lon_min <= p[0] <= lon_max and lat_min <= p[1] <= lat_max

    pieces = []
    cur = []
    for i in range(len(points)):
        p = points[i]
        if contains(p):
            if not cur and i > 0:
                # Entering: start on the boundary.
                cur.append(_clip_entry(points[i - 1], p, box))
            cur.append(p)
        else:
            if cur:
                cur.append(_clip_entry(p, points[i - 1], box))
                if len(cur) >= 2:
                    pieces.append(cur)
                cur = []
            elif i > 0 and _segment_crosses(points[i - 1], p, box):
                seg = _clip_segment(points[i - 1], p, box)
                if seg:
                    pieces.append(seg)
    if len(cur) >= 2:
        pieces.append(cur)
    return pieces


def _clip_entry(outside, inside, box):
    """Point where the segment outside->inside meets the box."""
    p = outside
    for edge in range(4):
        if not _inside(p, edge, box):
            p = _intersect(p, inside, edge, box)
    return p


def _segment_crosses(a, b, box):
    seg = _clip_segment(a, b, box)
    return bool(seg)


def _clip_segment(a, b, box):
    """Liang-Barsky style clip of one segment; [] when fully outside."""
    lon_min, lon_max, lat_min, lat_max = box
    t0, t1 = 0.0, 1.0
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    for p, q in ((-dx, a[0] - lon_min), (dx, lon_max - a[0]),
                 (-dy, a[1] - lat_min), (dy, lat_max - a[1])):
        if p == 0.0:
            if q < 0.0:
                return []
            continue
        t = q / p
        if p < 0.0:
            if t > t1:
                return []
            if t > t0:
                t0 = t
        else:
            if t < t0:
                return []
            if t < t1:
                t1 = t
    if t1 <= t0:
        return []
    lerp = lambda t: tuple(a[k] + (b[k] - a[k]) * t for k in range(len(a)))
    return [lerp(t0), lerp(t1)]


def clip_polygon_to_bbox(ring, box):
    """Sutherland-Hodgman clip of a ring to a lon/lat box. [] when disjoint."""
    out = list(ring)
    for edge in range(4):
        if not out:
            return []
        src = out
        out = []
        prev = src[-1]
        prev_in = _inside(prev, edge, box)
        for cur in src:
            cur_in = _inside(cur, edge, box)
            if cur_in:
                if not prev_in:
                    out.append(_intersect(prev, cur, edge, box))
                out.append(cur)
            elif prev_in:
                out.append(_intersect(prev, cur, edge, box))
            prev, prev_in = cur, cur_in
    return out
