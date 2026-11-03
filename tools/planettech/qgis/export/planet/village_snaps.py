"""Keep the QGIS roads out of the villages and cities, and lead them to the layouts' road snaps.

A road drawn in QGIS knows nothing of the villages Horizon spawns on top of it: it crossed village
M0002 between its buildings. Before the roads are packed (export_roads.py), every centreline is cut
where it enters a village's footprint, and each cut end runs on to the nearest snap of its kind
(a RoadSnap of the layout scene): straight to a point APPROACH_M in front of the snap, then onto it.
With no snap of its kind within MAX_REACH_M, the road simply stops at the footprint's edge.

Pure Python (no QGIS), so it is unit-tested on its own (test_village_snaps.py). Inputs:
  · Horizon's seed (horizonserver/ds_genericprops/startup_items.json): every "poi_village" entry, its
    position and rotation on the planet, its spawn_scene;
  · assets/qgis/export/layout_snaps.json (written by the game, LayoutSnaps): per layout scene, its
    footprint and its snaps, in the layout's own frame.

Frames are the game's: the planet's Y is the polar axis, a direction at (lon, lat) is
(cos lat cos lon, sin lat, −cos lat sin lon) (HEALPix.lonlat2vec), a village stands with +Y up the
radial and its heading kept (poi_villages.gd _stand_on_ground), the rotation is Godot's YXZ Euler.
"""

import json
import math

# The kind of RoadSnap each QGIS road_type joins.
KIND_OF_ROAD_TYPE = {"road": "road", "path": "path", "trail": "path", "highway": "highway",
                     "railway": "railway"}
APPROACH_M = 20.0       # the road comes straight at the snap over its last metres
MAX_REACH_M = 500.0     # farther than that, a cut end does not go looking for a snap
STEP_M = 5.0            # densify the centreline so no segment jumps over a footprint corner
RING_M = 10.0           # a lead-in runs round the footprint this far out, never through the village


# ── Frames ─────────────────────────────────────────────────────────────────

def vec_of(lon, lat):
    lo, la = math.radians(lon), math.radians(lat)
    return (math.cos(la) * math.cos(lo), math.sin(la), -math.cos(la) * math.sin(lo))


def lonlat_of(v):
    n = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)
    return [math.degrees(math.atan2(-v[2] / n, v[0] / n)), math.degrees(math.asin(max(-1.0, min(1.0, v[1] / n))))]


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _norm(a):
    n = math.sqrt(_dot(a, a))
    return (a[0] / n, a[1] / n, a[2] / n)


def _add(a, b, s=1.0):
    return (a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s)


def basis_z_from_euler(rx, ry, rz):
    """The +Z column of Godot's Basis.from_euler((rx, ry, rz)) (YXZ order: Ry · Rx · Rz)."""
    # Rz leaves +Z alone; Rx turns it to (0, −sin rx, cos rx); Ry then turns that about Y.
    z = (0.0, -math.sin(rx), math.cos(rx))
    return (math.cos(ry) * z[0] + math.sin(ry) * z[2], z[1], -math.sin(ry) * z[0] + math.cos(ry) * z[2])


