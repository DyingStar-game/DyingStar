"""
Volcanoes, lava flows, fumaroles → the VOLCANO, LAVA and FUMAROLE parts.
=========================================================================

Like the mountains (mountains.py), nothing is baked: Godot evaluates the cone,
the crater, the lava channel and the vents at runtime (scenes/planet/
volcano_relief.gd + native/MountainVolcanoNative.cs, scenes/planet/lava/,
scenes/planet/fumarole/). This module only tiles the INTENT into the pack.

volcano (KIND_VOLCANO)
----------------------
    A POPULATE record with ``point`` coverage whose props are the style
    resolved from the type preset (``PRESETS``) and ``cx/cy/cz``, the unit
    centre computed HERE — the runtime never evaluates a sine or a cosine for
    it, so the Windows client and the Linux server read the same bits. Written
    into every tile the lobed foot can reach, n1…export_nside, like a massif.

lava_flow (KIND_LAVA)
---------------------
    Emitted geometry (a crust ribbon over a carved channel), so it follows the
    ROAD rules: partitioned per pixel, never duplicated, baked down to
    max_quadtree_nside, along-metres from the TRUE start of the flow. The
    drawing direction is the flow direction; lava never flows uphill — the
    runtime profile is the running minimum of the terrain (GradeProfile's
    DESCENT rule). The exporter can only WARN when the line's end is higher
    than its start (``uphill``, from an optional height sampler); the runtime
    warns again from the real relief.

fumarole_field / fumarole_vent (KIND_FUMAROLE)
----------------------------------------------
    Polygons clipped to the tile box expanded by the stain feather (the
    runtime fades the deposit stain from the outline, so a synthetic clip edge
    must stay out of reach), vents as ``point`` records.  The runtime scatters
    the vents of a field deterministically from ``density`` and ``seed``.
"""

import hashlib
import math

from . import dsmp
from . import modifier_geom as mg
from .biomes import props_of, ring_area_deg2, MIN_RING_POINTS
from .mountains import resolve_impurity, _slack_m, _expanded_box

# ── Volcanoes ──────────────────────────────────────────────────────────

#: Type presets — the single source of truth for layers/volcanoes.py's
#: ``type`` dropdown (VolcanoRelief.PRESETS mirrors them for the debug
#: injection only). ``custom`` takes the stratovolcano values.
PRESETS = {
    "stratovolcano": {"base_diameter_m": 12000.0, "height_m": 2500.0, "crater_diameter_m": 600.0,
                      "crater_depth_m": 200.0, "floor_frac": 0.3, "flank_exponent": 2.0,
                      "roughness": 0.06, "gullies": 0.5, "irregularity": 0.12,
                      "lake_fill_m": 20.0},
    "shield": {"base_diameter_m": 40000.0, "height_m": 1500.0, "crater_diameter_m": 2000.0,
               "crater_depth_m": 120.0, "floor_frac": 0.6, "flank_exponent": 0.5,
               "roughness": 0.03, "gullies": 0.1, "irregularity": 0.25,
               "lake_fill_m": 30.0},
    "caldera": {"base_diameter_m": 20000.0, "height_m": 900.0, "crater_diameter_m": 8000.0,
                "crater_depth_m": 600.0, "floor_frac": 0.8, "flank_exponent": 1.5,
                "roughness": 0.05, "gullies": 0.2, "irregularity": 0.2,
                "lake_fill_m": 60.0},
    "cinder_cone": {"base_diameter_m": 800.0, "height_m": 150.0, "crater_diameter_m": 250.0,
                    "crater_depth_m": 50.0, "floor_frac": 0.2, "flank_exponent": 1.0,
                    "roughness": 0.04, "gullies": 0.1, "irregularity": 0.08,
                    "lake_fill_m": 5.0},
    "lava_dome": {"base_diameter_m": 1500.0, "height_m": 250.0, "crater_diameter_m": 0.0,
                  "crater_depth_m": 0.0, "floor_frac": 0.0, "flank_exponent": 0.5,
                  "roughness": 0.15, "gullies": 0.0, "irregularity": 0.2,
                  "lake_fill_m": 0.0},
}
PRESETS["custom"] = dict(PRESETS["stratovolcano"])
DEFAULT_TYPE = "stratovolcano"

