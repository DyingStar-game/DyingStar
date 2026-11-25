"""The "Profil en long" panel: the profile the game will lay a selected road on, over the zone
terrain — terrain, line, cuttings, tunnels, viaducts, and their lengths. It follows the selection
of EVERY road / railway layer (whatever the active layer), and updates while the geometry is
edited; its "Choisir sur la carte" button picks a road with one click."""
import importlib

from qgis.core import (Qgis, QgsCoordinateReferenceSystem, QgsCoordinateTransform, QgsGeometry,
                       QgsPointXY, QgsProject)
from qgis.gui import QgsMapToolIdentify, QgsRubberBand, QgsVertexMarker
from qgis.PyQt.QtCore import Qt, QTimer
from qgis.PyQt.QtGui import QColor
from qgis.PyQt.QtWidgets import (QDockWidget, QHBoxLayout, QLabel, QToolButton, QVBoxLayout,
                                 QWidget)

#: Segment colours (GradeSettings.Kind): ground none, cutting, tunnel, viaduct — on the plot and
#: on the map, chosen to stand out from the slope classes (green / orange / red) and the contours.
SEG_COLORS = {1: "#f0a020", 2: "#333333", 3: "#00c8ff"}
#: The profiled road on the map and on the plot: a bright blue on a white halo.
ROAD_COLOR = "#0050ff"
HALO_COLOR = "#ffffff"
SEG_NAMES = {0: "sol", 1: "tranchée", 2: "tunnel", 3: "viaduc"}
HELP = ("Sélectionne une route ou une voie ferrée : bouton « Choisir sur la carte » puis un clic "
        "sur la route, ou l'outil de sélection de QGIS sur sa couche.")


def is_line_layer(layer):
    return hasattr(layer, "selectionChanged") and hasattr(layer, "geometryType") \
        and int(layer.geometryType()) == 1


def is_road_layer(layer):
    """A road / railway layer of the planet project (layers/roads.py), or a legacy one."""
    if not is_line_layer(layer):
        return False
    return bool(layer.customProperty("road_type", "")) \
        or layer.fields().indexOf("max_slope_degrees") >= 0 \
        or layer.fields().indexOf("road_type") >= 0


class _PickTool(QgsMapToolIdentify):
    """One click on the map selects the road under it (among the road layers) for the panel."""

    def __init__(self, canvas, dock):
        super().__init__(canvas)
        self.dock = dock

    def canvasReleaseEvent(self, event):  # noqa: N802 — Qt
        layers = self.dock.road_layers()
        if not layers:
            self.dock.title.setText("Aucune couche de route ou de rail dans le projet.")
            return
        hits = self.identify(int(event.pos().x()), int(event.pos().y()), layers,
                             QgsMapToolIdentify.IdentifyMode.TopDownStopAtFirst)
        if not hits:
            self.dock.title.setText("Pas de route sous le clic — clique plus près de la ligne.")
            return
        layer = hits[0].mLayer
        layer.selectByIds([hits[0].mFeature.id()])
        self.dock.follow(layer)


