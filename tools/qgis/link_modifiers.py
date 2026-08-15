"""
Reassemble <planet>_chunks/terrainmodifier.pack from the per-kind parts.

    assets/qgis/export/<planet>_chunks/
        heights.pack                (DSHP, untouched)
        manifest.json
        terrainmodifier.pack        <- DERIVED, written by this script
        parts/
            strings.json            global, append-only
            roads.dsmpart           written by export_roads.py
            craters.dsmpart         written by export_craters.py
            caves.dsmpart           written by export_caves.py
            rivers.dsmpart          written by export_rivers.py
            biomes.dsmpart          written by export_biomes.py

Each exporter rewrites only its own part and then calls link(), so exporting
roads cannot disturb craters. That is the whole reason the pack is a derived
file rather than something an exporter edits in place.

Linking is pure concatenation: because the string table is append-only
(export/planet/dsmp_strings.py), a part's u16 string ids stay valid forever, so
record blocks are copied byte for byte and never re-encoded. Two links over
unchanged parts therefore produce a byte-identical pack.

Deliberately NOT supported in v1: compacting the string table. Dropping orphaned
entries would renumber ids and invalidate every part on disk; the table only
grows, and the u16 space (65535) is three orders of magnitude beyond what a
planet uses.

Usage — from the QGIS Python console (the exporters call link() for you):

    exec(open('.../tools/qgis/link_modifiers.py').read())
    link('tarsis_4')

or from a shell:

    python3 tools/qgis/link_modifiers.py tarsis_4
    python3 tools/qgis/link_modifiers.py tarsis_4 --explode

No QGIS import: this module is pure stdlib + the dsmp encoder.
"""
import glob
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from export.planet import dsmp                                    # noqa: E402
from export.planet.dsmp_strings import StringTable                # noqa: E402

#: Warn when a level's tile count gets big enough to matter for the index.
MAX_TILES_PER_LEVEL = 2_000_000

#: Fallback when neither the environment nor export_config.ini says otherwise.
_DEFAULT_EXPORT_DIR = ("/datas/developpement/sources/DyingStar-game/DyingStar"
                       "/assets/qgis/export")


def resolve_export_dir():
    """DS_EXPORT_DIR -> export_config.ini [paths] export_dir -> the default.

    The historical constant points at a checkout path that does not exist on
    every machine, so it is the last resort rather than the only option.
    """
    env = os.environ.get("DS_EXPORT_DIR")
    if env:
        return env
    ini = os.path.join(_HERE, "export_config.ini")
    if os.path.exists(ini):
        try:
            import configparser
            cp = configparser.ConfigParser()
            cp.read(ini)
            if cp.has_option("paths", "export_dir"):
                v = cp.get("paths", "export_dir").strip()
                if v:
                    return v
        except Exception as exc:                      # pragma: no cover
            print("  ! could not read export_config.ini: %s" % exc)
    return _DEFAULT_EXPORT_DIR


def chunks_dir_for(planet_name, export_dir=None):
    return os.path.join(export_dir or resolve_export_dir(),
                        "%s_chunks" % planet_name)


def parts_dir_for(planet_name, export_dir=None):
    return os.path.join(chunks_dir_for(planet_name, export_dir), "parts")


# ── Linking ─────────────────────────────────────────────────────────────

def _load_parts(parts_dir):
    """Read every .dsmpart, keyed by kind. Raises on a duplicated kind."""
    parts = {}
    for path in sorted(glob.glob(os.path.join(parts_dir, "*.dsmpart"))):
        c = dsmp.read_container(path)
        if c["magic"] != dsmp.MAGIC_PART:
            raise dsmp.DsmpError("%s is not a part (magic %r)" % (path, c["magic"]))
        kind = c["kind"]
        if kind in parts:
            raise dsmp.DsmpError(
                "two parts claim kind %s: %s and %s"
                % (dsmp.KIND_NAMES.get(kind, kind), parts[kind]["path"], path))
        c["path"] = path
        parts[kind] = c
    return parts


