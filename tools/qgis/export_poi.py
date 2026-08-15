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

Output
------
    <EXPORT_DIR>/<planet>_poi.json

    {
      "planet_name": "tarsis_4",
      "planet_radius": 6356000.0,        # metres, NOT the per-POI radius
      "crs": "EPSG:4326",
      "count": 2,
      "pois": [
        {"id": 1, "name": "Mine Village", "poi_type": "city",
         "population": 1200, "radius": 200.0, "description": "…",
         "lon": -83.7, "lat": 11.5, "elevation": null}
      ]
    }

Run from the QGIS Python Console:
    exec(open('/datas/developpement/sources/DyingStar-game/DyingStar/tools/qgis/export_poi.py').read())
"""
import os
import json

from qgis.core import (
    QgsProject,
    QgsVectorLayer,
    QgsWkbTypes,
    QgsExpressionContextUtils,
)

# ============================================================
# CONFIGURATION — edit for your planet
# ============================================================
_project = QgsProject.instance()
_proj_planet_name = QgsExpressionContextUtils.projectScope(_project).variable("planet_name")
_proj_planet_radius = QgsExpressionContextUtils.projectScope(_project).variable("planet_radius_m")

PLANET_NAME = str(_proj_planet_name) if _proj_planet_name else "tarsis_4"
# Planet radius in metres (sea-level surface). Only carried through to the JSON
# as a sanity reference — Godot uses the radius from its own chunk manifest.
PLANET_RADIUS = int(_proj_planet_radius) if _proj_planet_radius else 6_356_000

# Same directory as export_elevation.py — both exports must land side by side.
EXPORT_DIR = os.path.expanduser(
    "/datas/developpement/sources/DyingStar-game/DyingStar/assets/qgis/export"
)

# Fallback influence radius (metres) for a POI whose `radius` is NULL or <= 0.
DEFAULT_RADIUS = 100.0

# Layer name candidates, in priority order, before falling back to a substring
# search. setup_planet_project.py names the PostGIS table plainly `poi`.
_LAYER_NAMES = ("poi", f"{PLANET_NAME}_poi")


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
    for wanted in _LAYER_NAMES:
        for l in layers:
            if l.name().lower() == wanted.lower() and isinstance(l, QgsVectorLayer):
                return l
    for l in find_layers_by_keyword("poi"):
        if isinstance(l, QgsVectorLayer) \
                and l.geometryType() == QgsWkbTypes.PointGeometry:
            return l
    return None


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
def run_export():
    print("=" * 64)
    print(f"  POI export — planet '{PLANET_NAME}'")
    print("=" * 64)

    layer = _find_poi_layer()
    if layer is None:
        print("  ✗ No POI layer found. Expected a point layer named 'poi' "
              "(created by setup_planet_project.py).")
        return
    print(f"  Layer      : {layer.name()} ({layer.featureCount()} features)")

    pois = []
    skipped_nogeom = 0
    skipped_stub = 0
    fixed_radius = 0

    for feat in layer.getFeatures():
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
    print(f"  ✓ Done. {len(pois)} POI → {out_path}")
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


run_export()
