## From: https://github.com/godotengine/godot-demo-projects/blob/master/viewport/gui_in_3d/gui_3d.gd
extends Node3D

## SubViewport holding the 2D interface. Shown on node_quad and fed the mouse/keyboard input routed from 3D.
@export var node_viewport: SubViewport
## Screen mesh the interface is displayed on. Its 0..1 UVs and size map 3D hits to viewport pixels; gets an
## unshaded material showing node_viewport when it has no material_override.
@export var node_quad: MeshInstance3D
## Area3D picked by the mouse ray: its hover/input events are converted and pushed into node_viewport.
@export var node_area: Area3D

## Used for checking if the mouse is inside the Area3D.
var is_mouse_inside: bool = false

## The last processed input touch/mouse event. Used to calculate relative movement.
var last_event_pos_2d := Vector2()

## The time of the last event in seconds since engine start.
var last_event_time := -1.0


func _ready() -> void:
	add_to_group(ScreenTarget.GROUP)  # the crosshair looks for screens here (PlayerClient._point_screen)
	# Show the SubViewport on the screen mesh BY CODE, so the screen can be any mesh — e.g. one from
	# the vehicle's GLB model (named ScreenFront, etc.) — without setting up a ViewportTexture
	# material by hand. Only when the mesh has no material_override yet, so scenes that set their own
	# (like the mining depot) keep theirs untouched. The mesh still needs 0..1 UVs and its front face
	# (blue normal) toward the viewer, like the camera screens.
	if node_quad != null and node_viewport != null and node_quad.material_override == null:
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = node_viewport.get_texture()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_BACK
		node_quad.material_override = mat
	if node_area != null:
		node_area.mouse_entered.connect(_mouse_entered_area)
		node_area.mouse_exited.connect(_mouse_exited_area)
		node_area.input_event.connect(_mouse_input_event)

func _mouse_entered_area() -> void:
	is_mouse_inside = true
	# Notify the viewport that the mouse is now hovering it.
	if node_viewport != null:
		node_viewport.notification(NOTIFICATION_VP_MOUSE_ENTER)


func _mouse_exited_area() -> void:
	# Notify the viewport that the mouse is no longer hovering it.
	if node_viewport != null:
		node_viewport.notification(NOTIFICATION_VP_MOUSE_EXIT)
	is_mouse_inside = false


func _unhandled_input(input_event: InputEvent) -> void:
	# Check if the event is a non-mouse/non-touch event
	for mouse_event in [InputEventMouseButton, InputEventMouseMotion, InputEventScreenDrag, InputEventScreenTouch]:
		if is_instance_of(input_event, mouse_event):
			# If the event is a mouse/touch event, then we can ignore it here, because it will be
			# handled via Physics Picking — by the ROOT viewport, which is where 3D picking happens
			# (see ClientPerf's debug_no_picking ablation). This SubViewport's own
			# physics_object_picking would concern 3D objects INSIDE it, and it holds none: disable_3d.
			return
	# EVERY Gui3D in the world runs this handler, so an ungated push sent every keystroke to every
	# screen loaded at once. Focus is per-SubViewport, so that is not merely wasteful: a field left
	# focused on a console in another room would still swallow what is typed here, while
	# PlayerClient._screen_typing() only ever asks about the screen the player is STANDING at — so
	# gameplay input would not even be locked for it.
	# Nothing in a panel reacts to a key without holding focus, which makes "has a focus owner" the
	# exact condition. A click never comes through here — it arrives by picking, above — so a field
	# can still be focused in the first place.
	if node_viewport == null or node_viewport.gui_get_focus_owner() == null:
		return
	node_viewport.push_input(input_event)


## Width/height (m) of the interactive surface, taken from the MESH — the surface whose 0..1 UVs the
## interface actually occupies. PlaneMesh/QuadMesh expose it directly; any other mesh (e.g. a screen
## from the truck's GLB) falls back to the two largest axes of its AABB, the third being its thickness.
func _surface_size() -> Vector2:
	var mesh: Mesh = node_quad.mesh
	if mesh is QuadMesh or mesh is PlaneMesh:
		return mesh.size
	var aabb: Vector3 = mesh.get_aabb().size
	var axes: Array = [aabb.x, aabb.y, aabb.z]
	axes.sort()
	return Vector2(axes[2], axes[1])  # drop the smallest axis: that one is the thickness


## The interactive surface's size (m), for a screen that lays its interface out to the screen's shape.
func surface_size() -> Vector2:
	return _surface_size()


# -- The crosshair as the pointer ----------------------------------------------------------------------
# Walking up to a screen used to free the cursor and freeze the view: the player was stuck to it. Now
# the view stays the player's and the crosshair points: PlayerClient casts its ray here (hit), hovers
# (pointer_at) and clicks (click_at) with the `perforate` action. The free-cursor path below (physics
# picking) stays for any screen used with a visible mouse.

