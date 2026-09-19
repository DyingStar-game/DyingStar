"""
Procedural mountains → the MOUNTAIN and RIDGE parts of the terrain-modifier pack.
==================================================================================

The relief itself is never baked: Godot evaluates it per vertex
(scenes/planet/mountain_relief.gd, the C# twins under scenes/planet/native/) as
a deterministic function of the direction and of the parameters exported here.
This module only tiles the INTENT — the polygon or the crest line and its
style — into the pack, with the POPULATE record layout (dsmp.pack_populate:
generic f32 / i32 / string props + a vertex list) under two kinds of their own.

mountain_range (KIND_MOUNTAIN)
------------------------------
    Like a biome region (biomes.py), with one difference that matters: the
    runtime feathers the relief to zero over ``feather_m`` INSIDE the edge, from
    the distance to the nearest polygon edge.  A ring clipped to the bare tile
    box would put synthetic edges through the tile and feather against them, so
    the clip box is EXPANDED by the feather (plus a probe / stitch slack): every
    synthetic edge then lies ≥ feather from every point of the tile, and
    min(d, feather) is exact.  For the same reason the piece is never
    simplified — a moved vertex is a moved mountain foot.  A tile whose expanded
    box sits entirely inside the ring gets a ``full`` record (env == 1
    everywhere in it, no geometry).

ridge (KIND_RIDGE)
------------------
    The runtime needs the whole line (curvilinear abscissa for the end taper,
    both ends), so the record carries the ENTIRE polyline in every tile within
    its reach — never clipped.  Reach = width·(1+|asymmetry|) + warp + slack.

Both kinds are baked n1…export_nside (modifier_geom.level_policy): a finer
chunk reads its export-level ancestor's records, and the runtime adds every
record of the tile — there is no overlap rule, features stack.

Presets
-------
    ``PRESETS`` / ``RIDGE_PRESETS`` are the single source of truth for the
    ``style`` dropdowns of layers/mountains.py: the exporter fills every NULL
    field from the chosen preset, so the pack always carries explicit values
    and Godot needs no preset table.  Exponents stay in MountainNoise.pow_fast's
    exact set {0.5, 1, 1.5, 2, 3}.
"""

import hashlib
import math

from . import dsmp
from . import modifier_geom as mg
from .biomes import props_of, ring_area_deg2, MIN_RING_POINTS

#: Runtime floor of the feather (MountainRelief.FEATHER_MIN_M) — the expanded
#: clip box must cover at least this.
FEATHER_MIN_M = 250.0

#: Extra margin around the clip box, in finest-chunk vertex pitches: the
#: normal probes sit a quarter pitch outside a border vertex and the LOD
#: stitch reads the parent grid, so a tile's samples reach slightly past it.
SLACK_PITCHES = 4.0

PRESETS = {
    "rolling": dict(lift_m=0.0, amplitude_m=300.0, wavelength_m=6000.0, octaves=5,
                    persistence=0.45, ridge=0.0, exponent=1.0, terrace_step_m=0.0,
                    terrace_width=0.15, warp=0.0, feather_m=2000.0, seed=0),
    "hills": dict(lift_m=0.0, amplitude_m=700.0, wavelength_m=8000.0, octaves=6,
                  persistence=0.5, ridge=0.2, exponent=1.5, terrace_step_m=0.0,
                  terrace_width=0.15, warp=0.2, feather_m=2500.0, seed=0),
    "alpine": dict(lift_m=0.0, amplitude_m=1200.0, wavelength_m=8000.0, octaves=7,
                   persistence=0.5, ridge=0.8, exponent=1.5, terrace_step_m=0.0,
                   terrace_width=0.15, warp=0.15, feather_m=3000.0, seed=0),
    # Terrace walls: the wall takes `terrace_width` of a step's horizontal run,
    # so on a gentle base slope a wide value gives a ramp, not a cliff — mesa
    # 0.04 ≈ 74°, cliffs 0.05 on 250 m bands ≈ 85° at the finest grid
    # (transect figures in the technical-docs "Mountains" pages).
    "mesa": dict(lift_m=0.0, amplitude_m=500.0, wavelength_m=7000.0, octaves=5,
                 persistence=0.45, ridge=0.0, exponent=1.0, terrace_step_m=150.0,
                 terrace_width=0.04, warp=0.2, feather_m=2000.0, seed=0),
    "cliffs": dict(lift_m=0.0, amplitude_m=1200.0, wavelength_m=6000.0, octaves=6,
                   persistence=0.5, ridge=0.5, exponent=1.0, terrace_step_m=250.0,
                   terrace_width=0.05, warp=0.1, feather_m=2500.0, seed=0),
}
PRESETS["custom"] = dict(PRESETS["alpine"])

