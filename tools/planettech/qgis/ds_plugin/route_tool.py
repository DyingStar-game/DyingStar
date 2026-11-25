"""Routes ▸ Tracer une route: a dialog (target layer, max slope, structure cost), then a map tool —
left click: the start, then waypoints; right click: the end; Backspace: drop the last point;
Escape: give up. The search runs in the background (zone_route.py)."""
from qgis.core import (Qgis, QgsCoordinateReferenceSystem, QgsCoordinateTransform, QgsGeometry,
                       QgsPointXY, QgsProject)
from qgis.gui import QgsMapTool, QgsRubberBand
from qgis.PyQt.QtCore import Qt
from qgis.PyQt.QtGui import QColor
from qgis.PyQt.QtWidgets import (QComboBox, QDialog, QDialogButtonBox, QDoubleSpinBox,
                                 QFormLayout, QLabel, QVBoxLayout)

from . import settings
from .profile_dock import ROAD_COLOR, is_road_layer

_KEY = "route_tool/"
HELP = ("Tracer une route : clic gauche = départ puis points de passage, clic droit = arrivée, "
        "Retour arrière = enlever le dernier point, Échap = abandonner.")


class RouteDialog(QDialog):
    def __init__(self, max_slope_deg, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Tracer une route")
        form = QFormLayout()
        self.layer = QComboBox()
        layers = sorted((lyr for lyr in QgsProject.instance().mapLayers().values()
                         if is_road_layer(lyr) and lyr.customProperty("road_type", "")
                         and not lyr.customProperty("ds_route", "")),
                        key=lambda lyr: lyr.name())
        last = settings.value(_KEY + "layer", "highway")
        for lyr in layers:
            self.layer.addItem(f"{lyr.name()} ({lyr.customProperty('road_type')})", lyr.id())
            if lyr.name() == last:
                self.layer.setCurrentIndex(self.layer.count() - 1)
        self.slope = QDoubleSpinBox()
        self.slope.setRange(1.0, 45.0)
        self.slope.setDecimals(1)
        self.slope.setSuffix("°")
        self.slope.setValue(max_slope_deg)
        self.weight = QDoubleSpinBox()
        self.weight.setRange(0.0, 100.0)
        self.weight.setDecimals(1)
        self.weight.setValue(float(settings.value(_KEY + "structure_weight", "6")))
        self.weight.setToolTip("Combien un pas plus raide que la pente max coûte en plus, par "
                               "fois la pente max dépassée : plus haut = plus de lacets et de "
                               "détours, moins de tunnels et viaducs.")
        self.cracks = QDoubleSpinBox()
        self.cracks.setRange(0.0, 100.0)
        self.cracks.setDecimals(1)
        self.cracks.setValue(float(settings.value(_KEY + "crack_weight", "4")))
        self.cracks.setToolTip("Surcoût d'un pont sur une crevasse de corindon, en fois la "
                               "longueur (terrain exact avec crevasses).")
        bridge, tunnel = settings.structure_limits()
        self.max_bridge = self._metres(bridge, "Le tracé ne garde pas de viaduc plus long : il "
                                       "cherche à nouveau en contournant la vallée (0 = sans "
                                       "limite). Le profil en long le signale aussi.")
        self.max_tunnel = self._metres(tunnel, "Le tracé ne garde pas de tunnel plus long : il "
                                       "cherche à nouveau, en lacets ou par un détour (0 = sans "
                                       "limite).")
        form.addRow("Couche de destination", self.layer)
        form.addRow("Pente max (route)", self.slope)
        form.addRow("Coût des ouvrages", self.weight)
        form.addRow("Coût des ponts sur crevasse", self.cracks)
        form.addRow("Viaduc max (0 = sans limite)", self.max_bridge)
        form.addRow("Tunnel max (0 = sans limite)", self.max_tunnel)
        note = QLabel("Le calcul se fait sur le « Terrain de la zone » déjà calculé, qui doit "
                      "couvrir tout le parcours. Une voie ferrée prend sa pente du jeu (4 %). "
                      "Le tracé proposé s'affiche dans le profil en long avant d'être ajouté.")
        note.setWordWrap(True)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok
                                   | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        if not layers:
            layout.addWidget(QLabel("Aucune couche de route dans le projet "
                                    "(DyingStar ▸ Projet planète)."))
        layout.addLayout(form)
        layout.addWidget(note)
        layout.addWidget(buttons)

    @staticmethod
    def _metres(val, tip):
        w = QDoubleSpinBox()
        w.setRange(0.0, 100000.0)
        w.setDecimals(0)
        w.setSingleStep(50.0)
        w.setSuffix(" m")
        w.setValue(val)
        w.setToolTip(tip)
        return w

    def _save(self):
        if self.layer.currentData() is None:
            self.reject()
            return
        settings.set_value(_KEY + "layer", QgsProject.instance().mapLayer(
            self.layer.currentData()).name())
        settings.set_value(_KEY + "structure_weight", str(self.weight.value()))
        settings.set_value(_KEY + "crack_weight", str(self.cracks.value()))
        settings.set_value(settings.MAX_BRIDGE_KEY, str(self.max_bridge.value()))
        settings.set_value(settings.MAX_TUNNEL_KEY, str(self.max_tunnel.value()))
        self.accept()

    def options(self):
        return {"target_layer_id": self.layer.currentData(),
                "max_slope_deg": self.slope.value(),
                "structure_weight": self.weight.value(),
                "crack_weight": self.cracks.value(),
                "max_bridge_m": self.max_bridge.value(),
                "max_tunnel_m": self.max_tunnel.value()}


class RouteTool(QgsMapTool):
    """Collects the clicked points (snapped when QGIS's snapping is on), in EPSG:4326."""

    def __init__(self, canvas, on_done):
        super().__init__(canvas)
        self.on_done = on_done
        self.points = []       # canvas CRS
        self.band = QgsRubberBand(canvas, Qgis.GeometryType.Line)
        self.band.setColor(QColor(ROAD_COLOR))
        self.band.setWidth(2)
        self.band.setLineStyle(Qt.PenStyle.DashLine)
        self.marks = QgsRubberBand(canvas, Qgis.GeometryType.Point)
        self.marks.setColor(QColor(ROAD_COLOR))
        self.marks.setIconSize(10)
        self.setCursor(Qt.CursorShape.CrossCursor)

    def _point(self, event):
        match = self.canvas().snappingUtils().snapToMap(event.mapPoint())
        return QgsPointXY(match.point()) if match.isValid() else QgsPointXY(event.mapPoint())

    def canvasReleaseEvent(self, event):  # noqa: N802 — Qt
        pt = self._point(event)
        if event.button() == Qt.MouseButton.RightButton:
            if not self.points or self.points[-1] != pt:
                self.points.append(pt)
            self._redraw()
            if len(self.points) >= 2:
                pts = self.lonlat()
                self.reset()
                self.on_done(pts)
            return
        self.points.append(pt)
        self._redraw()

    def canvasMoveEvent(self, event):  # noqa: N802 — Qt
        if self.points:
            self._redraw(self._point(event))

    def keyPressEvent(self, event):  # noqa: N802 — Qt
        if event.key() == Qt.Key.Key_Escape:
            self.reset()
            self.canvas().unsetMapTool(self)
        elif event.key() == Qt.Key.Key_Backspace and self.points:
            self.points.pop()
            self._redraw()

    def _redraw(self, hover=None):
        pts = self.points + ([hover] if hover is not None else [])
        self.band.reset(Qgis.GeometryType.Line)
        if len(pts) >= 2:
            self.band.setToGeometry(QgsGeometry.fromPolylineXY(pts), None)
        self.marks.reset(Qgis.GeometryType.Point)
        for p in self.points:
            self.marks.addPoint(p)

    def lonlat(self):
        src = self.canvas().mapSettings().destinationCrs()
        wgs = QgsCoordinateReferenceSystem("EPSG:4326")
        xf = None if src == wgs else QgsCoordinateTransform(src, wgs, QgsProject.instance())
        out = []
        for p in self.points:
            q = xf.transform(p) if xf else p
            out.append((q.x(), q.y()))
        return out

    def reset(self):
        self.points = []
        self.band.reset(Qgis.GeometryType.Line)
        self.marks.reset(Qgis.GeometryType.Point)

    def deactivate(self):  # noqa: D401 — Qt
        self.reset()
        super().deactivate()