class Village:
    """A village on the planet: its tangent frame, its footprint and its snaps."""

    def __init__(self, name, position, rotation, layout, radius):
        self.name = name
        self.up = _norm(position)
        self.centre = tuple(c * radius for c in self.up)  # on the sphere: footprints are flat anyway
        z = basis_z_from_euler(*rotation)
        z = _add(z, self.up, -_dot(z, self.up))
        self.z_axis = _norm(z)
        self.x_axis = _norm(_cross(self.up, self.z_axis))
        self.z_axis = _norm(_cross(self.x_axis, self.up))
        fp = layout["footprint"]
        self.cx, self.cz, self.hx, self.hz = fp["cx"], fp["cz"], fp["hx"], fp["hz"]
        self.radius = radius
        self.snaps = []  # (kind, [lon, lat] of the snap, [lon, lat] of its approach point, name)
        for s in layout.get("snaps", []):
            p, f = s["position"], s["forward"]
            self.snaps.append((s["kind"], self.lonlat_at(p[0], p[2]),
                               self.lonlat_at(p[0] + f[0] * APPROACH_M, p[2] + f[2] * APPROACH_M), s["name"]))

    def lonlat_at(self, x, z):
        """The [lon, lat] of the point (x, z) metres of the layout's frame."""
        p = _add(_add(self.centre, self.x_axis, x), self.z_axis, z)
        return lonlat_of(p)

    def local(self, lonlat):
        """(x, z) metres of [lon, lat] in the layout's frame (on the tangent plane)."""
        v = vec_of(*lonlat)
        p = tuple(c * self.radius for c in v)
        d = (p[0] - self.centre[0], p[1] - self.centre[1], p[2] - self.centre[2])
        return _dot(d, self.x_axis), _dot(d, self.z_axis)

    def inside(self, lonlat):
        x, z = self.local(lonlat)
        return abs(x - self.cx) <= self.hx and abs(z - self.cz) <= self.hz

    def near_segment(self, a, b, margin):
        """Does the segment a–b ([lon, lat]) pass within [margin] metres of the footprint?"""
        (ax, az), (bx, bz) = self.local(a), self.local(b)
        dx, dz = bx - ax, bz - az
        ll = dx * dx + dz * dz
        t = 0.0 if ll <= 0.0 else max(0.0, min(1.0, ((self.cx - ax) * dx + (self.cz - az) * dz) / ll))
        x, z = ax + dx * t, az + dz * t
        return abs(x - self.cx) <= self.hx + margin and abs(z - self.cz) <= self.hz + margin

    def ring(self, a, b):
        """The way round the footprint, RING_M out, from the local point [a] to [b] ((x, z) each):
        both pushed onto the ring, then the ring's corners between them, the shorter way."""
        x0, x1 = self.cx - self.hx - RING_M, self.cx + self.hx + RING_M
        z0, z1 = self.cz - self.hz - RING_M, self.cz + self.hz + RING_M
        corners = [(x0, z0), (x1, z0), (x1, z1), (x0, z1)]
        sides = [x1 - x0, z1 - z0, x1 - x0, z1 - z0]
        perim = sum(sides)

        def onto(p):
            x, z = max(x0, min(x1, p[0])), max(z0, min(z1, p[1]))
            d = [abs(z - z0), abs(x - x1), abs(z - z1), abs(x - x0)]
            side = d.index(min(d))
            q = [(x, z0), (x1, z), (x, z1), (x0, z)][side]
            along = [q[0] - x0, q[1] - z0, x1 - q[0], z1 - q[1]][side]
            return q, sum(sides[:side]) + along

        (pa, ta), (pb, tb) = onto(a), onto(b)
        at = [sum(sides[:i]) for i in range(4)]  # where each corner stands along the ring
        fwd = (tb - ta) % perim
        if fwd <= perim - fwd:  # walk forward: the corners ahead, nearest first
            ahead = sorted((((c - ta) % perim), i) for i, c in enumerate(at) if 0.0 < (c - ta) % perim < fwd)
        else:                   # walk backward
            ahead = sorted((((ta - c) % perim), i) for i, c in enumerate(at) if 0.0 < (ta - c) % perim < perim - fwd)
        out = [pa] + [corners[i] for _, i in ahead]
        out.append(pb)
        return out


