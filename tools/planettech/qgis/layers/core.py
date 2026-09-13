"""
PostGIS / QGIS plumbing shared by every layer definition.
=========================================================

Turns a :class:`model.Layer` into a table in the planet schema of the
"DyingStar" PostgreSQL connection and a QgsVectorLayer registered with the
project (but NOT placed in the layer tree — the registry does that).

Existing tables are loaded as-is, never truncated, so re-running the setup on
a planet already drawn is safe.  Widgets, defaults, styles and custom
properties are re-applied on every run: they live in the .qgz, not in the
database, so this is how a tweak in a category module reaches the artist.
"""

from qgis.core import (
    Qgis,
    QgsMarkerLineSymbolLayer,
    QgsProject,
    QgsVectorLayer,
    QgsField,
    QgsFields,
    QgsCoordinateReferenceSystem,
    QgsMarkerSymbol,
    QgsLineSymbol,
    QgsFillSymbol,
    QgsEditorWidgetSetup,
    QgsDefaultValue,
    QgsWkbTypes,
    QgsDataSourceUri,
    QgsProviderRegistry,
    QgsStyle,
)
from qgis.PyQt.QtCore import QVariant
from qgis.PyQt.QtGui import QColor

CONNECTION_NAME = "DyingStar"

_QT_TYPE = {
    "string":   QVariant.String,
    "integer":  QVariant.Int,
    "double":   QVariant.Double,
    "datetime": QVariant.DateTime,
}

_WKB = {
    "Point":      QgsWkbTypes.Point,
    "LineString": QgsWkbTypes.LineString,
    "Polygon":    QgsWkbTypes.Polygon,
}

# QgsWkbTypes.geometryDisplayString() names, per definition geometry.
_GEOM_NAME = {"Point": "Point", "LineString": "Line", "Polygon": "Polygon"}

# Every table gets this column + a trigger keeping it current.
_LAST_UPDATED = ("last_updated", "datetime", "Last updated timestamp")


def hex_to_rgb(hex_color):
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# ============================================================
# Connection
# ============================================================
def get_connection():
    """The 'DyingStar' PostgreSQL provider connection, with a clear error if absent."""
    md = QgsProviderRegistry.instance().providerMetadata("postgres")
    connections = md.connections()
    if CONNECTION_NAME not in connections:
        available = ", ".join(connections.keys()) or "(none)"
        raise RuntimeError(
            f"PostgreSQL connection '{CONNECTION_NAME}' not found in QGIS.\n"
            f"  Available connections: {available}\n"
            "  → Add it via: Layer menu → Data Source Manager → PostgreSQL → New"
        )
    return connections[CONNECTION_NAME]


class PlanetDb:
    """One planet = one PostgreSQL schema; wraps the connection for that schema."""

    def __init__(self, planet_name):
        self.schema = planet_name
        self.conn = get_connection()
        self.conn.executeSql(f'CREATE SCHEMA IF NOT EXISTS "{self.schema}"')
        self._tables = None

    def tables(self):
        if self._tables is None:
            self._tables = {t.tableName() for t in self.conn.tables(self.schema)}
        return self._tables

    def has_table(self, table):
        return table in self.tables()

    def layer_uri(self, table):
        uri = QgsDataSourceUri(self.conn.uri())
        uri.setDataSource(self.schema, table, "geom", "", "fid")
        return uri

    def create_table(self, table, fields_def, geom):
        fields = QgsFields()
        for f in fields_def:
            fields.append(QgsField(f.name, _QT_TYPE[f.type], comment=f.comment))
        fields.append(QgsField(_LAST_UPDATED[0], _QT_TYPE[_LAST_UPDATED[1]],
                               comment=_LAST_UPDATED[2]))
        crs = QgsCoordinateReferenceSystem("EPSG:4326")
        # (schema, name, fields, wkbType, crs, overwrite, options)
        self.conn.createVectorTable(self.schema, table, fields, _WKB[geom], crs, False, {})
        self._tables = None

    def row_count(self, table):
        """Rows in the table, by SQL — QgsVectorLayer.featureCount() may answer -1
        ("unknown") on a PostGIS layer, which must never pass for "empty"."""
        rows = self.conn.executeSql(f'SELECT count(*) FROM "{self.schema}"."{table}"')
        try:
            return int(rows[0][0])
        except (IndexError, TypeError, ValueError):
            return -1

    def drop_table(self, table):
        self.conn.executeSql(f'DROP TABLE "{self.schema}"."{table}"')
        self._tables = None
        if self.has_table(table):
            raise RuntimeError(f"DROP TABLE {self.schema}.{table} did not take effect "
                               f"(open transaction or another session holding it?)")
        print(f"  · dropped table {self.schema}.{table}")

    def ensure_last_updated_trigger(self, table):
        """Idempotent: column + shared trigger function + per-table trigger."""
        s = self.schema
        self.conn.executeSql(
            f'ALTER TABLE "{s}"."{table}" '
            f'ADD COLUMN IF NOT EXISTS last_updated TIMESTAMP WITH TIME ZONE'
        )
        self.conn.executeSql(f"""
            CREATE OR REPLACE FUNCTION "{s}".set_last_updated()
            RETURNS TRIGGER AS $$
            BEGIN
                NEW.last_updated := NOW();
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
        """)
        trigger = f"trg_last_updated_{table}"
        self.conn.executeSql(f'DROP TRIGGER IF EXISTS "{trigger}" ON "{s}"."{table}"')
        self.conn.executeSql(f"""
            CREATE TRIGGER "{trigger}"
            BEFORE INSERT OR UPDATE ON "{s}"."{table}"
            FOR EACH ROW
            EXECUTE FUNCTION "{s}".set_last_updated();
        """)


