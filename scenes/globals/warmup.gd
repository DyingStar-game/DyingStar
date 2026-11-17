class_name Warmup
extends Node

## While the main menu shows, gets ready what the game needs the moment it is in it, so it does not hold
## the game then: the first ration out of a dispenser froze it for a long moment (its scene read from the
## disk on the main thread, then its shaders compiled at its first frame; playtest 2026-10-21), and so
## did every place and prop seen for the first time.
##
## It loads, on worker threads, the layouts of the places the world spawns (loading one loads every scene
## it is built of), the vehicles and the items of the dispensers, and keeps them for the session: the
## game's own load() then finds them in memory. Then it puts their meshes out, a few at a time, HIDDEN in a
## viewport of its own: Godot compiles a surface's pipelines on worker threads as soon as a render meets it,
## shown or not, and those are the game's too (they follow the project's settings, not the viewport's). A
## frame that DREW a surface whose pipelines are not ready would block the main thread until they are, behind
## every compilation queued before them -- 12 to 17 s on a cold cache (the first launch, an update, a new
## driver), and Windows closes a game "not responding" after 5 (exit code 0xCFFFFFFF, 2026-11-16). So nothing
## is ever drawn here but SSS_PRIMER, once its own are ready, and nothing new is put out before what was put
## out last is compiled (a marker task queued behind it has run). Only meshes and materials are read from the
## scenes (PackedScene.get_state), and what the terrain reads of a layout (LayoutData), which instances it
## out of the tree: nothing of the game runs. Read at the first village met, that froze the game ~1 s.
##
## Client only, where something is drawn; one per session (start), under the tree's root so it goes on
## once the game is entered. While the menu shows, a line in its corner says how far it is.

## The scenes wanted with everything they are built of: the places the world spawns, the vehicles.
const SCENES: Array[String] = [
	"res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn",
	"res://scenes/_universe/structures/urban/cities/ares_city_factory.tscn",
	"res://scenes/_universe/vehicles/ground/trucks/truck.tscn",
	ROCK_SCENE,
	# The mines' truck elevator: spawned over the network, its parts built at run time (VehicleLiftModel), so no
	# place's scene names them; seen first down a mine, they compiled there.
	ELEVATOR + "upper_landing.tscn",
	ELEVATOR + "lower_landing.tscn",
	ELEVATOR + "level_landing.tscn",
	ELEVATOR + "section.tscn",
	ELEVATOR + "platform.tscn",
]
const ELEVATOR := "res://scenes/_universe/structures/industrial/truck_elevator/"
## The mines' rock, which no scene names either (MineSite gives it the caves' milky rock at run time, CaveMineral),
## and the dust of a fallen layer: 72 pipelines compiled in one 10.7 s frame the first time a shaft was looked into
## (playtest 2026-11-11). Drawn on meshes made like the mine's own (mine_meshes), whose vertex format the pipelines
## depend on.
const MINE_ROCK: Array[String] = [
	"res://scenes/planet/cave/assets/crystal_corundum/corundum_rock_wall.tres",
	"res://scenes/planet/cave/assets/crystal_corundum/corundum_rock_floor.tres",
	"res://scenes/planet/cave/assets/crystal_corundum/corundum_rock_decor.tres",
]
const MINE_DUST_SHADER := preload("res://scenes/_universe/structures/industrial/mines/shaft/mine_dust.gdshader")
## A mining rock: drawn with its scene's materials and with the shader the game gives it at run time
## (MiningRock, rock_vein), which no scene names: the first rock met froze the game 2.7 s to compile it.
const ROCK_SCENE := "res://scenes/_universe/environment/terrain/rocks/rock_mining_md.tscn"
const ROCK_SHADER := preload("res://assets/_universe/environment/terrain/rocks/rock_vein.gdshader")
## Those of SCENES whose LayoutData is read ahead too.
const LAYOUTS: Array[String] = [
	"res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn",
	"res://scenes/_universe/structures/urban/cities/ares_city_factory.tscn",
]
## The dispensers' item folders (DispenserCatalog): each item's scene is wanted too.
const CATALOGUES: Array[String] = [
	"res://scenes/_universe/vehicles/specs/",
	"res://scenes/_universe/props/food/dispenser_items/",
	"res://scenes/_universe/props/tools/dispenser_items/",
	"res://scenes/_universe/vehicles/terminal_items/",
]
## The puppet a baked person is put out on (hidden), in its close-up materials then its far ones.
const PERSON_SCENE := "res://scenes/_universe/characters/humanoids/human_puppet.tscn"
## The first subsurface scattering DRAWN in a session (any viewport) turns on the engine's "advanced" shader
## group, and every shader then in memory compiles that group again (ShaderRD.enable_group): 4-6 s in one
## frame once the scenes below are loaded, even with warm caches. SSS_PRIMER is drawn before they are, when
## few shaders are in memory, and those loaded afterwards compile the group with the rest.
const SSS_PRIMER := preload("res://assets/_universe/characters/human/shaders/sss_primer.gdshader")
## Meshes put out at a time; the next ones wait until their pipelines are compiled.
const MESHES_PER_BATCH := 8
## Main-thread time (ms) a frame spends putting meshes out before it stops: a material's first use translates
## its shader on this thread (0.2-0.5 s for a person's), and a scene taken in reads its meshes and layout.
const FRAME_BUDGET_MS := 50

