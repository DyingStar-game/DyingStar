@tool
class_name VehicleLift
extends Node3D


@export_range(0.0, 100.0, 0.01, "suffix:%") var platform_progress_ratio: float = 0.0:
	set(value):
		#if not GameOrchestrator.is_server():
			#print_rich("[color=crimson][client][/color][color=gold] set platform_progress_ratio :[/color]")
		#else:
			#print_rich("[color=dodger_blue][server][/color][color=gold] set platform_progress_ratio :[/color]")
		platform_progress_ratio = value
		_update_platform_movement()

@export_range(0.0, 4.0, 0.01, "suffix:m") var guide_z_offset: float = 0.0:
	set(value):
		guide_z_offset = max(0.0, value)		# INFO Décalage du bord de la falaise
		update_gizmos()
		_update_visuals()

@export_range(3.0, 1000.0, 0.01, "suffix:m") var descent_depth: float = 3.0:
	set(value):
		descent_depth = max(0.0, value)			# INFO Profondeur de descente
		update_gizmos()
		_update_visuals()


@export_group("Lift Dynamics")
@export_range(0.1, 10.0, 0.01, "suffix:m/s") var max_speed: float = 5.0
@export_range(0.1, 10.0, 0.01, "suffix:m/s") var acceleration: float = 2.0


@export_group("Debug")
@export var debug_move_up: bool = false:
	set(value):
		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return
		if value == true:
			move_up()
		debug_move_up = false

@export var debug_stop_movement: bool = false:
	set(value):
		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return
		if value == true:
			stop_movement()
		debug_stop_movement = false

@export var debug_move_down: bool = false:
	set(value):
		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return
		if value == true:
			move_down()
		debug_move_down = false

@export var debug_reset_platform: bool = false:
	set(value):
		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return
		print_rich("[color=dodger_blue][server][/color] debug_reset_platform")
		if value == true:
			reset_platform()
		debug_reset_platform = false

func reset_platform() -> void:
	var platform_system = get_node_or_null("Platform System")
	if not platform_system:
		return
	print("platform_system.position = %.1v" % platform_system.position)
	platform_system.position = PLATFORM_SYSTEM_INITIAL_POSITION
	var platform = platform_system.get_node_or_null("Platform")
	if platform and platform.has_method("debug_reset_position"):
		platform.debug_reset_position()
	print("platform_system.position = %.1v" % platform_system.position)


const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

const PLATFORM_SYSTEM_INITIAL_POSITION: Vector3 = Vector3(0.0,-0.175,2.075)
const LOWER_LANDING_INITIAL_POSITION: Vector3 = Vector3(0.0,0.0,0.0)

const BASE_SCENE: PackedScene = preload("res://addons/vehicle_lift/base/base.tscn")
const UPPER_LANDING_SCENE: PackedScene = preload("res://addons/vehicle_lift/landings/upper_landing/upper_landing.tscn")
const LOWER_LANDING_SCENE: PackedScene = preload("res://addons/vehicle_lift/landings/lower_landing/lower_landing.tscn")
const RAIL_HEAD_SCENE: PackedScene = preload("res://addons/vehicle_lift/rail/rail_head.tscn")
const RAIL_SEGMENT_SCENE: PackedScene = preload("res://addons/vehicle_lift/rail/rail_segment.tscn")
const PLATFORM_SYSTEM_SCENE: PackedScene = preload("res://addons/vehicle_lift/platform/platform_system.tscn")
const RAILING_LIBRARY_SCENE: PackedScene = preload("res://addons/vehicle_lift/railing/railing_segments.tscn")
const DYNAMIC_BRIDGEs_SCENE: PackedScene = preload("res://addons/vehicle_lift/dynamic_bridge/dynamic_bridges.tscn")


var _target_ratio: float = 0.0
var _current_speed: float = 0.0
var _is_moving: bool = false
var _current_direction: float = 1.0
var _ui_update_timer: float = 0.0
var _is_platform_system_spawned: bool = false


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


