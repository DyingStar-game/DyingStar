class_name MineSite
extends Node3D
## A village mine as a networked prop (Horizon type "mine"): a shaft of 250 m to 1 km opened in the ground, levels
## along it and galleries leaving each level, straight or chaotic (MineLayout, from the seed). Its node holds the
## surface works (collar, pad); the rock is meshed around the people near it (MineCells): visuals on the client,
## collision on the server.
##
## Network fields: seed and style (the plan), faces (how far players dug each gallery, by id), face_step (how many
## layers fell at each face) and gallery_max_m (how far each gallery may ever go, measured once by the server and
## persisted, MineLayout.limits). A field this node does not know yet is waited for, never guessed.
##
## The ground opens under the shaft through PlanetTerrain.register_mine_hole; the server also opens it from the
## stored data before this node exists (server.gd), under the same id, so nothing is rebuilt when it comes.

## Every live mine, for MineSite.contains_point (the below-surface rescue must not pull anyone out of one).
static var _live: Array[MineSite] = []

@export_group("Shaft")
## Shallowest shaft (m) a seed may draw. The depth of each mine is drawn between this and depth_max_m.
@export_range(50.0, 1000.0, 1.0, "suffix:m") var depth_min_m: float = 250.0
## Deepest shaft (m) a seed may draw. Deeper mines get more levels (one every level_spacing m).
@export_range(50.0, 1000.0, 1.0, "suffix:m") var depth_max_m: float = 1000.0
## Radius (m) of the shaft and of the hole in the ground. Raising it widens the shaft and its collar.
@export_range(5.0, 40.0, 0.5, "suffix:m") var shaft_radius_m: float = 20.0
## Relief (m) of the shaft wall: higher = rougher rock, 0 = a smooth cylinder.
@export_range(0.0, 2.0, 0.05, "suffix:m") var shaft_roughness_m: float = 0.5
## Depth (m) of the first level under the ground.
@export_range(10.0, 200.0, 1.0, "suffix:m") var first_level_m: float = 40.0
## Smallest gap (m) between two levels: lower = more levels in the same depth.
@export_range(20.0, 300.0, 1.0, "suffix:m") var level_spacing_min_m: float = 60.0
## Largest gap (m) between two levels.
@export_range(20.0, 300.0, 1.0, "suffix:m") var level_spacing_max_m: float = 90.0

@export_group("Galleries")
## Style of the galleries: "seeded" = drawn from each mine's seed (half straight, half chaotic), "straight" = every
## mine's galleries run straight, "chaotic" = they wander and branch.
@export_enum("seeded", "straight", "chaotic") var force_style: String = "seeded"
## Fewest galleries a level gets.
@export_range(1, 12) var galleries_min: int = 2
## Most galleries a level gets.
@export_range(1, 12) var galleries_max: int = 6
## Width (m) of a gallery at its floor: 6 m lets a truck in, lower = tighter galleries.
@export_range(2.0, 12.0, 0.1, "suffix:m") var gallery_width_m: float = 6.0
## Height (m) of a gallery at its centre.
@export_range(2.0, 10.0, 0.1, "suffix:m") var gallery_height_m: float = 4.5
## Shortest length (m) a gallery is dug to before anyone mines it.
@export_range(5.0, 200.0, 1.0, "suffix:m") var initial_min_m: float = 20.0
## Longest length (m) a gallery is dug to before anyone mines it.
@export_range(5.0, 200.0, 1.0, "suffix:m") var initial_max_m: float = 60.0
## Longest a gallery may ever get (m), mined faces included. It stops sooner near another gallery or the surface.
@export_range(20.0, 2000.0, 1.0, "suffix:m") var gallery_cap_m: float = 500.0
## Relief (m) of the gallery walls: higher = rougher, more broken rock.
@export_range(0.0, 2.0, 0.05, "suffix:m") var wall_roughness_m: float = 0.6
## Size of that relief (1/m): higher = smaller bumps, lower = broad bulges.
@export_range(0.05, 1.0, 0.01) var wall_frequency: float = 0.35
## Rock (m) kept over a gallery: it stops before the ground above gets thinner than this.
@export_range(5.0, 200.0, 1.0, "suffix:m") var min_cover_m: float = 30.0

