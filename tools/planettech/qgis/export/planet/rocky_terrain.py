"""
Rocky terrain → the ROCKY part of the terrain-modifier pack.
=============================================================

A ``rocky_terrain`` polygon (layers/rocky_terrain.py) lays a rocky relief OVER
whatever is below it — plain, plateau, mountain — instead of replacing it like
a biome region does. Godot evaluates the relief at runtime
(scenes/planet/rock_field_relief.gd, C# twin RockFieldNative.cs) inside
PlanetData.sample_height_for_direction, after the mountains: a Voronoi cell is
a rock block whose height is the ground TERRACED with a phase of its own, so

    * on the flat the blocks are slabs at staggered heights,
    * on a slope the terrace cuts the slope into ledges — a cliff of blocks,
    * a dip vector tilts the terrace — inclined strata,
    * rare raised cells are buttes, stretched along the wind — yardangs.

This module only resolves the INTENT (``ruggedness`` level + ``style`` +
the nullable overrides) into explicit numbers and tiles the polygon into the
pack, exactly like a mountain_range (export/planet/mountains.py): expanded
clip box, never simplified, POPULATE layout under its own kind.

Everything the runtime needs that would take a sine or a cosine — the zone's
unit centre, the wind direction, the dip vector — is computed HERE and written
as f32 props, so the Windows client and the Linux server read the same bits.
"""

import hashlib
import math
import struct
import zlib

from . import dsmp
from . import mountain_noise
from . import rock_field_noise
from . import modifier_geom as mg
from .biomes import props_of, ring_area_deg2, MIN_RING_POINTS
from .mountains import FEATHER_MIN_M, SLACK_PITCHES, _expanded_box

#: The five levels of the layer's ``ruggedness`` dropdown, in order: the index
#: is the ``level`` prop the shader reads.
LEVELS = ("flat", "low", "medium", "rugged", "very_rugged")

#: Per level. cell_m = block size, step_m = ledge height, riser = share of a
#: step taken by its wall (terrace width), joint_* = the groove between blocks
#: (its width is also the blend between two blocks' phases, so ≥ the 25 m
#: finest pitch), butte_* = the raised cells, detail_m = the size of the small
#: blocks the shader draws inside a geometric block, feather_m = fade inside
#: the outline. Starting values, tuned on tarsis_8.
PRESETS = {
    "flat": dict(cell_m=120.0, step_m=0.0, riser=0.25, joint_depth_m=0.0, joint_width_m=30.0,
                 butte_rate=0.0, butte_height_m=0.0, butte_cell_m=600.0, butte_wall_m=40.0,
                 detail_m=3.0, feather_m=250.0),
    "low": dict(cell_m=150.0, step_m=3.0, riser=0.3, joint_depth_m=1.0, joint_width_m=30.0,
                butte_rate=0.0, butte_height_m=0.0, butte_cell_m=600.0, butte_wall_m=40.0,
                detail_m=4.0, feather_m=300.0),
    "medium": dict(cell_m=120.0, step_m=8.0, riser=0.25, joint_depth_m=2.0, joint_width_m=30.0,
                   butte_rate=0.02, butte_height_m=25.0, butte_cell_m=600.0, butte_wall_m=40.0,
                   detail_m=6.0, feather_m=400.0),
    "rugged": dict(cell_m=100.0, step_m=18.0, riser=0.2, joint_depth_m=4.0, joint_width_m=30.0,
                   butte_rate=0.05, butte_height_m=50.0, butte_cell_m=600.0, butte_wall_m=45.0,
                   detail_m=8.0, feather_m=500.0),
    "very_rugged": dict(cell_m=90.0, step_m=35.0, riser=0.15, joint_depth_m=6.0,
                        joint_width_m=30.0, butte_rate=0.10, butte_height_m=90.0,
                        butte_cell_m=600.0, butte_wall_m=50.0, detail_m=10.0, feather_m=600.0),
}

#: Shader intensity of the small blocks, per level.
INTENSITY = (0.3, 0.5, 0.7, 0.85, 1.0)

#: The rock types, in the order of the shader's type code (RockFieldRelief.STYLES).
STYLES = ("slabs", "columnar", "yardang", "strata", "chalk")

#: Chalk (Seven Sisters): no ledges, no grooves, no buttes — soft knobs of
#: this height (m) per level over LUMP_WAVELENGTH_M, the rest is the shader's
#: (lumpy surface, wandering cracks, flint bands on the walls).
CHALK_LUMP_M = (0.0, 1.5, 3.0, 5.0, 8.0)
LUMP_WAVELENGTH_M = 160.0