static func generate_railings(parent_node: Node3D, json_path: String) -> void:
	if parent_node.has_node("Visuals"):
		return
	
	var node_owner: Node = null
	if Engine.is_editor_hint():
		node_owner = parent_node.get_tree().edited_scene_root
		if node_owner == null:
			node_owner = parent_node
	print_rich("node_owner = [color=orange]%s[/color]" % node_owner.name)
	
	var json_file: FileAccess = FileAccess.open(json_path, FileAccess.READ)
	var json: JSON = JSON.new()
	var error: Error = json.parse(json_file.get_as_text())
	
	if error != OK:
		push_error("Erreur de lecture du JSON à la ligne ", json.get_error_line(), " : ", json.get_error_message())
		return
	
	var railing_visuals: Node3D = Node3D.new()
	railing_visuals.name = "Visuals"
	parent_node.add_child(railing_visuals)
	if node_owner:
		railing_visuals.owner = node_owner
	
	var railing_library: Node3D = RAILING_LIBRARY_SCENE.instantiate()
	
	var item_index: int = 0
	for item in json.data:
		var railing_type: String = "Railing " + str(item["type"])
		var railing_source_node: Node3D = railing_library.get_node_or_null(railing_type)
		
		if railing_source_node:
			var railing_segment: Node3D = railing_source_node.duplicate()
			railing_segment.name = "Railing Segment %d" % item_index
			railing_segment.show()
			
			railing_segment.position = Vector3(item["position"][0], item["position"][1], item["position"][2])
			railing_segment.rotation = Vector3(item["rotation"][0], item["rotation"][1], item["rotation"][2])
			
			railing_visuals.add_child(railing_segment)
			
			if node_owner:
				print_rich("\t[color=green]Il y a un node_owner, j'appel _set_owner_recursive pour %s[/color]" % railing_segment.name)
				_set_owner_recursive(railing_segment, node_owner)
			else:
				print_rich("\t[color=red]Il n'y a pas de node_owner pour %s[/color]" % railing_segment.name)
		else:
			push_warning("Type de garde-corps introuvable dans la bibliothèque : " + railing_type)
		
		item_index += 1
	
	railing_library.queue_free()


static func _set_owner_recursive(node: Node, new_owner: Node) -> void:
	node.owner = new_owner
	for child in node.get_children():
		_set_owner_recursive(child, new_owner)