#: MountainNoise.pow_fast's exact exponent set (VolcanoRelief.EXPONENTS).
EXPONENTS = (0.5, 1.0, 1.5, 2.0, 3.0)
#: VolcanoRelief.prepare clamps the crater to this share of the base radius.
CRATER_MAX_FRAC = 0.9
_VOLCANO_INT_FIELDS = ("seed", "has_lava_lake")


def snap_exponent(e):
    """The nearest exponent of the exact set (ties go to the first)."""
    e = float(e)
    best = 1.0
    for x in EXPONENTS:
        if abs(x - e) < abs(best - e):
            best = x
    return best


def resolve_volcano(fields):
    """The feature's fields with every NULL filled from its type preset."""
    vtype = str(fields.get("type") or DEFAULT_TYPE)
    if vtype not in PRESETS:
        vtype = DEFAULT_TYPE
    preset = PRESETS[vtype]
    out = dict(fields)
    out["type"] = vtype
    for key, value in preset.items():
        cur = out.get(key)
        if cur is None or cur == "":
            out[key] = value
    for key in preset:
        out[key] = float(out[key])
    out["flank_exponent"] = snap_exponent(out["flank_exponent"])
    for key in _VOLCANO_INT_FIELDS:
        if out.get(key) is not None and out.get(key) != "":
            out[key] = int(out[key])
    out["has_lava_lake"] = 1 if int(out.get("has_lava_lake") or 0) else 0
    out["activity"] = str(out.get("activity") or "dormant")
    return out


def unit_centre(lon, lat):
    """HEALPix.lonlat2vec: (cos lat·cos lon, sin lat, cos lat·sin lon)."""
    lo = math.radians(lon)
    la = math.radians(lat)
    cl = math.cos(la)
    return (cl * math.cos(lo), math.sin(la), cl * math.sin(lo))


def volcano_warnings(volcanoes, radius_m):
    """Human-readable warnings: oversized crater, overlapping bases."""
    out = []
    for v in volcanoes:
        f = v["fields"]
        if f["crater_diameter_m"] > CRATER_MAX_FRAC * f["base_diameter_m"]:
            out.append("volcano %r: crater %.0f m wider than %.0f%% of its base %.0f m — clamped"
                       % (f.get("name") or v["index"], f["crater_diameter_m"],
                          CRATER_MAX_FRAC * 100.0, f["base_diameter_m"]))
    for i in range(len(volcanoes)):
        for j in range(i + 1, len(volcanoes)):
            a, b = volcanoes[i], volcanoes[j]
            ca, cb = a["centre"], b["centre"]
            chord = math.sqrt(sum((ca[k] - cb[k]) ** 2 for k in range(3))) * radius_m
            if chord < a["reach_m"] + b["reach_m"]:
                out.append("volcanoes %r and %r overlap (%.0f m apart) — their cones add up"
                           % (a["fields"].get("name") or a["index"],
                              b["fields"].get("name") or b["index"], chord))
    return out


def build_volcano_part(points, radius_m, export_nside, max_quadtree_nside, table,
                       verbose=True, planet_name="", flows=()):
    """Build the VOLCANO part's levels and manifest.

    points: [{"lon", "lat", "props": {field: value, …}}, …] — NULLs dropped.
    flows: the lava flows (build_lava_part's input): a lake a flow leaves gets
           its rim tilted toward it (lake_breach: props fx/fy/fz, tilt_m).
    Returns (levels, manifest, warnings) for dsmp.write_part(path, dsmp.KIND_VOLCANO, …).
    """
    policy = mg.level_policy(export_nside, max_quadtree_nside)["volcano"]
    levels_ns = mg.levels_for(policy)
    slack = _slack_m(max_quadtree_nside, radius_m)

    prepared = []
    for vi, p in enumerate(points):
        lon, lat = float(p["lon"]), float(p["lat"])
        fields = resolve_volcano(p.get("props", {}))
        fields["impurity_intensity"] = resolve_impurity(
            fields.get("impurity_intensity"), [(lon, lat)], planet_name)
        c = unit_centre(lon, lat)
        fields["cx"], fields["cy"], fields["cz"] = float(c[0]), float(c[1]), float(c[2])
        fields.update(lake_breach(p, flows, radius_m))
        reach = 0.5 * fields["base_diameter_m"] * (1.0 + fields["irregularity"])
        prepared.append({
            "lon": lon, "lat": lat, "index": vi, "fields": fields, "centre": c,
            "reach_m": reach,
            "type_sid": table.intern("volcano"),
            "props": props_of(fields, table),
        })
    warnings = volcano_warnings(prepared, radius_m)

    levels, counts, fingerprint = _point_levels(prepared, levels_ns, radius_m, slack, verbose)
    manifest = {
        "kind": "volcano",
        "max_nside": policy["max"],
        "min_nside": policy["min"],
        "levels": levels_ns,
        "export_nside": export_nside,
        "max_quadtree_nside": max_quadtree_nside,
        "radius": radius_m,
        "counts": counts,
        "priority_rule": "additive",
        # Re-keys the chunk cache (PlanetData.mountain_fingerprint).
        "fingerprint": fingerprint,
    }
    return levels, manifest, warnings


