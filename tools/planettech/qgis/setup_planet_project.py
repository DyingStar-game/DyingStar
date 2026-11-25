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
    DyingStar ▸ Planet project…        (the plugin) — asks the name and radius
    DyingStar ▸ Update the layers       same, on the open project's planet

From the Python console:  import setup_planet_project; setup_planet_project.run()

Where the project is saved: next to itself when it already has a file, else
<projects dir>/<planet>/<planet>.qgz — the plugin setting "QGIS projects folder"
($DS_QGIS_PROJECTS_DIR), by default <checkout>/assets/qgis.
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


# ============================================================
# CONFIGURATION — defaults of the planet dialog when no planet project is open.
# ============================================================
PLANET_NAME = "tarsis_8"
PLANET_RADIUS_M = 1155667

_tools_dir = os.path.dirname(os.path.abspath(__file__))
if _tools_dir not in sys.path:
    sys.path.insert(0, _tools_dir)

import layers                                   # noqa: E402
import link_modifiers                           # noqa: E402
from layers.core import PlanetDb                # noqa: E402
from layers import dialog as layer_dialog       # noqa: E402


def projects_dir():
    """$DS_QGIS_PROJECTS_DIR (plugin setting) -> <checkout>/assets/qgis."""
    env = os.environ.get("DS_QGIS_PROJECTS_DIR", "").strip()
    if env:
        return os.path.expanduser(env)
    root = link_modifiers.repo_root()
    if root is None:
        raise RuntimeError("no folder to save the project in: set \"QGIS projects folder\" "
                           "in the DyingStar plugin settings")
    return os.path.join(root, "assets", "qgis")


def existing_features_path():
    """$DS_EXISTING_FEATURES (plugin setting): a reference GeoJSON loaded at the root, or ""."""
    return os.path.expanduser(os.environ.get("DS_EXISTING_FEATURES", "").strip())


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

    print("  ✓ Decorations: 10° grid + scale bar "
          "(if not visible: View → Decorations)")


# ============================================================
# Existing features (reference GeoJSON, root level)
# ============================================================
def load_existing_features(root, planet_name):
    path = existing_features_path()
    if not path:
        return
    if not os.path.exists(path):
        print(f"  · no existing features file ({path})")
        return
    name = f"{planet_name}_existing_features"
    if any(l.name() == name for l in QgsProject.instance().mapLayers().values()):
        print(f"  · {name} already in project")
        return
    existing = QgsVectorLayer(path, name, "ogr")
    if not existing.isValid():
        print(f"  ⚠ Could not load: {path}")
        return
    QgsProject.instance().addMapLayer(existing, False)
    root.addLayer(existing)
    print(f"  ✓ Loaded {path} ({existing.featureCount()} features)")


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


def run(interactive=True, update=False, decorations=False, parent=None):
    """Create or refresh the planet's PostGIS schema, layers and QGIS project.

    update: the open project's planet (ds_project), without asking its name and radius.
    interactive: the dialogs; False creates every layer (scripts, tests).
    decorations: also write QGIS's per-user grid / scale-bar settings.
    """
    from qgis.utils import iface
    parent = parent or (iface.mainWindow() if iface else None)
    if update:
        import ds_project
        planet = ds_project.planet()
        planet_name, radius_m = planet.name, int(planet.radius_m)
    else:
        planet_name, radius_m = _project_defaults()
        if interactive:
            answer = layer_dialog.ask_planet(planet_name, radius_m, parent)
            if answer is None:
                print("  ✗ Cancelled")
                return None
            planet_name, radius_m = answer

    print("=" * 60)
    print(f"  Setting up planet: {planet_name}  (radius {radius_m} m)")
    print("=" * 60)

    db = PlanetDb(planet_name)   # creates the schema, validates the connection

    selection = None
    if interactive:
        selection = layer_dialog.ask_selection(db, parent)
        if selection is None:
            print("  ✗ Cancelled")
            return None

    project = QgsProject.instance()
    same_planet = (QgsExpressionContextUtils.projectScope(project).variable("planet_name")
                   == planet_name)
    QgsExpressionContextUtils.setProjectVariable(project, "planet_name", planet_name)
    QgsExpressionContextUtils.setProjectVariable(project, "planet_radius_m", str(radius_m))
    project.setCrs(QgsCoordinateReferenceSystem("EPSG:4326"))
    print(f"  ✓ Project variables: planet_name={planet_name}, planet_radius_m={radius_m}")

    if iface and not update:
        canvas = iface.mapCanvas()
        canvas.setExtent(QgsRectangle(-180, -90, 180, 90))
        canvas.refresh()
    if decorations:
        setup_map_decorations()

    created = layers.setup_all(planet_name, selection)

    load_existing_features(project.layerTreeRoot(), planet_name)

    # A project already saved for this planet stays where it is; a new one goes to the
    # projects folder.
    if same_planet and project.fileName():
        project_path = project.fileName()
    else:
        project_path = os.path.join(projects_dir(), planet_name, f"{planet_name}.qgz")
        os.makedirs(os.path.dirname(project_path), exist_ok=True)
    project.write(project_path)
    print(f"\n  ✓ Project saved: {project_path}")

    print("\n" + "=" * 60)
    print(f"  Done — {len(created)} layers in schema '{planet_name}'")
    print("  Groups 'layer NN' = the order the layers apply on the ground.")
    print("  Line biomes (rivers…) are buffered by their width at export,")
    print("  point biomes (craters, geysers…) by their radius.")
    print("=" * 60)
    return created


if __name__ == "__main__":
    run()