## What was loaded, kept for the session (path -> resource).
static var _held: Dictionary = {}
## The mesh a material is drawn on when the scene names the material without its mesh (an override on a
## node of an imported model): its shader is compiled all the same.
static var _stand_in: Mesh = BoxMesh.new()

var _loading: Array[String] = []
## The scenes, meshes and materials already gathered, over every scene loaded.
var _seen: Dictionary = {}
## [mesh, [materials]] still to put out.
var _to_draw: Array = []
## What was put out last (hidden), freed once its pipelines are compiled.
var _batch: Array[Node] = []
var _viewport: SubViewport
var _wanted: int = 0
var _meshes_done: int = 0
## The neon signs of the layouts still to trace (NeonSign.mesh_params), one a frame.
var _signs: Array = []
var _label: Label
var _primer: MeshInstance3D = null
var _person: Node = null
var _person_step: int = 0  # 0 not yet put out, 1 baking, 2 close-up materials out, 3 far ones out, 4 done
## Frames run since the warm-up began, and the one in which something was last put out (-1: none waiting).
var _frames: int = 0
var _put_out_at: int = -1
## The marker task queued behind the pipelines of what was put out (-1: none).
var _marker: int = -1


## A person's shaders (CharacterMaterials), put out on a stand-in too: a look met later may wear one the
## warmed person does not (a scalp, a shell of hair), and its shader is compiled ahead all the same.
static func person_shaders() -> Array[Shader]:
	return [
		CharacterMaterials.SKIN_SHADER, CharacterMaterials.SKIN_FAR_SHADER, CharacterMaterials.EYE_SHADER,
		CharacterMaterials.EYE_WET_SHADER, CharacterMaterials.IRIS_SHADER, CharacterMaterials.HAIR_SHADER,
		CharacterMaterials.HAIR_STRANDS_SHADER, CharacterMaterials.HAIR_SHELL_SHADER, CharacterMaterials.HAIR_SCALP_SHADER,
	]


## Start the warm-up once per session, where something is drawn.
static func start(tree: SceneTree) -> void:
	if DisplayServer.get_name() == "headless" or tree.root.has_node(^"Warmup"):
		return
	var warmup := Warmup.new()
	warmup.name = "Warmup"
	tree.root.add_child.call_deferred(warmup)


## Every scene to load: the SCENES and each catalogue item's scene.
static func wanted() -> Array[String]:
	var paths: Array[String] = SCENES.duplicate()
	for dir: String in CATALOGUES:
		for item: Resource in DispenserCatalog.all(dir):
			var path: String = str(item.scene_path)
			if not path in paths:
				paths.append(path)
	return paths


## [mesh, [materials]] of a mine's run-time surfaces (MINE_ROCK, MINE_DUST_SHADER): a rock cell's mesh (vertices,
## normals, colours: MineMesher.to_mesh), a fractured block's (indexed: MineFracture.to_mesh) and the dust's box.
static func mine_meshes() -> Array:
	var rock: Array = []
	for path in MINE_ROCK:
		if ResourceLoader.exists(path):
			rock.append(load(path))
	var points := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	var normals := PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	var cell_arrays := []
	cell_arrays.resize(Mesh.ARRAY_MAX)
	cell_arrays[Mesh.ARRAY_VERTEX] = points
	cell_arrays[Mesh.ARRAY_NORMAL] = normals
	cell_arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.BLACK, Color.BLACK, Color.BLACK])
	var cell := ArrayMesh.new()
	cell.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cell_arrays)
	var block_arrays := []
	block_arrays.resize(Mesh.ARRAY_MAX)
	block_arrays[Mesh.ARRAY_VERTEX] = points
	block_arrays[Mesh.ARRAY_NORMAL] = normals
	block_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var block := ArrayMesh.new()
	block.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, block_arrays)
	var dust := ShaderMaterial.new()
	dust.shader = MINE_DUST_SHADER
	return [[cell, rock.duplicate()], [block, rock], [BoxMesh.new(), [dust]]]


