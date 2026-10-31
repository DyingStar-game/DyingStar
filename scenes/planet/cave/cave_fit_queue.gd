class_name CaveFitQueue
extends CaveFitter
## SERVER: fits the networked caves a player comes near, one at a time (PlanetTerrain.request_cave_fit).
##
## A cave imported from QGIS, or fitted on a relief since re-exported, has nothing the game can cut yet: its
## server node (CaveSite, materialized within its zone-6 radius of a player, ~3 km) asks for a fit here. The
## fit runs on worker threads through the native sampler (CaveGround), about a second a cave; its result goes
## back to the node, which persists it in the prop (or the refusal, in fit_error) for every server and client.

var _queue: Array[CaveSite] = []
var _current: CaveSite = null


func request(site: CaveSite, data: PlanetData) -> void:
    if site == _current or _queue.has(site):
        return
    _queue.append(site)
    if _current == null:
        _drain(data)


func _drain(data: PlanetData) -> void:
    while not _queue.is_empty():
        _current = _queue.pop_front()
        if not is_instance_valid(_current) or not _current.is_inside_tree():
            continue
        var site := _current.placement()
        if site == null or not site.needs_fit(data):
            continue
        var key := site.authored_key()
        var started := Time.get_ticks_msec()
        var report: Dictionary = await refit(data, [site] as Array[CavePlacement])
        if not is_instance_valid(_current):
            continue  # put to sleep meanwhile: its next wake asks again
        if report.sites.is_empty():
            var reasons: Array = report.rejected.keys()
            var error := str(reasons[0]).trim_prefix(site.placement_id + " : ") if not reasons.is_empty() else "annulé"
            _current.fit_refused(data, key, error)
            print("[CaveFit] grotte '%s' refusée en %d ms : %s" % [site.placement_id, Time.get_ticks_msec() - started, error])
        else:
            _current.fitted(report.sites[0])
            print("[CaveFit] grotte '%s' recalée en %d ms" % [site.placement_id, Time.get_ticks_msec() - started])
    _current = null
