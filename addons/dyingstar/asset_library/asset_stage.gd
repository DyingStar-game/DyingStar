@tool
extends SubViewport

## A small 3D stage outside the edited scene: its own world, a light, a neutral backdrop and a camera
## framed on whatever is put on it. The asset library uses one to render the thumbnail of a model and
## another to show the selected model, turned with the mouse.

const Catalog := preload("res://addons/dyingstar/asset_library/asset_catalog.gd")

## Scenes with more nodes than this are not put on a stage: a whole level is not a thumbnail.
const MAX_SCENE_NODES := 300
## The same limit for a model file: a building is many parts, and none of them runs anything.
const MAX_MODEL_NODES := 5000
## How a scene file states the class of a node.
const TYPE_ATTRIBUTE := " type=\""

## Backdrop colour, close to the editor's own panels.
const BACKDROP := Color(0.2, 0.23, 0.27)
## Vertical field of view of the stage camera, in degrees.
const FIELD_OF_VIEW := 35.0
## How much wider than the model the frame is: 1 touches its bounding sphere.
const FRAME_MARGIN := 1.15
## Pitch limits of the orbit, in radians, short of looking straight up or down.
const MAX_PITCH := 1.4
## Closest and farthest the orbit zooms, as a share of the framed distance.
const MIN_ZOOM := 0.2
const MAX_ZOOM := 4.0

var _camera: Camera3D
var _content: Node3D = null
var _centre := Vector3.ZERO
var _radius := 1.0
var _yaw := 0.6
var _pitch := 0.35
var _zoom := 1.0


func _init() -> void:
	own_world_3d = true
	world_3d = World3D.new()
	world_3d.environment = _environment()
	msaa_3d = Viewport.MSAA_4X
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, 0.7, 0.0)
	add_child(light)
	_camera = Camera3D.new()
	_camera.fov = FIELD_OF_VIEW
	add_child(_camera)


## A plain backdrop, lit and reflected by a sky that is never shown: metal with nothing to reflect
## comes out black.
func _environment() -> Environment:
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = BACKDROP
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	return environment


## The node that shows the loaded asset [param resource], or null when it is not something to put on a
## stage: not a model, not a 3D scene, or a scene too large.
static func node_of(resource: Resource) -> Node3D:
	if resource is Mesh:
		var instance := MeshInstance3D.new()
		instance.mesh = resource
		return instance
	if not resource is PackedScene:
		return null
	var state := (resource as PackedScene).get_state()
	var node_count := state.get_node_count()
	var is_model := resource.resource_path.get_extension().to_lower() in Catalog.MODEL_EXTENSIONS
	if node_count == 0 or node_count > (MAX_MODEL_NODES if is_model else MAX_SCENE_NODES):
		return null
	# An inherited scene gives no type for its root: it is known once instanced.
	var root_type := state.get_node_type(0)
	if root_type != &"" and root_type != &"Node3D" and not ClassDB.is_parent_class(root_type, &"Node3D"):
		return null
	var node := (resource as PackedScene).instantiate()
	if node is Node3D:
		_strip_scripts(node)
		return node
	node.free()
	return null


## Take every script off [param node] and its children, before they enter a tree. A scene is put on a
## stage to be looked at, never to run: left with its scripts, a planet's scene started generating the
## planet (tool scripts run in the editor) and the editor stopped answering.
static func _strip_scripts(node: Node) -> void:
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var current: Node = pending.pop_back()
		pending.append_array(current.get_children(true))
		if current.get_script() != null:
			current.set_script(null)


## Whether the scene file at [param path] can be a 3D one, read from its text, without loading it: a
## scene whose root is declared as something else (a Control, a plain Node that holds the whole game)
## is never loaded for a picture. An inherited scene declares no type: it may be.
static func may_be_3d(path: String) -> bool:
	if path.get_extension().to_lower() != "tscn":
		return true
	var text := FileAccess.get_file_as_string(path)
	var start := text.find("\n[node ")
	if start < 0:
		return false
	var line := text.substr(start + 1, text.find("\n", start + 1) - start - 1)
	var type_at := line.find(TYPE_ATTRIBUTE)
	if type_at < 0:
		return true
	type_at += TYPE_ATTRIBUTE.length()
	var type_name := line.substr(type_at, line.find("\"", type_at) - type_at)
	return type_name == "Node3D" or (ClassDB.class_exists(type_name) and ClassDB.is_parent_class(type_name, &"Node3D"))


## Put [param node] on the stage, in place of what was there, and frame it. The stage owns it from
## then on.
func show_node(node: Node3D) -> void:
	clear()
	_content = node
	add_child(node)
	var bounds := _bounds_of(node)
	_centre = bounds.get_center()
	_radius = maxf(bounds.size.length() * 0.5, 0.01)
	_zoom = 1.0
	_place_camera()


## Take the content off the stage.
func clear() -> void:
	if is_instance_valid(_content):
		remove_child(_content)
		_content.queue_free()
	_content = null


func has_content() -> bool:
	return is_instance_valid(_content)


## Turn the camera around the content by [param delta], in radians (x: around, y: over).
func orbit(delta: Vector2) -> void:
	_yaw -= delta.x
	_pitch = clampf(_pitch + delta.y, -MAX_PITCH, MAX_PITCH)
	_place_camera()


## Bring the camera closer ([param factor] under 1) or farther.
func zoom(factor: float) -> void:
	_zoom = clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	_place_camera()


## Slide the view by [param delta], in heights of the view (x: to the right, y: down).
func pan(delta: Vector2) -> void:
	var view_height := 2.0 * _distance() * tan(deg_to_rad(FIELD_OF_VIEW) * 0.5)
	var axes := _camera.transform.basis
	_centre += (axes.y * delta.y - axes.x * delta.x) * view_height
	_place_camera()


func _distance() -> float:
	return _radius * FRAME_MARGIN / sin(deg_to_rad(FIELD_OF_VIEW) * 0.5) * _zoom


func _place_camera() -> void:
	var distance := _distance()
	var direction := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch))
	_camera.near = maxf(distance * 0.01, 0.001)
	_camera.far = distance + _radius * 4.0
	# Set as a whole transform: look_at() needs the camera in the tree, this does not.
	_camera.transform = Transform3D(Basis.looking_at(-direction), _centre + direction * distance)


## The box around everything [param node] draws, in the stage's space.
func _bounds_of(node: Node3D) -> AABB:
	var bounds := AABB()
	var found := false
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var current: Node = pending.pop_back()
		pending.append_array(current.get_children())
		# Geometry only: a light's own box is the whole reach of its light.
		var visual := current as GeometryInstance3D
		if visual == null:
			continue
		var box: AABB = visual.global_transform * visual.get_aabb()
		if box.size == Vector3.ZERO:
			continue
		bounds = box if not found else bounds.merge(box)
		found = true
	return bounds if found else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
