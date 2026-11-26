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
            mountains.dsmpart       written by export_mountains.py
            ridges.dsmpart          written by export_mountains.py
            volcanoes.dsmpart       written by export_volcanoes.py
            lava_flows.dsmpart      written by export_volcanoes.py
            fumaroles.dsmpart       written by export_volcanoes.py
            rocky_terrain.dsmpart   written by export_rocky_terrain.py

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

Usage — DyingStar ▸ Publication ▸ Relink in QGIS (the exporters call link() for you), or
from the QGIS Python console:

    import link_modifiers; link_modifiers.link('tarsis_4')

or from a shell:

    python3 tools/planettech/qgis/link_modifiers.py tarsis_4
    python3 tools/planettech/qgis/link_modifiers.py tarsis_4 --explode

No QGIS import: this module is pure stdlib + the dsmp encoder.
"""
import glob
import hashlib
import json
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from export.planet import dsmp                                    # noqa: E402
from export.planet.dsmp_strings import StringTable                # noqa: E402

#: Warn when a level's tile count gets big enough to matter for the index.
MAX_TILES_PER_LEVEL = 2_000_000



def repo_root():
    """The DyingStar checkout these scripts belong to: the first parent of their REAL path
    holding project.godot (the plugin is loaded through a symlink); else $DS_REPO_DIR.

    The scripts' own checkout always wins: the Godot tools and the publication scripts they
    start must be the same version as them — another checkout may be on a branch without them.
    $DS_REPO_DIR (the plugin setting) only serves a copy installed from a zip, outside any
    checkout. None when neither finds one.
    """
    d = os.path.realpath(_HERE)
    while d != os.path.dirname(d):
        if os.path.exists(os.path.join(d, "project.godot")):
            return d
        d = os.path.dirname(d)
    env = os.environ.get("DS_REPO_DIR", "").strip()
    if env:
        return os.path.abspath(os.path.expanduser(env))
    return None


def _default_export_dir():
    root = repo_root()
    if root is None:
        raise RuntimeError("DyingStar checkout not found: set the repository folder in the "
                           "plugin settings (or $DS_REPO_DIR / $DS_EXPORT_DIR)")
    return os.path.join(root, "assets", "qgis", "export")


def auto_publish(path):
    """Hand [path] to tools/planettech/publish/publish_remote.py, in the background.

    Only when a target is configured (export_config.ini [publish] ssh, or $DS_PUBLISH_SSH):
    the game reads nothing local any more, so an export is only seen once published. Loaded
    from its file on every call — the QGIS console keeps one interpreter alive, and a stale
    module would publish with yesterday's code. Never raises: a failed hand-over must not
    fail the export, it is reported. Returns the log path or None.

    Only a file of the REAL export directory (resolve_export_dir) is ever published: a test
    linking a pack in a temporary directory must not ship it to the players' service.
    """
    if not _in_export_dir(path):
        return None
    try:
        log = _publish_remote().publish_in_background(path)
    except Exception as exc:  # noqa: BLE001 — the export itself succeeded
        print("  ! publication not started: %s" % exc)
        return None
    if log:
        print("  ⇪ publishing %s to the tile service in the background — log: %s"
              % (os.path.basename(path), log))
    return log


def _in_export_dir(path):
    export_root = os.path.abspath(resolve_export_dir()) + os.sep
    return os.path.abspath(path).startswith(export_root)


def _publish_remote():
    """tools/planettech/publish/publish_remote.py, chargé de son fichier à chaque appel."""
    import importlib.util
    root = repo_root()
    script = (os.path.join(root, "tools", "planettech", "publish", "publish_remote.py") if root
              else os.path.abspath(os.path.join(_HERE, "..", "publish", "publish_remote.py")))
    spec = importlib.util.spec_from_file_location("ds_publish_remote", script)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def pull_parts(planet_name, export_dir=None):
    """Bring parts/ up to the server's version BEFORE an exporter writes its own part.

    The parts are no longer in git: the server keeps the last published pack, which holds
    them all (explode). Every exporter calls this first, so that it rewrites ONE family on
    top of the team's latest and appends to the server's string table. See publish_remote.py
    "LES PARTS VIVENT SUR LE SERVEUR". A no-op without a [publish] target, or outside the
    real export directory (tests).

    Raises when this machine AND the server both changed the pack since they last agreed:
    going on would overwrite one of the two. Any other failure (server unreachable…) is
    reported and the export goes on with the local parts — publishing will refuse later
    if that would overwrite someone.
    """
    pack = os.path.join(chunks_dir_for(planet_name, export_dir), "terrainmodifier.pack")
    if not _in_export_dir(pack):
        return None
    try:
        mod = _publish_remote()
    except Exception as exc:  # noqa: BLE001
        print("  ! parts not synchronised: %s" % exc)
        return None
    try:
        state = mod.pull_for_export(pack)
    except mod.PartsConflict:
        raise
    except Exception as exc:  # noqa: BLE001 — the local parts are still usable
        print("  ! parts not synchronised with the server: %s" % exc)
        return None
    print("  parts %s: %s" % (planet_name, state))
    return state


def resolve_export_dir():
    """DS_EXPORT_DIR -> export_config.ini [paths] export_dir -> <checkout>/assets/qgis/export."""
    found = resolve_path("DS_EXPORT_DIR", "export_dir", None)
    return found if found else _default_export_dir()


def resolve_path(env_name, ini_key, default):
    """$<env_name> -> export_config.ini [paths] <ini_key> -> [default].

    One lookup for every configurable path, so each machine points the exporters at its own
    checkout without editing them. An unreadable export_config.ini is reported and skipped.
    """
    env = os.environ.get(env_name)
    if env:
        return env
    ini = os.path.join(_HERE, "export_config.ini")
    if os.path.exists(ini):
        try:
            import configparser
            cp = configparser.ConfigParser()
            cp.read(ini)
            if cp.has_option("paths", ini_key):
                v = cp.get("paths", ini_key).strip()
                if v:
                    return os.path.expanduser(v)
        except Exception as exc:                      # pragma: no cover
            print("  ! could not read export_config.ini: %s" % exc)
    return default


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
    # Fall back to the elevation manifest for anything no part declared —
    # and refuse a part measured against ANOTHER planet than the elevation:
    # the parts' along-metres, degree half-widths and buffers all come from
    # the exporter's radius (the QGIS project variable planet_radius_m), and
    # the runtime takes the planet's radius from the elevation manifest. A
    # road part at 5 875 km on tarsis_3's 6 356 km laid every length along
    # the railway 7.6 % short: a 10 cm gap in every rail joint.
    hm_path = os.path.join(chunks_dir, "manifest.json")
    if os.path.exists(hm_path):
        with open(hm_path, "r", encoding="utf-8") as fh:
            hm = json.load(fh)
        hm_radius = hm.get("radius")
        if hm_radius and meta.get("radius") \
                and abs(float(meta["radius"]) - float(hm_radius)) > 0.001 * float(hm_radius):
            raise dsmp.DsmpError(
                "the parts were exported for a planet radius of %s m but the "
                "elevation (manifest.json) is at %s m — set the QGIS project "
                "variable planet_radius_m to %s and re-export every part"
                % (meta["radius"], hm_radius, hm_radius))
        if hm.get("planet_name") and meta.get("planet_name") \
                and meta["planet_name"] != hm.get("planet_name"):
            raise dsmp.DsmpError(
                "the parts are for planet %r but the elevation is %r"
                % (meta["planet_name"], hm.get("planet_name")))
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


def link(planet_name, export_dir=None, verbose=True, publish=True):
    """Rebuild terrainmodifier.pack from every part present. Returns its path.

    [publish]: then hand the pack to the tile service in the background (auto_publish), when
    a target is configured — the game reads nothing else.
    """
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
        # Per-kind metadata the runtime decoder needs before it reads a tile:
        # the ROAD record layout revision and whether any road is grade-limited.
        for key in ("record_layout", "profiled_roads", "fingerprint", "priority_rule",
                    "full_inherit"):
            if key in m:
                part_info[name][key] = m[key]

    # The invariant the whole design rests on: a chunk finer than the deepest
    # baked ROAD level would fall back to a shared ancestor tile, and a shared
    # tile means two chunks extruding the same road at different heights.
    # Lava flows are emitted geometry too (a crust ribbon), same invariant.
    mqn = int(meta.get("max_quadtree_nside", 0) or 0)
    for deep_kind, what, one in (("road", "roads", "the road"),
                                 ("lava", "lava flows", "the lava flow")):
        deep_max = kind_max.get(deep_kind, 0)
        if deep_max and mqn and deep_max < mqn:
            raise dsmp.DsmpError(
                "%s are baked only to n%d but the quadtree reaches n%d — chunks "
                "below n%d would share an ancestor tile and render %s twice. "
                "Re-export %s with max_nside >= %d."
                % (what, deep_max, mqn, deep_max, one, what, mqn))

    levels = []
    tile_counts = {}
    # The pack's identity, from what a reader sees: every tile's bytes and the
    # string table. It names the published version (publish_tiles.py serves
    # <planet>.mod/<data_version>/), so two links of the same parts give the
    # same version and any changed byte gives a new one.
    version_digest = hashlib.blake2b(digest_size=8)
    version_digest.update(json.dumps(table.as_list(), ensure_ascii=False).encode("utf-8"))
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
            payload = dsmp.build_tile(blocks)
            tiles.append((ipix, payload))
            version_digest.update(struct.pack("<III", nside, ipix, len(payload)))
            version_digest.update(payload)
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
        "data_version": version_digest.hexdigest(),
    }

    out_path = os.path.join(chunks_dir, "terrainmodifier.pack")
    dsmp.write_pack(out_path, levels, manifest)
    if publish:
        auto_publish(out_path)

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
        # The railway / graded-road / lava profiles are baked from this pack
        # and the relief: a new pack leaves grade_profiles.pack stale, and the
        # game then profiles every line at run time (minutes on a long line).
        if any(k in part_info for k in ("road", "lava", "mountain", "ridge", "volcano", "rocky",
                                         "populate")):
            print("  ! re-bake the line profiles (tile service required):")
            print("      godot --headless --path . res://tools/bake_grade_profiles.tscn -- --planet=%s"
                  % planet_name)
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

    # A family exported with nothing in it (no fumarole on this planet) has no tile to be
    # found by, yet its part is in the manifest and must come back: relinking without it
    # would drop it from the manifest, and the pack would no longer be byte-identical.
    kind_of = {name: kind for kind, name in dsmp.KIND_NAMES.items()}
    for name, info in manifest.get("parts", {}).items():
        kind = kind_of.get(name)
        if kind is not None and kind not in per_kind:
            per_level = info.get("counts", {}).get("records_per_level", {}) \
                or {manifest.get("kind_max_nside", {}).get(name, 0): 0}
            per_kind[kind] = {int(ns): [] for ns in per_level if int(ns) > 0}

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
    "mountain": "mountains",
    "ridge": "ridges",
    "volcano": "volcanoes",
    "lava": "lava_flows",
    "fumarole": "fumaroles",
    "rocky": "rocky_terrain",
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
