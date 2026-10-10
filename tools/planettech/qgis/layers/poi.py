"""
Points of interest: cities, railway cities, factory and mining villages.
"""

from .model import Category, Layer, Field, ValueMap, STAGE_FINAL

CATEGORY = Category("poi", None, description="Points of interest (no sub-group)",
                    stage=STAGE_FINAL)

POI_TYPES = [
    ("City — populated settlement", "city"),
    ("Railway city — town on the railway", "railway city"),
    ("Factory village — industrial settlement", "factory village"),
    ("Mining village — mining settlement", "mining village"),
]

# What picking a poi_type writes into population and radius (metres).
POI_DEFAULTS = {
    "city": (0, 30000.0),
    "railway city": (0, 25000.0),
    "factory village": (1000, 2000.0),
    "mining village": (250, 1000.0),
}


def _follow_type(field, column):
    """Default expression making *field* follow the poi_type in the form.

    Re-evaluated on every edit (apply on update), it fills the field when the
    type changes and keeps a value typed by hand:
    - empty -> the type's value;
    - new feature -> follows the type while it still holds one of the type
      values;
    - type changed -> overwritten, unless the field was edited in this form
      (it no longer holds the stored value nor a type value);
    - back to the stored type in the same form -> the stored value again.
    """
    f = f'"{field}"'
    cases = " ".join(f"WHEN \"poi_type\" = '{t}' THEN {v[column]}" for t, v in POI_DEFAULTS.items())
    known = ", ".join(str(v) for v in sorted({v[column] for v in POI_DEFAULTS.values()}))
    typed = f"coalesce(CASE {cases} END, {f})"
    stored = f"attribute(@stored, '{field}')"
    return (
        f"with_variable('stored', get_feature_by_id(@layer, $id), CASE "
        f"WHEN {f} IS NULL THEN {typed} "
        f"WHEN @stored IS NULL THEN if({f} IN ({known}), {typed}, {f}) "
        f"WHEN \"poi_type\" IS NOT attribute(@stored, 'poi_type') "
        f"THEN if({f} IN ({known}) OR {f} = {stored}, {typed}, {f}) "
        f"WHEN {f} IN ({known}) AND {f} <> {stored} THEN {stored} "
        f"ELSE {f} END)"
    )


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
        Field("population", "integer", "Population of the Point of Interest (filled from poi_type)",
              default=_follow_type("population", 0), default_on_update=True),
        Field("radius", "double", "Influence radius in metres (filled from poi_type)",
              default=_follow_type("radius", 1), default_on_update=True),
        Field("elevation", "double", "Ground elevation override"),
        Field("description", "string", "Description of the Point of Interest"),
    ),
    color="#ff4040",
    description="Cities, railway cities, factory and mining villages (read by export_poi.py)",
    symbol_factory=_poi_symbol,
    labeling=_poi_labels,
))
