"""
QGIS planet project setup for DyingStar
=======================================
Run this in the QGIS Python Console to create (or refresh) the QGIS project and
PostGIS schema of a planet.

What it does
------------
  1. asks for the planet name and radius (pre-filled from the constants below)
  2. shows the layer picker: Region / POI / Lines → category → layer, with the
     per-planet value lists (rock types…) under the layers that declare some
  3. creates the missing PostGIS tables, loads the existing ones untouched,
     applies widgets / defaults / styles, and organises the layer tree
  4. sets the project CRS, variables, map decorations, and saves the .qgz

What it does NOT do
-------------------
  Define layers.  Every layer lives in a small declarative module under
  ``layers/`` — see ``layers/__init__.py`` and ``layers/biomes/<category>.py``.
  To add a biome, edit the category module; to add a category, add a module.

Storage: PostgreSQL (PostGIS)
  Connection : "DyingStar"  (must exist in QGIS: Layer → Data Source Manager → PostgreSQL)
  Schema     : <planet name>  (created automatically)
  Tables     : one per layer, named after the layer slug (sandy_desert, river, highway…)

Usage
-----
    exec(open('/path/to/DyingStar/tools/planettech/qgis/setup_planet_project.py').read())

Set INTERACTIVE = False to skip both dialogs and create everything.
"""

import os
import sys

from qgis.core import (
    QgsProject,
    QgsVectorLayer,
    QgsCoordinateReferenceSystem,
    QgsRectangle,
    QgsExpressionContextUtils,
)
from qgis.PyQt.QtGui import QColor, QFont
from qgis.utils import iface


# ============================================================
# CONFIGURATION — defaults, the dialog lets you change the first two.
# When a planet project is already open, its planet_name / planet_radius_m
# project variables win over these constants.
# ============================================================
PLANET_NAME = "tarsis_8"
PLANET_RADIUS_M = 1155667
WORK_DIR = os.path.expanduser(
    "/datas/developpement/sources/StarDeception/StarDeception/assets/qgis"
)
EXISTING_FEATURES = os.path.expanduser(
    "/datas/developpement/sources/StarDeception/StarDeception/assets/planet_features.geojson"
)
INTERACTIVE = True
# Only used when exec()'d from the console (no __file__): where layers/ lives.
TOOLS_DIR = "/datas/developpement/sources/DyingStar-game/DyingStar/tools/planettech/qgis"


# ============================================================
# Module loading
# ============================================================
# exec() from the QGIS console reuses one long-lived interpreter: a module
# imported by an earlier run stays in sys.modules and edits under layers/ would
# silently do nothing.  Drop everything previously loaded from this directory.
_tools_dir = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else TOOLS_DIR
if _tools_dir not in sys.path:
    sys.path.insert(0, _tools_dir)
for _name, _mod in list(sys.modules.items()):
    _mod_file = getattr(_mod, "__file__", None)
    if _mod_file and os.path.abspath(_mod_file).startswith(_tools_dir + os.sep):
        del sys.modules[_name]
    elif _mod_file is None and (_name == "layers" or _name.startswith("layers.")):
        del sys.modules[_name]

import layers                                   # noqa: E402
from layers.core import PlanetDb                # noqa: E402
from layers import dialog as layer_dialog       # noqa: E402


# ============================================================
# Map decorations
# ============================================================
def setup_map_decorations():
    """Lat/lon grid (10°) + scale bar.  QGIS keeps these in per-user QSettings."""
    from qgis.PyQt.QtCore import QSettings
    s = QSettings()

    s.setValue("/qgis/grid/annotationEnabled", True)
    s.setValue("/qgis/grid/annotationDirection", 0)
    s.setValue("/qgis/grid/annotationFont", QFont("Sans", 8).toString())
    s.setValue("/qgis/grid/annotationPrecision", 1)
    s.setValue("/qgis/grid/enabled", True)
    s.setValue("/qgis/grid/intervalX", 10.0)
    s.setValue("/qgis/grid/intervalY", 10.0)
    s.setValue("/qgis/grid/offsetX", 0.0)
    s.setValue("/qgis/grid/offsetY", 0.0)
    s.setValue("/qgis/grid/style", 1)  # crosses

    s.setValue("/qgis/scalebar/enabled", True)
    s.setValue("/qgis/scalebar/placement", 0)       # bottom-left
    s.setValue("/qgis/scalebar/preferredSize", 0)
    s.setValue("/qgis/scalebar/snapping", True)
    s.setValue("/qgis/scalebar/style", 0)
    s.setValue("/qgis/scalebar/colorBar", QColor(0, 0, 0).name())
    s.setValue("/qgis/scalebar/numMapUnitsPerScaleBarUnit", 1.0)

    # Ask the decoration objects to re-read their settings so they show now.
    try:
        for dec in iface.mainWindow().findChildren(type(None)):
            if type(dec).__name__ in ("QgsDecorationGrid", "QgsDecorationScaleBar"):
                dec.setEnabled(True)
                dec.update()
    except Exception:
        pass
    print("  ✓ Decorations: 10° grid + scale bar "
          "(if not visible: View → Decorations)")
    iface.mapCanvas().refresh()


