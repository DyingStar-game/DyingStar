"""
Points of interest: cities, stations, landmarks, spawn points.
"""

from .model import Category, Layer, Field, ValueMap, STAGE_FINAL

CATEGORY = Category("poi", None, description="Points of interest (no sub-group)",
                    stage=STAGE_FINAL)

POI_TYPES = [
    ("City — populated settlement", "city"),
    ("Station — outpost / base", "station"),
    ("Landmark — notable natural or artificial feature", "landmark"),
    ("Spawn point — player arrival", "spawn_point"),
]

# Ground radius -> degrees of latitude on the planet's sphere (the project
# variable planet_radius_m, written by setup_planet_project.py).
_DEG_LAT = '"radius" / (to_real(coalesce(@planet_radius_m, 6371000)) * pi() / 180)'
# An ellipse in lon/lat: a degree of longitude is cos(lat) shorter on the ground
# (clamped near the poles).  Azimuth 90 = major axis east-west.
RADIUS_CIRCLE = (
    f'if("radius" > 0, make_ellipse($geometry, '
    f'{_DEG_LAT} / max(cos(radians(y($geometry))), 0.01), {_DEG_LAT}, 90, 72), NULL)'
)
HOUSE_SVG = "gpsicons/house.svg"    # bundled with QGIS (svg/gpsicons/)
HOUSE_SIZE_MM = 6
# North-east of the point (mm, screen y down), so whatever is drawn right on
# the POI's centre stays visible.
HOUSE_OFFSET_MM = (4, -4)


def _poi_symbol(color):
    """The POI's influence radius as a circle on the ground, and a house icon on
    the point."""
    from qgis.core import (QgsMarkerSymbol, QgsFillSymbol, QgsGeometryGeneratorSymbolLayer,
                           QgsSvgMarkerSymbolLayer, QgsSymbolLayerUtils, QgsProject, Qgis)
    from qgis.PyQt.QtCore import QPointF
    from qgis.PyQt.QtGui import QColor

    circle = QgsGeometryGeneratorSymbolLayer.create({"geometryModifier": RADIUS_CIRCLE})
    circle.setSymbolType(Qgis.SymbolType.Fill)
    fill = QColor(color)
    fill.setAlpha(40)
    circle.setSubSymbol(QgsFillSymbol.createSimple({
        "color": fill.name(QColor.NameFormat.HexArgb), "outline_color": color.name(),
        "outline_width": "0.4",
    }))

    house = QgsSvgMarkerSymbolLayer(QgsSymbolLayerUtils.svgSymbolNameToPath(
        HOUSE_SVG, QgsProject.instance().pathResolver()), HOUSE_SIZE_MM)
    house.setFillColor(color)
    house.setStrokeColor(QColor("black"))
    house.setOffset(QPointF(*HOUSE_OFFSET_MM))

    sym = QgsMarkerSymbol()
    sym.changeSymbolLayer(0, circle)
    sym.appendSymbolLayer(house)
    return sym


def _poi_labels(layer):
    """The label right of the house icon, level with it.  Settings already on the
    layer (text, font, buffer…) are kept; only the placement is set, and the
    ``name`` field is used when the layer had no label yet."""
    from qgis.core import (QgsPalLayerSettings, QgsVectorLayerSimpleLabeling,
                           QgsUnitTypes)
    current = layer.labeling() if layer.labelsEnabled() else None
    if isinstance(current, QgsVectorLayerSimpleLabeling):
        settings = QgsPalLayerSettings(current.settings())
    else:
        settings = QgsPalLayerSettings()
        settings.fieldName = "name"
    settings.placement = QgsPalLayerSettings.Placement.OverPoint
    settings.quadOffset = QgsPalLayerSettings.QuadrantPosition.QuadrantRight
    settings.xOffset = HOUSE_OFFSET_MM[0] + HOUSE_SIZE_MM / 2 + 1
    settings.yOffset = HOUSE_OFFSET_MM[1]
    settings.offsetUnits = QgsUnitTypes.RenderUnit.RenderMillimeters
    layer.setLabeling(QgsVectorLayerSimpleLabeling(settings))
    layer.setLabelsEnabled(True)
    layer.triggerRepaint()


CATEGORY.add(Layer(
    "poi", "Point", (
        Field("name", "string", "Point of Interest name"),
        Field("poi_type", "string", "Type of Point of Interest", widget=ValueMap(POI_TYPES)),
        Field("population", "integer", "Population of the Point of Interest"),
        Field("radius", "double", "Influence radius in metres"),
        Field("elevation", "double", "Ground elevation override"),
        Field("description", "string", "Description of the Point of Interest"),
    ),
    color="#ff4040",
    description="Cities, stations, landmarks, spawn points (read by export_poi.py)",
    symbol_factory=_poi_symbol,
    labeling=_poi_labels,
))
