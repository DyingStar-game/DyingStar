extends RigidBody3D


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
	if not Engine.is_editor_hint() and GameOrchestrator.is_server():
		contact_monitor = true
		max_contacts_reported = 10
		
		await get_tree().physics_frame
		await get_tree().physics_frame
		
		#set_freeze_enabled(false)
		
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


func _physics_process(delta: float) -> void:
	#print("platform !!")
	pass



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


## Where a player's camera should look while using this screen: the screen SURFACE, not the depot's
## origin (they are metres apart). Part of the informal "3D screen" contract — PlayerClient calls it
## when present and falls back to the node itself, so a simpler screen needs nothing at all.
func screen_look_target() -> Node3D:
	var screen = get_node_or_null("Kiosk/Kiosk Pivot Base Arm 01/Kiosk Arm 01/Kiosk Pivot Z Arm 01 Arm 02/Kiosk Pivot Y Arm 01 Arm 02/Kiosk Arm 02/Kiosk Z Pivot Arm 02 BallJoint/Kiosk Ball Joint/Kiosk Tablet/Screen Display")
	return screen as Node3D


## 3D-screen contract: a player's proximity monitor gained (or lost) this console. The PLAYER owns
## `screen_interacting` and is the single active monitor of the game (Player.connect_area_detect), so
## all we do here is note who is using the machine.
## This used to be a pair of body_entered / body_exited handlers on our own Area3D, with a half-second
## grace period bolted on to survive the planet's spin. Both are gone: an area-to-area overlap cannot
## desynchronise across a moving frame, so there is no false exit left to absorb (see ScreenZone).
func screen_focus_changed(player: Player, focused: bool) -> void:
	if focused:
		active_player = player
		return
	if is_instance_valid(active_player) and active_player.client_uuid == player.client_uuid:
		active_player = null


func _on_call_button_triggered(datas: Dictionary) -> void:
	if GameOrchestrator.is_server():
		return
	
	var player: Player = NetworkOrchestrator.network_agent.player_entity
	player.client_send_action_to_server({
		"action": "screen_state",
		"elevator_screen_action": datas
	})
	pass

# PropSync applies the replicated transform, then calls this with the full payload so the depot can
# apply its own machine state. Replaces the old client_channel_data_update override.
func apply_prop_data(_data: Dictionary) -> void:
	if "weight_on_platform" in _data:
		_weight_on_platform = _data["weight_on_platform"]
		if not GameOrchestrator.is_server() and _platform_interface:
			_platform_interface.display_new_weight(_weight_on_platform)

func debug_reset_position() -> void:
	position = Vector3(0.0,0.0,2.425)
