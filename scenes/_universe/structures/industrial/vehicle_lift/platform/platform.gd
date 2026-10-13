extends RigidBody3D


## The platform's screen interface (lift_base_interface): receives the trip progress and the weight
## measured on the platform. Empty = nothing is displayed.
@export var _platform_interface: Control
#func set_interface(interface: Control) -> void:
	#print_rich("[color=gold]Dans set_interface de plateform, interface = %s[/color]" % interface)
	#_platform_interface = interface

var _weight_on_platform: float = 0.0
var _player_custom_force: float = 0.0

var _total_impulse_force: float = 0.0
var _unique_bodies_on_platform: Dictionary = {}

var active_player: Player


# Cached PropSync child. Resolved lazily (not @onready) because the uuid facade below is used
# before _ready: spawn code assigns uuid right after instantiate(), before the node enters the tree.
var _sync: PropSync:
	get:
		if not is_instance_valid(_sync):
			_sync = PropSync.of(self)
		return _sync

# Networking facade: expose the PropSync child's uuid on the body so the depot can be resolved
# as a networked parent by uuid (same inline pattern as spawn_building).
var uuid: String:
	get:
		return _sync.uuid if _sync != null else ""
	set(value):
		if _sync != null:
			_sync.uuid = value


func _ready() -> void:
	if not Engine.is_editor_hint() and not GameOrchestrator.is_server():
		# The client's platform is a frozen replica, KINEMATIC under its Platform System
		# (PropNet.apply_ride_freeze_mode), placed by the network alone. The scene's axis locks are
		# for the server's spring simulation, and they hold in WORLD axes: a locked kinematic body
		# cannot follow its planet along the orbit, so the platform stayed behind in space —
		# 1.5e6 m away after a minute, its kiosk out of every player's reach (2026-10-13).
		axis_lock_linear_x = false
		axis_lock_linear_z = false
		axis_lock_angular_x = false
		axis_lock_angular_y = false
		axis_lock_angular_z = false
	if not Engine.is_editor_hint() and GameOrchestrator.is_server():
		contact_monitor = true
		max_contacts_reported = 10
		# Dynamic on the server: _integrate_forces weighs the load from the contacts, and a frozen body
		# gets no such callback. The scene keeps freeze on for the editor and the client replicas.
		# Until 2026-10-13 the server's settle-culler did this by accident when it woke the platform;
		# it no longer touches it (Server._is_cullable_body), so the platform says it itself.
		freeze = false

		await get_tree().physics_frame
		await get_tree().physics_frame

		var parent_system_platform: Node3D = get_parent()
		if parent_system_platform.has_method("platform_spawned"):
			parent_system_platform.platform_spawned()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if Engine.is_editor_hint() or not GameOrchestrator.is_server():
		return

	var total_force_in_newtons: float = 0.0
	var local_gravity: Vector3 = state.total_gravity
	var up_direction: Vector3 = -local_gravity.normalized()
	var gravity_magnitude: float = local_gravity.length()

	for i in state.get_contact_count():
		var object_in_contact: Object = state.get_contact_collider_object(i)
		var normal: Vector3 = state.get_contact_local_normal(i)

		if normal.dot(up_direction) <- 0.5:
			var impulse: Vector3 = state.get_contact_impulse(i)
			_total_impulse_force += abs(impulse.dot(up_direction)) / state.step

			_unique_bodies_on_platform[object_in_contact] = true

	var total_static_force: float = 0.0
	for body in _unique_bodies_on_platform:
		if body is RigidBody3D:
			total_static_force += body.mass * gravity_magnitude
		if body is VehicleBody3D:
			## WARNING Le Vehicle n'est pas détecté comme en contact avec la plateforme
			total_static_force += body.mass * gravity_magnitude
		if body is CharacterBody3D and "mass" in body:
			total_static_force += body.mass * gravity_magnitude

	total_force_in_newtons = max(total_static_force, _total_impulse_force) + _player_custom_force
	_player_custom_force = 0.0

	if gravity_magnitude > 0.001:
		_weight_on_platform = total_force_in_newtons / gravity_magnitude
	else:
		_weight_on_platform = 0.0

	_unique_bodies_on_platform.clear()
	_total_impulse_force = 0.0

	#print_rich("[color=green]weight on platform = %.1f[/color]" % _weight_on_platform)

			## INFO seulement serveur
	if _sync != null:
		_sync.server_prop_update({
			"weight_on_platform": _weight_on_platform
		})



func add_kinematic_force(force: float) -> void:
	if Engine.is_editor_hint() or not GameOrchestrator.is_server():
		return

	_player_custom_force += force
	sleeping = false


func update_display_progress(progress: float, eta: int, status: String) -> void:
	if _platform_interface:
		_platform_interface.display_progress(progress, eta, status)


func update_screen(data: Dictionary):
	var action: Dictionary = data["elevator_screen_action"]

	## TODO très moche, à corriger
	var vehicle_lift = get_parent().get_parent()

	if vehicle_lift == null or not vehicle_lift is VehicleLift:
		push_error("vehicle_lift non présent ou n'est pas un VehicleLift dans %s" % name)
		return

	if action.has("button"):
		match action["button"]:
			"down":
				vehicle_lift.move_down()
			"stop":
				vehicle_lift.stop_movement()
			"up":
				vehicle_lift.move_up()
			_:
				pass


## SERVER, screen contract (ScreenTarget): who sent the screen action about to be handled. The
## crosshair points at the kiosk's screen; there is no zone in front of it any more.
func set_screen_actor(player: Player) -> void:
	active_player = player


## CLIENT: a button of the kiosk's screen. ScreenTarget.send names this screen in the action, so the
## server finds it again and checks the player is within reach of it.
func _on_call_button_triggered(datas: Dictionary) -> void:
	if GameOrchestrator.is_server():
		return
	ScreenTarget.send(self, {"elevator_screen_action": datas})

# PropSync applies the replicated transform, then calls this with the full payload so the depot can
# apply its own machine state. Replaces the old client_channel_data_update override.
func apply_prop_data(_data: Dictionary) -> void:
	if "weight_on_platform" in _data:
		_weight_on_platform = _data["weight_on_platform"]
		if not GameOrchestrator.is_server() and _platform_interface:
			_platform_interface.display_new_weight(_weight_on_platform)

func debug_reset_position() -> void:
	position = Vector3(0.0,0.0,2.425)