# ============================================================
# Layer configuration (QGIS side)
# ============================================================
def _configure_last_updated(layer):
    fidx = layer.fields().indexOf("last_updated")
    if fidx < 0:
        return
    layer.setEditorWidgetSetup(fidx, QgsEditorWidgetSetup("DateTime", {
        "display_format": "yyyy-MM-dd HH:mm:ss",
        "field_format": "yyyy-MM-dd HH:mm:ss",
        "calendar_popup": False,
    }))
    layer.setDefaultValueDefinition(fidx, QgsDefaultValue("now()", True))
    form = layer.editFormConfig()
    form.setReadOnly(fidx, True)
    layer.setEditFormConfig(form)


def _configure_fields(layer, fields_def):
    form = layer.editFormConfig()
    for f in fields_def:
        fidx = layer.fields().indexOf(f.name)
        if fidx < 0:
            print(f"  ⚠ column {f.name!r} missing in table — pre-existing table? "
                  f"add it by hand or drop the table")
            continue
        if f.widget is not None:
            layer.setEditorWidgetSetup(fidx, QgsEditorWidgetSetup(f.widget.kind, f.widget.config))
        if f.default is not None:
            layer.setDefaultValueDefinition(fidx, QgsDefaultValue(f.default, False))
        if f.read_only:
            form.setReadOnly(fidx, True)
    layer.setEditFormConfig(form)


def _apply_symbol(layer, layer_def):
    r, g, b = hex_to_rgb(layer_def.color)
    color = QColor(r, g, b, 180)
    geom = int(layer.geometryType())
    sym = _library_symbol(layer_def, geom)
    if sym is not None:
        if geom == 1 and layer_def.direction_marker:
            sym.appendSymbolLayer(_direction_marker(color))
        layer.renderer().setSymbol(sym)
        layer.triggerRepaint()
        return
    if geom == 0:       # Point
        props = {"name": "circle", "size": "3",
                 "color": color.name(), "outline_color": "black"}
        props.update(layer_def.symbol)
        sym = QgsMarkerSymbol.createSimple(props)
    elif geom == 1:     # Line
        props = {"color": color.name(), "width": "0.6"}
        props.update(layer_def.symbol)
        sym = QgsLineSymbol.createSimple(props)
        if layer_def.direction_marker:
            sym.appendSymbolLayer(_direction_marker(color))
    else:               # Polygon
        props = {"color": color.name(),
                 "outline_color": "#000000", "outline_width": "0.3"}
        props.update(layer_def.symbol)
        sym = QgsFillSymbol.createSimple(props)
    # createSimple() drops the alpha of a "#rrggbb" colour — set it explicitly,
    # unless the definition overrode the colour (transparent world border…).
    if "color" not in layer_def.symbol:
        sym.setColor(color)
    layer.renderer().setSymbol(sym)
    layer.triggerRepaint()


def _library_symbol(layer_def, geom):
    """Clone of the named QgsStyle symbol, or None (unknown name / wrong geometry)."""
    if not layer_def.style_symbol:
        return None
    sym = QgsStyle.defaultStyle().symbol(layer_def.style_symbol)
    if sym is None:
        print(f"  ⚠ style symbol {layer_def.style_symbol!r} not in the QGIS library — "
              f"using the simple symbol")
        return None
    if int(sym.type()) != geom:
        print(f"  ⚠ style symbol {layer_def.style_symbol!r} is not a "
              f"{layer_def.geom} symbol — using the simple symbol")
        return None
    return sym


