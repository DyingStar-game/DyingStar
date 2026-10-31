"""
Export the `cave_site` point layer (layers/caves.py) to the persistence import.
==============================================================================

One entry per point: its longitude / latitude (EPSG:4326, the game's
CavePlacement.longitude_deg / latitude_deg with no conversion, format 2) and
every attribute of the layer, under the names CavePlacement.from_prop_data
reads.  Two files::

    QGIS ── export_cave_sites.py ──▶ <dir>/<planet>_cave_sites.json   (authored)
                                 ──▶ <dir>/<planet>_cave_items.json   (admin panel import)
    admin panel ▸ import ◀── <dir>/<planet>_cave_items.json

The import carries the authored caves NOT fitted to the relief (terrain_version
empty): the game server fits each one when a player first comes within ~3 km
of it (CaveSite) and persists the result.  The optional Godot step fits them
all beforehand, lists the refused ones and rewrites the same import file::

    <godot> --headless --path <repo> res://tools/stargrot/fit_cave_items.tscn \\
        -- --in=<dir>/<planet>_cave_sites.json

Importing this file again resets every cave to "not fitted": the server fits
them again as players come near.  The prop uuids derive from the placement ids
(PropSpawn.stable_uuid), so an import updates the caves instead of adding new
ones.

A point added in QGIS without a `placement_id` gets one here, written back
into the layer: it is the cave's identity (its prop uuid derives from it), so
it must not change between two exports.

The file is PRIVATE: it goes outside the repository, to
    $DS_CAVE_EXPORT_DIR, else export_config.ini [paths] cave_export_dir,
    else ~/dyingstar-private/caves/

Run from the QGIS Python Console:
    exec(open('/datas/developpement/sources/DyingStar-game/DyingStar/tools/planettech/qgis/export_cave_sites.py').read())
"""
import configparser
import json
import math
import os
import uuid

from qgis.core import QgsExpressionContextUtils, QgsProject, QgsVectorLayer, QgsWkbTypes

# Only used when exec()'d from the console (no __file__): where export_config.ini lives.
TOOLS_DIR = "/datas/developpement/sources/DyingStar-game/DyingStar/tools/planettech/qgis"
DEFAULT_EXPORT_DIR = os.path.expanduser("~/dyingstar-private/caves")
# Columns that are not cave parameters.
SKIPPED = {"fid", "geom", "last_updated"}
# Integer columns the game reads as booleans.
BOOLEANS = {"exit_open"}
# PropSpawn.STABLE_UUID_NAMESPACE: a cave's prop uuid is uuid5(namespace, "cave:" + placement_id).
STABLE_UUID_NAMESPACE = uuid.UUID("a0affe13-815e-4162-b78b-e3988ca71339")
# The Horizon alias of each planet's object, the caves' parent (fit_cave_items.gd PARENT_ALIASES); the
# project variable planet_parent_id overrides it.
PARENT_ALIASES = {"tarsis_3": "_planet_SandBox"}
CAVE_SCENE = "scenes/planet/cave/cave_site.tscn"

_project = QgsProject.instance()
_scope = QgsExpressionContextUtils.projectScope(_project)
PLANET_NAME = str(_scope.variable("planet_name") or "")
PLANET_RADIUS = float(_scope.variable("planet_radius_m") or 6_356_000)
PLANET_PARENT = str(_scope.variable("planet_parent_id") or PARENT_ALIASES.get(PLANET_NAME, ""))


def resolve_export_dir():
    """DS_CAVE_EXPORT_DIR -> export_config.ini [paths] cave_export_dir -> ~/dyingstar-private/caves."""
    env = os.environ.get("DS_CAVE_EXPORT_DIR")
    if env:
        return env
    here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else TOOLS_DIR
    ini = os.path.join(here, "export_config.ini")
    if os.path.exists(ini):
        cp = configparser.ConfigParser()
        cp.read(ini)
        if cp.has_option("paths", "cave_export_dir") and cp.get("paths", "cave_export_dir").strip():
            return os.path.expanduser(cp.get("paths", "cave_export_dir").strip())
    return DEFAULT_EXPORT_DIR


def find_cave_layer():
    for layer in _project.mapLayers().values():
        if isinstance(layer, QgsVectorLayer) and layer.customProperty("ds_kind") == "cave_site":
            return layer
    raise RuntimeError("No cave_site layer in this project: run setup_planet_project.py (category caves)")


def _is_null(value):
    if value is None:
        return True
    if hasattr(value, "isNull"):
        return bool(value.isNull())
    return str(value) == "NULL"