func _ready() -> void:
	print_rich("[color=green]Vehicule lift Ready ![/color]")
	set_physics_process(false)
	
	var node_owner: Node = null
	if Engine.is_editor_hint():
		node_owner = get_tree().edited_scene_root
		if node_owner == null:
			node_owner = self
	else:
		node_owner = self
	
	if not has_node("PropSync"):
		print_rich("\t[color=green]Ajout du PropSync![/color]")
		var prop_sync: PropSync = PropSync.new()
		prop_sync.name = "PropSync"
		prop_sync.type_name = "vehicle_lift"
		add_child(prop_sync)
		
		if node_owner:
			prop_sync.owner = node_owner
	else:
		print_rich("\t[color=red]PropSync est déjà présent[/color]")
		print("Y'a un PropSync : %s" % self.get_node_or_null("PropSync"))
	
	if not has_node("Base"):
		var base: StaticBody3D = BASE_SCENE.instantiate()
		base.name = "Base"
		add_child(base)
		
		if node_owner:
			base.owner = node_owner
	
	if not has_node("Upper Landing"):
		var upper: StaticBody3D = UPPER_LANDING_SCENE.instantiate()
		upper.name = "Upper Landing"
		add_child(upper)
		
		if node_owner:
			upper.owner = node_owner
	
	if not has_node("Lower Landing"):
		var lower: StaticBody3D = LOWER_LANDING_SCENE.instantiate()
		lower.name = "Lower Landing"
		add_child(lower)
		
		if node_owner:
			lower.owner = node_owner
	
	if not has_node("Rail Head"):
		var rail_head: StaticBody3D = RAIL_HEAD_SCENE.instantiate()
		rail_head.name = "Rail Head"
		add_child(rail_head)
		
		if node_owner:
			rail_head.owner = node_owner
	
	if not has_node("Rail Segments"):
		var rail_segments: StaticBody3D = StaticBody3D.new()
		rail_segments.name = "Rail Segments"
		rail_segments.collision_mask = 0
		add_child(rail_segments)
		
		var rail_segments_visuals: Node3D = Node3D.new()
		rail_segments_visuals.name = "Visuals"
		rail_segments.add_child(rail_segments_visuals)
		
		var rail_segments_collider: CollisionShape3D = CollisionShape3D.new()
		rail_segments_collider.name = "Collider"
		rail_segments_collider.shape = BoxShape3D.new()
		rail_segments.add_child(rail_segments_collider)
		
		if node_owner:
			rail_segments.owner = node_owner
			rail_segments_visuals.owner = node_owner
			rail_segments_collider.owner = node_owner
	
	if not has_node("Dynamic Bridges"):
		var dynamic_bridges: Node3D = DYNAMIC_BRIDGEs_SCENE.instantiate()
		dynamic_bridges.name = "Dynamic Bridges"
		add_child(dynamic_bridges)
		
		if node_owner:
			dynamic_bridges.owner = node_owner
	
	if not Engine.is_editor_hint() and GameOrchestrator.is_server() and not _is_platform_system_spawned:
		print_rich("[color=dodger_blue][server][/color][color=gold] ready : [/color][color=red]flag de platform_system non présent, je la spawn[/color]")
		var data := {
			"type": "vehicle_lift_platformsystem",
			"uuid": UUID_UTIL.new().as_string(),
			"position": {
				"x": PLATFORM_SYSTEM_INITIAL_POSITION.x,
				"y": PLATFORM_SYSTEM_INITIAL_POSITION.y,
				"z": PLATFORM_SYSTEM_INITIAL_POSITION.z
			},
			"rotation": {
				"x": 0.0,
				"y": 0.0,
				"z": 0.0
			},
			"scenename": "addons/vehicle_lift/platform/platform_system.tscn",
			"parent_id": uuid,
			"name": "Platform System"
		}
		NetworkOrchestrator.spawn_prop_authoritative(data)
	elif not Engine.is_editor_hint() and GameOrchestrator.is_server():
		print_rich("[color=dodger_blue][server][/color][color=gold] ready : [/color][color=green]flag de platform_system déjà présent[/color]")
	
	_update_visuals()


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or descent_depth <= 0.001:
		set_physics_process(false)
		return
	
	if not GameOrchestrator.is_server():
		return
	
	var current_depth_in_meter: float = (platform_progress_ratio / 100.0) * descent_depth
	var target_depth_in_meter: float = (_target_ratio / 100.0) * descent_depth
	var distance_to_target: float = abs(target_depth_in_meter - current_depth_in_meter)
	
	var stopping_distance = (_current_speed * _current_speed) / (2.0 * acceleration)
	
	var desired_direction: float = 1.0 if target_depth_in_meter >= current_depth_in_meter else -1.0
	
	if _is_moving:
		# Freiner avant le changement de direction
		if _current_speed > 0.0 and _current_direction != desired_direction:
			_current_speed -= acceleration * _delta
		else:
			# Arrêt complet -> Changement de direction
			_current_direction = desired_direction
			
			# Accélération / Décélération
			if distance_to_target <= stopping_distance:
				_current_speed -= acceleration * _delta
			else:
				_current_speed += acceleration * _delta
	else:
		_current_speed -= acceleration * _delta
	
	_current_speed = clamp(_current_speed, 0.0, max_speed)
	var frame_movement: float = _current_speed * _delta
	
	if _is_moving and _current_direction == desired_direction and distance_to_target <= frame_movement:
		current_depth_in_meter = target_depth_in_meter
		_current_speed = 0.0
		_is_moving = false
		set_physics_process(false)
			## INFO seulement serveur
		if _sync != null:
			_sync.server_prop_update({
				"is_moving": _is_moving
			})
		#_on_lift_stopped()
	else:
		current_depth_in_meter += frame_movement * _current_direction
		
		if not _is_moving and _current_speed <= 0.0:
			_current_speed = 0.0
			set_physics_process(false)
			#_on_lift_stopped()
			
		elif current_depth_in_meter <= 0.0 or current_depth_in_meter >= descent_depth:
			current_depth_in_meter = clamp(current_depth_in_meter, 0.0, descent_depth)
			_current_speed = 0.0
			_is_moving = false
			set_physics_process(false)
			## INFO seulement serveur
			if _sync != null:
				_sync.server_prop_update({
					"is_moving": _is_moving
				})
			#_on_lift_stopped()
	
	platform_progress_ratio = (current_depth_in_meter / descent_depth) * 100.0
	
	## INFO seulement serveur
	if _sync != null:
		#print_rich("[color=dodger_blue][server][/color] platform_progress_ratio = %.1f" % platform_progress_ratio)
		_sync.server_prop_update({
			"platform_progress_ratio": platform_progress_ratio
		})
	
	## INFO serveur et client (fait automatiquement ?)
	#apply_prop_data()


