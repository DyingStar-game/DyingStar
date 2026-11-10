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

## Horizon type of a mine.
const TYPE := "mine"
const LIFT_SCENE := "scenes/_universe/structures/industrial/vehicle_lift/vehicle_lift.tscn"
const DEBRIS_DIR := "scenes/_universe/environment/terrain/rocks/"
## The rocks a fallen layer drops: scene, size (m) across, how often (weight).
const DEBRIS := [
    ["rock_mining_debris_040.tscn", 0.4, 0.3],
    ["rock_mining_debris_070.tscn", 0.7, 0.3],
    ["rock_mining_debris_100.tscn", 1.0, 0.2],
    ["rock_mining_debris_140.tscn", 1.4, 0.12],
    ["rock_mining_debris_200.tscn", 2.0, 0.08],
]

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

@export_group("Face")
## Time (s) a player holds the mining tool on a face's fault before a layer of rock falls.
@export_range(1.0, 120.0, 0.5, "suffix:s") var face_seconds: float = 20.0
## Thickness (m) of a fallen layer: how far the gallery moves on each time. Lower = more layers to mine.
@export_range(0.5, 5.0, 0.1, "suffix:m") var layer_m: float = 1.5
## How close (m) to the fault the tool must hit; higher = easier to aim.
@export_range(0.02, 1.0, 0.01, "suffix:m") var fault_tolerance_m: float = 0.15
## Fewest rocks a fallen layer drops.
@export_range(1, 20) var debris_min: int = 4
## Most rocks a fallen layer drops.
@export_range(1, 20) var debris_max: int = 10
## Lowest gold purity (0..1) a fallen layer may get; drawn once per layer, all its rocks carry it.
@export_range(0.0, 1.0, 0.01) var gold_min: float = 0.02
## Highest gold purity (0..1) a fallen layer may get.
@export_range(0.0, 1.0, 0.01) var gold_max: float = 0.30
## Sound of a layer falling, heard round the face (empty = silent).
@export var sfx_layer_fall: AudioStream
## Loudness of that sound in decibels (0 = the sample's own level).
@export_range(-40.0, 12.0, 0.5) var sfx_layer_fall_db: float = 0.0

@export_group("Lift")
## Speed (m/s) of the shaft's vehicle lift: 10 m/s takes a kilometre in under two minutes.
@export_range(0.5, 10.0, 0.1, "suffix:m/s") var lift_speed_m_s: float = 10.0
## How far (m) the lift's origin stands back from the shaft's rim, in the rock: its rails run in the wall.
@export_range(0.0, 10.0, 0.1, "suffix:m") var lift_setback_m: float = 1.0
## Distance (m) from the lift's origin out to its guide (VehicleLift.guide_z_offset): the bridges' length.
@export_range(0.0, 10.0, 0.1, "suffix:m") var lift_guide_m: float = 2.0

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
var lift_spawned: bool = false

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
## The open faces, by gallery id.
var _faces: Dictionary = {}
## The box holding the mine's air as dug now (mine frame, with a margin): what contains_global looks at first.
var _bounds := AABB()

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
    var before := face_step.duplicate()
    for field: String in ["faces", "face_step", "gallery_max_m"]:
        if data.get(field) is Dictionary:
            set(field, (data[field] as Dictionary).duplicate())
    if data.has("seed") and data.seed != null:
        seed = int(data.seed)
    if data.has("style") and data.style != null:
        style = str(data.style)
    if data.has("lift_spawned") and data.lift_spawned != null:
        lift_spawned = bool(data.lift_spawned)
    if is_inside_tree() and not _layout.is_empty() and not GameOrchestrator.is_server():
        for key: String in face_step:
            if int(face_step[key]) > int(before.get(key, face_step[key])):
                _layer_fell(int(key))  # where the old face stood, before the refresh moves it
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
    if not _bounds.has_point(local):
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
    var settings := layout_settings()
    var key := "%d|%s|%s" % [seed, wanted, settings]
    var fresh := key != _layout_key
    if fresh:
        _layout_key = key
        _layout = MineLayout.generate(seed, settings, wanted)
        if server and style != str(_layout.style):
            style = str(_layout.style)
            _persist({"style": style})
            if wanted.is_empty():
                # The same plan as forcing the style drawn (the seed draws it first either way): not a new mine.
                _layout_key = "%d|%s|%s" % [seed, style, settings]
    var previous := _dug
    _dug = MineLayout.dug(_layout, faces, gallery_max_m)
    var graph := MineLayout.graph(_layout, _dug)
    _bounds = (graph.bounds as AABB).grow(5.0)
    _ensure_cells()
    if _cells != null:
        if fresh:
            _cells.set_graph(graph)
        elif previous != _dug:
            _cells.set_graph(graph, _changed_cells(previous, _dug))
    if not server and (fresh or previous != _dug):
        _rebuild_lights()
    _update_faces()
    _register_hole()
    if server and gallery_max_m.is_empty():
        _measure_limits()
    if server and not lift_spawned:
        _spawn_lift()


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