@export_group("Rendering")
## Material of the rock walls (triplanar in the mine's frame).
@export var wall_material: Material = preload("res://scenes/planet/cave/libraries/gabarits/rock_wall.tres")
## Material of the floors.
@export var floor_material: Material = preload("res://scenes/planet/cave/libraries/gabarits/rock_floor.tres")
## Distance (m) around the player within which the rock is built. Higher = seen further down the galleries, more
## cells in memory and more building.
@export_range(40.0, 600.0, 1.0, "suffix:m") var view_radius_m: float = 160.0
## Spacing (m) of the lamps along the galleries; 0 = only the stations are lit.
@export_range(0.0, 200.0, 1.0, "suffix:m") var lamp_spacing_m: float = 30.0
## Brightness of a lamp.
@export_range(0.0, 16.0, 0.1) var lamp_energy: float = 2.5
## Reach (m) of a lamp.
@export_range(2.0, 60.0, 0.5, "suffix:m") var lamp_range_m: float = 18.0

# Network fields (mine_def.json).
var seed: int = 0
var style: String = ""
var faces: Dictionary = {}
var face_step: Dictionary = {}
var gallery_max_m: Dictionary = {}

## Set by the server (sleep, zone hand-over) or the client (out of range) before freeing this node while the mine
## stays in the world: its hole stays open, as TerrainPad.keep_on_exit.
var keep_on_exit := false

var _layout: Dictionary = {}
var _layout_key := ""
var _dug: Dictionary = {}
var _cells: MineCells = null
var _lights: Node3D = null
var _terrain: PlanetTerrain = null
var _hole_signature := ""
var _measuring := -1
var _measure_result: Array = []

## The PropSync child's uuid on the node itself: what makes the mine a networked parent (PropSpawn.find_net_parent).
var uuid: String:
    get:
        var sync := PropSync.of(self)
        return sync.uuid if sync != null else ""
    set(value):
        var sync := PropSync.of(self)
        if sync != null:
            sync.uuid = value


func apply_prop_data(data: Dictionary) -> void:
    for field: String in ["faces", "face_step", "gallery_max_m"]:
        if data.get(field) is Dictionary:
            set(field, (data[field] as Dictionary).duplicate())
    if data.has("seed") and data.seed != null:
        seed = int(data.seed)
    if data.has("style") and data.style != null:
        style = str(data.style)
    if is_inside_tree():
        _refresh.call_deferred()


func _enter_tree() -> void:
    if not _live.has(self):
        _live.append(self)
    set_notify_transform(true)
    _refresh.call_deferred()


func _exit_tree() -> void:
    _live.erase(self)
    if _measuring >= 0:
        WorkerThreadPool.wait_for_task_completion(_measuring)
        _measuring = -1


func _notification(what: int) -> void:
    if what == NOTIFICATION_TRANSFORM_CHANGED:
        _register_hole.call_deferred()  # the server seats the mine on its pad: the hole follows
    elif what == NOTIFICATION_PREDELETE and not keep_on_exit and is_instance_valid(_terrain) and not uuid.is_empty():
        _terrain.unregister_mine_hole(uuid)


## The tunables of MineLayout, from the exports.
func layout_settings() -> Dictionary:
    var out := {}
    for key: String in MineLayout.DEFAULTS:
        if key in self:
            out[key] = get(key)
    return out


## The plan of this mine, {} while its seed is unknown.
func layout() -> Dictionary:
    return _layout


## How far each gallery is dug (MineLayout.dug), by gallery id.
func dug() -> Dictionary:
    return _dug


## Is [param global_point] in the air of a live mine (shaft, station or dug gallery)?
static func contains_point(global_point: Vector3) -> bool:
    for mine in _live:
        if is_instance_valid(mine) and mine.contains_global(global_point):
            return true
    return false


## The live mine whose air holds [param global_point], or null.
static func mine_at(global_point: Vector3) -> MineSite:
    for mine in _live:
        if is_instance_valid(mine) and mine.contains_global(global_point):
            return mine
    return null


## Is the rock round [param global_point] (and a couple of metres under it) built with the latest geometry? What
## a body or a player waits for before falling there (server).
func rock_ready_at(global_point: Vector3) -> bool:
    if _cells == null:
        return false
    var local := global_transform.affine_inverse() * global_point
    return _cells.ready_at(local) and _cells.ready_at(local + Vector3.DOWN * 2.0)


