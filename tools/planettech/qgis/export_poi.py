"""
Export the `poi` point layer to a compact JSON consumed by Godot.
================================================================

The POI layer is created by setup_planet_project.py as a PostGIS Point table
(EPSG:4326) with the fields `name`, `poi_type`, `population`, `radius`,
`elevation` and `description`. This script flattens it into one JSON file that
PlanetTerrain's "Import POI from JSON" inspector button reads back.

Coordinates
-----------
    Features are stored as longitude/latitude in degrees (EPSG:4326). The
    pipeline treats them as directions on a perfect sphere — the WGS84
    ellipsoid is ignored — so Godot's HEALPix.lonlat2vec() reproduces the same
    unit direction:  (cos φ·cos λ, sin φ, cos φ·sin λ), Y = polar axis.

Elevation
---------
    `elevation` is an OPTIONAL override, in metres above sea level. Left NULL
    (the normal case) it is exported as null and Godot samples the terrain
    heightmap instead, which is what puts the POI on the actual ground.

Regions
-------
    The `region` polygon layer (lore names, map labels — not a biome) is
    exported here too, as one simplified outline per region: see
    export/planet/regions.py. It no longer goes into the terrain-modifier pack.

Output
------
    <EXPORT_DIR>/<planet>_poi.json

    {
      "planet_name": "tarsis_4",
      "planet_radius": 6356000.0,        # metres, NOT the per-POI radius
      "crs": "EPSG:4326",
      "count": 2,
      "pois": [
        {"id": 1, "name": "Mine Village", "poi_type": "mining village",
         "population": 1200, "radius": 200.0, "description": "…",
         "lon": -83.7, "lat": 11.5, "elevation": null}
      ],
      "regions": [
        {"name": "Rox Planum Centralis", "rings": [[[lon, lat], …]],
         "bbox": [lon0, lat0, lon1, lat1]}
      ]
    }

Run from QGIS: DyingStar ▸ Export ▸ POI (the plugin). From the Python console:
    import export_poi; export_poi.run()
"""
import os
import json
import sys

from qgis.core import (
    Qgis,
    QgsProject,
    QgsVectorLayer,
)

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

from export.planet import regions as regions_lib        # noqa: E402
import ds_project                                       # noqa: E402
import link_modifiers                                   # noqa: E402

# ============================================================
# CONFIGURATION — edit for your planet
# ============================================================
# The planet of the open project, read by _configure() at each run (ds_project.py).
PLANET_NAME = None
# Planet radius in metres (sea-level surface). Only carried through to the JSON
# as a sanity reference — Godot uses the radius from its own chunk manifest.
PLANET_RADIUS = None
# Same directory as export_elevation.py — both exports must land side by side.
EXPORT_DIR = None

# Fallback influence radius (metres) for a POI whose `radius` is NULL or <= 0.
DEFAULT_RADIUS = 100.0



def _configure():
    """Read the open project's planet and the export folder; at the start of every run."""
    global PLANET_NAME, PLANET_RADIUS, EXPORT_DIR
    planet = ds_project.planet()
    PLANET_NAME = planet.name
    PLANET_RADIUS = int(planet.radius_m)
    EXPORT_DIR = link_modifiers.resolve_export_dir()


def _layer_names():
    """Layer name candidates, in priority order, before falling back to a substring
    search. setup_planet_project.py names the PostGIS table plainly `poi`."""
    return ("poi", f"{PLANET_NAME}_poi")


def _region_layer_names():
    """The named-region polygon layer (tools/planettech/qgis/layers/base.py)."""
    return ("region", f"{PLANET_NAME}_region")


# ============================================================
# Helpers
# ============================================================
def find_layers_by_keyword(keyword):
    """Return project layers whose name contains *keyword* (case-insensitive)."""
    kw = keyword.lower()
    return [l for l in QgsProject.instance().mapLayers().values()
            if kw in l.name().lower()]


def _find_poi_layer():
    """Exact name match first, then any point vector layer named like a POI one."""
    layers = list(QgsProject.instance().mapLayers().values())
    for wanted in _layer_names():
        for l in layers:
            if l.name().lower() == wanted.lower() and isinstance(l, QgsVectorLayer):
                return l
    for l in find_layers_by_keyword("poi"):
        if isinstance(l, QgsVectorLayer) \
                and l.geometryType() == Qgis.GeometryType.Point:
            return l
    return None


def _find_region_layer():
    """The `region` polygon layer, by exact name only (a substring would catch biomes)."""
    for l in QgsProject.instance().mapLayers().values():
        if not isinstance(l, QgsVectorLayer) \
                or l.geometryType() != Qgis.GeometryType.Polygon:
            continue
        if l.name().lower() in [n.lower() for n in _region_layer_names()]:
            return l
    return None