## The frame of gallery [param id]'s face [param distance] m along it: origin on the floor there, -Z along the
## gallery (level), +Y up.
func face_frame(id: int, distance: float) -> Transform3D:
    var gallery: Dictionary = _layout.galleries[id]
    var forward := MineLayout.direction_at(gallery, distance)
    forward = Vector3(forward.x, 0.0, forward.z).normalized()
    var back := -forward
    return Transform3D(Basis(Vector3.UP.cross(back), Vector3.UP, back), MineLayout.point_at(gallery, distance))


## The fault of layer [param step] of gallery [param id]'s face, seeded: [normal in the face's XY plane, offset].
## Through the gallery's axis, at any tilt, within 0.6 m of the face's middle.
func fault_of(id: int, step: int) -> Array:
    var rng := RandomNumberGenerator.new()
    rng.seed = ("%d|fault|%d|%d" % [seed, id, step]).hash()
    var angle := rng.randf_range(0.0, PI)
    var normal := Vector2(cos(angle), sin(angle))
    var center := Vector2(0.0, float(_layout.settings.gallery_height_m) * 0.45)
    return [normal, center.dot(normal) + rng.randf_range(-0.6, 0.6)]


## One MineFace per gallery whose face can still move on, kept at its dug end with the current fault.
func _update_faces() -> void:
    var open := {}
    if not _layout.is_empty() and not gallery_max_m.is_empty():
        for id: int in _dug:
            if MineLayout.face_open(_layout, id, faces, gallery_max_m):
                open[id] = true
    for id: int in _faces.keys():
        if not open.has(id):
            (_faces[id] as Node).queue_free()
            _faces.erase(id)
    var client: bool = not GameOrchestrator.is_server()
    for id: int in open:
        var step := int(face_step.get(str(id), 0))
        var frame := face_frame(id, float(_dug[id]))
        var face: MineFace = _faces.get(id)
        if face != null and face.step == step and face.transform.is_equal_approx(frame):
            continue
        if face == null:
            face = MineFace.new()
            face.name = "Face%d" % id
            add_child(face)
            _faces[id] = face
        var fault := fault_of(id, step)
        face.mine = self
        face.gallery = id
        face.step = step
        face.half_width = float(_layout.settings.gallery_width_m) * 0.5
        face.height = float(_layout.settings.gallery_height_m)
        face.fault_normal = fault[0]
        face.fault_offset = fault[1]
        face.tolerance_m = fault_tolerance_m
        face.transform = frame
        face.build(client)


## SERVER: a player held the tool [param face_seconds] on the face of gallery [param id], layer [param step], at
## [param hit] (mine frame). A layer falls if it was the current layer's fault, within reach. True when it fell.
func server_perforate_face(player: Node3D, id: int, step: int, hit: Vector3) -> bool:
    var face: MineFace = _faces.get(id)
    if face == null or step != face.step or step != int(face_step.get(str(id), 0)):
        return false  # another player's layer fell meanwhile, or no such face
    var slack := 0.1  # the client judged the hit on its own copy of the face
    var local := face.transform.affine_inverse() * hit
    if absf(Vector2(local.x, local.y).dot(face.fault_normal) - face.fault_offset) > face.tolerance_m + slack:
        return false
    if player != null and (global_transform * hit).distance_to(player.global_position) > 5.0:
        return false
    server_break_face(id)
    return true


