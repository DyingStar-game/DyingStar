"""The longitudinal profile of a grade-limited line, as the game lays it — numpy-free Python twin of
scenes/planet/road/grade_profile.gd (GradeProfile), for the QGIS road tools.

A railway, or a highway / road with `max_slope_degrees`, is laid on a profile: it starts at the
terrain's altitude, then per window of WINDOW_M it goes straight to the terrain when the max grade
allows it, else climbs toward it at the max grade (a road; a railway too, RailwaySettings
CLIMB_AT_MAX_GRADE) or stays level. Every STATION_STEP_M the terrain is compared with the line:
a tunnel where it stands TUNNEL_MIN_COVER_M or more above, a cutting above GORGE_MIN_M, a viaduct
more than BED_THICKNESS_M below, else the ground; runs too short to build are absorbed (three
hysteresis passes). Viaducts are built as decks of at most VIADUCT_MAX_SPAN_M.

Same order of operations and the same float64 arithmetic as the GDScript: on the same terrain the
two give the same knots and segments, bit for bit. grade_profile_golden.json (written by
tools/planettech/grade_profile_golden.tscn from the GDScript) pins them:
test/unit/test_grade_profile_py.py here, test/unit/test_grade_profile_golden.gd there.

Not ported: the lava flows' DESCENT rule, the deck plans, the slicing — the game's business.
"""
import bisect
import math

# GradeSettings / RailwaySettings — keep in sync (the golden file fails otherwise).
STATION_STEP_M = 5.0
WINDOW_M = 200.0
TUNNEL_MIN_COVER_M = 10.0
GORGE_MIN_M = 0.5
MIN_TUNNEL_M = 30.0
MIN_GORGE_BETWEEN_TUNNELS_M = 10.0
BED_THICKNESS_M = 2.0
MIN_SPAN_M = 24.0
VIADUCT_MAX_SPAN_M = 400.0
RAILWAY_MAX_GRADE = 0.04
RAILWAY_CLIMB_AT_MAX_GRADE = True

# GradeSettings.Kind
GROUND, GORGE, TUNNEL, BRIDGE = 0, 1, 2, 3
KIND_NAMES = {GROUND: "ground", GORGE: "gorge", TUNNEL: "tunnel", BRIDGE: "bridge"}