# ============================================================
# Existing features (reference GeoJSON, root level)
# ============================================================
def load_existing_features(root, planet_name):
    if not os.path.exists(EXISTING_FEATURES):
        print(f"  · no existing features file ({EXISTING_FEATURES})")
        return
    name = f"{planet_name}_existing_features"
    if any(l.name() == name for l in QgsProject.instance().mapLayers().values()):
        print(f"  · {name} already in project")
        return
    existing = QgsVectorLayer(EXISTING_FEATURES, name, "ogr")
    if not existing.isValid():
        print(f"  ⚠ Could not load: {EXISTING_FEATURES}")
        return
    QgsProject.instance().addMapLayer(existing, False)
    root.addLayer(existing)
    print(f"  ✓ Loaded {EXISTING_FEATURES} ({existing.featureCount()} features)")


# ============================================================
# Main
# ============================================================
def _project_defaults():
    """Planet name / radius from the open project's variables, else the constants."""
    scope = QgsExpressionContextUtils.projectScope(QgsProject.instance())
    name = scope.variable("planet_name") or PLANET_NAME
    radius = scope.variable("planet_radius_m")
    try:
        radius = int(float(radius)) if radius else PLANET_RADIUS_M
    except (TypeError, ValueError):
        radius = PLANET_RADIUS_M
    return str(name), radius


def setup_planet():
    planet_name, radius_m = _project_defaults()
    if INTERACTIVE:
        answer = layer_dialog.ask_planet(planet_name, radius_m, iface.mainWindow())
        if answer is None:
            print("  ✗ Cancelled")
            return
        planet_name, radius_m = answer

    print("=" * 60)
    print(f"  Setting up planet: {planet_name}  (radius {radius_m} m)")
    print("=" * 60)

    db = PlanetDb(planet_name)   # creates the schema, validates the connection

    selection = None
    if INTERACTIVE:
        selection = layer_dialog.ask_selection(db, iface.mainWindow())
        if selection is None:
            print("  ✗ Cancelled")
            return

    project = QgsProject.instance()
    QgsExpressionContextUtils.setProjectVariable(project, "planet_name", planet_name)
    QgsExpressionContextUtils.setProjectVariable(project, "planet_radius_m", str(radius_m))
    project.setCrs(QgsCoordinateReferenceSystem("EPSG:4326"))
    print(f"  ✓ Project variables: planet_name={planet_name}, planet_radius_m={radius_m}")

    canvas = iface.mapCanvas()
    canvas.setExtent(QgsRectangle(-180, -90, 180, 90))
    canvas.refresh()
    setup_map_decorations()

    created = layers.setup_all(planet_name, selection)

    load_existing_features(project.layerTreeRoot(), planet_name)

    os.makedirs(os.path.join(WORK_DIR, planet_name), exist_ok=True)
    project_path = os.path.join(WORK_DIR, planet_name, f"{planet_name}.qgz")
    project.write(project_path)
    print(f"\n  ✓ Project saved: {project_path}")

    print("\n" + "=" * 60)
    print(f"  Done — {len(created)} layers in schema '{planet_name}'")
    print("  Region = areas, POI = points, Lines = linear features.")
    print("  Line biomes (rivers…) are buffered by their width at export,")
    print("  point biomes (craters, geysers…) by their radius.")
    print("=" * 60)


setup_planet()
