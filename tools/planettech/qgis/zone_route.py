"""A road drawn by the computer between clicked points, keeping to the max slope over the zone
terrain (export/planet/route_search.py) — DyingStar ▸ Routes ▸ Tracer une route.

The proposal goes to a scratch layer "DyingStar — tracé proposé" and is selected, so the profile
panel shows it at once; the message bar offers to add it to the target road layer (which is put
in edit mode: save it to write it to the database) or to drop it.
"""
import math
import os
import sys

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

import ds_project                                         # noqa: E402
from export.planet import grade_profile as gp             # noqa: E402
from export.planet import route_search as rs              # noqa: E402

PREVIEW_NAME = "DyingStar — tracé proposé"
TAG = "ds_route"

#: Set by the plugin's runner (unused: the search is one C call per leg).
PROGRESS = None


def _terrain_layers():
    from qgis.core import QgsProject
    dem, cracks = [], []
    for lyr in QgsProject.instance().mapLayers().values():
        kind = lyr.customProperty("ds_terrain", "")
        if kind == "dem":
            dem.append(lyr)
        elif kind == "cracks":
            cracks.append(lyr)
    return dem, cracks


def prepare(points, target_layer_id, max_slope_deg=8.0, structure_weight=6.0, crack_weight=4.0,
            max_nodes=1_000_000, max_bridge_m=0.0, max_tunnel_m=0.0):
    """Main thread: the clicked points (lon, lat), the target layer, the terrain files."""
    from qgis.core import QgsProject
    planet = ds_project.planet()
    target = QgsProject.instance().mapLayer(target_layer_id)
    if target is None:
        raise RuntimeError("the target road layer is gone")
    road_type = str(target.customProperty("road_type", "") or "road")
    grade = gp.max_grade_of(road_type, max_slope_deg)
    if grade is None:   # a path / trail: no grade rule in the game, the slope is a wish
        grade = math.tan(math.radians(max_slope_deg))
    dem, cracks = _terrain_layers()
    if not dem:
        raise RuntimeError("no zone terrain: DyingStar ▸ Routes ▸ Terrain de la zone first, over "
                           "the whole route")
    dem_path = dem[0].source()
    crack_path = cracks[0].source() if cracks else None
    pts = [(float(x), float(y)) for x, y in points]
    print("=" * 64)
    print(f"  Route search — {len(pts)} point(s), {target.name()} ({road_type}), "
          f"max grade {100.0 * grade:.1f} %, structure weight {structure_weight:g}")

    def work():
        import road_profile
        z, grid = road_profile._read_dem(dem_path)
        cr = None
        if crack_path:
            cz, cgrid = road_profile._read_dem(crack_path)
            if cgrid == grid:
                cr = cz
        route = rs.plan_with_limits(
            z, grid, planet.radius_m, pts, grade, max_bridge_m=max_bridge_m,
            max_tunnel_m=max_tunnel_m, climb=gp.climbs_at_max_grade_of(road_type),
            structure_weight=structure_weight, cracks=cr, crack_weight=crack_weight,
            max_nodes=max_nodes)
        print(f"  {route['length_m'] / 1000.0:.2f} km, {len(route['line'])} vertices, cell "
              f"{route['cell_m']:.0f} m ({route['nodes']} nodes), "
              f"{100.0 * route['steep_share']:.0f} % of its steps past the grade, "
              f"{route['tries']} search(es)")
        for seg in route["overlong"]:
            kind = "viaduct" if seg["kind"] == gp.BRIDGE else "tunnel"
            limit = max_bridge_m if seg["kind"] == gp.BRIDGE else max_tunnel_m
            print(f"  ! still a {kind} of {seg['hi'] - seg['lo']:.0f} m (max {limit:.0f} m) at "
                  f"{seg['lo'] / 1000.0:.2f} km: no way round found in the zone terrain")
        if route["cell_m"] > 60.0:
            print("  ! coarse search cell: zoom the zone terrain on the route for finer bends")
        return lambda: _show(route, target, road_type, max_slope_deg)
    return work