## Where the ray from [param from] along [param dir] meets the screen, within [param reach] m, or null
## when it misses it. Pure geometry on the screen mesh's plane: no physics query, any frame.
func hit(from: Vector3, dir: Vector3, reach: float) -> Variant:
	if node_quad == null or node_viewport == null:
		return null
	var xf: Transform3D = node_quad.global_transform
	var normal: Vector3 = xf.basis.z.normalized()
	var facing: float = dir.dot(normal)
	if is_zero_approx(facing):
		return null
	var t: float = (xf.origin - from).dot(normal) / facing
	if t < 0.0 or t > reach:
		return null
	var point: Vector3 = from + dir * t
	var uv: Vector2 = _uv_of(point)
	return point if uv.x >= 0.0 and uv.x <= 1.0 and uv.y >= 0.0 and uv.y <= 1.0 else null


## Hover the interface at [param point] (a hit()): a mouse motion pushed into the viewport.
func pointer_at(point: Vector3) -> void:
	var motion := InputEventMouseMotion.new()
	_push_at(motion, point)


## Hand the interface a real mouse event (a motion, any button, the wheel) as if it happened at
## [param point] (a hit()): a screen read with a free cursor (the wrist DataPad, WristDatapad), whose
## pointer is the mouse itself rather than the crosshair. A copy is pushed: the caller's event is left as
## the window gave it.
func push_at(input_event: InputEventMouse, point: Vector3) -> void:
	_push_at(input_event.duplicate(), point)


## The point (world) on the screen mesh at [param uv] (0..1, (0, 0) the top-left corner): the inverse
## of _uv_of, for a pointer kept in the screen's own coordinates (the wrist DataPad, WristDatapad).
func point_at_uv(uv: Vector2) -> Vector3:
	var size: Vector2 = _surface_size()
	return node_quad.global_transform * Vector3((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y, 0.0)


## Press or release ([param pressed]) the left button at [param point] (a hit()).
func click_at(point: Vector3, pressed: bool) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	click.pressed = pressed
	_push_at(click, point)


## The crosshair left the screen: the interface stops showing a hover.
func pointer_left() -> void:
	if node_viewport != null:
		node_viewport.notification(NOTIFICATION_VP_MOUSE_EXIT)


## Give the keyboard back to the game: whatever field of this screen has it lets go.
func release_keyboard() -> void:
	if node_viewport != null:
		node_viewport.gui_release_focus()


## [param point] (world) on the screen mesh as 0..1 UVs, (0, 0) the top-left corner. A QuadMesh or
## PlaneMesh lies in its own local XY plane, so the mesh's frame gives (x, -y) whatever the Area's
## orientation (see _mouse_input_event).
func _uv_of(point: Vector3) -> Vector2:
	var local: Vector3 = node_quad.global_transform.affine_inverse() * point
	var size: Vector2 = _surface_size()
	return Vector2(local.x / size.x + 0.5, -local.y / size.y + 0.5)


## Place [param input_event] at [param point] in the viewport's pixels, relative motion included, and push it.
func _push_at(input_event: InputEvent, point: Vector3) -> void:
	if node_viewport != null:
		_push_at_pixel(input_event, _uv_of(point) * Vector2(node_viewport.size))


## Push [param input_event] at [param event_pos_2d] (the viewport's pixels). A screen whose SubViewport
## is handed over later (the vehicle lift's kiosks, kiosk.gd) may have none yet: nothing to push into.
func _push_at_pixel(input_event: InputEvent, event_pos_2d: Vector2) -> void:
	if node_viewport == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	input_event.position = event_pos_2d
	if input_event is InputEventMouse:
		input_event.global_position = event_pos_2d
	if input_event is InputEventMouseMotion or input_event is InputEventScreenDrag:
		input_event.relative = event_pos_2d - last_event_pos_2d
		if now > last_event_time:
			input_event.velocity = input_event.relative / (now - last_event_time)
	last_event_pos_2d = event_pos_2d
	last_event_time = now
	node_viewport.push_input(input_event)


func _mouse_input_event(_camera: Camera3D, input_event: InputEvent, event_position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	# The crosshair drives a screen while the mouse is captured (hit / pointer_at / click_at): picking
	# at the window centre would hand the interface the same events a second time.
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return
	# Size AND position both come from the MESH, never from the collision shape. They used to be mixed:
	# the width was read off the BoxShape's Z while the position was read off the Area's X — which is
	# the shape's THICKNESS (0.23 m on the mining depot, whose Area is turned 90° from the mesh). A
	# depth of impact was therefore divided by a width, pinning the horizontal coordinate to
	# 0.5 +/- 0.077: the pointer could never leave a narrow band in the middle of the screen, and only
	# quivered inside it with the ray's angle of incidence. _uv_of works in the mesh's frame.
	# Outside the area (a drag leaving it), the last known position stands.
	var event_pos_2d: Vector2 = last_event_pos_2d
	if is_mouse_inside and node_viewport != null:
		event_pos_2d = _uv_of(event_position) * Vector2(node_viewport.size)
	_push_at_pixel(input_event, event_pos_2d)