func _update_visuals() -> void:
	var base: Node3D = get_node_or_null("Base")
	var upper_landing: Node3D = get_node_or_null("Upper Landing")
	var lower_landing: Node3D = get_node_or_null("Lower Landing")
	var rail_head: Node3D = get_node_or_null("Rail Head")
	var rail_segments: Node3D = get_node_or_null("Rail Segments")
	var dynamic_bridges: Node3D = get_node_or_null("Dynamic Bridges")
	
	if base:
		base.set_axis_length(guide_z_offset)
	
	if upper_landing:
		upper_landing.position = Vector3(0, 0, guide_z_offset)
	
	if lower_landing:
		lower_landing.position = LOWER_LANDING_INITIAL_POSITION + Vector3(0, -descent_depth, guide_z_offset)
	
	if rail_head:
		rail_head.position = Vector3(0, 0, guide_z_offset)
	
	if rail_segments:
		var node_owner: Node = null
		if Engine.is_editor_hint():
			node_owner = get_tree().edited_scene_root
			if node_owner == null:
				node_owner = self
		
		rail_segments.position = Vector3(0, 0, guide_z_offset)
		
		var segment_height: float = 3.0
		var nb_segments: int = ceili(descent_depth / segment_height) + 1
		
		var rail_segments_visuals: Node3D = rail_segments.get_node_or_null("Visuals")
		if rail_segments_visuals:
			var current_segment_index: int = rail_segments_visuals.get_child_count()
			
			for segment_index in range(current_segment_index, nb_segments):
				var segment = RAIL_SEGMENT_SCENE.instantiate()
				segment.name = "Rail Segment %d" % segment_index
				
				var pos: Vector3 = Vector3(0.0, -(segment_index * segment_height + 1.5), 0.0)
				segment.position = pos
				rail_segments_visuals.add_child(segment)
				
				if node_owner:
					segment.owner = node_owner
			
			if current_segment_index > nb_segments:
				for segment_index in range(current_segment_index - 1, nb_segments - 1, -1):
					var segment = rail_segments_visuals.get_child(segment_index)
					rail_segments_visuals.remove_child(segment)
					segment.queue_free()
		
		var rail_segments_collider: CollisionShape3D = rail_segments.get_node_or_null("Collider")
		
		if rail_segments_collider and rail_segments_collider.shape:
			var total_height = nb_segments * segment_height
			rail_segments_collider.shape.size = Vector3(2.67, total_height, 0.5)
			rail_segments_collider.position = Vector3(0, -total_height / 2.0, 2.25)
	
	if dynamic_bridges:
		dynamic_bridges.update_length(guide_z_offset)
		dynamic_bridges.update_collider_position(guide_z_offset)
	
	_update_platform_movement()