func contains_global(global_point: Vector3) -> bool:
    if _layout.is_empty():
        return false
    var local := global_transform.affine_inverse() * global_point
    if local.y > 10.0 or local.y < -float(_layout.depth) - 10.0:
        return false
    return MineLayout.contains(_layout, _dug, local)


func _refresh() -> void:
    if not is_inside_tree() or Engine.is_editor_hint():
        return
    var server: bool = GameOrchestrator.is_server()
    if seed == 0:
        if not server or uuid.is_empty():
            return  # the server draws it from the uuid and persists it
        seed = _seed_from(uuid)
        _persist({"seed": seed})
    var wanted := style
    if force_style == MineLayout.STYLE_STRAIGHT or force_style == MineLayout.STYLE_CHAOTIC:
        wanted = force_style
    var key := "%d|%s|%s" % [seed, wanted, layout_settings()]
    var fresh := key != _layout_key
    if fresh:
        _layout_key = key
        _layout = MineLayout.generate(seed, layout_settings(), wanted)
        if server and style != str(_layout.style):
            style = str(_layout.style)
            _persist({"style": style})
    var previous := _dug
    _dug = MineLayout.dug(_layout, faces, gallery_max_m)
    _ensure_cells()
    if _cells != null:
        var graph := MineLayout.graph(_layout, _dug)
        if fresh:
            _cells.set_graph(graph)
        elif previous != _dug:
            _cells.set_graph(graph, _changed_cells(previous, _dug))
    if not server and (fresh or previous != _dug):
        _rebuild_lights()
    _register_hole()
    if server and gallery_max_m.is_empty():
        _measure_limits()


## A stable seed from the mine's uuid (never 0).
static func _seed_from(id: String) -> int:
    var digest := id.sha256_buffer()
    var value := 0
    for index in 6:
        value = (value << 8) | digest[index]
    return maxi(1, value)


func _persist(update: Dictionary) -> void:
    var sync := PropSync.of(self)
    if sync != null and GameOrchestrator.is_server():
        sync.server_prop_update(update)


## The cells a change of dug lengths from [param before] to [param after] reshapes.
func _changed_cells(before: Dictionary, after: Dictionary) -> Dictionary:
    var out := {}
    for id: int in before.keys() + after.keys():
        var from := float(before.get(id, 0.0))
        var to := float(after.get(id, 0.0))
        if is_equal_approx(from, to):
            continue
        out.merge(MineLayout.face_cells(_layout, _layout.galleries[id], from, to, MineCells.CELL_M))
    return out


func _ensure_cells() -> void:
    if _cells != null:
        return
    if not MineMesher.warm():
        push_warning("[MineSite] %s : module natif absent, la roche de la mine n'est pas construite" % name)
        return
    _cells = MineCells.new()
    _cells.name = "Rock"
    _cells.physics = GameOrchestrator.is_server()
    _cells.wall_material = wall_material
    _cells.floor_material = floor_material
    _cells.view_radius_m = view_radius_m
    _cells.step_m = float(MineLayout.DEFAULTS.cell_m)
    _cells.viewers = _viewers
    add_child(_cells)


## Where the people who need the rock are, in the mine frame: every player on the server, the camera on a client.
func _viewers() -> Array:
    var out: Array = []
    var inverse := global_transform.affine_inverse()
    if GameOrchestrator.is_server():
        for player in get_tree().get_nodes_in_group("player"):
            if player is Node3D:
                out.append(inverse * (player as Node3D).global_position)
    else:
        var camera := get_viewport().get_camera_3d()
        if camera != null:
            out.append(inverse * camera.global_position)
    return out


func _register_hole() -> void:
    if _layout.is_empty() or uuid.is_empty():
        return
    var terrain := _planet_terrain()
    if terrain == null:
        return
    if _terrain != null and _terrain != terrain and is_instance_valid(_terrain):
        _terrain.unregister_mine_hole(uuid)
    _terrain = terrain
    var frame := terrain.global_transform.affine_inverse() * global_transform
    var hole := MinePlacement.make(uuid, frame, shaft_radius_m, float(_layout.depth))
    if hole.signature() == _hole_signature:
        return
    _hole_signature = hole.signature()
    terrain.register_mine_hole(hole)


