"""
Interactive setup dialogs (QGIS only).
======================================

    ask_planet(name, radius)   → (name, radius) or None
    ask_selection(db)          → Selection or None

The selection dialog is a checkable tree mirroring the future layer tree
(Region / POI / Lines → category → layer).  Under a layer, every field
declared with ``choices=`` (rock types…) lists its options so the artist ticks
the ones that exist on this planet.

Pre-check rules — the project is the reference, no hidden state:
  • the project already holds layers of this planet → ticked iff in the project
  • empty project but tables in the schema (planet reopened) → ticked iff in DB
  • nothing anywhere (first run) → everything ticked
  A definition you just added is therefore unticked: tick it by hand once.
  Choice values default to the layer's current dropdown.

Unticking removes the layer from the project; its table is dropped only when
empty (see layers.setup_all).
"""

from qgis.PyQt.QtCore import Qt
from qgis.PyQt.QtWidgets import (
    QDialog, QDialogButtonBox, QVBoxLayout, QHBoxLayout, QFormLayout,
    QLineEdit, QDoubleSpinBox, QTreeWidget, QTreeWidgetItem, QPushButton,
    QLabel,
)
from qgis.core import QgsProject

from . import all_categories, Selection, _project_layers_by_slug
from .model import KINDS

_ROLE_KIND = Qt.UserRole + 1      # "layer" | "choice"
_ROLE_KEY = Qt.UserRole + 2       # layer slug | (layer slug, field name, value)


# ============================================================
# Planet identity
# ============================================================
def ask_planet(planet_name, radius_m, parent=None):
    dlg = QDialog(parent)
    dlg.setWindowTitle("DyingStar — planet setup")
    form = QFormLayout(dlg)
    name_edit = QLineEdit(planet_name)
    name_edit.setToolTip("PostgreSQL schema name and QGIS project name (snake_case)")
    radius_spin = QDoubleSpinBox()
    radius_spin.setRange(1_000, 1_000_000_000)
    radius_spin.setDecimals(0)
    radius_spin.setSingleStep(1_000)
    radius_spin.setSuffix(" m")
    radius_spin.setValue(radius_m)
    form.addRow("Planet name", name_edit)
    form.addRow("Radius", radius_spin)
    buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
    buttons.accepted.connect(dlg.accept)
    buttons.rejected.connect(dlg.reject)
    form.addRow(buttons)
    if dlg.exec_() != QDialog.Accepted:
        return None
    name = name_edit.text().strip().replace(" ", "_")
    if not name:
        return None
    return name, int(radius_spin.value())


# ============================================================
# Layer selection
# ============================================================
def _current_dropdown_values(layer, field_name):
    """Values of the ValueMap currently configured on *field_name*, or None."""
    fidx = layer.fields().indexOf(field_name)
    if fidx < 0:
        return None
    setup = layer.editorWidgetSetup(fidx)
    if setup.type() != "ValueMap":
        return None
    values = []
    for entry in setup.config().get("map", []):
        values.extend(entry.values())
    return values


