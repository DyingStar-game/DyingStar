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

Full-coverage inheritance ("full_inherit")
------------------------------------------
    A tile lying entirely inside a zone gets a ``full`` record, and its
    descendants at every finer level get NOTHING for that zone: the runtime
    adds the ``full`` records of a tile's ancestors to its own
    (ModifierPack.populate_zones_at).  Without it a zone was rewritten in
    every tile it covers at every level — 10 M records for one plateau on
    tarsis_3, 1.2 GB of part.  Since one tile's zones now come from several
    levels, a record carries its ``rank`` (its place in the overlap order
    below) and the runtime re-sorts the merged list by it.

Overlap rule
------------
    Records of a tile are emitted by descending ``priority`` (the category's
    ``ds_priority`` custom property: liquids 300, regolith 200, outcrop 100,
    everything else 0) and, at equal priority, smallest area first.  Godot
    keeps "first matching zone wins" (PlanetChunk._query_zones_at_direction),
    so the record rank IS the priority — nothing else to interpret at runtime.

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
import struct

from . import dsmp
from . import modifier_geom as mg

#: Feature fields never exported as props.
_SKIP_FIELDS = ("fid", "id", "last_updated", "biome_type", "biome_index")

#: Vertices a clipped piece needs to be worth a record.
MIN_RING_POINTS = 3

#: Highest rank a populate record can carry (u16 slot of the record header).
MAX_RANK = 0xFFFF


def _shift(nside, ancestor_nside):
    """Bits to drop from a NESTED ipix at [nside] to get its [ancestor_nside] ancestor."""
    return 2 * ((nside // ancestor_nside).bit_length() - 1)


def flatten_tile(levels, nside, ipix):
    """Records a tile's zones resolve to, in first-match order: its own plus the
    FULL ones of its ancestors, sorted by rank — what the runtime does
    (ModifierPack.populate_zones_at). [(rank, record_bytes)].

    levels: [(nside, [(ipix, part_tile_payload), …]), …] as build_populate_part
    returns them. Used by the tests and the size probes.
    """
    by_level = {ns: dict(tiles) for ns, tiles in levels}
    out = []
    for ns in sorted(by_level):
        if ns > nside:
            break
        payload = by_level[ns].get(ipix >> _shift(nside, ns))
        if payload is None:
            continue
        for rec in split_records(payload):
            cov = rec[2]
            if ns == nside or cov == dsmp.COVERAGE_FULL:
                out.append((int.from_bytes(rec[10:12], "little"), rec))
    out.sort(key=lambda r: r[0])
    return out


def split_records(payload):
    """The raw POPULATE records of a part tile payload, as bytes."""
    _count, blob = dsmp.split_part_tile(payload)
    out = []
    p = 0
    while p < len(blob):
        _sid, cov, nprops, _bidx, nverts, _rank = struct.unpack_from("<HBBiHH", blob, p)
        size = 12 + 8 * nprops
        if cov == dsmp.COVERAGE_POINT:
            size += 8
        elif cov == dsmp.COVERAGE_PARTIAL:
            size += 8 * nverts
        out.append(bytes(blob[p:p + size]))
        p += size
    return out


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
                        verbose=True, full_inherit=True):
    """Build the POPULATE part's levels and manifest.

    zones: [{"ring": [(lon, lat), …], "biome_type", "biome_index", "props": {…},
             "priority": int}, …]
    table: a dsmp_strings.StringTable, interned into (and left dirty for the
           caller to save).

    full_inherit: False writes every FULL record at every level, as before
                  the inheritance (the reference the tests compare against).

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
    if len(prepared) > MAX_RANK + 1:
        raise dsmp.DsmpError("%d zones exceed the u16 rank of a populate record"
                             % len(prepared))

    levels = []
    counts = {"zones": len(prepared), "records_per_level": {},
              "full_per_level": {}, "inherited_per_level": {}}
    digest = hashlib.sha1()
    # Per zone, the tiles that got a FULL record, level by level: [(nside, {ipix})].
    # Only the coarsest full tiles are kept (their children are inherited), so
    # these sets hold a band along each zone's edge, not its whole interior.
    full_tiles = [[] for _ in prepared]
    for nside in levels_ns:
        # Simplification tolerance: a quarter of a chunk vertex pitch at this
        # level, like the roads — never coarser than the tile itself.
        eps_deg = mg.decim_eps_m(nside, radius_m, 0.0) / mg.m_per_deg(radius_m)
        per_tile = {}
        n_full = 0
        n_inherited = 0
        for rank, zone in enumerate(prepared):
            ancestors = [(_shift(nside, ns), tiles) for ns, tiles in full_tiles[rank]]
            full_here = set()
            for ipix in mg.tiles_for_polygon(nside, zone["ring"], 0.0, radius_m):
                if any((ipix >> sh) in tiles for sh, tiles in ancestors):
                    # A coarser tile holding this one is entirely in the zone.
                    n_inherited += 1
                    continue
                box = mg.tile_bbox(nside, ipix, 0.0)
                if mg.bbox_inside_ring(box, zone["ring"]):
                    rec = dsmp.pack_populate(zone["biome_type_sid"], zone["biome_index"],
                                             dsmp.COVERAGE_FULL, zone["props"], rank=rank)
                    full_here.add(ipix)
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
                                             vertices=piece, rank=rank)
                per_tile.setdefault(ipix, []).append(rec)
            if full_here and full_inherit:
                full_tiles[rank].append((nside, full_here))
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
        counts["inherited_per_level"][str(nside)] = n_inherited
        if verbose:
            print("    n%-5d %6d tiles %7d records (%d full, %d inherited)"
                  % (nside, len(tiles), n_records, n_full, n_inherited))

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
        # A tile's zones = its records + the FULL records of its ancestors,
        # merged by the records' rank. Read by ModifierPack.populate_zones_at.
        "full_inherit": bool(full_inherit),
        # Changes with the drawn regions: PlanetTerrain folds it into the chunk
        # cache key so a re-export re-bakes the vertex colours.
        "fingerprint": digest.hexdigest(),
    }
    return levels, manifest
