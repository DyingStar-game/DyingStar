"""
Layer registry — every layer the planet setup can create, and how to create them.
==================================================================================

    from layers import all_categories, setup_all

Categories are discovered from:
    layers/base.py, layers/poi.py, layers/roads.py,
    layers/mountains.py, layers/volcanoes.py,
    layers/rocky_terrain.py                           (non-biome, listed by hand)
    layers/biomes/*.py                                (one module per biome category)

Adding a biome category = dropping a new module in ``layers/biomes/`` that
defines ``CATEGORY = BiomeCategory(...)``.  Nothing else to register.

QGIS layer tree produced — one top-level group per stage (model.STAGES), in
the order the layers apply on the ground::

    layer 00 - base/        contours, region, world border
    layer 01 - outcrop/     plateau, volcanic
    layer 02 - massifs/     mountains/  mountain range, ridge
                            volcanoes/  volcano
    layer 03 - rocky terrain/  rocky terrain
    layer 10 - final/       poi
                            roads/      highway, road, path, trail, railway
                            volcanoes/  lava flow, fumarole field, fumarole vent
    uncategorized/          every other biome category (aride desert/, forest/, …)

The Region / POI / Lines split (by geometry) only remains in the layer picker.
"""

import dataclasses
import importlib
import pkgutil

from .model import (  # noqa: F401 — re-exported for convenience
    Category, BiomeCategory, Layer, Field, Widget,
    Range, Color, ValueMap, KINDS, KIND_BY_GEOM, STAGES,
)


# ============================================================
# Discovery
# ============================================================
def all_categories():
    """Non-biome categories first, then ``layers/biomes/*`` in alphabetical order."""
    from . import base, poi, roads, mountains, volcanoes, rocky_terrain
    from . import biomes as biomes_pkg
    cats = [base.CATEGORY, poi.CATEGORY, roads.CATEGORY, mountains.CATEGORY,
            volcanoes.CATEGORY, rocky_terrain.CATEGORY]
    for info in sorted(pkgutil.iter_modules(biomes_pkg.__path__), key=lambda m: m.name):
        if info.name.startswith("_"):
            continue
        mod = importlib.import_module(f"{biomes_pkg.__name__}.{info.name}")
        cats.append(mod.CATEGORY)
    _validate(cats)
    return cats


def _validate(cats):
    tables, btypes, bindexes = {}, {}, {}
    for cat in cats:
        for l in cat.layers:
            for registry, key, what in ((tables, l.table, "table"),
                                        (btypes, l.biome_type, "biome_type"),
                                        (bindexes, l.biome_index, "biome_index")):
                if key is None:
                    continue
                if key in registry:
                    raise ValueError(f"duplicate {what} {key!r}: "
                                     f"{registry[key]} and {cat.slug}/{l.slug}")
                registry[key] = f"{cat.slug}/{l.slug}"


def all_layers():
    """Flat ``[(category, layer), …]`` in creation order."""
    return [(cat, l) for cat in all_categories() for l in cat.layers]


def biome_layers():
    return [(cat, l) for cat, l in all_layers() if l.is_biome]


def biome_by_type():
    """``{biome_type: Layer}`` — the catalogue, for export scripts."""
    return {l.biome_type: l for _, l in biome_layers()}


# ============================================================
# Selection (what the interactive dialog returns)
# ============================================================
@dataclasses.dataclass
class Selection:
    """Which layers to create and, per ``(layer slug, field name)``, which of
    the field's ``choices`` values are valid on this planet."""
    layers: set = dataclasses.field(default_factory=set)
    choices: dict = dataclasses.field(default_factory=dict)

    @classmethod
    def everything(cls):
        sel = cls()
        for _, l in all_layers():
            sel.layers.add(l.slug)
            for f in l.choice_fields:
                sel.choices[(l.slug, f.name)] = [v for _, v in f.choices]
        return sel

    def wants(self, layer_def):
        return layer_def.slug in self.layers

    def effective(self, layer_def):
        """*layer_def* with every ``choices`` field turned into a ValueMap of
        the selected values (or a plain text field when nothing is selected)."""
        if not layer_def.choice_fields:
            return layer_def
        fields = []
        for f in layer_def.fields:
            if not f.choices:
                fields.append(f)
                continue
            keep = self.choices.get((layer_def.slug, f.name))
            if keep is None:
                keep = [v for _, v in f.choices]
            options = [(label, v) for label, v in f.choices if v in keep]
            widget = ValueMap(options) if options else None
            fields.append(dataclasses.replace(f, choices=None, widget=widget))
        return dataclasses.replace(layer_def, fields=tuple(fields))