def _direction_marker(color):
    """Arrow on the first vertex, rotated along the line.  A "triangle" marker
    at 90° is the one that points in the drawing direction (checked by rendering)."""
    ml = QgsMarkerLineSymbolLayer()
    ml.setPlacements(Qgis.MarkerLinePlacement.FirstVertex)
    if hasattr(ml, "setRotateSymbols"):
        ml.setRotateSymbols(True)
    else:  # QGIS < 3.24
        ml.setRotateMarker(True)
    ml.setSubSymbol(QgsMarkerSymbol.createSimple({
        "name": "triangle", "angle": "90", "size": "4",
        "color": color.name(), "outline_color": "#000000", "outline_width": "0.2",
    }))
    return ml


def _write_properties(layer, layer_def, category):
    props = {
        "ds_category": category.slug,
        "ds_layer": layer_def.slug,
        "ds_priority": int(category.priority),
    }
    if layer_def.is_biome:
        # Read by the export pipeline (recipe.py & co) — keep these names.
        props["biome_type"] = layer_def.biome_type
        props["biome_index"] = layer_def.biome_index
        props["color_hex"] = layer_def.color
        props["terrain_modifier"] = layer_def.terrain_modifier
        if layer_def.planet_type:
            props["planet_type"] = layer_def.planet_type
    props.update(layer_def.properties)
    for key, value in props.items():
        layer.setCustomProperty(key, value)


# ============================================================
# Entry points
# ============================================================
def open_layer(db, layer_def):
    """Create the table if needed and return a fresh QgsVectorLayer on it (or None).

    The layer is NOT registered with the project nor configured — see
    :func:`configure_layer`.  Returns ``(layer, created)``.
    """
    table = layer_def.table
    created = False
    if not db.has_table(table):
        db.create_table(table, layer_def.fields, layer_def.geom)
        created = True
    db.ensure_last_updated_trigger(table)

    layer = QgsVectorLayer(db.layer_uri(table).uri(False), layer_def.name, "postgres")
    if not layer.isValid():
        print(f"  ✗ Failed to open {db.schema}.{table}")
        return None, created
    # A definition whose geometry changed (cliff Polygon → LineString…) or
    # whose fields no longer fit the table (railway lanes → tracks) cannot reuse
    # the old table.  An EMPTY one is dropped and recreated — nothing to lose;
    # one with features is kept: geometry mismatch is refused (it would be filed
    # under the wrong group), missing columns are reported for a manual ALTER.
    if not created:
        actual = QgsWkbTypes.geometryDisplayString(layer.geometryType())
        geom_ok = _GEOM_NAME.get(layer_def.geom) == actual
        columns = {f.name() for f in layer.fields()}
        missing = [f.name for f in layer_def.fields if f.name not in columns]
        if not geom_ok or missing:
            n_rows = db.row_count(table)
            why = (f"{actual} → {layer_def.geom}" if not geom_ok
                   else f"missing columns {', '.join(missing)}")
            print(f"  · {db.schema}.{table}: {why}, {n_rows} row(s) in the table")
            if n_rows == 0:
                del layer
                db.drop_table(table)
                return open_layer(db, layer_def)
            if not geom_ok:
                print(f"  ✗ {db.schema}.{table} is {actual} but the definition says "
                      f"{layer_def.geom} and it holds {n_rows} row(s) "
                      f"— migrate or rename the table, then re-run")
                return None, created
            print(f"  ⚠ {db.schema}.{table} holds {n_rows} row(s) and "
                  f"lacks column(s) {', '.join(missing)} — add them by hand "
                  f"(ALTER TABLE) or drop the table"
                  + (" (row count unknown: check the connection)" if n_rows < 0 else ""))
    return layer, created


def configure_layer(layer, layer_def, category):
    """(Re)apply everything that lives in the project rather than in the database:
    widgets, defaults, read-only flags, custom properties, symbol, name."""
    layer.setName(layer_def.name)
    _configure_fields(layer, layer_def.fields)
    _configure_last_updated(layer)
    _write_properties(layer, layer_def, category)
    _apply_symbol(layer, layer_def)


def create_layer(db, layer_def, category):
    """open + configure + register with the project (not placed in the tree)."""
    layer, created = open_layer(db, layer_def)
    if layer is None:
        return None
    configure_layer(layer, layer_def, category)
    QgsProject.instance().addMapLayer(layer, False)
    if layer_def.on_created is not None:
        layer_def.on_created(layer)
    verb = "Created" if created else "Loaded "
    extra = "" if created else f", {layer.featureCount()} features"
    print(f"  ✓ {verb} {db.schema}.{table_label(layer_def):<32} {layer_def.geom:<10} "
          f"{len(layer_def.fields)} fields{extra}")
    return layer


def table_label(layer_def):
    return layer_def.table
