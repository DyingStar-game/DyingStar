"""Road design: the "DyingStar — Routes" toolbar and the zone terrain dialog (zone_terrain.py)."""
from qgis.PyQt.QtWidgets import (
    QCheckBox, QComboBox, QDialog, QDialogButtonBox, QDoubleSpinBox, QFormLayout, QLabel,
    QVBoxLayout,
)

from . import settings
from .runner import Step

_KEY = "zone_terrain/"
#: The steep-slope threshold's default: past it a road cannot go even across the slope.
DEFAULT_STEEP = 30.0
DEFAULT_MAX_SLOPE = 8.0


def max_slope():
    return float(settings.value(_KEY + "max_slope_deg", str(DEFAULT_MAX_SLOPE)))


def steep():
    return float(settings.value(_KEY + "steep_deg", str(DEFAULT_STEEP)))


class RoadsUi:
    """The Routes toolbar: max slope and steep threshold (recolour the slope layers at once),
    the max slope taken from the selected road; and the zone terrain action."""

    def __init__(self, plugin):
        self.plugin = plugin
        self.iface = plugin.iface
        self.toolbar = self.iface.addToolBar("DyingStar — Routes")
        self.toolbar.setObjectName("DyingStarRoadsToolbar")
        self.toolbar.addWidget(QLabel(" Pente max "))
        self.max_spin = self._spin(max_slope(), 1.0, 45.0,
                                   "La pente maximale de la route (max_slope_degrees) : en vert, "
                                   "le terrain qu'elle suit sans ouvrage. Reprise de la route "
                                   "sélectionnée.")
        self.toolbar.addWidget(QLabel(" raide "))
        self.steep_spin = self._spin(steep(), 5.0, 89.0,
                                     "Au-delà, même en biais ou en lacets la route ne passe pas "
                                     "sans tunnel ni viaduc (rouge).")
        self.max_spin.valueChanged.connect(self._restyle)
        self.steep_spin.valueChanged.connect(self._restyle)
        self.terrain_action = self.toolbar.addAction("Terrain de la zone…", self.zone_terrain)
        self.terrain_action.setToolTip("Altitude, courbes et pente de la zone affichée")
        self._watched = None
        self.iface.currentLayerChanged.connect(self._watch_layer)
        self._watch_layer(self.iface.activeLayer())

    def _spin(self, val, lo, hi, tip):
        w = QDoubleSpinBox()
        w.setRange(lo, hi)
        w.setDecimals(1)
        w.setSingleStep(0.5)
        w.setSuffix("°")
        w.setValue(val)
        w.setToolTip(tip)
        self.toolbar.addWidget(w)
        return w

    def unload(self):
        try:
            self.iface.currentLayerChanged.disconnect(self._watch_layer)
        except TypeError:
            pass
        self._watch_layer(None)
        self.toolbar.deleteLater()

    # ── max slope ─────────────────────────────────────────────────────────────
    def _restyle(self, *_):
        settings.set_value(_KEY + "max_slope_deg", str(self.max_spin.value()))
        settings.set_value(_KEY + "steep_deg", str(self.steep_spin.value()))
        import zone_terrain
        zone_terrain.restyle_all(self.max_spin.value(), self.steep_spin.value())

    def _watch_layer(self, layer):
        if self._watched is not None:
            try:
                self._watched.selectionChanged.disconnect(self._selection_changed)
            except (TypeError, RuntimeError):
                pass
            self._watched = None
        if layer is not None and hasattr(layer, "selectionChanged") \
                and layer.fields().indexOf("max_slope_degrees") >= 0:
            layer.selectionChanged.connect(self._selection_changed)
            self._watched = layer
            self._selection_changed()

    def _selection_changed(self, *_):
        layer = self._watched
        if layer is None:
            return
        for feat in layer.getSelectedFeatures():
            v = feat["max_slope_degrees"]
            if v is not None and str(v) != "NULL":
                try:
                    self.max_spin.setValue(float(v))
                except (TypeError, ValueError):
                    pass
            return

    # ── zone terrain ──────────────────────────────────────────────────────────
    def zone_terrain(self):
        dlg = ZoneTerrainDialog(self.iface.mainWindow())
        if dlg.exec() != QDialog.DialogCode.Accepted:
            return
        opts = dlg.options()
        opts["max_slope_deg"] = self.max_spin.value()
        opts["steep_deg"] = self.steep_spin.value()
        label = "exact" if opts["source"] == "exact" else "rapide"
        self.plugin._job(f"Terrain de la zone ({label})", [Step("zone_terrain", **opts)])


class ZoneTerrainDialog(QDialog):
    CHANNELS = [("(celui de client.ini)", ""), ("unstable", "unstable"), ("dev", "dev"),
                ("preprod", "preprod"), ("prod", "prod")]

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Terrain de la zone")
        form = QFormLayout()
        self.source = QComboBox()
        self.source.addItem("Rapide — QGIS seul, sans export", "quick")
        self.source.addItem("Exact — Godot, le sol du jeu", "exact")
        self.source.setCurrentIndex(max(0, self.source.findData(
            settings.value(_KEY + "source", "quick"))))
        self.pitch = self._dspin(settings.value(_KEY + "pitch_m", "25"), 5, 5000, " m")
        self.contour = self._dspin(settings.value(_KEY + "contour_m", "25"), 0, 1000, " m")
        self.cracks = QCheckBox()
        self.cracks.setChecked(settings.value(_KEY + "cracks", True))
        self.local = QCheckBox()
        self.local.setChecked(settings.value(_KEY + "local_modifiers", True))
        self.channel = QComboBox()
        for label, value in self.CHANNELS:
            self.channel.addItem(label, value)
        self.channel.setCurrentIndex(max(0, self.channel.findData(
            settings.value(_KEY + "tile_channel", ""))))
        form.addRow("Source", self.source)
        form.addRow("Pas de la grille", self.pitch)
        form.addRow("Courbes de niveau tous les (0 = aucune)", self.contour)
        form.addRow("Exact : crevasses de corindon", self.cracks)
        form.addRow("Exact : modificateurs du dernier export local", self.local)
        form.addRow("Exact : canal de l'élévation", self.channel)
        note = QLabel(
            "Rapide : les courbes de niveau (comme l'export) + massifs et crêtes tels que "
            "dessinés ; sans volcans ni terrain rocheux.\n"
            "Exact : la fonction que lisent les profils des routes dans le jeu ; les massifs, "
            "volcans et rochers du dernier export local, sans publier. Binaire Godot à "
            "renseigner dans Paramètres.\n"
            "Zone = l'emprise de la carte. 25 m = le pas le plus fin du terrain du jeu.")
        note.setWordWrap(True)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok
                                   | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(note)
        layout.addWidget(buttons)

    @staticmethod
    def _dspin(val, lo, hi, suffix):
        w = QDoubleSpinBox()
        w.setRange(lo, hi)
        w.setDecimals(0)
        w.setSuffix(suffix)
        w.setValue(float(val))
        return w

    def options(self):
        return {
            "source": self.source.currentData(),
            "pitch_m": float(self.pitch.value()),
            "contour_m": float(self.contour.value()),
            "cracks": self.cracks.isChecked(),
            "local_modifiers": self.local.isChecked(),
            "tile_channel": self.channel.currentData(),
        }

    def _save(self):
        for key, v in self.options().items():
            settings.set_value(_KEY + key, v if isinstance(v, bool) else str(v))
        self.accept()