## SERVER: layer [member face_step] of gallery [param id]'s face falls: the gallery moves on by layer_m (never past
## its limit) and the layer's rocks drop in front of the old face.
func server_break_face(id: int) -> void:
    if not MineLayout.face_open(_layout, id, faces, gallery_max_m):
        return
    var key := str(id)
    var gallery: Dictionary = _layout.galleries[id]
    var reach := minf(float(gallery_max_m[key]), float(_layout.settings.gallery_cap_m))
    var from := float(_dug.get(id, gallery.initial_m))
    var step := int(face_step.get(key, 0))
    faces[key] = minf(float(faces.get(key, 0.0)) + layer_m, reach - float(gallery.initial_m))
    face_step[key] = step + 1
    _persist({"faces": faces, "face_step": face_step})
    _spawn_debris(id, from, step)
    _refresh()


## SERVER: the rocks of layer [param step] of gallery [param id], dropped just in front of the face that stood
## [param from] m along it (open air: the new rock is still being built). Gold, at one purity for the layer.
func _spawn_debris(id: int, from: float, step: int) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = ("%d|debris|%d|%d" % [seed, id, step]).hash()
    var purity := rng.randf_range(minf(gold_min, gold_max), maxf(gold_min, gold_max))
    var count := rng.randi_range(debris_min, maxi(debris_min, debris_max))
    var frame := face_frame(id, from)
    var half := float(_layout.settings.gallery_width_m) * 0.5
    var top := minf(float(_layout.settings.gallery_height_m) - 1.0, 2.8)
    var host := _host_rock()
    var density := RockMining.INERT_DENSITY_DEFAULT
    if MineralRegistry.has_mineral(StringName(host)):
        density = MineralRegistry.get_mineral(StringName(host)).density_kg_m3
    var seed_str := "%s|layer|%d|%d" % [uuid, id, step]
    var placed: Array = []
    var rocks: Array = []
    for index in count:
        var pick := _pick_debris(rng)
        var radius := float(pick[1]) * 0.5
        var at := Vector3.ZERO
        for attempt in 10:
            at = Vector3(rng.randf_range(-half + 0.3 + radius, half - 0.3 - radius), rng.randf_range(0.3 + radius, top),
                -rng.randf_range(0.2, 1.6))
            var clear := true
            for other: Array in placed:
                if (other[0] as Vector3).distance_to(at) < (radius + float(other[1])) * 0.8:
                    clear = false
                    break
            if clear:
                break
        placed.append([at, radius])
        var position := frame * at
        var rotation := Vector3(rng.randf_range(-PI, PI), rng.randf_range(-PI, PI), rng.randf_range(-PI, PI))
        rocks.append({
            "type": "miningrock",
            "uuid": PropSpawn.stable_uuid("%s#%d" % [seed_str, index]),
            "position": {"x": position.x, "y": position.y, "z": position.z},
            "rotation": {"x": rotation.x, "y": rotation.y, "z": rotation.z},
            "scenename": DEBRIS_DIR + str(pick[0]),
            "parent_id": uuid,
            "ore_seed": gold_seed(seed_str, index, purity),
            "mineral_id": "gold",
            "host_rock_id": host,
            "inert_density": density,
            "ground_color": "",
        })
    NetworkOrchestrator.spawn_props_authoritative(rocks)


## The ore_seed of rock [param index] of a layer ([param seed_str]) whose purity (RockMining.ore_richness: the
## seed's hash, modulo 1000) is within 0.01 of [param purity]. Candidates are digests, not "…|k": Godot's string
## hash of "…|0", "…|1"… are consecutive integers, so counting k only walks a few thousandths of purity.
static func gold_seed(seed_str: String, index: int, purity: float) -> String:
    var best := ""
    var best_err := INF
    for k in 512:
        var candidate := "%s|ore%d|%s" % [seed_str, index, ("%d|%d" % [index, k]).sha256_text().substr(0, 12)]
        var err := absf(float(absi(candidate.hash()) % 1000) / 1000.0 - purity)
        if err < best_err:
            best_err = err
            best = candidate
        if err <= 0.01:
            break
    return best