def _planet_meta(parts, chunks_dir):
    """Merge the planet-level metadata the parts agree on.

    Every part carries it, so a stale part exported against a different planet
    geometry is caught here rather than producing a subtly wrong pack.
    """
    meta = {}
    for kind, c in sorted(parts.items()):
        m = c["manifest"]
        for key in ("planet_name", "radius", "export_nside", "max_quadtree_nside"):
            if key not in m:
                continue
            if key in meta and meta[key] != m[key]:
                raise dsmp.DsmpError(
                    "part %s disagrees on %s (%r vs %r) — re-export the stale "
                    "part" % (os.path.basename(c["path"]), key, meta[key], m[key]))
            meta[key] = m[key]
    # Fall back to the elevation manifest for anything no part declared.
    hm_path = os.path.join(chunks_dir, "manifest.json")
    if os.path.exists(hm_path):
        with open(hm_path, "r", encoding="utf-8") as fh:
            hm = json.load(fh)
        meta.setdefault("planet_name", hm.get("planet_name"))
        meta.setdefault("radius", hm.get("radius"))
        meta.setdefault("export_nside", hm.get("nside_max", hm.get("nside")))
    return meta


def _merge_levels(parts):
    """{nside: {ipix: {kind: (record_count, block_bytes)}}}."""
    merged = {}
    for kind, c in sorted(parts.items()):
        for nside, tiles in c["levels"]:
            per_level = merged.setdefault(nside, {})
            for ipix, payload in tiles:
                count, records = dsmp.split_part_tile(payload)
                if count == 0 or not records:
                    continue
                per_level.setdefault(ipix, {})[kind] = (count, records)
    return merged


def link(planet_name, export_dir=None, verbose=True):
    """Rebuild terrainmodifier.pack from every part present. Returns its path."""
    chunks_dir = chunks_dir_for(planet_name, export_dir)
    parts_dir = os.path.join(chunks_dir, "parts")
    if not os.path.isdir(parts_dir):
        raise dsmp.DsmpError(
            "no parts directory at %s — run an exporter first "
            "(export_roads.py, export_craters.py, …)" % parts_dir)

    parts = _load_parts(parts_dir)
    if not parts:
        raise dsmp.DsmpError("no .dsmpart files in %s" % parts_dir)

    table = StringTable.load(parts_dir)
    meta = _planet_meta(parts, chunks_dir)
    merged = _merge_levels(parts)

    kind_max = {}
    part_info = {}
    for kind, c in sorted(parts.items()):
        name = dsmp.KIND_NAMES.get(kind, str(kind))
        m = c["manifest"]
        kind_max[name] = int(m.get("max_nside", 0))
        part_info[name] = {
            "file": os.path.basename(c["path"]),
            "generated_at": m.get("generated_at"),
            "generated_by": m.get("generated_by"),
            "source_layer": m.get("source_layer"),
            "counts": m.get("counts", {}),
        }

    # The invariant the whole design rests on: a chunk finer than the deepest
    # baked ROAD level would fall back to a shared ancestor tile, and a shared
    # tile means two chunks extruding the same road at different heights.
    mqn = int(meta.get("max_quadtree_nside", 0) or 0)
    road_max = kind_max.get("road", 0)
    if road_max and mqn and road_max < mqn:
        raise dsmp.DsmpError(
            "roads are baked only to n%d but the quadtree reaches n%d — chunks "
            "below n%d would share an ancestor tile and render the road twice. "
            "Re-export roads with max_nside >= %d."
            % (road_max, mqn, road_max, mqn))

    levels = []
    tile_counts = {}
    for nside in sorted(merged):
        per_level = merged[nside]
        if len(per_level) > MAX_TILES_PER_LEVEL:
            print("  ! level n%d has %d tiles (over %d) — the index alone is "
                  "%.1f MB" % (nside, len(per_level), MAX_TILES_PER_LEVEL,
                               len(per_level) * 16 / 1e6))
        tiles = []
        by_kind = {}
        for ipix in sorted(per_level):
            blocks = per_level[ipix]
            tiles.append((ipix, dsmp.build_tile(blocks)))
            for k in blocks:
                by_kind[dsmp.KIND_NAMES.get(k, str(k))] = \
                    by_kind.get(dsmp.KIND_NAMES.get(k, str(k)), 0) + 1
        levels.append((nside, tiles))
        tile_counts[str(nside)] = by_kind

    all_nsides = sorted(merged)
    manifest = {
        "format": "dsmp_v1",
        "pack_file": "terrainmodifier.pack",
        "planet_name": meta.get("planet_name", planet_name),
        "radius": meta.get("radius"),
        "export_nside": meta.get("export_nside"),
        "max_quadtree_nside": meta.get("max_quadtree_nside"),
        "nside_min": all_nsides[0] if all_nsides else 0,
        "nside_max": all_nsides[-1] if all_nsides else 0,
        "levels": all_nsides,
        "kind_max_nside": kind_max,
        "coord_scale": dsmp.COORD_SCALE,
        "strings": table.as_list(),
        "parts": part_info,
        "tile_counts": tile_counts,
    }

    out_path = os.path.join(chunks_dir, "terrainmodifier.pack")
    dsmp.write_pack(out_path, levels, manifest)

    if verbose:
        total_tiles = sum(len(t) for _n, t in levels)
        size = os.path.getsize(out_path)
        print("  linked %s" % out_path)
        print("    parts    : %s" % ", ".join(sorted(part_info)))
        print("    levels   : n%d..n%d (%d)"
              % (manifest["nside_min"], manifest["nside_max"], len(all_nsides)))
        print("    tiles    : %d" % total_tiles)
        print("    strings  : %d" % len(table))
        print("    size     : %.2f MB" % (size / 1e6))
        for name in sorted(kind_max):
            print("    %-9s: baked to n%d" % (name, kind_max[name]))
    return out_path


