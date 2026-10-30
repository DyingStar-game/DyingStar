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
    var signature := site.signature()
    if terrain == _terrain and site.placement_id == _placement_id and signature == _signature:
        return
    if _terrain != null and (terrain != _terrain or site.placement_id != _placement_id):
        _unregister()
    _terrain = terrain
    _placement_id = site.placement_id
    _signature = signature
    terrain.register_cave_site(site)


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