RIDGE_PRESETS = {
    "soft": dict(height_m=250.0, width_m=1500.0, sharpness=0.15, roughness=0.3,
                 warp_m=100.0, asymmetry=0.0, terrace_step_m=0.0, terrace_width=0.15, seed=0),
    "sharp": dict(height_m=400.0, width_m=1200.0, sharpness=0.8, roughness=0.35,
                  warp_m=150.0, asymmetry=0.0, terrace_step_m=0.0, terrace_width=0.15, seed=0),
    "escarpment": dict(height_m=300.0, width_m=1000.0, sharpness=0.6, roughness=0.2,
                       warp_m=80.0, asymmetry=0.7, terrace_step_m=0.0, terrace_width=0.15,
                       seed=0),
    "stepped": dict(height_m=350.0, width_m=1400.0, sharpness=0.5, roughness=0.25,
                    warp_m=120.0, asymmetry=0.3, terrace_step_m=60.0, terrace_width=0.1,
                    seed=0),
}
RIDGE_PRESETS["custom"] = dict(RIDGE_PRESETS["sharp"])

#: Field types as the runtime reads them (f32 / i32) — everything else the
#: feature carries goes through props_of unchanged.
_INT_FIELDS = ("octaves", "seed")


def resolve_style(fields, presets, default):
    """The feature's fields with every NULL / missing style value filled from
    its preset. Returns a new dict; ``style`` itself is kept as a string prop."""
    style = str(fields.get("style") or default)
    preset = presets.get(style, presets[default])
    out = dict(fields)
    out["style"] = style
    for key, value in preset.items():
        cur = out.get(key)
        if cur is None or cur == "":
            out[key] = value
    for key in _INT_FIELDS:
        if key in out and out[key] is not None:
            out[key] = int(out[key])
    for key in preset:
        if key not in _INT_FIELDS and out.get(key) is not None:
            out[key] = float(out[key])
    return out


def _slack_m(max_quadtree_nside, radius_m):
    return SLACK_PITCHES * mg.pixel_side_m(max_quadtree_nside, radius_m) / 32.0


def _expanded_box(nside, ipix, margin_m, radius_m):
    """The tile's lon/lat box grown by margin_m on every side — the longitude
    side by 1/cos(lat) of the box's most polar row, so the margin holds in
    metres everywhere in the tile."""
    lon_min, lon_max, lat_min, lat_max = mg.tile_bbox(nside, ipix, 0.0)
    m_deg = margin_m / mg.m_per_deg(radius_m)
    lat_ext = max(abs(lat_min), abs(lat_max))
    clat = max(math.cos(math.radians(min(lat_ext, 89.5))), 0.05)
    return (lon_min - m_deg / clat, lon_max + m_deg / clat, lat_min - m_deg, lat_max + m_deg)