static func _pick_debris(rng: RandomNumberGenerator) -> Array:
    var total := 0.0
    for entry: Array in DEBRIS:
        total += float(entry[2])
    var roll := rng.randf() * total
    for entry: Array in DEBRIS:
        roll -= float(entry[2])
        if roll <= 0.0:
            return entry
    return DEBRIS[0]


## The rock the mine is dug in: the planet's mining host rock (granite when unknown).
func _host_rock() -> String:
    var terrain := _planet_terrain()
    if terrain != null and terrain.planet_data != null and not terrain.planet_data.mining_zone_host_rock.is_empty():
        return terrain.planet_data.mining_zone_host_rock
    return "granite"


## CLIENT: a layer of gallery [param id] fell: dust where its face stood, and its sound.
func _layer_fell(id: int) -> void:
    if not _dug.has(id):
        return
    var frame := face_frame(id, float(_dug[id]))
    var dust := CPUParticles3D.new()
    dust.one_shot = true
    dust.amount = 80
    dust.lifetime = 4.0
    dust.explosiveness = 0.9
    dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
    dust.emission_box_extents = Vector3(float(_layout.settings.gallery_width_m) * 0.4, 1.5, 0.6)
    dust.direction = Vector3.BACK
    dust.spread = 60.0
    dust.initial_velocity_min = 0.5
    dust.initial_velocity_max = 2.5
    dust.gravity = Vector3(0.0, -0.4, 0.0)
    dust.damping_min = 0.6
    dust.damping_max = 1.2
    dust.scale_amount_min = 0.6
    dust.scale_amount_max = 1.6
    var quad := QuadMesh.new()
    quad.size = Vector2.ONE * 0.8
    var material := StandardMaterial3D.new()
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
    material.vertex_color_use_as_albedo = true
    quad.material = material
    dust.mesh = quad
    var fade := Gradient.new()
    fade.set_color(0, Color(0.55, 0.5, 0.44, 0.55))
    fade.set_color(1, Color(0.55, 0.5, 0.44, 0.0))
    dust.color_ramp = fade
    dust.transform = frame * Transform3D(Basis.IDENTITY, Vector3(0.0, 1.8, -1.0))
    add_child(dust)
    dust.emitting = true
    dust.finished.connect(dust.queue_free)
    if sfx_layer_fall != null and not Sfx3D.muted():
        Sfx3D.play(dust, sfx_layer_fall, sfx_layer_fall_db, 6.0, 60.0, Sfx3D.Attenuation.REALISTIC)


## Where the lift stands in the mine frame: on the rim at -Z, set back into the rock, facing the shaft.
func lift_origin() -> Vector3:
    return Vector3(0.0, 0.0, -(shaft_radius_m + lift_setback_m))


## The lift's stops: every level but the bottom one (its lower landing), as depths under the rim.
static func lift_stops(plan: Dictionary) -> PackedFloat32Array:
    var stops := PackedFloat32Array()
    for level: Dictionary in plan.levels:
        var depth := -float(level.y)
        if depth < float(plan.depth) - 1.0:
            stops.append(depth)
    return stops


## SERVER: spawn the shaft's vehicle lift under this mine, once: down to the bottom, a stop at each level.
## Its uuid is drawn from ours, so a lost lift_spawned flag upserts the same lift instead of piling copies.
func _spawn_lift() -> void:
    if lift_spawned or uuid.is_empty() or _layout.is_empty():
        return
    lift_spawned = true
    var lift_uuid := PropSpawn.stable_uuid("%s|lift" % uuid)
    NetworkOrchestrator.protected_prop_uuids[lift_uuid] = true  # world infrastructure
    var origin := lift_origin()
    NetworkOrchestrator.spawn_prop_authoritative({
        "type": "vehicle_lift",
        "uuid": lift_uuid,
        "position": {"x": origin.x, "y": origin.y, "z": origin.z},
        "rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
        "scenename": LIFT_SCENE,
        "parent_id": uuid,
        "name": "MineLift",
        "descent_depth": float(_layout.depth),
        "stop_depths": Array(lift_stops(_layout)),
        "guide_z_offset": lift_guide_m,
        "max_speed": lift_speed_m_s,
        "notch_length_m": 0.0,
    })
    _persist({"lift_spawned": true})


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
