"""
Biome REGION polygons → the POPULATE part of the terrain-modifier pack.
=======================================================================

A region drawn in QGIS (one PostGIS table per biome: ``plateau``, ``sand``,
``ocean``…) is a polygon with per-feature fields (``rock_type``, ``clarity``,
``name``, ``density``…).  Godot never gets the whole polygon: it gets, per
HEALPix tile and per level n1…export_nside, the piece of it that touches the
tile — a ``full`` record (12 bytes, no geometry) when the tile lies entirely
inside the polygon, a ``partial`` record with the clipped and simplified ring
otherwise.  A chunk therefore only ever loads the zones of its own tile, and
the number of regions on the planet does not matter: only the overlap count
inside one tile does.

Overlap rule
------------
    Records of a tile are emitted by descending ``priority`` (the category's
    ``ds_priority`` custom property: liquids 300, regolith 200, outcrop 100,
    everything else 0) and, at equal priority, smallest area first.  Godot
    keeps "first matching zone wins" (PlanetChunk._query_zones_at_direction),
    so the record order IS the priority — nothing to interpret at runtime.

Props
-----
    ``rock_type``, ``clarity``, ``name`` and the layer's ``color_hex`` (the
    runtime fallback colour) as string ids, plus every other non-null field of
    the feature — numbers as f32 (``density``, ``canopy_height``, ``depth``…),
    anything else as a string id.  Only the outer ring of a polygon is used;
    an enclave is another region drawn on top.

The rock itself (colours, impurities…) is NOT in the pack: a zone carries the
slug, everything else comes from rocks.json (export_rocks.py).
"""

import hashlib

from . import dsmp
from . import modifier_geom as mg

#: Feature fields never exported as props.
_SKIP_FIELDS = ("fid", "id", "last_updated", "biome_type", "biome_index")

#: Vertices a clipped piece needs to be worth a record.
MIN_RING_POINTS = 3


def ring_area_deg2(ring):
    """Shoelace area in degree², enough to order zones of one tile."""
    a = 0.0
    n = len(ring)
    for i in range(n):
        x0, y0 = ring[i][0], ring[i][1]
        x1, y1 = ring[(i + 1) % n][0], ring[(i + 1) % n][1]
        a += x0 * y1 - x1 * y0
    return abs(a) * 0.5


def props_of(fields, table):
    """``[(key_sid, vtype, value), …]`` from a ``{name: value}`` mapping."""
    out = []
    for key in sorted(fields):
        if key in _SKIP_FIELDS or key.startswith("_"):
            continue
        value = fields[key]
        if value is None or value == "":
            continue
        if isinstance(value, bool):
            out.append((table.intern(key), dsmp.VTYPE_I32, int(value)))
        elif isinstance(value, int):
            out.append((table.intern(key), dsmp.VTYPE_I32, value))
        elif isinstance(value, float):
            out.append((table.intern(key), dsmp.VTYPE_F32, value))
        else:
            out.append((table.intern(key), dsmp.VTYPE_SID, table.intern(str(value))))
    return out


def build_populate_part(zones, radius_m, export_nside, max_quadtree_nside, table,
                        verbose=True):
    """Build the POPULATE part's levels and manifest.

    zones: [{"ring": [(lon, lat), …], "biome_type", "biome_index", "props": {…},
             "priority": int}, …]
    table: a dsmp_strings.StringTable, interned into (and left dirty for the
           caller to save).

    Returns (levels, manifest) ready for dsmp.write_part().
    """
    policy = mg.level_policy(export_nside, max_quadtree_nside)["populate"]
    levels_ns = mg.levels_for(policy)

    prepared = []
    for zi, z in enumerate(zones):
        ring = [(float(p[0]), float(p[1])) for p in z.get("ring", [])]
        if len(ring) < MIN_RING_POINTS:
            continue
        prepared.append({
            "ring": ring,
            "area": ring_area_deg2(ring),
            "priority": int(z.get("priority", 0)),
            "order": zi,
            "biome_type_sid": table.intern(str(z["biome_type"])),
            "biome_index": int(z.get("biome_index", -1)),
            "props": props_of(z.get("props", {}), table),
        })
    # Emission order = overlap rule (see the module docstring); stable on the
    # drawing order for exact ties so re-exports are byte-identical.
    prepared.sort(key=lambda p: (-p["priority"], p["area"], p["order"]))

    levels = []
    counts = {"zones": len(prepared), "records_per_level": {},
              "full_per_level": {}}
    digest = hashlib.sha1()
    for nside in levels_ns:
        # Simplification tolerance: a quarter of a chunk vertex pitch at this
        # level, like the roads — never coarser than the tile itself.
        eps_deg = mg.decim_eps_m(nside, radius_m, 0.0) / mg.m_per_deg(radius_m)
        per_tile = {}
        n_full = 0
        for zone in prepared:
            for ipix in mg.tiles_for_polygon(nside, zone["ring"], 0.0, radius_m):
                box = mg.tile_bbox(nside, ipix, 0.0)
                if mg.bbox_inside_ring(box, zone["ring"]):
                    rec = dsmp.pack_populate(zone["biome_type_sid"], zone["biome_index"],
                                             dsmp.COVERAGE_FULL, zone["props"])
                    n_full += 1
                else:
                    piece = mg.clip_polygon_to_bbox(zone["ring"], box)
                    if len(piece) < MIN_RING_POINTS:
                        continue
                    piece = mg.simplify_ring(piece, eps_deg)
                    if len(piece) < MIN_RING_POINTS:
                        continue
                    rec = dsmp.pack_populate(zone["biome_type_sid"], zone["biome_index"],
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
        "kind": "populate",
        "max_nside": policy["max"],
        "min_nside": policy["min"],
        "levels": levels_ns,
        "export_nside": export_nside,
        "max_quadtree_nside": max_quadtree_nside,
        "radius": radius_m,
        "counts": counts,
        "priority_rule": "first-match",
        # Changes with the drawn regions: PlanetTerrain folds it into the chunk
        # cache key so a re-export re-bakes the vertex colours.
        "fingerprint": digest.hexdigest(),
    }
    return levels, manifest
