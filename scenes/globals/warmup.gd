class_name Warmup
extends Node

## While the main menu shows, gets ready what the game needs the moment it is in it, so it does not hold
## the game then: the first ration out of a dispenser froze it for a long moment (its scene read from the
## disk on the main thread, then its shaders compiled at its first frame; playtest 2026-10-21), and so
## did every place and prop seen for the first time.
##
## It loads, on worker threads, the layouts of the places the world spawns (loading one loads every scene
## it is built of), the vehicles and the items of the dispensers, and keeps them for the session: the
## game's own load() then finds them in memory. Then it draws their meshes, a few a frame, out of sight
## in a viewport of its own, so their shaders are compiled. No scene is instanced: nothing of the game
## runs, only meshes and materials are read from the scenes (PackedScene.get_state).
##
## Client only, where something is drawn; one per session (start), under the tree's root so it goes on
## once the game is entered. While the menu shows, a line in its corner says how far it is.

## The scenes wanted with everything they are built of: the places the world spawns, the vehicles.
const SCENES: Array[String] = [
	"res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn",
	"res://scenes/_universe/structures/urban/cities/ares_city_factory.tscn",
	"res://scenes/_universe/vehicles/ground/trucks/truck.tscn",
]
## The dispensers' item folders (DispenserCatalog): each item's scene is wanted too.
const CATALOGUES: Array[String] = [
	"res://scenes/_universe/vehicles/specs/",
	"res://scenes/_universe/props/food/dispenser_items/",
	"res://scenes/_universe/props/tools/dispenser_items/",
]
## Meshes drawn a frame while their shaders compile.
const MESHES_PER_FRAME := 8

## What was loaded, kept for the session (path -> resource).
static var _held: Dictionary = {}
## The mesh a material is drawn on when the scene names the material without its mesh (an override on a
## node of an imported model): its shader is compiled all the same.
static var _stand_in: Mesh = BoxMesh.new()

var _loading: Array[String] = []
## The scenes, meshes and materials already gathered, over every scene loaded.
var _seen: Dictionary = {}
## [mesh, [materials]] still to draw.
var _to_draw: Array = []
var _drawn: Array[Node] = []
var _viewport: SubViewport
var _wanted: int = 0
var _meshes_done: int = 0
var _label: Label


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
	for path in wanted():
		if _held.has(path) or not ResourceLoader.exists(path):
			continue
		if ResourceLoader.load_threaded_request(path, "", true) == OK:
			_loading.append(path)
	_wanted = _loading.size()
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true  # out of the game's world: nothing drawn here shows anywhere else
	_viewport.size = Vector2i(64, 64)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 6.0)
	_viewport.add_child(camera)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.8, 0.4, 0.0)
	_viewport.add_child(sun)


func _process(_delta: float) -> void:
	for node in _drawn:
		node.queue_free()
	_drawn.clear()
	for path: String in _loading.duplicate():
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_loading.erase(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var loaded: Resource = ResourceLoader.load_threaded_get(path)
			_held[path] = loaded
			if loaded is PackedScene:
				_to_draw.append_array(meshes_of(loaded as PackedScene, _seen))
	for i in mini(MESHES_PER_FRAME, _to_draw.size()):
		_draw(_to_draw.pop_back())
		_meshes_done += 1
	_show_progress()
	if _loading.is_empty() and _to_draw.is_empty() and _drawn.is_empty():
		print("[Warmup] %d scenes ready, their shaders compiled" % _held.size())
		_viewport.queue_free()
		if _label != null:
			_label.get_parent().queue_free()
		set_process(false)


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


## Draw [param entry]'s mesh once, with each of its materials in turn on its first surface.
func _draw(entry: Array) -> void:
	var mesh: Mesh = entry[0]
	var materials: Array = entry[1]
	for material: Variant in ([null] if materials.is_empty() else materials):
		var shown := MeshInstance3D.new()
		shown.mesh = mesh
		shown.material_override = material
		shown.scale = Vector3.ONE / maxf(mesh.get_aabb().get_longest_axis_size(), 0.001)
		_viewport.add_child(shown)
		_drawn.append(shown)