## Add the mining rocks' run-time shader to the materials of [param meshes] ([method meshes_of]).
static func with_rock_shader(meshes: Array) -> void:
	var material := ShaderMaterial.new()
	material.shader = ROCK_SHADER
	for entry: Array in meshes:
		(entry[1] as Array).append(material)


## The [mesh, [materials]] of [param scene] and of the scenes it instances, each once: what is drawn
## to compile their shaders. [param seen] gathers the scenes, meshes and materials already listed.
static func meshes_of(scene: PackedScene, seen: Dictionary = {}) -> Array:
	var out: Array = []
	if scene == null or seen.has(scene):
		return out
	seen[scene] = true
	var state: SceneState = scene.get_state()
	for node in state.get_node_count():
		var inner: PackedScene = state.get_node_instance(node)
		if inner != null:
			out.append_array(meshes_of(inner, seen))
		var mesh: Mesh = null
		var materials: Array = []
		for prop in state.get_node_property_count(node):
			var value: Variant = state.get_node_property_value(node, prop)
			if value is Mesh:
				mesh = value
			elif value is Material and not seen.has(value):
				seen[value] = true
				materials.append(value)
		if mesh != null and not seen.has(mesh):
			seen[mesh] = true
			out.append([mesh, materials])
		elif not materials.is_empty():
			out.append([_stand_in, materials])
	return out


func _ready() -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true  # out of the game's world: nothing drawn here shows anywhere else
	_viewport.size = Vector2i(64, 64)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 6.0)
	_viewport.add_child(camera)
	# With shadows, as in the game: a mesh is also drawn in the shadow passes, with pipelines of their own,
	# and those were still compiling when a place was first seen (the sun's cascades, a lamp's atlas).
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.8, 0.4, 0.0)
	sun.shadow_enabled = true
	_viewport.add_child(sun)
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(1.0, 1.0, 1.0)
	lamp.omni_range = 10.0
	lamp.shadow_enabled = true
	_viewport.add_child(lamp)
	var primer := ShaderMaterial.new()
	primer.shader = SSS_PRIMER
	_primer = _instance(_stand_in, primer)
	_put_out_at = 0


func _exit_tree() -> void:
	if _marker != -1:
		WorkerThreadPool.wait_for_task_completion(_marker)
		_marker = -1


## Load the scenes on worker threads, and list the mines' meshes and a person's shaders: once SSS_PRIMER
## was drawn.
func _request_loads() -> void:
	for path in wanted():
		if _held.has(path) or not ResourceLoader.exists(path):
			continue
		if ResourceLoader.load_threaded_request(path, "", true) == OK:
			_loading.append(path)
	_wanted = _loading.size()
	_to_draw.append_array(mine_meshes())
	for shader in person_shaders():
		_to_draw.append([_stand_in, [shader]])  # its material made when put out (_material)


func _process(_delta: float) -> void:
	_frames += 1
	_take_loaded()
	if not _signs.is_empty():
		NeonSign.shared_mesh(_signs.pop_back())
	_show_progress()
	if not _compiled():
		return  # what was put out last is still compiling: nothing new meanwhile, the frames go on
	for node in _batch:
		node.queue_free()
	_batch.clear()
	if _primer != null:
		if not _primer.visible:
			_primer.visible = true  # its pipelines are ready: drawn this frame, the SSS turned on
			return
		_primer.queue_free()  # drawn: the shaders and pipelines it made Godot redo were queued in that render
		_primer = null
		_put_out_at = _frames - 1
		_request_loads()
		return
	if _loading.is_empty() and _person_step < 4:
		_step_person()
		return
	var started: int = Time.get_ticks_msec()
	for i in mini(MESHES_PER_BATCH, _to_draw.size()):
		if i > 0 and Time.get_ticks_msec() - started > FRAME_BUDGET_MS:
			break
		var entry: Array = _to_draw.pop_back()
		var materials: Array = entry[1]
		for material: Variant in ([null] if materials.is_empty() else materials):
			_batch.append(_instance(entry[0], _material(material)))
		_meshes_done += 1
		_put_out_at = _frames
	if _loading.is_empty() and _to_draw.is_empty() and _batch.is_empty() and _signs.is_empty() \
			and _put_out_at == -1:
		print("[Warmup] %d scenes ready, their pipelines compiled" % _held.size())
		_viewport.queue_free()
		if _label != null:
			_label.get_parent().queue_free()
		set_process(false)


