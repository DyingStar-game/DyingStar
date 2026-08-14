## From: https://github.com/godotengine/godot-demo-projects/blob/master/viewport/gui_in_3d/gui_3d.gd
extends Node3D

@export var node_viewport: SubViewport
@export var node_quad: MeshInstance3D
@export var node_area: Area3D

## Used for checking if the mouse is inside the Area3D.
var is_mouse_inside: bool = false

## The last processed input touch/mouse event. Used to calculate relative movement.
var last_event_pos_2d := Vector2()

## The time of the last event in seconds since engine start.
var last_event_time := -1.0


func _ready() -> void:
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
	node_viewport.notification(NOTIFICATION_VP_MOUSE_ENTER)


func _mouse_exited_area() -> void:
	# Notify the viewport that the mouse is no longer hovering it.
	node_viewport.notification(NOTIFICATION_VP_MOUSE_EXIT)
	is_mouse_inside = false


func _unhandled_input(input_event: InputEvent) -> void:
	# Check if the event is a non-mouse/non-touch event
	for mouse_event in [InputEventMouseButton, InputEventMouseMotion, InputEventScreenDrag, InputEventScreenTouch]:
		if is_instance_of(input_event, mouse_event):
			# If the event is a mouse/touch event, then we can ignore it here, because it will be
			# handled via Physics Picking.
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


func _mouse_input_event(_camera: Camera3D, input_event: InputEvent, event_position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	# Size AND position both come from the MESH, never from the collision shape. They used to be mixed:
	# the width was read off the BoxShape's Z while the position was read off the Area's X — which is
	# the shape's THICKNESS (0.23 m on the mining depot, whose Area is turned 90° from the mesh). A
	# depth of impact was therefore divided by a width, pinning the horizontal coordinate to
	# 0.5 +/- 0.077: the pointer could never leave a narrow band in the middle of the screen, and only
	# quivered inside it with the ray's angle of incidence.
	# A QuadMesh/PlaneMesh lies in its own local XY plane BY CONSTRUCTION, so working in the mesh's
	# frame makes (x, -y) correct whatever the Area's orientation — no axis is assumed anywhere.
	var quad_mesh_size: Vector2 = _surface_size()

	# Event position in Area3D in world coordinate space.
	var event_pos_3d := event_position

	# Current time in seconds since engine start.
	var now := Time.get_ticks_msec() / 1000.0

	# Convert position to a coordinate space relative to the SCREEN MESH.
	# NOTE: `affine_inverse()` accounts for the node's scale, rotation, and position in the scene!
	event_pos_3d = node_quad.global_transform.affine_inverse() * event_pos_3d

	# TODO: Adapt to bilboard mode or avoid completely.

	var event_pos_2d := Vector2()

	if is_mouse_inside:
		# Convert the relative event position from 3D to 2D.
		event_pos_2d = Vector2(event_pos_3d.x, -event_pos_3d.y)

		# Right now the event position's range is the following: (-quad_size/2) -> (quad_size/2)
		# We need to convert it into the following range: -0.5 -> 0.5
		event_pos_2d.x = event_pos_2d.x / quad_mesh_size.x
		event_pos_2d.y = event_pos_2d.y / quad_mesh_size.y
		# Then we need to convert it into the following range: 0 -> 1
		event_pos_2d.x += 0.5
		event_pos_2d.y += 0.5

		# Finally, we convert the position to the following range: 0 -> viewport.size
		event_pos_2d.x *= node_viewport.size.x
		event_pos_2d.y *= node_viewport.size.y
		# We need to do these conversions so the event's position is in the viewport's coordinate system.

	elif last_event_pos_2d != null:
		# Fall back to the last known event position.
		event_pos_2d = last_event_pos_2d

	# Set the event's position and global position.
	input_event.position = event_pos_2d
	if input_event is InputEventMouse:
		input_event.global_position = event_pos_2d

	# Calculate the relative event distance.
	if input_event is InputEventMouseMotion or input_event is InputEventScreenDrag:
		# If there is not a stored previous position, then we'll assume there is no relative motion.
		if last_event_pos_2d == null:
			input_event.relative = Vector2(0, 0)
		# If there is a stored previous position, then we'll calculate the relative position by subtracting
		# the previous position from the new position. This will give us the distance the event traveled from prev_pos.
		else:
			input_event.relative = event_pos_2d - last_event_pos_2d
			input_event.velocity = input_event.relative / (now - last_event_time)

	# Update last_event_pos_2d with the position we just calculated.
	last_event_pos_2d = event_pos_2d

	# Update last_event_time to current time.
	last_event_time = now

	# Finally, send the processed input event to the viewport.
	node_viewport.push_input(input_event)