#: Fields a user may type to override the preset (NULL = resolved here).
OVERRIDES = ("cell_m", "step_m", "riser", "joint_depth_m", "joint_width_m", "butte_rate",
             "butte_height_m", "butte_cell_m", "butte_wall_m", "detail_m", "feather_m",
             "dip_deg", "dip_azimuth_deg", "wind_azimuth_deg", "elongation", "lump_m",
             "lump_wavelength_m", "seed")

#: Floors the runtime enforces too (RockFieldRelief.prepare).
JOINT_WIDTH_MIN_M = 1.0
CELL_MIN_M = 10.0
DIP_MAX_DEG = 60.0
ELONGATION_MAX = 8.0


def _is_null(v):
    return v is None or v == ""


def _hash_u(points, planet_name, salt):
    """A stable [0, 1) from the feature's centroid (quantised to 0.01°), the
    planet name and a salt — the auto value of a NULL seed / azimuth / dip."""
    if not points:
        return 0.5
    lon = sum(p[0] for p in points) / len(points)
    lat = sum(p[1] for p in points) / len(points)
    ix = int(round(lon * 100.0))
    iy = int(round(lat * 100.0))
    seed = zlib.crc32(str(planet_name or "").encode("utf-8")) & 0x7FFFFFFF
    return mountain_noise.cell(ix, iy, salt, seed)


def unit_vec(lon, lat):
    """HEALPix.lonlat2vec: (cos lat·cos lon, sin lat, cos lat·sin lon)."""
    lo, la = math.radians(lon), math.radians(lat)
    cl = math.cos(la)
    return (cl * math.cos(lo), math.sin(la), cl * math.sin(lo))


def tangent_dir(lon, lat, azimuth_deg):
    """Unit tangent at (lon, lat) pointing azimuth_deg clockwise from north."""
    lo, la = math.radians(lon), math.radians(lat)
    a = math.radians(azimuth_deg)
    east = (-math.sin(lo), 0.0, math.cos(lo))
    north = (-math.sin(la) * math.cos(lo), math.cos(la), -math.sin(la) * math.sin(lo))
    v = tuple(north[i] * math.cos(a) + east[i] * math.sin(a) for i in range(3))
    n = math.sqrt(sum(c * c for c in v)) or 1.0
    return tuple(c / n for c in v)


def _f32(v):
    return struct.unpack("<f", struct.pack("<f", v))[0]