def _clampf(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def _lerpf(a, b, t):
    return a + (b - a) * t


# ── Which lines, which grade ──────────────────────────────────────────────────
def max_grade_of(road_type, max_slope_degrees=None):
    """GradeSettings.max_grade_of: rise / run. None for a line that is not profiled (a road
    without max_slope_degrees hugs the terrain)."""
    if road_type == "railway":
        return RAILWAY_MAX_GRADE
    if road_type in ("highway", "road") and max_slope_degrees is not None:
        return math.tan(math.radians(_clampf(float(max_slope_degrees), 0.0, 89.0)))
    return None


def climbs_at_max_grade_of(road_type):
    """GradeSettings.climbs_at_max_grade_of."""
    return RAILWAY_CLIMB_AT_MAX_GRADE if road_type == "railway" else True


# ── Geometry ──────────────────────────────────────────────────────────────────
def lonlat_at(cl, cum, along):
    """RoadBridge.lonlat_at: (lon, lat) at an along-distance, linear between the vertices."""
    n = len(cl)
    if along <= cum[0]:
        return cl[0]
    if along >= cum[n - 1]:
        return cl[n - 1]
    lo, hi = 0, n - 1
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if cum[mid] <= along:
            lo = mid
        else:
            hi = mid
    seg = cum[hi] - cum[lo]
    if seg <= 1e-9:
        return cl[lo]
    t = (along - cum[lo]) / seg
    return (_lerpf(cl[lo][0], cl[hi][0], t), _lerpf(cl[lo][1], cl[hi][1], t))


def station_alongs(a0, a1):
    """GradeProfile.station_alongs: every STATION_STEP_M, ACCUMULATED (the game's floats), a1 last."""
    out = []
    s = a0
    while s < a1 - 1e-6:
        out.append(s)
        s += STATION_STEP_M
    out.append(a1)
    return out


# ── The profile ───────────────────────────────────────────────────────────────
def knots(a0, a1, terrain, max_grade, climb):
    """GradeProfile._knots: [knots_along], [knots_z]; terrain(along) -> metres."""
    ka = [a0]
    kz = [float(terrain(a0))]
    cur = kz[0]
    s = a0
    while s < a1 - 1e-6:
        s2 = min(s + WINDOW_M, a1)
        t2 = float(terrain(s2))
        reach = max_grade * (s2 - s)
        z2 = cur
        if abs(t2 - cur) <= reach:
            z2 = t2
        elif climb:
            z2 = cur + _clampf(t2 - cur, -reach, reach)
        ka.append(s2)
        kz.append(z2)
        cur = z2
        s = s2
    return ka, kz


def z_track_at(ka, kz, along):
    """GradeProfile.z_track_at."""
    n = len(ka)
    if n == 0:
        return 0.0
    if along <= ka[0]:
        return kz[0]
    if along >= ka[n - 1]:
        return kz[n - 1]
    lo, hi = 0, n - 1
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if ka[mid] <= along:
            lo = mid
        else:
            hi = mid
    seg = ka[hi] - ka[lo]
    if seg <= 1e-9:
        return kz[lo]
    return _lerpf(kz[lo], kz[hi], (along - ka[lo]) / seg)


def segments(sa, st, ka, kz, along1):
    """GradeProfile._segments: [{kind, lo, hi, max_depth, max_gap}, …] partitioning the line."""
    kinds = []
    diffs = []
    for a, t in zip(sa, st):
        d = t - z_track_at(ka, kz, a)
        diffs.append(d)
        if d >= TUNNEL_MIN_COVER_M:
            kinds.append(TUNNEL)
        elif d > GORGE_MIN_M:
            kinds.append(GORGE)
        elif d < -BED_THICKNESS_M:
            kinds.append(BRIDGE)
        else:
            kinds.append(GROUND)
    runs = _rle(kinds, sa, diffs, along1)
    for _pass in range(3):
        changed = False
        for i, r in enumerate(runs):
            len_m = r["hi"] - r["lo"]
            if r["kind"] == TUNNEL and len_m < MIN_TUNNEL_M:
                r["kind"] = GORGE
                changed = True
            elif (r["kind"] == GORGE and len_m < MIN_GORGE_BETWEEN_TUNNELS_M
                  and 0 < i < len(runs) - 1
                  and runs[i - 1]["kind"] == TUNNEL and runs[i + 1]["kind"] == TUNNEL):
                r["kind"] = TUNNEL
                changed = True
            elif r["kind"] == BRIDGE and len_m < MIN_SPAN_M:
                r["kind"] = GROUND
                changed = True
        if changed:
            runs = _merge_runs(runs)
        else:
            break
    return runs


def _rle(kinds, sa, diffs, along1):
    runs = []
    n = len(kinds)
    i = 0
    while i < n:
        k = kinds[i]
        j = i
        max_depth = 0.0
        max_gap = 0.0
        while j < n and kinds[j] == k:
            max_depth = max(max_depth, diffs[j])
            max_gap = max(max_gap, -diffs[j])
            j += 1
        runs.append({"kind": k, "lo": sa[i], "hi": sa[j] if j < n else along1,
                     "max_depth": max_depth, "max_gap": max_gap})
        i = j
    return runs


def _merge_runs(runs):
    out = []
    for r in runs:
        if out and out[-1]["kind"] == r["kind"]:
            last = out[-1]
            last["hi"] = r["hi"]
            last["max_depth"] = max(last["max_depth"], r["max_depth"])
            last["max_gap"] = max(last["max_gap"], r["max_gap"])
        else:
            out.append(dict(r))
    return out


def compute(a0, a1, terrain, max_grade, climb, stations_terrain=None):
    """The profile of a line from along a0 to a1 (absolute, the exporter's cumulative metres);
    terrain(along) -> metres. None when too short to profile (the game refuses it too)."""
    if a1 - a0 < STATION_STEP_M:
        return None
    ka, kz = knots(a0, a1, terrain, max_grade, climb)
    sa = station_alongs(a0, a1)
    st = stations_terrain if stations_terrain is not None else [float(terrain(a)) for a in sa]
    return {
        "along0": a0, "along1": a1, "max_grade": max_grade, "climb": climb,
        "knots_along": ka, "knots_z": kz,
        "stations_along": sa, "stations_terrain": st,
        "segments": segments(sa, st, ka, kz, a1),
    }


def viaduct_decks(seg):
    """How many decks a BRIDGE segment is built as (GradeProfile.spans_of)."""
    return max(1, math.ceil((seg["hi"] - seg["lo"]) / VIADUCT_MAX_SPAN_M))


def summary(profile):
    """Lengths per kind, the steepest line grade, the structures: what the profile panel shows."""
    by_kind = {k: 0.0 for k in KIND_NAMES}
    tunnels = []
    viaducts = []
    for s in profile["segments"]:
        length = s["hi"] - s["lo"]
        by_kind[s["kind"]] += length
        if s["kind"] == TUNNEL:
            tunnels.append(length)
        elif s["kind"] == BRIDGE:
            viaducts.append((length, viaduct_decks(s), s["max_gap"]))
    ka, kz = profile["knots_along"], profile["knots_z"]
    steepest = 0.0
    for i in range(1, len(ka)):
        run = ka[i] - ka[i - 1]
        if run > 1e-9:
            steepest = max(steepest, abs(kz[i] - kz[i - 1]) / run)
    total = profile["along1"] - profile["along0"]
    return {
        "length_m": total,
        "by_kind_m": by_kind,
        "share": {k: (v / total if total > 0 else 0.0) for k, v in by_kind.items()},
        "steepest_grade": steepest,
        "climb_m": kz[-1] - kz[0],
        "tunnels_m": tunnels,
        "viaducts": viaducts,
        "max_cover_m": max((s["max_depth"] for s in profile["segments"]
                            if s["kind"] in (TUNNEL, GORGE)), default=0.0),
        "max_gap_m": max((s["max_gap"] for s in profile["segments"] if s["kind"] == BRIDGE),
                         default=0.0),
    }


# ── The golden fixture's terrain ──────────────────────────────────────────────
def piecewise_terrain(breakpoints):
    """terrain(along) linear between [(along, h), …] (sorted), flat past both ends — the
    golden fixture's terrain, written with the same operations as grade_profile_golden.gd."""
    xs = [float(p[0]) for p in breakpoints]
    hs = [float(p[1]) for p in breakpoints]

    def terrain(a):
        if a <= xs[0]:
            return hs[0]
        if a >= xs[-1]:
            return hs[-1]
        i = bisect.bisect_right(xs, a) - 1
        t = (a - xs[i]) / (xs[i + 1] - xs[i])
        return hs[i] + (hs[i + 1] - hs[i]) * t
    return terrain
