class_name RearCamera
extends Camera3D

## Rear-view camera fed onto an in-cab screen — a drop-in, reusable by any vehicle (like Gui3D).
##
## THIS node is a real Camera3D so you can place and frame it in the editor (gizmo + frustum +
## the "Preview" button show exactly what it films). It never renders to the player's view
## (current = false); it is only the pose. A twin Camera3D inside the SubViewport copies that pose
## (and fov) and renders the feed, which is shown on the `screen` mesh.
##
## How a vehicle uses it (no code):
## 1. Instance rear_camera.tscn under the vehicle.
## 2. Place/aim THIS camera in the editor at the back, looking behind (use Preview to frame it).
## 3. Set `screen` to the MeshInstance3D that displays the feed (e.g. the cab "Recul" screen).
##
## Purely visual: it only runs on clients, never on the headless game server.

## The cab surface that shows the camera feed (its material_override is replaced by the feed).
@export var screen: MeshInstance3D
## Render resolution of the feed. Keep it small — each refresh is a second full 3D render.
@export var resolution: Vector2i = Vector2i(320, 200)
## Flip the feed left/right. false = a reversing camera (true view); true = a real mirror (side
## mirror / rear-view mirror, which reverses left and right).
@export var mirror: bool = false
## How many times per second the feed re-renders. Each render is a full extra 3D pass, so a lower
## rate is much cheaper on weak GPUs. 0 = render every frame.
@export var refresh_hz: float = 20.0
## Beyond this distance (m) from the player's view, the feed stops rendering entirely (the screen
## keeps its last image). The feed is only readable up close anyway, so far trucks cost nothing.
@export var max_distance: float = 60.0

var _refresh_accum: float = 0.0
var _feed_mat: StandardMaterial3D = null    # the live camera feed shown on the screen
var _off_mat: StandardMaterial3D = null     # solid black shown when the engine is off
var _vehicle: Vehicle = null                # owning vehicle: the screen lights up only with its engine
var _powered: bool = true                   # last applied power state (flip only on change)

@onready var _viewport: SubViewport = $SubViewport
@onready var _camera: Camera3D = $SubViewport/Camera3D

func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		return  # the headless server renders nothing
	current = false  # this camera is only the placement/preview pose, never the player's view
	_viewport.size = resolution
	_viewport.world_3d = get_world_3d()  # render the SAME world, not an empty SubViewport world
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED  # driven per-frame in _process
	_camera.current = true
	_camera.fov = fov
	if screen != null:
		_feed_mat = StandardMaterial3D.new()
		_feed_mat.albedo_texture = _viewport.get_texture()
		_feed_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # show the feed as-is, unlit
		_feed_mat.cull_mode = BaseMaterial3D.CULL_BACK  # one-sided: show only on the screen's front face
		if mirror:
			# Reverse left/right within the quad's 0..1 UVs, like a real mirror.
			_feed_mat.uv1_scale = Vector3(-1.0, 1.0, 1.0)
			_feed_mat.uv1_offset = Vector3(1.0, 0.0, 0.0)
		# Solid-black "screen off" image, shown while the engine is cut.
		_off_mat = StandardMaterial3D.new()
		_off_mat.albedo_color = Color(0, 0, 0, 1)
		_off_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_off_mat.cull_mode = BaseMaterial3D.CULL_BACK
		screen.material_override = _feed_mat

	# The screens power off with the engine: find the owning vehicle and apply the current state.
	_vehicle = _find_vehicle()
	_apply_power(_is_powered())

func _process(delta: float) -> void:
	if OS.has_feature("dedicated_server"):
		return
	# The screen is dark while the engine is off; flip material + rendering only on a real change.
	var powered := _is_powered()
	if powered != _powered:
		_apply_power(powered)
	if not powered:
		return
	# Too far from the player's view: stop rendering entirely (the screen keeps its last image).
	if _is_beyond_max_distance():
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	# Keep the SubViewport camera glued to this (placeable) camera's pose + lens.
	_camera.global_transform = global_transform
	_camera.fov = fov
	if refresh_hz <= 0.0:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		return
	# Throttle: render one frame every 1/refresh_hz seconds (UPDATE_ONCE auto-disables after).
	_refresh_accum += delta
	if _refresh_accum >= 1.0 / refresh_hz:
		_refresh_accum = 0.0
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

## True when the owning vehicle's engine is running (the screen is lit only then).
func _is_powered() -> bool:
	return _vehicle != null and is_instance_valid(_vehicle) and _vehicle.is_engine_on()

## Swap the screen between the live feed and the black "off" image, and stop the render pass when off.
func _apply_power(on: bool) -> void:
	_powered = on
	if screen != null and _feed_mat != null and _off_mat != null:
		screen.material_override = _feed_mat if on else _off_mat
	if not on:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_refresh_accum = 0.0

## Walk up the tree to the owning Vehicle (the rear camera is placed under it).
func _find_vehicle() -> Vehicle:
	var n: Node = get_parent()
	while n != null and not (n is Vehicle):
		n = n.get_parent()
	return n as Vehicle

## True when the player's active camera is farther than max_distance from this screen.
func _is_beyond_max_distance() -> bool:
	if max_distance <= 0.0:
		return false  # 0 = no distance culling
	var view := get_viewport().get_camera_3d()
	if view == null:
		return false
	return global_position.distance_to(view.global_position) > max_distance