func _update_platform_movement() -> void:
	if not Engine.is_editor_hint() and not GameOrchestrator.is_server():
		return
	
	if not GameOrchestrator.is_server():
		print_rich("[color=crimson][client][/color][color=gold] _update_platform_movement :[/color]")
	#else:
		#print_rich("[color=dodger_blue][server][/color][color=gold] _update_platform_movement :[/color]")
	
	var platform = get_node_or_null("Platform System") as AnimatableBody3D
	
	if platform:
		var target_y: float = lerpf(0.0, -descent_depth, (platform_progress_ratio / 100.0))
		var target_position: Vector3 = PLATFORM_SYSTEM_INITIAL_POSITION + Vector3(0, target_y, guide_z_offset)
		#print_rich("\t[color=green]Il y a une plateforme[/color] target_position = [color=orange]%.1v[/color]" % target_position)
		
		### INFO Ne fonctionne pas en ligne: probablement à cause du mouvement combiné (planete, orbite)
		#if Engine.is_editor_hint():
			### INFO Déplacement par position (peut provoquer des "sauts" physiques en jeu)
			#platform.position = target_position
		#else:
			### INFO Déplacement physique (censé poser moins de problème : pas probant)
			#var platform_motion: Vector3 = target_position - platform.position
			##print_rich("\t[color=gold]platform_motion = [/color][color=green]%.1v[/color]" % platform_motion)
			#
			#platform.move_and_collide(platform_motion)
		platform.position = target_position
		
		#print_rich("\t[color=green]elevator.position[/color] = [color=orange]%.1v[/color] [color=green]elevator.global_position[/color] = [color=orange]%.1v[/color]" % [position, self.global_position])
		#print_rich("\t[color=green]platform.position[/color] = [color=orange]%.1v[/color] [color=green]platform.global_position[/color] = [color=orange]%.1v[/color]" % [platform.position, platform.global_position])
		#print_rich("\t[color=green]target_position[/color] = [color=orange]%.1v[/color] [color=green]target_y[/color] = [color=orange]%.1f[/color]" % [target_position, target_y])
	else:
		#print_rich("\t[color=red]Il n'y a pas de plateforme[/color]")
		pass


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or GameOrchestrator.is_server():
		return
	
	var base: Node3D = get_node_or_null("Base") as StaticBody3D
	var platform: Node3D = get_node_or_null("Platform System") as AnimatableBody3D
	
	var current_depth_in_meter: float = (platform_progress_ratio / 100.0) * descent_depth
	var target_depth_in_meter: float = (_target_ratio / 100.0) * descent_depth
	var distance_to_target: float = abs(target_depth_in_meter - current_depth_in_meter)
	
	var stopping_distance = (_current_speed * _current_speed) / (2.0 * acceleration)
	
	_ui_update_timer += _delta
	if _ui_update_timer >= 1.0:
		_ui_update_timer = 0.0
		
		var eta: int = 0
		if _is_moving:
			var eta_float: float = 0.0
			
			if distance_to_target <= stopping_distance:
				if acceleration > 0.0:
					eta_float = _current_speed / acceleration
			else:
				var cruise_time: float = distance_to_target / max_speed
				var braking_penalty = max_speed / (2.0 * acceleration)
				var accel_penalty = pow(max_speed - _current_speed, 2) / (2.0 * max_speed * acceleration)
				
				eta_float = cruise_time + braking_penalty + accel_penalty
			
			eta = ceili(eta_float)
			
			var upper_landing: Node3D = get_node_or_null("Upper Landing")
			var lower_landing: Node3D = get_node_or_null("Lower Landing")
			
			if upper_landing:
				upper_landing.update_interface_lift_progress(platform_progress_ratio, eta, "Going Up" if _current_direction < 0.0 else "Going Down")
			if lower_landing:
				lower_landing.update_interface_lift_progress(platform_progress_ratio, eta, "Going Up" if _current_direction < 0.0 else "Going Down")
			if platform:
				platform.update_interface_lift_progress(platform_progress_ratio, eta, "Going Up" if _current_direction < 0.0 else "Going Down")
	
	if base:
		base.set_axis_length(guide_z_offset)
		base.update_animated_axis_rotation(platform_progress_ratio, descent_depth)