# ============================================================
# Creation
# ============================================================
def setup_all(planet_name, selection=None):
    """Create/refresh every selected layer and place it in its stage group.

    Returns ``{layer slug: QgsVectorLayer}``.  Layers already present in the
    project (matched on their PostGIS table) are reconfigured and moved to
    their group, so re-running the setup never duplicates tree entries.

    Unselected layers are removed from the project; their table is dropped
    only when it holds no feature — drawn data is never deleted.
    """
    from qgis.core import QgsProject, QgsLayerTreeGroup
    from .core import PlanetDb, create_layer, configure_layer

    if selection is None:
        selection = Selection.everything()

    project = QgsProject.instance()
    root = project.layerTreeRoot()
    db = PlanetDb(planet_name)

    def _group(parent, name):
        node = _child_group(parent, name)
        return node if node is not None else parent.addGroup(name)

    cats = all_categories()
    existing = _project_layers_by_slug(project, db, cats)
    todo = [(cat, l) for cat in cats for l in cat.layers if selection.wants(l)]
    print(f"  {len(todo)} layers selected out of {sum(len(c.layers) for c in cats)}")

    created = {}
    for step, (cat, layer_def) in enumerate(todo, 1):
        eff = selection.effective(layer_def)
        stage = cat.stage_of(layer_def)
        group = None if cat.flat else cat.group
        print(f"\n[{step}/{len(todo)}] {stage} / {group or '-'} / {layer_def.name}")
        if layer_def.description:
            print(f"        {layer_def.description}")
        parent = _group(root, stage)
        if group:
            parent = _group(parent, group)
        layer = existing.get(layer_def.slug)
        if layer is not None and _fits(layer, eff):
            configure_layer(layer, eff, cat)
            _move_layer(root, layer, parent)
            print(f"  ✓ Refreshed {layer.name()} ({layer.featureCount()} features)")
        else:
            if layer is not None:
                # The project layer still shows the table as it was (a column
                # added to the definition, a geometry change): drop the node
                # and go through the create path, which recreates an empty
                # table or reports a non-empty one, then reopens it.
                print(f"  · {layer.name()} no longer matches its definition — reopening")
                project.removeMapLayer(layer.id())
            layer = create_layer(db, eff, cat)
            if layer is None:
                continue
            parent.addLayer(layer)
        created[layer_def.slug] = layer

    _remove_unselected(db, project, existing,
                       [l for cat in cats for l in cat.layers if not selection.wants(l)])

    _prune_empty_groups(root)
    _sort_tree(root)
    n_groups = sum(1 for n in root.children() if isinstance(n, QgsLayerTreeGroup))
    print(f"\n  ✓ Layer tree organised: {n_groups} top-level groups, {len(created)} layers")
    return created


def _child_group(parent, name):
    """The direct sub-group *name* of *parent*, or None.  Not ``findGroup``,
    which searches the whole sub-tree: a same-named group nested elsewhere
    (an ``uncategorized`` of the user's) would be taken for the stage."""
    from qgis.core import QgsLayerTreeGroup
    for child in parent.children():
        if isinstance(child, QgsLayerTreeGroup) and child.name() == name:
            return child
    return None


def _move_layer(root, layer, parent):
    """Put *layer*'s tree node under *parent* (a no-op when it already is) — the
    node is cloned, so its visibility, expansion and styling travel with it."""
    from qgis.core import QgsLayerTreeLayer
    if any(isinstance(c, QgsLayerTreeLayer) and c.layerId() == layer.id()
           for c in parent.children()):
        return
    node = root.findLayer(layer.id())
    if node is None:
        parent.addLayer(layer)
        return
    parent.addChildNode(node.clone())
    node.parent().removeChildNode(node)