def _point_levels(prepared, levels_ns, radius_m, slack, verbose, extra_records=None):
    """Tile point records (each with lon, lat, reach_m, type_sid, index, props)
    into every tile within reach, per level. extra_records(nside) → {ipix: [bytes]}
    merges polygon records (the fumarole part holds both)."""
    levels = []
    counts = {"features": len(prepared), "records_per_level": {}}
    digest = hashlib.sha1()
    for nside in levels_ns:
        per_tile = extra_records(nside) if extra_records else {}
        for pt in prepared:
            rec = dsmp.pack_populate(pt["type_sid"], pt["index"], dsmp.COVERAGE_POINT,
                                     pt["props"], lon=pt["lon"], lat=pt["lat"])
            for ipix in mg.tiles_for_point(nside, pt["lon"], pt["lat"],
                                           pt["reach_m"] + slack, radius_m):
                per_tile.setdefault(ipix, []).append(rec)
        tiles = []
        n_records = 0
        for ipix in sorted(per_tile):
            blocks = per_tile[ipix]
            n_records += len(blocks)
            payload = dsmp.part_tile(len(blocks), b"".join(blocks))
            digest.update(payload)
            tiles.append((ipix, payload))
        levels.append((nside, tiles))
        counts["records_per_level"][str(nside)] = n_records
        if verbose:
            print("    n%-5d %6d tiles %7d records" % (nside, len(tiles), n_records))
    return levels, counts, digest.hexdigest()


def volcano_height_offset(volcano_fields, centre, lon, lat, radius_m):
    """The noise-free cone + crater height (m) a resolved volcano adds at
    (lon, lat) — VolcanoRelief.offset without lobes, gullies and detail.
    Only the exporter's uphill warning uses it."""
    p = unit_centre(lon, lat)
    r = math.sqrt(sum((p[k] - centre[k]) ** 2 for k in range(3))) * radius_m
    rb = 0.5 * volcano_fields["base_diameter_m"]
    rc = min(0.5 * volcano_fields["crater_diameter_m"], CRATER_MAX_FRAC * rb)
    h = volcano_fields["height_m"]
    if r >= rb:
        return 0.0
    if r < rc:
        f = volcano_fields["floor_frac"] * rc
        t = 0.0 if r <= f else min((r - f) / max(rc - f, 1e-9), 1.0)
        return h - volcano_fields["crater_depth_m"] * (1.0 - t * t * (3.0 - 2.0 * t))
    s = (r - rc) / max(rb - rc, 1.0)
    return h * (1.0 - s) ** volcano_fields["flank_exponent"]


# ── Lava lakes: where a flow leaving the crater starts ─────────────────

#: A flow whose first point is inside a lava lake or within this distance of
#: its shore starts ON the shore (VolcanoRelief.LAKE_SNAP_M).
LAKE_SNAP_M = 200.0
#: The lake never rises closer than this share of the crater depth to the rim
#: (VolcanoFeatures.MAX_FILL_FRAC).
LAKE_MAX_FILL_FRAC = 0.9


def _smoothstep_inv(y):
    """s in [0, 1] with 3s² − 2s³ = y (bisection; the curve is monotone)."""
    y = min(max(float(y), 0.0), 1.0)
    lo, hi = 0.0, 1.0
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        if mid * mid * (3.0 - 2.0 * mid) < y:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