def build_mountain_part(zones, radius_m, export_nside, max_quadtree_nside, table,
                        verbose=True):
    """Build the MOUNTAIN part's levels and manifest.

    zones: [{"ring": [(lon, lat), …], "props": {field: value, …}}, …] — the
           props are the feature's fields, NULLs already dropped.
    Returns (levels, manifest) for dsmp.write_part(path, dsmp.KIND_MOUNTAIN, …).
    """
    policy = mg.level_policy(export_nside, max_quadtree_nside)["mountain"]
    levels_ns = mg.levels_for(policy)
    slack = _slack_m(max_quadtree_nside, radius_m)

    prepared = []
    for zi, z in enumerate(zones):
        ring = [(float(p[0]), float(p[1])) for p in z.get("ring", [])]
        if len(ring) < MIN_RING_POINTS:
            continue
        fields = resolve_style(z.get("props", {}), PRESETS, "alpine")
        fields["feather_m"] = max(float(fields.get("feather_m", FEATHER_MIN_M)), FEATHER_MIN_M)
        prepared.append({
            "ring": ring,
            "area": ring_area_deg2(ring),
            "order": zi,
            "margin_m": fields["feather_m"] + slack,
            "type_sid": table.intern("mountain_range"),
            "index": zi,
            "props": props_of(fields, table),
        })
    prepared.sort(key=lambda p: (p["area"], p["order"]))

    levels = []
    counts = {"features": len(prepared), "records_per_level": {}, "full_per_level": {}}
    digest = hashlib.sha1()
    for nside in levels_ns:
        per_tile = {}
        n_full = 0
        for zone in prepared:
            margin = zone["margin_m"]
            for ipix in mg.tiles_for_polygon(nside, zone["ring"], margin, radius_m):
                box = _expanded_box(nside, ipix, margin, radius_m)
                if mg.bbox_inside_ring(box, zone["ring"]):
                    rec = dsmp.pack_populate(zone["type_sid"], zone["index"],
                                             dsmp.COVERAGE_FULL, zone["props"])
                    n_full += 1
                else:
                    piece = mg.clip_polygon_to_bbox(zone["ring"], box)
                    if len(piece) < MIN_RING_POINTS:
                        continue
                    rec = dsmp.pack_populate(zone["type_sid"], zone["index"],
                                             dsmp.COVERAGE_PARTIAL, zone["props"],
                                             vertices=piece)
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
        counts["full_per_level"][str(nside)] = n_full
        if verbose:
            print("    n%-5d %6d tiles %7d records (%d full)" % (nside, len(tiles), n_records, n_full))

    manifest = {
        "kind": "mountain",
        "max_nside": policy["max"],
        "min_nside": policy["min"],
        "levels": levels_ns,
        "export_nside": export_nside,
        "max_quadtree_nside": max_quadtree_nside,
        "radius": radius_m,
        "counts": counts,
        "priority_rule": "additive",
        # Re-keys the chunk cache (PlanetData.mountain_fingerprint).
        "fingerprint": digest.hexdigest(),
    }
    return levels, manifest


def build_ridge_part(lines, radius_m, export_nside, max_quadtree_nside, table,
                     verbose=True):
    """Build the RIDGE part's levels and manifest.

    lines: [{"points": [(lon, lat), …], "props": {field: value, …}}, …]
    Returns (levels, manifest) for dsmp.write_part(path, dsmp.KIND_RIDGE, …).
    """
    policy = mg.level_policy(export_nside, max_quadtree_nside)["ridge"]
    levels_ns = mg.levels_for(policy)
    slack = _slack_m(max_quadtree_nside, radius_m)

    prepared = []
    for li, ln in enumerate(lines):
        pts = [(float(p[0]), float(p[1])) for p in ln.get("points", [])]
        if len(pts) < 2:
            continue
        fields = resolve_style(ln.get("props", {}), RIDGE_PRESETS, "sharp")
        reach = float(fields["width_m"]) * (1.0 + abs(float(fields["asymmetry"]))) \
            + float(fields["warp_m"])
        prepared.append({
            "points": pts,
            "order": li,
            "reach_m": reach + slack,
            "type_sid": table.intern("ridge"),
            "index": li,
            "props": props_of(fields, table),
        })

    levels = []
    counts = {"features": len(prepared), "records_per_level": {}}
    digest = hashlib.sha1()
    for nside in levels_ns:
        per_tile = {}
        for line in prepared:
            rec = dsmp.pack_populate(line["type_sid"], line["index"], dsmp.COVERAGE_PARTIAL,
                                     line["props"], vertices=line["points"], min_vertices=2)
            for ipix in mg.tiles_for_polyline(nside, line["points"], line["reach_m"], radius_m):
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

    manifest = {
        "kind": "ridge",
        "max_nside": policy["max"],
        "min_nside": policy["min"],
        "levels": levels_ns,
        "export_nside": export_nside,
        "max_quadtree_nside": max_quadtree_nside,
        "radius": radius_m,
        "counts": counts,
        "priority_rule": "additive",
        "fingerprint": digest.hexdigest(),
    }
    return levels, manifest