class _SelectionDialog(QDialog):
    def __init__(self, db, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"DyingStar — layers for '{db.schema}'")
        self.resize(900, 700)
        self._db = db
        self._project_layers = _project_layers_by_slug(QgsProject.instance(), db, all_categories())
        if self._project_layers:
            self._tick = lambda in_db, in_project: in_project
        elif db.tables():
            self._tick = lambda in_db, in_project: in_db
        else:
            self._tick = lambda in_db, in_project: True

        vbox = QVBoxLayout(self)
        vbox.addWidget(QLabel(
            "Tick the layers to create (or refresh) for this planet.  "
            "An unticked layer is removed from the project, and its table is "
            "dropped only if it holds no feature — drawn data is never deleted."))

        self._filter = QLineEdit()
        self._filter.setPlaceholderText("filter…")
        self._filter.textChanged.connect(self._apply_filter)
        vbox.addWidget(self._filter)

        self._tree = QTreeWidget()
        self._tree.setHeaderLabels(["Layer", "Geometry", "Table", "Description"])
        self._tree.setColumnWidth(0, 260)
        self._tree.setColumnWidth(1, 90)
        self._tree.setColumnWidth(2, 200)
        vbox.addWidget(self._tree)

        self._build()

        row = QHBoxLayout()
        for label, fn in (("All", lambda: self._check_all(Qt.Checked)),
                          ("None", lambda: self._check_all(Qt.Unchecked)),
                          ("In database only", self._check_db_only)):
            btn = QPushButton(label)
            btn.clicked.connect(fn)
            row.addWidget(btn)
        row.addStretch()
        vbox.addLayout(row)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        vbox.addWidget(buttons)

    # ---- tree building -------------------------------------------------
    def _make_item(self, parent, texts, checked=None):
        item = QTreeWidgetItem(parent, texts)
        flags = item.flags() | Qt.ItemIsUserCheckable
        if checked is None:
            flags |= Qt.ItemIsAutoTristate
        item.setFlags(flags)
        item.setCheckState(0, checked if checked is not None else Qt.Unchecked)
        return item

    def _build(self):
        kind_items = {}
        for kind in KINDS:
            kind_items[kind] = self._make_item(self._tree, [kind])
            kind_items[kind].setExpanded(True)

        self._layer_items = []
        for cat in all_categories():
            group_items = {}
            for layer_def in cat.layers:
                parent = kind_items[layer_def.kind]
                if cat.group:
                    if cat.group not in group_items:
                        group_items[cat.group] = self._make_item(parent, [cat.group])
                        group_items[cat.group].setExpanded(True)
                    parent = group_items[cat.group]

                in_db = self._db.has_table(layer_def.table)
                in_project = layer_def.slug in self._project_layers
                ticked = self._tick(in_db, in_project)
                table_txt = layer_def.table + ("  (in DB)" if in_db else "")
                item = self._make_item(
                    parent,
                    [layer_def.name, layer_def.geom, table_txt, layer_def.description],
                    Qt.Checked if ticked else Qt.Unchecked)
                item.setData(0, _ROLE_KIND, "layer")
                item.setData(0, _ROLE_KEY, layer_def.slug)
                item.setToolTip(3, layer_def.description)
                self._layer_items.append((item, layer_def, in_db))

                for f in layer_def.choice_fields:
                    # A choice field is a plain container: the layer's own
                    # check state is what matters, so no auto-tristate here.
                    field_item = QTreeWidgetItem(item, [f"{f.name}  — pick the values valid here",
                                                        "", "", f.comment])
                    field_item.setFlags(field_item.flags() & ~Qt.ItemIsUserCheckable)
                    current = None
                    if in_project:
                        current = _current_dropdown_values(self._project_layers[layer_def.slug], f.name)
                    for label, value in f.choices:
                        on = current is None or value in current
                        opt = self._make_item(field_item, [label, "", value, ""],
                                              Qt.Checked if on else Qt.Unchecked)
                        opt.setData(0, _ROLE_KIND, "choice")
                        opt.setData(0, _ROLE_KEY, (layer_def.slug, f.name, value))

    # ---- buttons -------------------------------------------------------
    def _check_all(self, state):
        for item, _, _ in self._layer_items:
            item.setCheckState(0, state)

    def _check_db_only(self):
        for item, _, in_db in self._layer_items:
            item.setCheckState(0, Qt.Checked if in_db else Qt.Unchecked)

    def _apply_filter(self, text):
        text = text.lower().strip()
        for item, layer_def, _ in self._layer_items:
            hit = (not text or text in layer_def.name.lower()
                   or text in (layer_def.biome_type or "").lower()
                   or text in layer_def.description.lower())
            item.setHidden(not hit)

    # ---- result --------------------------------------------------------
    def selection(self):
        sel = Selection()
        for item, layer_def, _ in self._layer_items:
            if item.checkState(0) != Qt.Checked:
                continue
            sel.layers.add(layer_def.slug)
            for f in layer_def.choice_fields:
                sel.choices[(layer_def.slug, f.name)] = []
            for i in range(item.childCount()):
                field_item = item.child(i)
                for j in range(field_item.childCount()):
                    opt = field_item.child(j)
                    if opt.checkState(0) == Qt.Checked:
                        slug, fname, value = opt.data(0, _ROLE_KEY)
                        sel.choices[(slug, fname)].append(value)
        return sel


def ask_selection(db, parent=None):
    dlg = _SelectionDialog(db, parent)
    if dlg.exec_() != QDialog.Accepted:
        return None
    return dlg.selection()