def load_villages(startup_items_path, layout_snaps_path, radius):
    """The villages of Horizon's seed standing on the body of [radius] (within 50 km of it) whose
    layout has a footprint in layout_snaps.json."""
    with open(startup_items_path, encoding="utf-8") as f:
        items = json.load(f)
    with open(layout_snaps_path, encoding="utf-8") as f:
        layouts = json.load(f)
    out = []
    for it in items:
        if it.get("object_type") != "poi_village":
            continue
        od = it.get("object_data", {})
        layout = layouts.get(str(od.get("spawn_scene", "")).replace("res://", ""))
        pos = od.get("position") or {}
        rot = od.get("rotation") or {}
        p = (float(pos.get("x", 0.0)), float(pos.get("y", 0.0)), float(pos.get("z", 0.0)))
        if layout is None or abs(math.sqrt(_dot(p, p)) - radius) > 50000.0:
            continue
        r = (float(rot.get("x", 0.0)), float(rot.get("y", 0.0)), float(rot.get("z", 0.0)))
        out.append(Village(str(od.get("name", it.get("object_uuid", ""))), p, r, layout, radius))
    out.sort(key=lambda v: v.name)
    return out


# ── Re-routing ─────────────────────────────────────────────────────────────

def _m_between(a, b, m_per_deg):
    ls = math.cos(math.radians((a[1] + b[1]) * 0.5))
    return math.hypot((b[0] - a[0]) * ls, b[1] - a[1]) * m_per_deg


def _densify(line, m_per_deg):
    out = [list(line[0])]
    for a, b in zip(line, line[1:]):
        n = max(1, int(math.ceil(_m_between(a, b, m_per_deg) / STEP_M)))
        for k in range(1, n + 1):
            t = k / n
            out.append([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t])
    return out


def _village_at(villages, lonlat):
    for v in villages:
        if v.inside(lonlat):
            return v
    return None


def _edge(a, b, village):
    """The point between a (outside) and b (inside [village]) where the line crosses its edge."""
    lo, hi = list(a), list(b)
    for _ in range(30):
        mid = [(lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5]
        if village.inside(mid):
            hi = mid
        else:
            lo = mid
    return lo


def _lead_in(village, kind, at, m_per_deg):
    """From [at] (on the footprint's edge) to [village]'s nearest snap of [kind]: round the footprint
    on its ring, then out to the snap's approach point and onto the snap. [] when none is in reach."""
    best = None
    for k, snap, approach, name in village.snaps:
        if k != kind:
            continue
        d = _m_between(at, approach, m_per_deg)
        if d <= MAX_REACH_M and (best is None or (d, name) < best[0]):
            best = ((d, name), approach, snap)
    if best is None:
        return []
    _, approach, snap = best
    way = village.ring(village.local(at), village.local(approach))
    return [village.lonlat_at(x, z) for x, z in way] + [approach, snap]


def reroute(centerline, road_type, villages, m_per_deg):
    """The pieces [centerline] (a list of [lon, lat]) becomes once cut out of every village footprint,
    each cut end led to the nearest snap of its kind. A line touching no village comes back as it was."""
    kind = KIND_OF_ROAD_TYPE.get(str(road_type or "road"), "road")
    near = [v for v in villages
            if any(v.near_segment(a, b, MAX_REACH_M) for a, b in zip(centerline, centerline[1:]))]
    if not near:
        return [centerline]
    dense = _densify(centerline, m_per_deg)
    if all(_village_at(near, p) is None for p in dense):
        return [centerline]
    pieces, run = [], []
    prev_in = None  # the village the previous point stood in
    for i, p in enumerate(dense):
        v = _village_at(near, p)
        if v is None:
            if prev_in is not None:  # leaving a village: start from its snap
                run = _lead_in(prev_in, kind, _edge(p, dense[i - 1], prev_in), m_per_deg)[::-1]
                run.append(_edge(p, dense[i - 1], prev_in))
            run.append(p)
        elif prev_in is None and run:  # entering a village: end at its snap
            edge = _edge(dense[i - 1], p, v)
            run.append(edge)
            run.extend(_lead_in(v, kind, edge, m_per_deg))
            pieces.append(run)
            run = []
        prev_in = v
    if len(run) >= 2:
        pieces.append(run)
    return [r for r in pieces if len(r) >= 2]