# ── Explode (bootstrap parts from an existing pack) ─────────────────────

def explode(planet_name, export_dir=None, verbose=True):
    """Regenerate parts/ (and strings.json) from an existing pack.

    For a checkout that has terrainmodifier.pack but no parts/ — after which
    incremental per-kind exports work again. link(explode(x)) == x.
    """
    chunks_dir = chunks_dir_for(planet_name, export_dir)
    pack_path = os.path.join(chunks_dir, "terrainmodifier.pack")
    if not os.path.exists(pack_path):
        raise dsmp.DsmpError("no pack at %s" % pack_path)
    parts_dir = os.path.join(chunks_dir, "parts")
    os.makedirs(parts_dir, exist_ok=True)

    c = dsmp.read_container(pack_path)
    if c["magic"] != dsmp.MAGIC_PACK:
        raise dsmp.DsmpError("%s is not a pack" % pack_path)
    manifest = c["manifest"]

    StringTable(manifest.get("strings", [])).save(parts_dir, force=True)

    # kind -> nside -> [(ipix, records)]
    per_kind = {}
    for nside, tiles in c["levels"]:
        for ipix, payload in tiles:
            for kind, (count, records) in dsmp.split_pack_tile(payload).items():
                if count == 0 or not records:
                    continue
                per_kind.setdefault(kind, {}).setdefault(nside, []).append(
                    (ipix, dsmp.part_tile(count, records)))

    written = []
    for kind, levels_map in sorted(per_kind.items()):
        name = dsmp.KIND_NAMES.get(kind, str(kind))
        levels = [(ns, sorted(t, key=lambda e: e[0]))
                  for ns, t in sorted(levels_map.items())]
        pm = dict(manifest.get("parts", {}).get(name, {}))
        pm.update({
            "kind": name,
            "planet_name": manifest.get("planet_name", planet_name),
            "radius": manifest.get("radius"),
            "export_nside": manifest.get("export_nside"),
            "max_quadtree_nside": manifest.get("max_quadtree_nside"),
            "max_nside": manifest.get("kind_max_nside", {}).get(
                name, levels[-1][0] if levels else 0),
            "levels": [ns for ns, _t in levels],
        })
        # Provenance is preserved, not overwritten: relinking exploded parts
        # must reproduce the original pack byte for byte, and the pack manifest
        # echoes generated_by / generated_at / source_layer back out.
        pm.setdefault("generated_by", "link_modifiers.explode")
        pm["exploded_from"] = os.path.basename(pack_path)
        pm.pop("file", None)
        path = os.path.join(parts_dir, "%s.dsmpart" % _part_basename(name))
        dsmp.write_part(path, kind, levels, pm)
        written.append(path)
        if verbose:
            print("  exploded %s (%d levels)" % (os.path.basename(path), len(levels)))
    return written


#: Part file basenames. Plural where the exporter is named that way.
_PART_BASENAMES = {
    "road": "roads",
    "crater": "craters",
    "radial": "caves",
    "linear": "rivers",
    "populate": "biomes",
}


def _part_basename(kind_name):
    return _PART_BASENAMES.get(kind_name, kind_name)


def part_path(planet_name, kind_name, export_dir=None):
    """Where the exporter for [kind_name] must write its part."""
    return os.path.join(parts_dir_for(planet_name, export_dir),
                        "%s.dsmpart" % _part_basename(kind_name))


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print(__doc__)
        return 1
    planet = argv[0]
    if "--explode" in argv:
        explode(planet)
        return 0
    link(planet)
    return 0


if __name__ == "__main__":
    sys.exit(main())
