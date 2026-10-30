class_name CaveSite
extends Node3D
## A StarGrotte cave as a networked prop (Horizon type "cave"), stored in the persistence and spawned like any
## other item. It carries its CavePlacement flat in its object_data (CavePlacement.to_prop_data) and hands it to
## the terrain of the planet it stands on (PlanetTerrain.register_cave_site): the terrain cuts the openings and
## meshes the network while the chunks around it are resident — collision on the server, visuals on the client.
##
## This node holds no geometry. Its own transform only serves the streaming (it sits on the cave's entrance
## point); the cave is placed from the longitude, latitude and heading in its data, in the terrain's frame.
##
## The server also registers the cave from its stored data before this node exists (server.gd), so the
## collision chunks are cut from the start; registering the same definition again changes nothing.
##
## A cave not fitted to the current relief (imported from QGIS, or fitted before a terrain re-export) is cut
## nowhere: the server node fits it (CaveFitQueue) when a player comes within its zone-6 radius, then persists
## the fitted fields, its true position on the ground included, or the refusal in fit_error. Clients wait for
## those fields.

## The prop field holding why the server refused to fit this cave: {relief, terrain_version, key, error}.
const FIT_ERROR := "fit_error"

## Set by the server (sleep, zone hand-over) or the client (out of range) before freeing this node while the
## cave stays in the world: its terrain cut stays registered, as TerrainPad.keep_on_exit.
var keep_on_exit := false

## Every field received so far: updates only carry what changed.
var _data: Dictionary = {}
## The terrain the cave is registered with, under which placement id and definition signature.
var _terrain: PlanetTerrain = null
var _placement_id := ""
var _signature := ""


func apply_prop_data(data: Dictionary) -> void:
    _data.merge(data, true)
    # The first call runs before add_child: _enter_tree registers then.
    if is_inside_tree():
        _register()


## Not _ready: a networked prop may be reparented (_exit_tree then _enter_tree, _ready only once).
func _enter_tree() -> void:
    if not _data.is_empty():
        _register()


func _notification(what: int) -> void:
    if what == NOTIFICATION_PREDELETE and not keep_on_exit:
        _unregister()


## The definition carried by the data received so far, or null while it is incomplete.
func placement() -> CavePlacement:
    return CavePlacement.from_prop_data(_data)


func _register() -> void:
    if Engine.is_editor_hint():
        return
    var site := placement()
    var terrain := _planet_terrain()
    if site == null or terrain == null:
        return
    if site.needs_fit(terrain.planet_data):
        if _terrain != null:
            _unregister()  # a re-import replaced a fitted definition: the old cut goes until the fit
        if terrain.is_server and not _refused(site, terrain.planet_data):
            terrain.request_cave_fit(self)
        return
    var signature := site.signature()
    if terrain == _terrain and site.placement_id == _placement_id and signature == _signature:
        return
    if _terrain != null and (terrain != _terrain or site.placement_id != _placement_id):
        _unregister()
    _terrain = terrain
    _placement_id = site.placement_id
    _signature = signature
    terrain.register_cave_site(site)


## SERVER (CaveFitQueue): [param site] is this cave fitted to the current relief. Persist it, standing on its
## entrance point, and cut it.
func fitted(site: CavePlacement) -> void:
    var frame := site.surface_transform()  # the planet's frame: PlanetTerrain sits at the planet's origin
    var update := site.to_prop_data()
    update[FIT_ERROR] = {}
    _data.merge(update, true)
    position = frame.origin
    rotation = frame.basis.get_euler()
    var sync := get_node_or_null("PropSync") as PropSync
    if sync != null:
        sync.server_prop_update(update.merged({"position": position, "rotation": rotation}))
    _register()


## SERVER (CaveFitQueue): the fit refused this cave. Persisted, so no server tries again until the cave or the
## relief changes; the admin panel shows why.
func fit_refused(data: PlanetData, key: String, error: String) -> void:
    var refusal := {"relief": data.relief_signature, "terrain_version": data.chunk_data_version, "key": key, "error": error}
    _data[FIT_ERROR] = refusal
    var sync := get_node_or_null("PropSync") as PropSync
    if sync != null:
        sync.server_prop_update({FIT_ERROR: refusal})
    push_warning("[CaveSite] grotte '%s' refusée par le recalage : %s" % [str(_data.get("placement_id", "?")), error])


## Was this very definition already refused on [param data]'s relief?
func _refused(site: CavePlacement, data: PlanetData) -> bool:
    var refusal: Variant = _data.get(FIT_ERROR)
    return refusal is Dictionary and str(refusal.get("relief", "")) == data.relief_signature \
        and str(refusal.get("terrain_version", "")) == data.chunk_data_version \
        and str(refusal.get("key", "")) == site.authored_key()


func _unregister() -> void:
    if is_instance_valid(_terrain) and not _placement_id.is_empty():
        _terrain.unregister_cave_site(_placement_id)
    _terrain = null
    _placement_id = ""
    _signature = ""


## The terrain of the body this cave belongs to: its nearest Planet ancestor's.
func _planet_terrain() -> PlanetTerrain:
    var n: Node = get_parent()
    while n != null:
        if n is Planet:
            return (n as Planet).planet_terrain
        n = n.get_parent()
    return null