def _value(field, value):
    """The attribute as the JSON type the game expects, None when NULL."""
    if _is_null(value):
        return None
    if field.name() in BOOLEANS:
        return bool(int(value))
    # PyQGIS hands integer, double and string columns back as Python int, float and str.
    return value if isinstance(value, (int, float, str)) else str(value)


def _point(geom):
    if geom is None or geom.isEmpty():
        return None
    if QgsWkbTypes.isMultiType(geom.wkbType()):
        points = geom.asMultiPoint()
        return points[0] if points else None
    return geom.asPoint()


def _assign_missing_ids(layer):
    """Give every point without a placement_id a stable one, saved in the layer."""
    index = layer.fields().indexOf("placement_id")
    missing = [f.id() for f in layer.getFeatures() if _is_null(f["placement_id"]) or not str(f["placement_id"]).strip()]
    if not missing:
        return 0
    changes = {fid: {index: "qgis-%s-%s" % (PLANET_NAME, uuid.uuid4().hex[:8])} for fid in missing}
    if not layer.dataProvider().changeAttributeValues(changes):
        raise RuntimeError("Could not write the new placement_id values into %s" % layer.name())
    layer.reload()
    return len(missing)


def _item(site):
    """The admin panel import entry of an authored cave: a "cave" prop not fitted to the relief yet."""
    lon = math.radians(site["longitude_deg"])
    lat = math.radians(site["latitude_deg"])
    # CaveTerrain.lonlat_to_dir, at sea level: the server places it on the ground once fitted.
    direction = (math.cos(lat) * math.cos(lon), math.sin(lat), -math.cos(lat) * math.sin(lon))
    data = dict(site)
    data.update({
        "parent_id": PLANET_PARENT,
        "scenename": CAVE_SCENE,
        "position": {"x": direction[0] * PLANET_RADIUS, "y": direction[1] * PLANET_RADIUS,
                     "z": direction[2] * PLANET_RADIUS},
        "rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
        # Clears a previous fit and refusal: the definition may have changed.
        "terrain_version": "",
        "terrain_relief_signature": "",
        "fit_error": {},
    })
    return {"object_type": "cave",
            "object_uuid": str(uuid.uuid5(STABLE_UUID_NAMESPACE, "cave:" + site["placement_id"])),
            "object_data": data}


def _write_json(path, payload):
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as out:
        json.dump(payload, out, indent=1, ensure_ascii=False)
        out.write("\n")
    os.replace(tmp_path, path)


def export():
    if not PLANET_NAME:
        raise RuntimeError("The project has no planet_name variable (setup_planet_project.py sets it)")
    if not PLANET_PARENT:
        raise RuntimeError("No Horizon parent known for %s: set the project variable planet_parent_id "
                           "(_planet_<name>, as the admin panel shows it)" % PLANET_NAME)
    layer = find_cave_layer()
    if layer.isEditable():
        raise RuntimeError("Save or roll back the edits of %s first" % layer.name())
    added = _assign_missing_ids(layer)
    fields = [f for f in layer.fields() if f.name() not in SKIPPED]
    sites = []
    seen = set()
    for feat in layer.getFeatures():
        point = _point(feat.geometry())
        if point is None:
            print("  ! cave %s has no point: skipped" % feat.id())
            continue
        site = {"longitude_deg": point.x(), "latitude_deg": point.y(),
                "planet_name": PLANET_NAME, "planet_radius_m": PLANET_RADIUS, "format_version": 2}
        for field in fields:
            value = _value(field, feat[field.name()])
            if value is not None:
                site[field.name()] = value
        if site["placement_id"] in seen:
            raise RuntimeError("Two caves share the placement_id %s" % site["placement_id"])
        seen.add(site["placement_id"])
        site.setdefault("name", site["placement_id"])
        sites.append(site)
    sites.sort(key=lambda s: s["placement_id"])
    out_dir = resolve_export_dir()
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "%s_cave_sites.json" % PLANET_NAME)
    _write_json(out_path, {"planet_name": PLANET_NAME, "planet_radius": PLANET_RADIUS, "crs": "EPSG:4326",
                           "count": len(sites), "sites": sites})
    items_path = os.path.join(out_dir, "%s_cave_items.json" % PLANET_NAME)
    _write_json(items_path, [_item(site) for site in sites])
    print("[export_cave_sites] %d caves (%d new ids) -> %s" % (len(sites), added, out_path))
    print("[export_cave_sites] admin panel import (not fitted, the server fits them) -> %s" % items_path)
    return out_path


export()