def _fits(layer, layer_def):
    """Does the opened QGIS layer carry every defined column and the right geometry?"""
    from qgis.core import QgsWkbTypes
    columns = {f.name() for f in layer.fields()}
    if any(f.name not in columns for f in layer_def.fields):
        return False
    geom = QgsWkbTypes.geometryDisplayString(layer.geometryType())
    return {"Point": "Point", "LineString": "Line", "Polygon": "Polygon"}[layer_def.geom] == geom


def _project_layers_by_slug(project, db, cats):
    """``{slug: QgsVectorLayer}`` for every project layer backed by a table of the
    planet schema — matched on the PostGIS source, so layers created by the old
    monolithic script (no ``ds_layer`` property) are recognised too.  When the
    same table is loaded several times, the extra copies are removed."""
    from qgis.core import QgsDataSourceUri
    slug_by_table = {l.table: l.slug for cat in cats for l in cat.layers}
    found = {}
    for layer in list(project.mapLayers().values()):
        if layer.providerType() != "postgres":
            continue
        uri = QgsDataSourceUri(layer.source())
        if uri.schema() != db.schema:
            continue
        slug = slug_by_table.get(uri.table()) or layer.customProperty("ds_layer", "")
        if not slug:
            continue
        if slug in found:
            print(f"  · duplicate project layer for {db.schema}.{uri.table()} removed")
            project.removeMapLayer(layer.id())
            continue
        found[slug] = layer
    return found


def _remove_unselected(db, project, existing, layer_defs):
    """Drop unticked layers from the project, and from the database if empty."""
    removed = dropped = kept = 0
    for layer_def in layer_defs:
        layer = existing.get(layer_def.slug)
        if layer is not None:
            project.removeMapLayer(layer.id())
            removed += 1
        if not db.has_table(layer_def.table):
            continue
        count = db.row_count(layer_def.table)
        if count == 0:
            db.drop_table(layer_def.table)
            dropped += 1
            print(f"  · dropped empty table {db.schema}.{layer_def.table}")
        else:
            kept += 1
            print(f"  · kept {db.schema}.{layer_def.table} ({count} features) — unticked but not empty")
    if removed or dropped or kept:
        print(f"\n  ✓ Unselected: {removed} removed from project, "
              f"{dropped} empty tables dropped, {kept} kept (have data)")


def _prune_empty_groups(root):
    from qgis.core import QgsLayerTreeGroup

    def _prune(group):
        for child in list(group.children()):
            if isinstance(child, QgsLayerTreeGroup):
                _prune(child)
                if not child.children():
                    group.removeChildNode(child)

    # The stage groups, and the Region / POI / Lines groups of the old tree,
    # which the move to the stages empties.
    for name in (*STAGES, *KINDS):
        node = _child_group(root, name)
        if node is not None:
            _prune(node)
            if not node.children():
                root.removeChildNode(node)


def _sort_tree(root):
    """The stage groups first (in STAGES order), then anything else; inside a
    stage: sub-groups then layers, each alphabetically."""
    from qgis.core import QgsLayerTreeGroup

    def _reorder(group, key):
        for node in sorted(group.children(), key=key):
            clone = node.clone()
            group.insertChildNode(-1, clone)
            group.removeChildNode(node)

    def _alpha(node):
        return (0 if isinstance(node, QgsLayerTreeGroup) else 1, node.name().lower())

    def _walk(group):
        _reorder(group, _alpha)
        for child in group.children():
            if isinstance(child, QgsLayerTreeGroup):
                _walk(child)

    for stage in STAGES:
        node = _child_group(root, stage)
        if node is not None:
            _walk(node)

    rank = {k: i for i, k in enumerate(STAGES)}
    _reorder(root, lambda n: (rank.get(n.name(), len(STAGES)), n.name().lower()))