def resolve_rocky(fields, ring, planet_name, radius_m=6356000.0):
    """The feature's fields → the explicit record props (see the module doc).
    Returns a new dict."""
    level = str(fields.get("ruggedness") or "medium")
    if level not in PRESETS:
        level = "medium"
    style = str(fields.get("style") or "slabs")
    if style not in STYLES:
        style = "slabs"
    out = dict(PRESETS[level])
    out["elongation"] = 1.0
    out["dip_deg"] = 0.0
    out["lump_m"] = 0.0
    out["lump_wavelength_m"] = LUMP_WAVELENGTH_M
    # Style adjustments on top of the level (a flat zone stays flat: no
    # buttes, no ledges, whatever its style).
    if level == "flat":
        pass
    elif style == "columnar":
        out["riser"] = max(out["riser"] * 0.4, 0.05)
        out["cell_m"] = out["cell_m"] * 0.75
        out["detail_m"] = out["detail_m"] * 0.7
    elif style == "yardang":
        out["elongation"] = 3.0
        out["butte_rate"] = max(out["butte_rate"] * 3.0, 0.06)
        out["butte_height_m"] = max(out["butte_height_m"], 20.0)
        out["butte_cell_m"] = out["butte_cell_m"] * 0.8
    elif style == "chalk":
        out["step_m"] = 0.0
        out["joint_depth_m"] = 0.0
        out["butte_rate"] = 0.0
        out["lump_m"] = CHALK_LUMP_M[LEVELS.index(level)]
    elif style == "strata":
        out["dip_deg"] = 8.0 + 12.0 * _hash_u(ring, planet_name, 3)
        out["riser"] = out["riser"] * 0.6
    out["dip_azimuth_deg"] = 360.0 * _hash_u(ring, planet_name, 1)
    out["wind_azimuth_deg"] = 360.0 * _hash_u(ring, planet_name, 2)
    out["seed"] = int(_hash_u(ring, planet_name, 4) * 1000000.0)
    for key in OVERRIDES:
        v = fields.get(key)
        if not _is_null(v):
            out[key] = int(v) if key == "seed" else float(v)
    # Clamps (the runtime repeats them).
    out["cell_m"] = max(out["cell_m"], CELL_MIN_M)
    out["step_m"] = max(out["step_m"], 0.0)
    out["riser"] = min(max(out["riser"], 0.02), 1.0)
    out["joint_depth_m"] = max(out["joint_depth_m"], 0.0)
    out["joint_width_m"] = max(out["joint_width_m"], JOINT_WIDTH_MIN_M)
    out["butte_rate"] = min(max(out["butte_rate"], 0.0), 1.0)
    out["butte_height_m"] = max(out["butte_height_m"], 0.0)
    out["butte_cell_m"] = max(out["butte_cell_m"], CELL_MIN_M)
    out["butte_wall_m"] = min(max(out["butte_wall_m"], 1.0), out["butte_cell_m"] * 0.5)
    out["feather_m"] = max(out["feather_m"], FEATHER_MIN_M)
    out["elongation"] = min(max(out["elongation"], 1.0), ELONGATION_MAX)
    out["dip_deg"] = min(max(out["dip_deg"], 0.0), DIP_MAX_DEG)
    out["lump_m"] = max(out["lump_m"], 0.0)
    out["lump_wavelength_m"] = max(out["lump_wavelength_m"], 2.0 * CELL_MIN_M)
    # The vectors, computed once here (no trig at runtime).
    lon = sum(p[0] for p in ring) / len(ring)
    lat = sum(p[1] for p in ring) / len(ring)
    c = unit_vec(lon, lat)
    w = tangent_dir(lon, lat, out["wind_azimuth_deg"])
    d = tangent_dir(lon, lat, out["dip_azimuth_deg"])
    t = math.tan(math.radians(out["dip_deg"]))
    rec = {
        "ruggedness": level,
        "style": style,
        "level": LEVELS.index(level),
        "type": STYLES.index(style),
        "intensity": float(INTENSITY[LEVELS.index(level)]),
        "cx": float(c[0]), "cy": float(c[1]), "cz": float(c[2]),
        "wx": float(w[0]), "wy": float(w[1]), "wz": float(w[2]),
        "k": float(1.0 - 1.0 / out["elongation"]),
        "dpx": float(d[0] * t), "dpy": float(d[1] * t), "dpz": float(d[2] * t),
    }
    for key in ("cell_m", "step_m", "riser", "joint_depth_m", "joint_width_m", "butte_rate",
                "butte_height_m", "butte_cell_m", "butte_wall_m", "detail_m", "feather_m",
                "lump_m", "lump_wavelength_m"):
        rec[key] = float(out[key])
    rec["seed"] = int(out["seed"])
    # The joint and butte means, subtracted at runtime (zero-mean terms):
    # measured on the f32 values the runtime will read.
    f32 = {k: (_f32(v) if isinstance(v, float) else v) for k, v in rec.items()}
    jm, bm = rock_field_noise.term_means(f32, radius_m)
    rec["joint_mean_m"] = float(jm)
    rec["butte_mean_m"] = float(bm)
    if not _is_null(fields.get("name")):
        rec["name"] = str(fields["name"])
    return rec


def build_rocky_part(zones, radius_m, export_nside, max_quadtree_nside, table,
                     verbose=True, planet_name=""):
    """Build the ROCKY part's levels and manifest.

    zones: [{"ring": [(lon, lat), …], "props": {field: value, …}}, …]
    Returns (levels, manifest) for dsmp.write_part(path, dsmp.KIND_ROCKY, …).
    """
    policy = mg.level_policy(export_nside, max_quadtree_nside)["rocky"]
    levels_ns = mg.levels_for(policy)
    slack = SLACK_PITCHES * mg.pixel_side_m(max_quadtree_nside, radius_m) / 32.0

    prepared = []
    for zi, z in enumerate(zones):
        ring = [(float(p[0]), float(p[1])) for p in z.get("ring", [])]
        if len(ring) < MIN_RING_POINTS:
            continue
        rec = resolve_rocky(z.get("props", {}), ring, planet_name, radius_m)
        prepared.append({
            "ring": ring,
            "area": ring_area_deg2(ring),
            "order": zi,
            "margin_m": rec["feather_m"] + slack,
            "type_sid": table.intern("rocky_terrain"),
            "index": zi,
            "props": props_of(rec, table),
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
        "kind": "rocky",
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