#: The crater rim on the side a flow leaves the lake is lowered to this much
#: above the lake (VolcanoRelief.RIM_FREEBOARD_M) — the rim is TILTED toward
#: the flow, so the lava spills over it instead of cutting a canyon.
RIM_FREEBOARD_M = 2.0


def _lake_fill(fields):
    dc = float(fields["crater_depth_m"])
    return min(max(float(fields.get("lake_fill_m") or 0.0), 0.0), dc * LAKE_MAX_FILL_FRAC)


def rim_height(fields, u_dot_f=None):
    """Height of the crater rim above the base in the azimuth whose unit
    tangent u has u·f = u_dot_f (VolcanoRelief's tilt, ((1 + u·f)/2)²)."""
    h = float(fields["height_m"])
    tilt = float(fields.get("tilt_m") or 0.0)
    if tilt <= 0.0 or u_dot_f is None:
        return h
    q = (1.0 + u_dot_f) * 0.5
    return h - tilt * (q * q)


def lake_shore_radius(fields, u_dot_f=None):
    """Distance (m) from the summit at which the crater wall reaches the lava
    lake's surface (the crater profile of VolcanoRelief.offset) in the azimuth
    u·f = u_dot_f (the untilted crater when None), or None when the volcano
    holds no lake. Same numbers as VolcanoRelief.lake_shore_radius."""
    if not int(fields.get("has_lava_lake") or 0):
        return None
    rb = 0.5 * float(fields["base_diameter_m"])
    rc = min(0.5 * float(fields["crater_diameter_m"]), CRATER_MAX_FRAC * rb)
    dc = float(fields["crater_depth_m"])
    if rc <= 0.0 or dc <= 0.0:
        return None
    fill = _lake_fill(fields)
    drop = dc
    if float(fields.get("tilt_m") or 0.0) > 0.0 and u_dot_f is not None:
        drop = rim_height(fields, u_dot_f) - (float(fields["height_m"]) - dc)
    ff = min(max(float(fields["floor_frac"]), 0.0), 0.95) * rc
    return ff + (rc - ff) * _smoothstep_inv(fill / drop)


def _unit(v):
    n = math.sqrt(sum(x * x for x in v))
    return tuple(x / n for x in v)


def _lonlat_of(v):
    x, y, z = _unit(v)
    return (math.degrees(math.atan2(z, x)), math.degrees(math.asin(max(-1.0, min(1.0, y)))))


def _chord_m(a, b, radius_m):
    return math.sqrt(sum((a[k] - b[k]) ** 2 for k in range(3))) * radius_m


def _outward_tangent(c, centerline, radius_m):
    """Unit tangent at the summit c pointing along the flow's start: toward its
    first point, or the next one when it starts on the summit. None if none."""
    ref = None
    for q in centerline:
        v = unit_centre(*q)
        if _chord_m(v, c, radius_m) > 1e-3:
            ref = v
            break
    if ref is None:
        return None
    d = sum(ref[k] * c[k] for k in range(3))
    t = tuple(ref[k] - c[k] * d for k in range(3))
    if math.sqrt(sum(x * x for x in t)) < 1e-15:
        return None
    return _unit(t)


def lake_breach(volcano, flows, radius_m, snap_m=LAKE_SNAP_M):
    """{"fx", "fy", "fz", "tilt_m"} for a volcano whose lava lake a flow leaves
    (the first flow, in layer order, starting in or within snap_m of its shore):
    the rim is lowered toward it to RIM_FREEBOARD_M above the lake. {} else."""
    fields = resolve_volcano(volcano.get("props", {}))
    r_shore = lake_shore_radius(fields)
    if r_shore is None:
        return {}
    c = unit_centre(float(volcano["lon"]), float(volcano["lat"]))
    for f in flows:
        cl = [(float(p[0]), float(p[1])) for p in f.get("centerline", [])]
        if len(cl) < 2:
            continue
        if _chord_m(unit_centre(*cl[0]), c, radius_m) - r_shore > snap_m:
            continue
        t = _outward_tangent(c, cl, radius_m)
        if t is None:
            continue
        dc = float(fields["crater_depth_m"])
        tilt = max(dc - _lake_fill(fields) - RIM_FREEBOARD_M, 0.0)
        return {"fx": float(t[0]), "fy": float(t[1]), "fz": float(t[2]), "tilt_m": tilt}
    return {}