def collect_regions():
    """The `regions` array of the JSON, [] when the project has no region layer."""
    layer = _find_region_layer()
    if layer is None:
        print("  Regions    : no 'region' polygon layer — none exported")
        return []
    features = []
    for feat in layer.getFeatures():
        geom = feat.geometry()
        if geom is None or geom.isEmpty():
            continue
        features.append({
            "name": _str(feat, "name"),
            "rings": regions_lib.outer_rings(json.loads(geom.asJson())),
        })
    out = regions_lib.build_regions(features)
    print(f"  Regions    : {layer.name()} ({layer.featureCount()} features) "
          f"→ {len(out)} named region(s)")
    return out


def _is_null(value):
    """True for a NULL attribute, whether PyQGIS hands it back as None or QVariant."""
    if value is None:
        return True
    # QGIS < 3.30 returns a QVariant for NULL; it compares equal to qgis.core.NULL
    # and stringifies as "NULL". Both checks are cheap and neither can raise.
    if hasattr(value, "isNull"):
        return bool(value.isNull())
    return str(value) == "NULL"


def _str(feat, name, default=""):
    if feat.fields().indexOf(name) < 0:
        return default
    value = feat[name]
    return default if _is_null(value) else str(value)


def _num(feat, name, default=None):
    if feat.fields().indexOf(name) < 0:
        return default
    value = feat[name]
    if _is_null(value):
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _poi_id(feat):
    """`id` field if the layer has one, else the PostGIS `fid` PK, else the FID."""
    for name in ("id", "fid"):
        value = _num(feat, name)
        if value is not None:
            return int(value)
    return int(feat.id())


def _point_of(geom):
    """Longitude/latitude of a (multi)point geometry, or None if unusable."""
    if geom is None or geom.isEmpty():
        return None
    if geom.isMultipart():
        parts = geom.asMultiPoint()
        if not parts:
            return None
        pt = parts[0]
    else:
        pt = geom.asPoint()
    return float(pt.x()), float(pt.y())


# ============================================================
# Export
# ============================================================
def run():
    """The whole export, on the main thread (it reads layers and writes one small JSON)."""
    _configure()
    print("=" * 64)
    print(f"  POI export — planet '{PLANET_NAME}'")
    print("=" * 64)

    layer = _find_poi_layer()
    regions = collect_regions()
    if layer is None and not regions:
        print("  ✗ No POI layer found. Expected a point layer named 'poi' "
              "(created by setup_planet_project.py).")
        return
    if layer is not None:
        print(f"  Layer      : {layer.name()} ({layer.featureCount()} features)")

    pois = []
    skipped_nogeom = 0
    skipped_stub = 0
    fixed_radius = 0

    for feat in (layer.getFeatures() if layer is not None else []):
        lonlat = _point_of(feat.geometry())
        if lonlat is None:
            skipped_nogeom += 1
            continue
        lon, lat = lonlat

        name = _str(feat, "name")
        # setup_planet_project.py seeds some layers with an empty feature at the
        # origin; drop it rather than exporting a nameless POI at (0, 0).
        if not name and abs(lon) < 1e-9 and abs(lat) < 1e-9:
            skipped_stub += 1
            continue

        radius = _num(feat, "radius")
        if radius is None or radius <= 0.0:
            print(f"    ! '{name or feat.id()}' has no usable radius "
                  f"→ {DEFAULT_RADIUS} m")
            radius = DEFAULT_RADIUS
            fixed_radius += 1

        population = _num(feat, "population", 0.0)

        pois.append({
            "id": _poi_id(feat),
            "name": name,
            "poi_type": _str(feat, "poi_type"),
            "population": int(population),
            "radius": radius,
            "description": _str(feat, "description"),
            "lon": lon,
            "lat": lat,
            # None → Godot samples the terrain heightmap at this direction.
            "elevation": _num(feat, "elevation"),
        })

    payload = {
        "planet_name": PLANET_NAME,
        "planet_radius": float(PLANET_RADIUS),
        "crs": "EPSG:4326",
        "count": len(pois),
        "pois": pois,
        "regions": regions,
    }

    os.makedirs(EXPORT_DIR, exist_ok=True)
    out_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_poi.json")
    tmp_path = out_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as out:
        json.dump(payload, out, indent=2, ensure_ascii=False)
    os.replace(tmp_path, out_path)

    by_type = {}
    for poi in pois:
        key = poi["poi_type"] or "(none)"
        by_type[key] = by_type.get(key, 0) + 1

    print("=" * 64)
    print(f"  ✓ Done. {len(pois)} POI, {len(regions)} region(s) → {out_path}")
    for key in sorted(by_type):
        print(f"    {key:<14} {by_type[key]}")
    if skipped_nogeom:
        print(f"    skipped (no geometry) : {skipped_nogeom}")
    if skipped_stub:
        print(f"    skipped (origin stub) : {skipped_stub}")
    if fixed_radius:
        print(f"    defaulted radius      : {fixed_radius}")
    print(f"    → In Godot: select PlanetTerrain, click 'Import POI from JSON'.")
    print("=" * 64)


def prepare():
    """The plugin's entry point: the export is quick and reads the layers, so it is done here."""
    run()
    return None


if __name__ == "__main__":
    run()
