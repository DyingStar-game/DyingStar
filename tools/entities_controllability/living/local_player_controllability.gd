extends EntityControllability
class_name LocalPlayerControllability

func _init() -> void:
	pass

func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed(JUMP) and entity.is_on_floor():
		entity.is_jumping = true

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouse_motion = -event.relative * 0.001

	if event.is_action_pressed("toggle_flashlight"):
		entity.flashlight.visible = not entity.flashlight.visible

	if event.is_action_pressed("spawn_50cmbox"):
		spawn_box50cm()

	if event.is_action_pressed("spawn_4mbox"):
		var box_spawn_position: Vector3 = entity.global_position + (- entity.global_basis.z * 3.0) + entity.global_basis.y * 6.0

		var player_up = entity.global_transform.basis.y.normalized()
		var to_player = (entity.global_transform.origin - box_spawn_position)
		to_player -= to_player.dot(player_up) * player_up
		to_player = to_player.normalized()
		var box_basis: Basis = Basis.looking_at(to_player, player_up)
		var box_spawn_rotation = box_basis.get_euler()

		spawn_box4m(box_spawn_position, box_spawn_rotation)

	if Input.is_action_just_pressed("ext_cam"):
		if entity.camera_ext.current:
			entity.camera_pov.make_current()
			entity.astronaut.visible = false
		else:
			entity.astronaut.visible = true
			entity.camera_ext.make_current()

func process(_delta: float) -> void:
	handle_camera_motion()

	var dir_vect = Vector3.ZERO
	var sprint = null

	if not entity.direct_chat.can_write:
		dir_vect = Input.get_vector(MOVE_LEFT, MOVE_RIGHT, MOVE_FORWARD, MOVE_BACK)
		sprint = Input.is_action_pressed(SPRINT)

	if dir_vect:
		input_direction = dir_vect
	else:
		input_direction = Vector2.ZERO

	# send move_direction
	if input_direction != client_last_input_direction or entity.global_rotation != entity.client_last_global_rotation:
		client_last_input_direction = input_direction
		entity.client_last_global_rotation = entity.global_rotation
		entity.emit_signal("hs_client_action_move", input_direction, entity.global_rotation)
	entity.update_last_basis()

func physics_process(_delta: float) -> void:
	if entity.puppet_player: return
	if !entity.active: return

	var sprint = null

	var parent_gravity_area: Area3D = entity.gravity_parents.back() if not entity.gravity_parents.is_empty() else null

	if parent_gravity_area:
		if parent_gravity_area.gravity_point:
			entity.up_direction = parent_gravity_area.global_position.direction_to(entity.global_position)
		else:
			entity.up_direction = parent_gravity_area.global_basis.y

		entity.gravity = parent_gravity_area.gravity
		entity.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	else:
		# 0g movement
		entity.gravity = 0.0
		entity.camera_pivot.rotation.x = 0
		entity.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		var dir = Vector3(input_direction.x, 0, input_direction.y)

		entity.velocity += entity.global_basis * dir * entity.player_thruster_force * _delta
		entity.velocity *= 0.98

	var move_direction = (entity.global_transform.basis * Vector3(input_direction.x, 0, input_direction.y)).normalized()

	var speed = entity.sprint_speed if sprint else entity.walk_speed

	if entity.is_on_floor():
		if input_direction:
			entity.velocity = move_direction * speed
		else:
			entity.velocity = entity.velocity.move_toward(Vector3.ZERO, speed)
	else:
		# "air" movement
		if input_direction:
			entity.velocity += move_direction * speed * _delta


	if entity.is_on_floor() and entity.is_jumping:
		entity.velocity += entity.up_direction * entity.jump_height * entity.gravity
		entity.is_jumping = false
	# Add the gravity.
	elif not entity.is_on_floor():
		entity.velocity -= entity.up_direction * entity.gravity * 2.0 * _delta
	
	entity.move_and_slide()
	entity.update_last_basis()

func spawn_box50cm():
	var box_spawn_position: Vector3 = entity.global_position + (- entity.global_basis.z * 1.5) +entity.global_basis.y * 2.0
	var prop_instance = entity.box50m.instantiate()
	prop_instance.spawn_position = box_spawn_position
	prop_instance.tree_entered.connect(func():
		prop_instance.owner = entity.get_tree().current_scene
	, CONNECT_ONE_SHOT)
	entity.get_tree().current_scene.add_child(prop_instance)

func spawn_box4m(spawn_position, spawn_rotation):
	var prop_instance = entity.box4m.instantiate()
	prop_instance.spawn_position = spawn_position
	prop_instance.spawn_rotation = spawn_rotation
	prop_instance.tree_entered.connect(func():
		prop_instance.owner = entity.get_tree().current_scene
	, CONNECT_ONE_SHOT)
	entity.get_tree().current_scene.add_child(prop_instance)
