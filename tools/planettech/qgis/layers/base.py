"""
Non-biome reference layers: world border, contours, region.
"""

from .model import Category, Layer, Field

CATEGORY = Category("base", None, description="Reference layers (no sub-group)")


def _seed_world_rect(layer):
    """Insert the full-extent rectangle once, so the border is visible right away."""
    if layer.featureCount() > 0:
        return
    from qgis.core import QgsFeature, QgsGeometry, QgsRectangle
    feat = QgsFeature(layer.fields())
    feat.setGeometry(QgsGeometry.fromRect(QgsRectangle(-180, -90, 180, 90)))
    layer.dataProvider().addFeature(feat)
    layer.updateExtents()


CATEGORY.add(Layer(
    "world_border", "Polygon", (),
    description="Full-extent reference border (−180…180 × −90…90)",
    # Transparent fill with a thin grey outline so it never hides a biome.
    symbol={"color": "0,0,0,0", "outline_color": "#888888", "outline_width": "0.3"},
    on_created=_seed_world_rect,
    name="world border",
))

CATEGORY.add(Layer(
    "contours", "LineString", (
        Field("elevation", "double", "Elevation in metres above sea level"),
        Field("type", "string", "Contour type: contour, ridge, valley, cliff"),
        Field("interval", "double", "Contour interval this line represents"),
    ),
    color="#a0522d",
    description="Elevation contour lines (read by export_elevation.py)",
))

CATEGORY.add(Layer(
    "region", "Polygon", (
        Field("name", "string", "The name of the region"),
    ),
    color="#c0c0c0",
    description="Named regions (lore / map labels, not a biome)",
))
