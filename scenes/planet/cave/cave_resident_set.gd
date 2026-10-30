class_name CaveResidentSet
extends RefCounted
## A subscriber to PlanetTerrain's native desired/pinned chunk set. No distance polling.
## Definitions/cuts stay immutable; meshes and collision nodes live only while referenced.

var _owner: CavePlanetRegistry
var _terrain: PlanetTerrain
var _index: Dictionary = {}
var _sites: Dictionary = {}
var _wanted: Dictionary = {}
var _active: Dictionary = {}
var _tasks: Dictionary = {}
var _errors: Dictionary = {}
var _assembled_frame: int = -1
var _pumped_frame: int = -1
var _ready: bool = false
var _index_nside: int


func initialize(owner: CavePlanetRegistry, terrain: PlanetTerrain) -> void:
    _owner = owner
    _terrain = terrain
    _index_nside = terrain.planet_data.collision_detail_nside()
    for site in owner._catalog_cuts:
        if site != null:
            _index_site(site)
    terrain.residency_changed.connect(_changed)
    _changed(PackedStringArray(), PackedStringArray())


## Add or replace one site at run time (a networked cave): its built network, if any, is dropped and rebuilt
## from the new definition once its sectors are resident.
func add_site(site: CavePlacement) -> void:
    _forget(site.placement_id)
    _index_site(site)
    _changed(PackedStringArray(), PackedStringArray())


## Drop one site at run time: its network, its colliders and its plan go with it.
func remove_site(id: String) -> void:
    if _forget(id):
        _changed(PackedStringArray(), PackedStringArray())


func _index_site(site: CavePlacement) -> void:
    _sites[site.placement_id] = site
    for tile: int in CavePlanetRegistry.site_tiles(_terrain.planet_data, site, _index_nside):
        if not _index.has(tile): _index[tile] = []
        _index[tile].append(site.placement_id)


func _forget(id: String) -> bool:
    if not _sites.has(id):
        return false
    _sites.erase(id)
    _errors.erase(id)
    for tile: int in _index.keys():
        var ids: Array = _index[tile]
        ids.erase(id)
        if ids.is_empty():
            _index.erase(tile)
    if _active.has(id):
        (_active[id] as Node).queue_free()
        _active.erase(id)
    return true


func _changed(_added: PackedStringArray, _removed: PackedStringArray) -> void:
    _wanted = desired_sites(_terrain.residency_keys(), _index_nside, _index)
    _pumped_frame = -1  # A new sector set must invalidate even within the same frame.
    _ready = _wanted.is_empty()
    _owner.prepared = _wanted.is_empty()
    for id: String in _active.keys():
        if not _wanted.has(id):
            (_active[id] as Node).queue_free()
            _active.erase(id)
    _publish()


static func desired_sites(keys: Dictionary, export_nside: int, index: Dictionary) -> Dictionary:
    var wanted: Dictionary = {}
    for key: String in keys:
        var nside := PlanetTerrain._parse_nside_from_key(key)
        var tile := PlanetTerrain._parse_ipix_from_key(key)
        # Coarse orbital leaves do not request every cave visible on a hemisphere.
        if nside < export_nside or tile < 0:
            continue
        while nside > export_nside:
            nside >>= 1
            tile >>= 2
        for id: String in index.get(tile, []):
            wanted[id] = int(wanted.get(id, 0)) + 1
    return wanted


func pump() -> bool:
    var frame := Engine.get_process_frames()
    if _pumped_frame == frame:
        return _ready
    _pumped_frame = frame
    for id: String in _tasks.keys():
        if _assembled_frame == Engine.get_process_frames():
            break
        var task: Dictionary = _tasks[id]
        if not WorkerThreadPool.is_task_completed(task.id):
            continue
        WorkerThreadPool.wait_for_task_completion(task.id)
        _tasks.erase(id)
        if not _wanted.has(id) or task.site != _sites.get(id):
            continue  # unwanted now, or built from a definition replaced since
        var plan: Dictionary = task.result[0]
        if not str(plan.error).is_empty():
            _errors[id] = plan.error
            _owner.site_failed(id, str(plan.error))
            continue
        var node := _owner.assemble_plan(plan)
        node.set_meta("plan", plan)
        _active[id] = node
        _assembled_frame = Engine.get_process_frames()
        _publish()
        break  # bound main-thread mesh/collision assembly to one cave per frame
    for id: String in _wanted:
        if _tasks.size() >= 2:
            break
        if _active.has(id) or _tasks.has(id) or _errors.has(id):
            continue
        var site: CavePlacement = _sites[id]
        if not CavePlanetRegistry.tiles_ready(_terrain.planet_data, site):
            continue
        var data := _terrain.planet_data
        var result: Array = [{}]
        var dressing := CavePreviewBuilder.decoration_request(site.profile.asset_library)
        var task_id := WorkerThreadPool.add_task(func(): result[0] = CavePlanetRegistry.build_plan(data, site, dressing))
        _tasks[id] = {"id": task_id, "result": result, "site": site}
    _owner.error_message = "" if _errors.is_empty() else str(_errors.values()[0])
    _ready = true
    for id: String in _wanted:
        if not _active.has(id):
            _ready = false  # an invalid/missing cave never allows a chunk with an unsupported opening
            break
    return _ready


func _publish() -> void:
    var plans: Array[Dictionary] = []
    for node: Node in _active.values():
        plans.append(node.get_meta("plan"))
    _terrain.planet_data.stargrot_plans = plans


func shutdown() -> void:
    if is_instance_valid(_terrain) and _terrain.residency_changed.is_connected(_changed):
        _terrain.residency_changed.disconnect(_changed)
    for task: Dictionary in _tasks.values():
        WorkerThreadPool.wait_for_task_completion(task.id)
    _tasks.clear()


func ready_for_chunk(key: String) -> bool:
    for id: String in desired_sites({key: true}, _index_nside, _index):
        if not _active.has(id):
            return false
    return true


func stats() -> Dictionary:
    return {"definitions": _sites.size(), "requested": _wanted.size(), "resident": _active.size(),
        "workers": _tasks.size(), "errors": _errors.size()}