## The hole of the mine [param uuid] from its stored data (server.gd, before its node exists): same id and same
## frame as the node registers later, so nothing is rebuilt then. The depth does not change the cut.
static func hole_from_data(id: String, frame: Transform3D) -> MinePlacement:
    return MinePlacement.make(id, frame, float(MineLayout.DEFAULTS.shaft_radius_m), float(MineLayout.DEFAULTS.depth_min_m))


## SERVER: measure how far each gallery may go (MineLayout.limits) on a worker, once the relief over the mine can be
## read; then persist it. A mine already measured is never measured again.
func _measure_limits() -> void:
    if _measuring >= 0 or _layout.is_empty():
        return
    var terrain := _planet_terrain()
    if terrain == null or terrain.planet_data == null:
        return
    var data := terrain.planet_data
    var frame := terrain.global_transform.affine_inverse() * global_transform
    var tiles := {}
    for gallery: Dictionary in _layout.galleries:
        for point: Vector3 in gallery.points:
            tiles[HEALPix.vec2pix_nest(data.export_nside, (frame * point).normalized())] = true
    if not CavePlanetRegistry.request_tiles(data, tiles):
        get_tree().create_timer(2.0).timeout.connect(_measure_limits)
        return
    var plan := _layout
    _measure_result = [null]
    var result := _measure_result
    var cover := func(point: Vector3) -> float:
        var at := frame * point
        return CaveGround.surface_dist(data, at.normalized()) - at.length()
    _measuring = WorkerThreadPool.add_task(func(): result[0] = CaveGround.run(data, func(): return MineLayout.limits(plan, cover)))
    _await_limits.call_deferred()


func _await_limits() -> void:
    while _measuring >= 0 and not WorkerThreadPool.is_task_completed(_measuring):
        await get_tree().process_frame
        if not is_inside_tree():
            return
    if _measuring < 0:
        return
    WorkerThreadPool.wait_for_task_completion(_measuring)
    _measuring = -1
    var limits: Variant = _measure_result[0]
    if not (limits is Dictionary) or (limits as Dictionary).is_empty():
        get_tree().create_timer(5.0).timeout.connect(_measure_limits)
        return
    gallery_max_m = limits
    _persist({"gallery_max_m": gallery_max_m})
    print("[MineSite] %s : %d galeries mesurées, profondeur %d m, style %s" % [name, gallery_max_m.size(),
        int(_layout.depth), _layout.style])
    _refresh()


## Lamps at the stations and along the dug galleries (client).
func _rebuild_lights() -> void:
    if _lights != null:
        _lights.queue_free()
    _lights = Node3D.new()
    _lights.name = "Lamps"
    add_child(_lights)
    for level: Dictionary in _layout.levels:
        _add_lamp((level.station as Vector3) + Vector3.UP * (float(_layout.settings.station_height_m) - 1.5))
    if lamp_spacing_m <= 0.0:
        return
    var height := float(_layout.settings.gallery_height_m) - 0.8
    for gallery: Dictionary in _layout.galleries:
        var id := int(gallery.id)
        if not _dug.has(id):
            continue
        var distance := lamp_spacing_m
        while distance < float(_dug[id]):
            _add_lamp(MineLayout.point_at(gallery, distance) + Vector3.UP * height)
            distance += lamp_spacing_m


func _add_lamp(at: Vector3) -> void:
    var lamp := OmniLight3D.new()
    lamp.position = at
    lamp.light_color = Color(1.0, 0.86, 0.62)
    lamp.light_energy = lamp_energy
    lamp.omni_range = lamp_range_m
    lamp.distance_fade_enabled = true
    lamp.distance_fade_begin = view_radius_m * 0.5
    lamp.distance_fade_length = 20.0
    _lights.add_child(lamp)


## The terrain of the body this mine belongs to: its nearest Planet ancestor's.
func _planet_terrain() -> PlanetTerrain:
    var n: Node = get_parent()
    while n != null:
        if n is Planet:
            return (n as Planet).planet_terrain
        n = n.get_parent()
    return null
