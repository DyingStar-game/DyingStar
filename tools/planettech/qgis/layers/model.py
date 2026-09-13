"""
Declarative layer model — no QGIS import here, so it stays testable outside QGIS.
=================================================================================

A planet project is a list of :class:`Category`, each holding :class:`Layer`
definitions.  Category modules (``layers/base.py``, ``layers/roads.py``,
``layers/biomes/*.py``) only *describe* layers; ``layers/core.py`` turns the
descriptions into PostGIS tables + QGIS layers.

Naming rules (kept identical to the previous monolithic script so planets
already drawn keep loading):

    slug          "sandy_desert"          → PostGIS table name
    Layer.name    "sandy desert"          → QGIS layer name (slug, '_' → ' ')
    biome_type    "aride_desert-sandy_desert"  (custom property read by exports)
"""

from dataclasses import dataclass, field as _dc_field
from typing import Callable, Optional, Sequence


GEOM_TYPES = ("Point", "LineString", "Polygon")
FIELD_TYPES = ("string", "integer", "double", "datetime")

# Top-level QGIS groups — decided by geometry, not by category:
#   Region = areas (Polygon), POI = points, Lines = linear features.
KIND_BY_GEOM = {"Polygon": "Region", "Point": "POI", "LineString": "Lines"}
KINDS = ("Region", "POI", "Lines")


# ============================================================
# Editor widgets
# ============================================================
@dataclass(frozen=True)
class Widget:
    """A QGIS editor widget: ``QgsEditorWidgetSetup(kind, config)``."""
    kind: str
    config: dict


def Range(minimum, maximum, step):
    return Widget("Range", {"Min": minimum, "Max": maximum, "Step": step})


def Color():
    return Widget("Color", {})


def ValueMap(options):
    """Dropdown.  *options* is ``[(label, value), …]`` — label shown, value stored."""
    return Widget("ValueMap", {"map": [{label: value} for label, value in options]})


# ============================================================
# Fields
# ============================================================
@dataclass(frozen=True)
class Field:
    name: str
    type: str = "string"        # one of FIELD_TYPES
    comment: str = ""           # shown as the column comment / form tooltip
    widget: Optional[Widget] = None
    default: Optional[str] = None   # QGIS default-value EXPRESSION, e.g. "6.0" or "'asphalt'"
    read_only: bool = False
    # Selectable value list ``[(label, value), …]`` (rock types…).  The setup
    # dialog lets the artist tick the subset valid for THIS planet; the ticked
    # values become a ValueMap dropdown.  Mutually exclusive with *widget*.
    choices: Optional[Sequence[tuple]] = None

    def __post_init__(self):
        if self.type not in FIELD_TYPES:
            raise ValueError(f"field {self.name!r}: unknown type {self.type!r}")
        if self.choices is not None and self.widget is not None:
            raise ValueError(f"field {self.name!r}: use either widget= or choices=")


NAME_FIELD = Field("name", "string", "(Optional) Zone name")


# ============================================================
# Layers
# ============================================================
@dataclass
class Layer:
    slug: str                       # PostGIS table name, e.g. "sandy_desert"
    geom: str = "Polygon"           # one of GEOM_TYPES
    fields: Sequence[Field] = ()
    color: str = "#888888"          # base symbol colour
    description: str = ""
    # Biome identity — None for non-biome layers (contours, poi, roads…)
    biome_type: Optional[str] = None
    biome_index: Optional[int] = None
    planet_type: Optional[str] = None   # terrestrial / volcanic / cryo / toxic / …
    terrain_modifier: bool = False      # True → modifies the heightmap (rivers, craters…)
    # Extra QGIS custom properties written on the layer — export scripts read them.
    properties: dict = _dc_field(default_factory=dict)
    # Symbol overrides merged over the default simple symbol, e.g.
    # {"width": "3.0"} for a line or {"color": "0,0,0,0"} for a transparent fill.
    symbol: dict = _dc_field(default_factory=dict)
    # Name of a symbol from the QGIS default style library ("topo railway"…)
    # used INSTEAD of the simple symbol; falls back to it when the name is
    # unknown in the running QGIS.
    style_symbol: Optional[str] = None
    # Line layers only: draw an arrow on the first vertex showing the drawing
    # direction — for layers whose meaning depends on it (roads, rivers with
    # width_start/width_end, cliffs with their high side on the left).
    direction_marker: bool = False
    # Called with the QgsVectorLayer once it exists (seed features, custom renderer…)
    on_created: Optional[Callable] = None
    # QGIS layer name; defaults to the slug with spaces.
    name: Optional[str] = None
    # PostGIS table; defaults to the slug.  Only for legacy tables whose name
    # does not follow the rule — do not use for new layers.
    table_name: Optional[str] = None

    def __post_init__(self):
        if self.geom not in GEOM_TYPES:
            raise ValueError(f"layer {self.slug!r}: unknown geom {self.geom!r}")
        if self.name is None:
            self.name = self.slug.replace("_", " ")
        self.fields = tuple(self.fields)
        seen = set()
        for f in self.fields:
            if f.name in seen:
                raise ValueError(f"layer {self.slug!r}: duplicate field {f.name!r}")
            seen.add(f.name)

    @property
    def table(self):
        return self.table_name or self.slug

    @property
    def is_biome(self):
        return self.biome_type is not None

    @property
    def kind(self):
        """Top-level group: Region / POI / Lines."""
        return KIND_BY_GEOM[self.geom]

    @property
    def choice_fields(self):
        return [f for f in self.fields if f.choices]


# ============================================================
# Categories
# ============================================================
@dataclass
class Category:
    """A sub-group inside Region / POI / Lines.

    ``group=None`` puts the layers directly under the top-level group (no
    sub-group) — used for the handful of non-biome layers (contours, poi…).
    """
    slug: str
    group: Optional[str]
    layers: list = _dc_field(default_factory=list)
    description: str = ""
    # Overlap rule for Region (polygon) layers: where two zones overlap, the
    # higher priority wins (loose cover over bedrock, liquids over both).
    # Written on every layer as the ``ds_priority`` custom property, exported
    # by export_biomes.py, and applied by Godot as "first matching zone wins".
    priority: int = 0

    def add(self, layer):
        if any(l.slug == layer.slug for l in self.layers):
            raise ValueError(f"category {self.slug!r}: duplicate layer {layer.slug!r}")
        self.layers.append(layer)
        return layer


class BiomeCategory(Category):
    """A category whose layers are biomes: ``biome_type = f"{slug}-{biome_slug}"``."""

    def __init__(self, slug, group=None, description="", priority=0):
        super().__init__(slug, group if group is not None else slug.replace("_", " "),
                         [], description, priority)

    def biome(self, index, slug, color, description, *, geom="Polygon", fields=(),
              planet_type=None, terrain_modifier=False, name_hint=None, **kwargs):
        """Declare one biome layer.

        A ``name`` text field is always added first; *name_hint* customises its
        tooltip.  *fields* lists the biome-specific extra fields.
        """
        name_field = NAME_FIELD if name_hint is None else Field("name", "string", name_hint)
        return self.add(Layer(
            slug, geom, (name_field, *fields), color, description,
            biome_type=f"{self.slug}-{slug}", biome_index=index,
            planet_type=planet_type, terrain_modifier=terrain_modifier, **kwargs,
        ))