func move_down() -> void:
	if platform_progress_ratio >= 100.0:
		return
	
	if not _is_moving and _current_speed <= 0.0:
		_target_ratio = 100.0
		_is_moving = true
		set_physics_process(true)
		
			## INFO seulement serveur
		if _sync != null:
			_sync.server_prop_update({
				"is_moving": _is_moving
			})


func move_up() -> void:
	if platform_progress_ratio <= 0.0:
		return
	
	if not _is_moving and _current_speed <= 0.0:
		_target_ratio = 0.0
		_is_moving = true
		set_physics_process(true)
		
			## INFO seulement serveur
		if _sync != null:
			_sync.server_prop_update({
				"is_moving": _is_moving
			})


func stop_movement() -> void:
	_is_moving = false
	_ui_update_timer = 0.0
	
		## INFO seulement serveur
	if _sync != null:
		_sync.server_prop_update({
			"is_moving": _is_moving
		})


func _on_lift_started() -> void:
	var upper_landing: Node3D = get_node_or_null("Upper Landing")
	var lower_landing: Node3D = get_node_or_null("Lower Landing")
	
	if upper_landing:
		upper_landing.start_beacons()
	if lower_landing:
		lower_landing.start_beacons()


func _on_lift_stopped() -> void:
	var upper_landing: Node3D = get_node_or_null("Upper Landing")
	var lower_landing: Node3D = get_node_or_null("Lower Landing")
	var platform: Node3D = get_node_or_null("Platform System")
	
	if upper_landing:
		upper_landing.stop_beacons()
		upper_landing.update_interface_lift_progress(platform_progress_ratio, 0, "Stopped")
	if platform:
		platform.update_interface_lift_progress(platform_progress_ratio, 0, "Stopped")
	if lower_landing:
		lower_landing.stop_beacons()
		lower_landing.update_interface_lift_progress(platform_progress_ratio, 0, "Stopped")


func platform_system_spawned() -> void:
	print_rich("[color=green]La plateform_system de %s a spawn[/color]" % name)
	_is_platform_system_spawned = true
	if _sync != null:
		_sync.server_prop_update({
			"is_platformsystem_spawned": _is_platform_system_spawned
	})


# PropSync applies the replicated transform, then calls this with the full payload so the depot can
# apply its own machine state. Replaces the old client_channel_data_update override.
func apply_prop_data(_data: Dictionary) -> void:
	#if not GameOrchestrator.is_server():
		#print_rich("[color=crimson][client][/color][color=gold] apply_prop_data :[/color]")
	#else:
		#print_rich("[color=dodger_blue][server][/color][color=gold] apply_prop_data :[/color]")
	
	if "name" in _data and not name == _data["name"]:
		name = _data["name"]
	if "descent_depth" in _data:
		descent_depth = _data["descent_depth"]
	if "guide_z_offset" in _data:
		guide_z_offset = _data["guide_z_offset"]
	if "max_speed" in _data:
		max_speed = _data["max_speed"]
	if "acceleration" in _data:
		acceleration = _data["acceleration"]
	if "platform_progress_ratio" in _data:
		platform_progress_ratio = _data["platform_progress_ratio"]
	if "is_platformsystem_spawned" in _data:
		_is_platform_system_spawned = _data["is_platformsystem_spawned"]
	if "is_moving" in _data:
		var last_moving_state: bool = _is_moving
		_is_moving = _data["is_moving"]
		
		if not GameOrchestrator.is_server():
			if _is_moving != last_moving_state:
				if _is_moving:
					_on_lift_started()
				else:
					_on_lift_stopped()