def _show(route, target, road_type, max_slope_deg):
    """Main thread: the proposal in the scratch layer, selected; Add / Drop in the message bar."""
    from qgis.core import QgsFeature, QgsGeometry, QgsPointXY, QgsProject, QgsVectorLayer
    project = QgsProject.instance()
    for lyr in list(project.mapLayers().values()):
        if lyr.customProperty(TAG, ""):
            project.removeMapLayer(lyr.id())
    preview = QgsVectorLayer("LineString?crs=EPSG:4326&field=name:string"
                             "&field=max_slope_degrees:double", PREVIEW_NAME, "memory")
    preview.setCustomProperty(TAG, "preview")
    preview.setCustomProperty("road_type", road_type)
    f = QgsFeature(preview.fields())
    f.setGeometry(QgsGeometry.fromPolylineXY([QgsPointXY(x, y) for x, y in route["line"]]))
    f["name"] = "tracé proposé"
    f["max_slope_degrees"] = float(max_slope_deg)
    preview.dataProvider().addFeatures([f])
    project.addMapLayer(preview)
    preview.selectAll()
    print(f"  ✓ proposal in « {PREVIEW_NAME} » — see the profile panel; add it or drop it from "
          f"the message bar")
    _offer(preview, target, max_slope_deg)


#: The pending offer's callables and message: kept here, alive while the message is up (a slot
#: only referenced by the widget it is connected to dies with it).
_OFFER = {}


def _offer(preview, target, max_slope_deg):
    try:
        from qgis.utils import iface
        from qgis.PyQt.QtCore import QTimer
        from qgis.PyQt.QtWidgets import QPushButton
        from qgis.core import Qgis
    except Exception:  # noqa: BLE001 — no GUI
        return
    if iface is None:
        return
    _close_offer()
    bar = iface.messageBar()
    item = bar.createMessage("DyingStar", f"Tracé proposé pour « {target.name()} »")
    add = QPushButton(f"Ajouter à « {target.name()} »")
    drop = QPushButton("Abandonner")
    preview_id, target_id = preview.id(), target.id()

    # The buttons only SCHEDULE the action: it removes the message, i.e. deletes the very button
    # whose clicked() is being emitted — done inside the slot, that took QGIS down (SIGABRT in the
    # Python slot, 2026-11-25).
    def do_add():
        _close_offer()
        from qgis.core import QgsProject
        project = QgsProject.instance()
        prev, tgt = project.mapLayer(preview_id), project.mapLayer(target_id)
        if prev is None or tgt is None:
            iface.messageBar().pushWarning("DyingStar", "Le tracé proposé ou la couche de "
                                           "destination n'est plus dans le projet.")
            return
        add_to_layer(prev, tgt, max_slope_deg)

    def do_drop():
        _close_offer()
        from qgis.core import QgsProject
        if QgsProject.instance().mapLayer(preview_id) is not None:
            QgsProject.instance().removeMapLayer(preview_id)

    def on_add():
        QTimer.singleShot(0, do_add)

    def on_drop():
        QTimer.singleShot(0, do_drop)
    add.clicked.connect(on_add)
    drop.clicked.connect(on_drop)
    item.layout().addWidget(add)
    item.layout().addWidget(drop)
    _OFFER.update(bar=bar, item=item, slots=(on_add, on_drop, do_add, do_drop))
    bar.pushWidget(item, Qgis.MessageLevel.Info, 0)


def _close_offer():
    """Take the pending offer's message off the bar (outside any of its buttons' signals)."""
    bar, item = _OFFER.get("bar"), _OFFER.get("item")
    if bar is not None and item is not None:
        try:
            bar.popWidget(item)
        except RuntimeError:   # already gone (the user closed it)
            pass
    _OFFER.clear()


def add_to_layer(preview, target, max_slope_deg):
    """Copy the proposal into [target] (edit mode, with its default values); drop the preview."""
    from qgis.core import QgsProject, QgsVectorLayerUtils
    feat = next(preview.getFeatures(), None)
    if feat is None:
        return None
    if not target.isEditable():
        target.startEditing()
    attrs = {}
    idx = target.fields().indexOf("max_slope_degrees")
    if idx >= 0:
        attrs[idx] = int(round(max_slope_deg))
    new = QgsVectorLayerUtils.createFeature(target, feat.geometry(), attrs, target.createExpressionContext())
    target.addFeature(new)
    target.triggerRepaint()
    QgsProject.instance().removeMapLayer(preview.id())
    try:
        from qgis.utils import iface
        iface.setActiveLayer(target)
        iface.messageBar().pushInfo("DyingStar", f"Route ajoutée à « {target.name()} » "
                                    f"(en édition) : enregistre la couche pour l'écrire en base.")
    except Exception:  # noqa: BLE001
        pass
    return new