## Whether the pipelines of what was put out are compiled: a render meets it in the frame it was put out in,
## which queues them; the next frame queues a high-priority marker task behind them, and once that has run,
## so have they (the queue is first in, first out). False meanwhile.
func _compiled() -> bool:
	if _put_out_at != -1 and _frames > _put_out_at:
		_marker = WorkerThreadPool.add_task(_mark, true, "Warmup pipelines")
		_put_out_at = -1
		return false
	if _marker != -1:
		if not WorkerThreadPool.is_task_completed(_marker):
			return false
		WorkerThreadPool.wait_for_task_completion(_marker)
		_marker = -1
	return _put_out_at == -1


static func _mark() -> void:
	pass


## A shader put out on its own gets its material here, when put out: making it translates the shader.
static func _material(what: Variant) -> Variant:
	if what is Shader:
		var material := ShaderMaterial.new()
		material.shader = what
		return material
	return what


## One scene loaded since: kept, its meshes listed, its layout's signs read (one a frame: a layout read here
## takes a second).
func _take_loaded() -> void:
	for path: String in _loading.duplicate():
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_loading.erase(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var loaded: Resource = ResourceLoader.load_threaded_get(path)
			_held[path] = loaded
			if LAYOUTS.has(path):
				_signs.append_array(LayoutData.of(path)["signs"])
			if loaded is PackedScene:
				var meshes := meshes_of(loaded as PackedScene, _seen)
				if path == ROCK_SCENE:
					with_rock_shader(meshes)
				_to_draw.append_array(meshes)
		return


## A person (hidden): a baked body is built at run time (HumanAppearance), so no scene names its skin, eye and
## hair materials, and the first avatar seen froze the game to compile them. Put out once baked, in its
## close-up materials, then its far ones.
func _step_person() -> void:
	var looks: HumanAppearance = null
	if is_instance_valid(_person):
		looks = _person.get_node_or_null(^"HumanAppearance") as HumanAppearance
	match _person_step:
		0:
			_person = (load(PERSON_SCENE) as PackedScene).instantiate()
			(_person as Node3D).visible = false
			_viewport.add_child(_person)
			looks = _person.get_node_or_null(^"HumanAppearance") as HumanAppearance
			if looks == null:
				_person_step = 4
				return
			looks.set_appearance(CharacterAppearance.preset("default_male"))
			_person_step = 1
		1:
			if looks.is_applied():  # its body swapped in during the frame before: that render met it
				_put_out_at = _frames - 1
				_person_step = 2
		2:
			looks.set_detail(false)
			_put_out_at = _frames
			_person_step = 3
		_:
			_person.queue_free()
			_person = null
			_person_step = 4


## How far it is (0..1): the scenes loaded for one half, the meshes drawn for the other. Pure.
static func progress(wanted: int, loading: int, drawn: int, to_draw: int) -> float:
	var loaded: float = 1.0 if wanted == 0 else float(wanted - loading) / float(wanted)
	var compiled: float = 1.0 if drawn + to_draw == 0 else float(drawn) / float(drawn + to_draw)
	return 0.5 * loaded + 0.5 * (compiled if loading == 0 else 0.0)


## The line in the menu's corner: shown while the menu is up, gone in the game (the work goes on).
func _show_progress() -> void:
	if _label == null:
		var layer := CanvasLayer.new()
		layer.layer = 100
		add_child(layer)
		_label = Label.new()
		_label.add_theme_font_size_override("font_size", 16)
		_label.modulate = Color(1.0, 1.0, 1.0, 0.7)
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(_label)
		_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
		_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_label.visible = get_tree().get_first_node_in_group(MenuStage.GROUP) != null
	var line: String = tr("%%MENU_WARMUP")
	if "%d" in line:  # a translation not imported yet comes back as its key, with nothing to fill
		line = line % roundi(100.0 * progress(_wanted, _loading.size(), _meshes_done, _to_draw.size()))
	_label.text = line


## [param mesh] in [param material], hidden in the viewport: its pipelines compile all the same.
func _instance(mesh: Mesh, material: Variant) -> MeshInstance3D:
	var shown := MeshInstance3D.new()
	shown.mesh = mesh
	shown.material_override = material
	shown.scale = Vector3.ONE / maxf(mesh.get_aabb().get_longest_axis_size(), 0.001)
	shown.visible = false
	_viewport.add_child(shown)
	return shown