def snap_to_lakes(centerline, lakes, radius_m, snap_m=LAKE_SNAP_M):
    """The flow's centerline with its SOURCE moved onto the shore of the lava
    lake it starts in or next to. lakes: [(unit centre, resolved fields, name)]
    — the fields carry the rim tilt when a flow breaches it. A first point
    inside the lake is replaced by the shore point on the ray from the summit;
    one outside within snap_m of the shore gets the shore point prepended.
    Returns (centerline, lake name or None)."""
    if len(centerline) < 2 or not lakes:
        return list(centerline), None
    p0 = unit_centre(*centerline[0])
    best = None
    for c, fields, name in lakes:
        r_shore = lake_shore_radius(fields)
        if r_shore is None:
            continue
        gap = _chord_m(p0, c, radius_m) - r_shore
        if gap <= snap_m and (best is None or gap < best[0]):
            best = (gap, c, fields, name)
    if best is None:
        return list(centerline), None
    gap, c, fields, name = best
    t = _outward_tangent(c, centerline, radius_m)
    if t is None:
        return list(centerline), None
    u_dot_f = None
    if float(fields.get("tilt_m") or 0.0) > 0.0:
        u_dot_f = t[0] * float(fields["fx"]) + t[1] * float(fields["fy"]) + t[2] * float(fields["fz"])
    a = lake_shore_radius(fields, u_dot_f) / radius_m
    shore = _lonlat_of(tuple(c[k] * math.cos(a) + t[k] * math.sin(a) for k in range(3)))
    out = list(centerline)
    if gap < 0.0:
        out[0] = shore
    else:
        out.insert(0, shore)
    return out, name


# ── Lava flows ─────────────────────────────────────────────────────────

#: State presets: widths and the lava surface's depth below its banks.
LAVA_PRESETS = {
    "active": {"width_start_m": 15.0, "width_end_m": 30.0, "depth_m": 3.0},
    "cooling": {"width_start_m": 20.0, "width_end_m": 35.0, "depth_m": 2.0},
    "solid": {"width_start_m": 25.0, "width_end_m": 40.0, "depth_m": 1.0},
}
LAVA_STATES = tuple(LAVA_PRESETS)
#: Lava feature ids start here, disjoint from the roads' (the grade tables
#: key their profiles by feature id).
LAVA_FID_BASE = 1 << 30
MIN_LAVA_POINTS = 2


def resolve_lava(fields):
    state = str(fields.get("state") or "active")
    if state not in LAVA_PRESETS:
        state = "active"
    out = dict(fields)
    out["state"] = state
    for key, value in LAVA_PRESETS[state].items():
        cur = out.get(key)
        out[key] = float(value if cur is None or cur == "" else cur)
    return out