class ProfileDock(QDockWidget):

    def __init__(self, iface, max_slope_deg):
        super().__init__("Profil en long — DyingStar")
        self.setObjectName("DyingStarProfileDock")
        self.iface = iface
        self.max_slope_deg = max_slope_deg   # callable: the toolbar's value
        self._layer = None
        self._fid = None
        self._data = None
        self._marker = None
        self._watched = {}     # layer id -> layer
        self._tool = None
        self._bands = []       # the profiled road drawn on the map
        body = QWidget()
        layout = QVBoxLayout(body)
        row = QHBoxLayout()
        self.pick = QToolButton()
        self.pick.setText("Choisir sur la carte")
        self.pick.setCheckable(True)
        self.pick.setToolTip("Puis un clic sur une route ou une voie ferrée : son profil s'affiche. "
                             "Reste actif pour en choisir d'autres.")
        self.pick.toggled.connect(self._toggle_pick)
        row.addWidget(self.pick)
        self.title = QLabel(HELP)
        self.title.setWordWrap(True)
        self.title.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        row.addWidget(self.title, 1)
        layout.addLayout(row)
        self.canvas = None
        try:
            from matplotlib.figure import Figure
            from matplotlib.backends.backend_qtagg import FigureCanvasQTAgg
            self.figure = Figure(figsize=(6, 2.6), tight_layout=True)
            self.ax = self.figure.add_subplot(111)
            self.canvas = FigureCanvasQTAgg(self.figure)
            self.canvas.setMinimumHeight(200)
            self.canvas.mpl_connect("motion_notify_event", self._hover)
            self.canvas.mpl_connect("axes_leave_event", lambda _e: self._hide_marker())
            layout.addWidget(self.canvas, 1)
        except Exception as exc:  # noqa: BLE001 — matplotlib missing: stats only
            layout.addWidget(QLabel(f"(graphique indisponible : {exc})"))
        self.stats = QLabel("")
        self.stats.setWordWrap(True)
        self.stats.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        layout.addWidget(self.stats)
        self.setWidget(body)
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.setInterval(200)
        self._timer.timeout.connect(self.refresh)
        project = QgsProject.instance()
        project.layersAdded.connect(self._rescan)
        project.layersRemoved.connect(self._rescan)
        iface.currentLayerChanged.connect(self._active_changed)
        self._rescan()

    # ── following the selection ───────────────────────────────────────────────
    def road_layers(self):
        return [lyr for lyr in QgsProject.instance().mapLayers().values() if is_road_layer(lyr)]

    def _rescan(self, *_):
        """Watch the selection and the edits of every road layer (and of the active line layer)."""
        wanted = {lyr.id(): lyr for lyr in self.road_layers()}
        active = self.iface.activeLayer()
        if active is not None and is_line_layer(active):
            wanted[active.id()] = active
        for lid in list(self._watched):
            if lid not in wanted:
                self._disconnect(self._watched.pop(lid))
        for lid, layer in wanted.items():
            if lid not in self._watched:
                self._watched[lid] = layer
                layer.selectionChanged.connect(self._selection_changed)
                layer.geometryChanged.connect(self._edited)
                layer.afterCommitChanges.connect(self._edited)
        if self._layer is not None and self._layer.id() not in self._watched:
            self._layer = None
        self.schedule()

    def _disconnect(self, layer):
        for sig, slot in ((layer.selectionChanged, self._selection_changed),
                          (layer.geometryChanged, self._edited),
                          (layer.afterCommitChanges, self._edited)):
            try:
                sig.disconnect(slot)
            except (TypeError, RuntimeError):
                pass

    def _active_changed(self, layer):
        self._rescan()
        if layer is not None and layer.id() in self._watched and layer.selectedFeatureCount():
            self.follow(layer)

    def _selection_changed(self, *_):
        layer = self.sender()
        if layer is not None and layer.selectedFeatureCount():
            self.follow(layer)
        else:
            self.schedule()

    def _edited(self, *_):
        if self.sender() is self._layer:
            self.schedule()

    def follow(self, layer):
        """Show the profile of [layer]'s (first) selected feature."""
        self._layer = layer
        self.schedule()

    def schedule(self, *_):
        self._timer.start()

    def _toggle_pick(self, on):
        canvas = self.iface.mapCanvas()
        if on:
            if self._tool is None:
                self._tool = _PickTool(canvas, self)
                self._tool.deactivated.connect(lambda: self.pick.setChecked(False))
            canvas.setMapTool(self._tool)
            self.setVisible(True)
        elif self._tool is not None and canvas.mapTool() is self._tool:
            canvas.unsetMapTool(self._tool)

    def unload(self):
        project = QgsProject.instance()
        for sig, slot in ((project.layersAdded, self._rescan), (project.layersRemoved, self._rescan),
                          (self.iface.currentLayerChanged, self._active_changed)):
            try:
                sig.disconnect(slot)
            except (TypeError, RuntimeError):
                pass
        for layer in self._watched.values():
            self._disconnect(layer)
        self._watched = {}
        if self._tool is not None:
            self.pick.setChecked(False)
            self._tool = None
        self._hide_marker()
        self._clear_bands()

    # ── the profile ───────────────────────────────────────────────────────────
    def showEvent(self, event):  # noqa: N802 — Qt
        super().showEvent(event)
        self.schedule()

    def hideEvent(self, event):  # noqa: N802 — Qt
        super().hideEvent(event)
        self._clear_bands()
        self._hide_marker()

    def refresh(self):
        if not self.isVisible():
            return
        layer = self._layer
        if layer is None or not layer.selectedFeatureCount():
            # Whatever road layer holds a selection, the active one first.
            active = self.iface.activeLayer()
            order = sorted(self._watched.values(), key=lambda lyr: lyr is not active)
            layer = next((lyr for lyr in order if lyr.selectedFeatureCount()), None)
            self._layer = layer
        feats = list(layer.getSelectedFeatures()) if layer is not None else []
        if not feats:
            self._show_message(HELP)
            return
        feat = feats[0]
        try:
            rp = importlib.import_module("road_profile")
            data = rp.profile_of(layer, feat, float(self.max_slope_deg()))
        except Exception as exc:  # noqa: BLE001 — shown in the panel
            self._show_message(f"{layer.name()} #{feat.id()} : {exc}")
            return
        self._data = data
        self._draw(layer, feat, data)
        self._draw_on_map(data)

    def _show_message(self, text):
        self._data = None
        self._clear_bands()
        self.title.setText(text)
        self.stats.setText("")
        if self.canvas is not None:
            self.ax.clear()
            self.canvas.draw_idle()

    def _draw(self, layer, feat, data):
        prof, s = data["profile"], data["summary"]
        name = ""
        if feat.fields().indexOf("name") >= 0 and feat["name"] not in (None, "") \
                and str(feat["name"]) != "NULL":
            name = f" « {feat['name']} »"
        self.title.setText(f"<b>{layer.name()}{name}</b> #{feat.id()} — {data['grade_label']}"
                           f"<br><small>sur la carte : la route en "
                           f"<span style='color:{ROAD_COLOR}'><b>bleu</b></span> — "
                           f"terrain : {data['terrain_name']}"
                           + (" — <i>hypothèse</i>" if data["what_if"] else "") + "</small>")
        if self.canvas is not None:
            ax = self.ax
            ax.clear()
            a0 = prof["along0"]
            km = [(a - a0) / 1000.0 for a in prof["stations_along"]]
            ax.plot(km, prof["stations_terrain"], color="#8c6a46", lw=1.0, label="terrain")
            ax.plot([(a - a0) / 1000.0 for a in prof["knots_along"]], prof["knots_z"],
                    color=ROAD_COLOR, lw=1.6, label="route")
            for seg in prof["segments"]:
                if seg["kind"] in SEG_COLORS:
                    ax.axvspan((seg["lo"] - a0) / 1000.0, (seg["hi"] - a0) / 1000.0,
                               color=SEG_COLORS[seg["kind"]], alpha=0.25, lw=0)
            ax.set_xlabel("km")
            ax.set_ylabel("m")
            ax.grid(True, lw=0.3, alpha=0.5)
            self.canvas.draw_idle()
        by = s["by_kind_m"]
        parts = [f"{s['length_m'] / 1000.0:.2f} km",
                 f"dénivelé {s['climb_m']:+.0f} m",
                 f"pente max de la route {100.0 * s['steepest_grade']:.1f} %"]
        for kind in (0, 1, 2, 3):
            if by[kind] > 0:
                parts.append(f"<span style='color:{SEG_COLORS.get(kind, '#444')}'>"
                             f"{SEG_NAMES[kind]}</span> {by[kind]:.0f} m "
                             f"({100.0 * s['share'][kind]:.0f} %)")
        if s["tunnels_m"]:
            parts.append(f"{len(s['tunnels_m'])} tunnel(s), le plus long "
                         f"{max(s['tunnels_m']):.0f} m, couverture max {s['max_cover_m']:.0f} m")
        if s["viaducts"]:
            decks = sum(v[1] for v in s["viaducts"])
            parts.append(f"{len(s['viaducts'])} viaduc(s) — {decks} tablier(s) de ≤ 400 m, "
                         f"hauteur max {s['max_gap_m']:.0f} m")
        self.stats.setText(" · ".join(parts))

    # ── the road on the map ───────────────────────────────────────────────────
    def _band(self, color, width, dash=False):
        band = QgsRubberBand(self.iface.mapCanvas(), Qgis.GeometryType.Line)
        band.setColor(QColor(color))
        band.setWidth(width)
        if dash:
            band.setLineStyle(Qt.PenStyle.DashLine)
        self._bands.append(band)
        return band

    def _clear_bands(self):
        canvas = self.iface.mapCanvas()
        for band in self._bands:
            band.reset(Qgis.GeometryType.Line)
            canvas.scene().removeItem(band)
        self._bands = []

    def _map_geometry(self, pts):
        geom = QgsGeometry.fromPolylineXY([QgsPointXY(x, y) for x, y in pts])
        dest = self.iface.mapCanvas().mapSettings().destinationCrs()
        wgs = QgsCoordinateReferenceSystem("EPSG:4326")
        if dest != wgs:
            geom.transform(QgsCoordinateTransform(wgs, dest, QgsProject.instance()))
        return geom

    def _draw_on_map(self, data):
        """The profiled road in blue on a white halo, its cuttings, tunnels and viaducts on top
        in the plot's colours — the yellow selection is lost on the slope classes."""
        self._clear_bands()
        rp = importlib.import_module("road_profile")
        line, cum = data["line"], data["cum"]
        self._band(HALO_COLOR, 8).setToGeometry(self._map_geometry(line), None)
        self._band(ROAD_COLOR, 4).setToGeometry(self._map_geometry(line), None)
        for seg in data["profile"]["segments"]:
            if seg["kind"] not in SEG_COLORS:
                continue
            lo, hi = seg["lo"], seg["hi"]
            pts = [rp.gp.lonlat_at(line, cum, lo)]
            pts += [p for p, a in zip(line, cum) if lo < a < hi]
            pts.append(rp.gp.lonlat_at(line, cum, hi))
            self._band(SEG_COLORS[seg["kind"]], 5, dash=seg["kind"] == 2).setToGeometry(
                self._map_geometry(pts), None)

    # ── hover → map marker ────────────────────────────────────────────────────
    def _hover(self, event):
        if self._data is None or event.xdata is None:
            return
        rp = importlib.import_module("road_profile")
        prof = self._data["profile"]
        along = prof["along0"] + 1000.0 * float(event.xdata)
        lon, lat = rp.gp.lonlat_at(self._data["line"], self._data["cum"], along)
        canvas = self.iface.mapCanvas()
        pt = QgsPointXY(lon, lat)
        dest = canvas.mapSettings().destinationCrs()
        wgs = QgsCoordinateReferenceSystem("EPSG:4326")
        if dest != wgs:
            pt = QgsCoordinateTransform(wgs, dest, QgsProject.instance()).transform(pt)
        if self._marker is None:
            self._marker = QgsVertexMarker(canvas)
            self._marker.setIconType(QgsVertexMarker.IconType.ICON_CIRCLE)
            self._marker.setColor(QColor("#d7301f"))
            self._marker.setIconSize(12)
            self._marker.setPenWidth(3)
        self._marker.setCenter(pt)
        self._marker.show()

    def _hide_marker(self):
        if self._marker is not None:
            self._marker.hide()