def build_lava_part(flows, radius_m, export_nside, max_quadtree_nside, table,
                    res_max=32, verbose=True, height_at=None, volcanoes=()):
    """Build the LAVA part's levels and manifest.

    flows: [{"centerline": [(lon, lat), …], "props": {field: value}}, …] — the
           drawing direction is the flow direction.
    height_at: optional callable (lon, lat) → metres, the ground as the
           exporter can guess it (DEM + volcanoes); feeds the uphill warning.
    volcanoes: the volcano points (build_volcano_part's input): a flow starting
           in or within LAKE_SNAP_M of a lava lake starts on its shore.
    Returns (levels, manifest, warnings) for dsmp.write_part(path, dsmp.KIND_LAVA, …).
    """
    policy = mg.level_policy(export_nside, max_quadtree_nside)["lava"]
    levels_ns = mg.levels_for(policy)
    mpd = mg.m_per_deg(radius_m)

    lakes = []
    for v in volcanoes:
        vf = resolve_volcano(v.get("props", {}))
        if lake_shore_radius(vf) is not None:
            vf.update(lake_breach(v, flows, radius_m))
            lakes.append((unit_centre(float(v["lon"]), float(v["lat"])), vf,
                          str(vf.get("name") or "")))

    prepared = []
    warnings = []
    uphill = []
    for i, f in enumerate(flows):
        cl = [(float(p[0]), float(p[1])) for p in f.get("centerline", [])]
        if len(cl) < MIN_LAVA_POINTS:
            continue
        fields = resolve_lava(f.get("props", {}))
        cl, lake = snap_to_lakes(cl, lakes, radius_m)
        if lake is not None and verbose:
            print("    lava flow %r starts on the shore of lava lake %r"
                  % (fields.get("name") or i, lake))
        pts = mg.with_cumulative(cl, mpd)
        fid = LAVA_FID_BASE + i
        hw = 0.5 * max(fields["width_start_m"], fields["width_end_m"])
        if height_at is not None:
            h0 = height_at(cl[0][0], cl[0][1])
            h1 = height_at(cl[-1][0], cl[-1][1])
            if h0 is not None and h1 is not None and h1 > h0:
                name = fields.get("name") or fid
                uphill.append({"feature_id": fid, "name": str(name), "rise_m": h1 - h0})
                warnings.append("lava flow %r ends %.0f m ABOVE its source — lava never climbs, "
                                "a channel will be cut; draw it from the source downhill"
                                % (name, h1 - h0))
        prepared.append({
            "fid": fid,
            "points": pts,
            "total_length_m": pts[-1][2],
            "half_width_m": hw,
            "type_sid": table.intern("lava_river"),
            "state_sid": table.intern(fields["state"]),
            "name_sid": table.intern(fields.get("name")),
            "fields": fields,
        })

    levels = []
    counts = {"features": len(prepared), "records_per_level": {}}
    digest = hashlib.sha1()
    for nside in levels_ns:
        per_tile = {}
        for flow in prepared:
            eps_deg = mg.decim_eps_m(nside, radius_m, flow["half_width_m"], res_max) / mpd
            f = flow["fields"]
            for ipix, pieces in mg.partition_polyline(nside, flow["points"]).items():
                for piece in pieces:
                    piece = mg.douglas_peucker(piece, eps_deg)
                    if len(piece) < MIN_LAVA_POINTS:
                        continue
                    per_tile.setdefault(ipix, []).append(dsmp.pack_lava(
                        flow["type_sid"], flow["state_sid"], flow["name_sid"],
                        f["width_start_m"], f["width_end_m"], f["depth_m"],
                        flow["total_length_m"], flow["fid"], piece))
        tiles = []
        n_records = 0
        for ipix in sorted(per_tile):
            blocks = per_tile[ipix]
            n_records += len(blocks)
            payload = dsmp.part_tile(len(blocks), b"".join(blocks))
            digest.update(payload)
            tiles.append((ipix, payload))
        levels.append((nside, tiles))
        counts["records_per_level"][str(nside)] = n_records
        if verbose:
            print("    n%-5d %5d tiles %6d pieces" % (nside, len(tiles), n_records))

    manifest = {
        "kind": "lava",
        "max_nside": policy["max"],
        "min_nside": policy["min"],
        "levels": levels_ns,
        "export_nside": export_nside,
        "max_quadtree_nside": max_quadtree_nside,
        "radius": radius_m,
        "counts": counts,
        "assignment": "partition",
        "record_layout": dsmp.LAVA_RECORD_LAYOUT,
        "uphill": uphill,
        "fingerprint": digest.hexdigest(),
    }
    return levels, manifest, warnings


# ── Fumaroles ──────────────────────────────────────────────────────────

#: Gas presets for the NULL fields of a field / vent.
GAS_PRESETS = {
    "steam": {"density": 20.0, "radius": 3.0, "intensity": 0.6, "plume_height_m": 40.0,
              "stain": 0.3},
    "sulfur": {"density": 25.0, "radius": 2.5, "intensity": 0.5, "plume_height_m": 25.0,
               "stain": 0.6},
    "co2": {"density": 15.0, "radius": 2.0, "intensity": 0.3, "plume_height_m": 10.0,
            "stain": 0.4},
    "chlorine": {"density": 15.0, "radius": 2.0, "intensity": 0.4, "plume_height_m": 20.0,
                 "stain": 0.5},
}
DEFAULT_GAS = "sulfur"
#: The runtime fades the stain over this many metres inside a field's outline
#: (FumaroleField.FEATHER_M) — the expanded clip box must cover it.
FUMAROLE_FEATHER_M = 60.0
_FUMAROLE_INT_FIELDS = ("seed",)


def resolve_fumarole(fields, vent=False):
    gas = str(fields.get("gas") or DEFAULT_GAS)
    if gas not in GAS_PRESETS:
        gas = DEFAULT_GAS
    out = dict(fields)
    out["gas"] = gas
    for key, value in GAS_PRESETS[gas].items():
        if vent and key == "density":
            continue
        cur = out.get(key)
        out[key] = float(value if cur is None or cur == "" else cur)
    for key in _FUMAROLE_INT_FIELDS:
        if out.get(key) is not None and out.get(key) != "":
            out[key] = int(out[key])
    return out


def build_fumarole_part(fields_in, vents_in, radius_m, export_nside, max_quadtree_nside,
                        table, verbose=True):
    """Build the FUMAROLE part's levels and manifest.

    fields_in: [{"ring": [(lon, lat), …], "props": {…}}, …] — fumarole_field polygons.
    vents_in:  [{"lon", "lat", "props": {…}}, …]            — fumarole_vent points.
    Returns (levels, manifest) for dsmp.write_part(path, dsmp.KIND_FUMAROLE, …).
    """
    policy = mg.level_policy(export_nside, max_quadtree_nside)["fumarole"]
    levels_ns = mg.levels_for(policy)
    slack = _slack_m(max_quadtree_nside, radius_m)

    zones = []
    for zi, z in enumerate(fields_in):
        ring = [(float(p[0]), float(p[1])) for p in z.get("ring", [])]
        if len(ring) < MIN_RING_POINTS:
            continue
        f = resolve_fumarole(z.get("props", {}))
        zones.append({
            "ring": ring,
            "area": ring_area_deg2(ring),
            "order": zi,
            "margin_m": FUMAROLE_FEATHER_M + 3.0 * f["radius"] + slack,
            "type_sid": table.intern("fumarole_field"),
            "index": zi,
            "props": props_of(f, table),
        })
    zones.sort(key=lambda p: (p["area"], p["order"]))

    vents = []
    for vi, v in enumerate(vents_in):
        f = resolve_fumarole(v.get("props", {}), vent=True)
        vents.append({
            "lon": float(v["lon"]), "lat": float(v["lat"]),
            "index": vi,
            "reach_m": 3.0 * f["radius"] + FUMAROLE_FEATHER_M,
            "type_sid": table.intern("fumarole_vent"),
            "props": props_of(f, table),
        })

    def polygon_records(nside):
        per_tile = {}
        for zone in zones:
            margin = zone["margin_m"]
            for ipix in mg.tiles_for_polygon(nside, zone["ring"], margin, radius_m):
                box = _expanded_box(nside, ipix, margin, radius_m)
                if mg.bbox_inside_ring(box, zone["ring"]):
                    rec = dsmp.pack_populate(zone["type_sid"], zone["index"],
                                             dsmp.COVERAGE_FULL, zone["props"])
                else:
                    piece = mg.clip_polygon_to_bbox(zone["ring"], box)
                    if len(piece) < MIN_RING_POINTS:
                        continue
                    rec = dsmp.pack_populate(zone["type_sid"], zone["index"],
                                             dsmp.COVERAGE_PARTIAL, zone["props"],
                                             vertices=piece)
                per_tile.setdefault(ipix, []).append(rec)
        return per_tile

    levels, counts, fingerprint = _point_levels(vents, levels_ns, radius_m, slack, verbose,
                                                extra_records=polygon_records)
    counts["features"] = len(zones) + len(vents)
    counts["fields"] = len(zones)
    counts["vents"] = len(vents)
    manifest = {
        "kind": "fumarole",
        "max_nside": policy["max"],
        "min_nside": policy["min"],
        "levels": levels_ns,
        "export_nside": export_nside,
        "max_quadtree_nside": max_quadtree_nside,
        "radius": radius_m,
        "counts": counts,
        "priority_rule": "additive",
        "fingerprint": fingerprint,
    }
    return levels, manifest
