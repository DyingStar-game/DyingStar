@tool
class_name VehicleLift
extends Node3D


## Where the platform stands on its run (%): 0 = at the upper landing, 100 = at the lower one. The
## server drives it while the lift moves; set it by hand in the editor to preview a position.
@export_range(0.0, 100.0, 0.01, "suffix:%") var platform_progress_ratio: float = 0.0:
	set(value):
		platform_progress_ratio = value

		if not Engine.is_editor_hint() and not GameOrchestrator.is_server():
			return

		_update_platform_movement()

## Horizontal distance (m) from the cliff edge (the lift's origin) out to the vertical guide the platform
## runs down, along +Z. 0 on a vertical wall; on a sloped face, at least the slope's run from the edge to
## its foot, or the platform rides into it. Raising it lengthens the bridges to the platform; past ~4 m the
## rail segments no longer touch the cliff.
@export_range(0.0, 500.0, 0.01, "suffix:m") var guide_z_offset: float = 0.0:
	set(value):
		guide_z_offset = max(0.0, value)		# INFO Décalage du bord de la falaise
		update_gizmos()
		_update_visuals()

		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return

		if _sync != null:
			_sync.server_prop_update({
				"guide_z_offset": guide_z_offset
		})

## Height (m) the platform travels down from the upper landing to the lower one, which stands on the ground
## at the foot. Raising it adds rail segments (one per 3 m) and lengthens every trip.
@export_range(3.0, 1000.0, 0.01, "suffix:m") var descent_depth: float = 3.0:
	set(value):
		descent_depth = max(0.0, value)			# INFO Profondeur de descente

		update_gizmos()
		_update_visuals()

		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return

		if _sync != null:
			_sync.server_prop_update({
				"descent_depth": descent_depth
		})


## Length (m) of the notch cut into the terrain under the lift, along +Z from the edge: on a sloped
## cliff, how far out the slope runs before it is down to the lower landing. 0 = no notch (a vertical
## wall, or open ground). Keep it under ~380 m (a notch reaches at most half a finest terrain chunk).
@export_range(0.0, 400.0, 0.1, "suffix:m") var notch_length_m: float = 0.0:
	set(value):
		notch_length_m = maxf(0.0, value)
		_update_notch()
		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return
		if _sync != null:
			_sync.server_prop_update({"notch_length_m": notch_length_m})

## Width (m) of that notch, centred on the lift: wider than the lower landing (22.2 m), or its sides
## stand in the rock.
@export_range(0.0, 100.0, 0.1, "suffix:m") var notch_width_m: float = NOTCH_DEFAULT_WIDTH_M:
	set(value):
		notch_width_m = maxf(0.0, value)
		_update_notch()
		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return
		if _sync != null:
			_sync.server_prop_update({"notch_width_m": notch_width_m})


@export_group("Lift Dynamics")
## Cruising speed of the platform (m/s). Higher = shorter trips; the screens' ETA follows.
@export_range(0.1, 10.0, 0.01, "suffix:m/s") var max_speed: float = 5.0
## Acceleration and braking of the platform (m/s²). Lower = gentler starts and stops, but longer
## trips (a short run may never reach max_speed).
@export_range(0.1, 10.0, 0.01, "suffix:m/s") var acceleration: float = 2.0

@export_group("Start / stop sound")
## Played at the platform when it starts or stops (each client, as it hears the lift change state).
## The winch's hum (Base/Animated Axis/WinchHum) and the cart's rolling (Platform System/RollingNoise)
## run in between: set them on those nodes.
@export var sfx_start_stop: AudioStream = preload(
		"res://assets/_universe/audio/sfx/structures/vehicle_lift/lift-platform-start-stop.mp3")
## Loudness in decibels (0 = the sample's own level, negative = quieter).
@export_range(-40.0, 12.0, 0.5) var sfx_start_stop_db: float = 2.0
## Reference distance (m) at which the sound has its nominal volume; past it, it starts fading.
@export_range(0.5, 200.0, 0.5) var sfx_start_stop_falloff: float = 10.0
## Distance (m) past which the sound is no longer audible at all (hard cut-off).
@export_range(1.0, 500.0, 1.0) var sfx_start_stop_distance: float = 100.0
## How the sound fades with distance.
@export var sfx_start_stop_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.REALISTIC
## Slowest the cart drawn on a client is heard rolling (m/s). Braking at 2 m/s², it drops under
## 0.15 m/s some 0.07 s before it rests: the rolling falls silent just before the stop's clunk.
@export_range(0.0, 2.0, 0.01, "suffix:m/s") var rolling_min_speed_m_s: float = 0.15

## Slowest the cart drawn on a client may still be moving (m/s) and be "at rest": the stop's clunk
## waits for it.
const REST_SPEED_M_S: float = 0.02


@export_group("Debug")
## SERVER, at run time: tick to send the platform up to the upper landing (unticks itself).
@export var debug_move_up: bool = false:
	set(value):
		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return
		if value == true:
			move_up()
		debug_move_up = false

## SERVER, at run time: tick to stop the platform where it is (unticks itself).
@export var debug_stop_movement: bool = false:
	set(value):
		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return
		if value == true:
			stop_movement()
		debug_stop_movement = false

## SERVER, at run time: tick to send the platform down to the lower landing (unticks itself).
@export var debug_move_down: bool = false:
	set(value):
		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return
		if value == true:
			move_down()
		debug_move_down = false

## SERVER, at run time: tick to put the platform back at its starting position (unticks itself).
@export var debug_reset_platform: bool = false:
	set(value):
		if Engine.is_editor_hint() or not GameOrchestrator.is_server():
			return

		if value == true:
			reset_platform()
		debug_reset_platform = false

func reset_platform() -> void:
	var platform_system = get_node_or_null("Platform System")
	if not platform_system:
		return

	platform_system.position = PLATFORM_SYSTEM_INITIAL_POSITION
	var platform = platform_system.get_node_or_null("Platform")
	if platform and platform.has_method("debug_reset_position"):
		platform.debug_reset_position()



const PLATFORM_SYSTEM_INITIAL_POSITION: Vector3 = Vector3(0.0,-0.175,2.075)
## Width of the notch under a lift when its data does not say (see notch_width_m).
const NOTCH_DEFAULT_WIDTH_M := 24.0
## How far under the lower landing's floor the notch's floor is: the lift's origin stands this high
## above the ground at the top (the hand-placed first lift), so the bottom gets the same step.
const NOTCH_FLOOR_BELOW_LANDING_M := 0.74
## Name of the TerrainNotch child the lift keeps in step with its dimensions.
const NOTCH_NODE_NAME := "TerrainNotch"
const LOWER_LANDING_INITIAL_POSITION: Vector3 = Vector3(0.0,0.0,0.0)

const LIFT_DIR: String = "res://scenes/_universe/structures/industrial/vehicle_lift/"
const BASE_SCENE: PackedScene = preload(LIFT_DIR + "base/base.tscn")
const UPPER_LANDING_SCENE: PackedScene = preload(LIFT_DIR + "landings/upper_landing/upper_landing.tscn")
const LOWER_LANDING_SCENE: PackedScene = preload(LIFT_DIR + "landings/lower_landing/lower_landing.tscn")
const RAIL_HEAD_SCENE: PackedScene = preload(LIFT_DIR + "rail/rail_head.tscn")
const RAIL_SEGMENT_SCENE: PackedScene = preload(LIFT_DIR + "rail/rail_segment.tscn")
const PLATFORM_SYSTEM_SCENE: PackedScene = preload(LIFT_DIR + "platform/platform_system.tscn")
const RAILING_LIBRARY_SCENE: PackedScene = preload(LIFT_DIR + "railing/railing_segments.tscn")
const DYNAMIC_BRIDGES_SCENE: PackedScene = preload(LIFT_DIR + "dynamic_bridge/dynamic_bridges.tscn")


var _target_ratio: float = 0.0
var _current_speed: float = 0.0
var _is_moving: bool = false
var _current_direction: float = 1.0
var _ui_update_timer: float = 0.0
var _is_platform_system_spawned: bool = false

var _travel_time: float = 0.0
## CLIENT: whether a moving state was heard already. The first one is how the lift was when we
## arrived: a lift found running is heard running, without the clunk of a start.
var _moving_heard: bool = false
## CLIENT: the stop's clunk waits for the platform drawn here to be at rest (_process); where the
## cart was drawn last frame, to tell how fast it goes; whether there was a last frame.
var _clunk_on_rest: bool = false
var _cart_drawn_at: Vector3 = Vector3.ZERO
var _cart_seen: bool = false


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
				_set_owner_recursive(railing_segment, node_owner)
		else:
			push_warning("Type de garde-corps introuvable dans la bibliothèque : " + railing_type)

		item_index += 1

	railing_library.queue_free()


static func _set_owner_recursive(node: Node, new_owner: Node) -> void:
	node.owner = new_owner
	for child in node.get_children():
		_set_owner_recursive(child, new_owner)


static func compute_travel_time(travel_distance: float, max_speed: float, p_acceleration: float) -> float:
	var computed_travel_time: float = 0.0

	if travel_distance <= 0.0 or max_speed <= 0.0 or p_acceleration <= 0.0:
		return computed_travel_time

	var threshold_distance: float = (max_speed * max_speed) / p_acceleration
	if travel_distance >= threshold_distance:
		var nonlinear_speed_time : float = (2.0 * max_speed) / p_acceleration
		var linear_speed_distance : float = travel_distance - threshold_distance
		var linear_speed_time : float = linear_speed_distance / max_speed

		computed_travel_time = nonlinear_speed_time + linear_speed_time
	else:
		var nonlinear_speed_time : float = sqrt(travel_distance / p_acceleration) * 2.0

		computed_travel_time = nonlinear_speed_time

	return computed_travel_time


func _ready() -> void:
	set_physics_process(false)

	var node_owner: Node = null
	if Engine.is_editor_hint():
		node_owner = get_tree().edited_scene_root
		if node_owner == null:
			node_owner = self
	else:
		node_owner = self

	if not has_node("PropSync"):
		var prop_sync: PropSync = PropSync.new()
		prop_sync.name = "PropSync"
		prop_sync.type_name = "vehicle_lift"
		add_child(prop_sync)

		if node_owner:
			prop_sync.owner = node_owner

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
		var dynamic_bridges: Node3D = DYNAMIC_BRIDGES_SCENE.instantiate()
		dynamic_bridges.name = "Dynamic Bridges"
		add_child(dynamic_bridges)

		if node_owner:
			dynamic_bridges.owner = node_owner

	if not Engine.is_editor_hint() and GameOrchestrator.is_server() and not _is_platform_system_spawned:
		# Deferred: create_generic_object registers us in props_list only after add_child, and the
		# platform system's parent_id is our uuid.
		spawn_platform_system.call_deferred()

	_update_visuals()


## SERVER: spawn the networked platform system under this lift, once. Its uuid is drawn from ours, so
## a lost is_platformsystem_spawned flag upserts the same platform instead of piling copies.
func spawn_platform_system() -> void:
	if _is_platform_system_spawned or not is_inside_tree() or uuid == "":
		return
	_is_platform_system_spawned = true  # before spawning: apply_prop_data runs again on every update
	var system_uuid := PropSpawn.stable_uuid("%s|platform_system" % uuid)
	NetworkOrchestrator.protected_prop_uuids[system_uuid] = true  # world infrastructure
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": "vehicle_lift_platformsystem",
		"uuid": system_uuid,
		"position": {
			"x": PLATFORM_SYSTEM_INITIAL_POSITION.x,
			"y": PLATFORM_SYSTEM_INITIAL_POSITION.y,
			"z": PLATFORM_SYSTEM_INITIAL_POSITION.z
		},
		"rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
		"scenename": PLATFORM_SYSTEM_SCENE.resource_path.trim_prefix("res://"),
		"parent_id": uuid,
		"name": "Platform System"
	})


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
	else:
		current_depth_in_meter += frame_movement * _current_direction

		if not _is_moving and _current_speed <= 0.0:
			_current_speed = 0.0
			set_physics_process(false)

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

	platform_progress_ratio = (current_depth_in_meter / descent_depth) * 100.0

	## INFO seulement serveur
	if _sync != null:
		_sync.server_prop_update({
			"platform_progress_ratio": platform_progress_ratio
		})


func _update_visuals() -> void:
	_update_notch()
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

	if not Engine.is_editor_hint() and not GameOrchestrator.is_server():
		return

	_update_platform_movement()


func _update_platform_movement() -> void:
	if not Engine.is_editor_hint() and not GameOrchestrator.is_server():
		return

	var platform = get_node_or_null("Platform System") as AnimatableBody3D

	if platform:
		var target_y: float = lerpf(0.0, -descent_depth, (platform_progress_ratio / 100.0))
		var target_position: Vector3 = PLATFORM_SYSTEM_INITIAL_POSITION + Vector3(0, target_y, guide_z_offset)

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



func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or GameOrchestrator.is_server():
		return

	var base: Node3D = get_node_or_null("Base") as StaticBody3D
	var platform_system: Node3D = get_node_or_null("Platform System") as AnimatableBody3D

	var current_depth_in_meter: float = (platform_progress_ratio / 100.0) * descent_depth
	var target_depth_in_meter: float = (_target_ratio / 100.0) * descent_depth
	var distance_to_target: float = abs(target_depth_in_meter - current_depth_in_meter)

	var stopping_distance = (_current_speed * _current_speed) / (2.0 * acceleration)

	var display_direction: float = 1.0 if target_depth_in_meter >= current_depth_in_meter else -1.0

	_sound_cart(_delta)

	_ui_update_timer += _delta
	if _ui_update_timer >= 1.0:
		_ui_update_timer = 0.0
		_travel_time -= 1.0

		var eta: int = 0
		if _is_moving:
			eta = ceili(_travel_time)

			var upper_landing: Node3D = get_node_or_null("Upper Landing")
			var lower_landing: Node3D = get_node_or_null("Lower Landing")

			if upper_landing:
				upper_landing.update_interface_lift_progress(platform_progress_ratio, eta, "Going Up" if display_direction < 0.0 else "Going Down")
			if lower_landing:
				lower_landing.update_interface_lift_progress(platform_progress_ratio, eta, "Going Up" if display_direction < 0.0 else "Going Down")
			if platform_system:
				platform_system.update_interface_lift_progress(platform_progress_ratio, eta, "Going Up" if display_direction < 0.0 else "Going Down")

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
				"is_moving": _is_moving,
				"target_ratio": _target_ratio
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
				"is_moving": _is_moving,
				"target_ratio": _target_ratio
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
	var current_depth_in_meter: float = (platform_progress_ratio / 100.0) * descent_depth
	var target_depth_in_meter: float = (_target_ratio / 100.0) * descent_depth
	var distance_to_target: float = abs(target_depth_in_meter - current_depth_in_meter)

	_travel_time = compute_travel_time(distance_to_target, max_speed, acceleration)

	var upper_landing: Node3D = get_node_or_null("Upper Landing")
	var lower_landing: Node3D = get_node_or_null("Lower Landing")

	if upper_landing:
		upper_landing.start_beacons()
	if lower_landing:
		lower_landing.start_beacons()
	_sound_running(true)


func _on_lift_stopped() -> void:
	_travel_time = 0.0

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
	_sound_running(false)


## CLIENT: the lift's machinery heard while it runs ([param running]): the winch at the top, and the
## clunk of the platform as it sets off — or, on a stop, once the platform drawn here is at rest
## (_sound_cart): the server says it stopped as it arrives, while the platform we draw still glides
## into place. The cart's rolling is _sound_cart's too.
func _sound_running(running: bool) -> void:
	var winch := get_node_or_null("Base/Animated Axis/WinchHum") as AmbientLoop3D
	if winch != null:
		winch.set_running(running)
	_clunk_on_rest = false
	if not _moving_heard:
		return  # how the lift was when we arrived: no start nor stop was heard
	if running:
		_play_clunk()
	else:
		_clunk_on_rest = true


## CLIENT: the clunk of the platform starting or stopping, at the cart.
func _play_clunk() -> void:
	if sfx_start_stop == null or Sfx3D.muted():
		return
	var cart: Node3D = get_node_or_null("Platform System") as Node3D
	Sfx3D.play(cart if cart != null else self, sfx_start_stop, sfx_start_stop_db, sfx_start_stop_falloff,
			sfx_start_stop_distance, sfx_start_stop_attenuation)


## CLIENT, every frame: the cart as it is DRAWN here decides its sounds — rolling while it goes, the
## stop's clunk once it rests. The server's word comes as the platform arrives, and the platform we
## draw glides on a little after it: the sounds follow what the player sees.
func _sound_cart(delta: float) -> void:
	var cart := get_node_or_null("Platform System") as Node3D
	if cart == null or delta <= 0.0:
		_cart_seen = false
		return
	var speed: float = cart.position.distance_to(_cart_drawn_at) / delta if _cart_seen else 0.0
	_cart_drawn_at = cart.position
	_cart_seen = true
	var rolling := cart.get_node_or_null("RollingNoise") as AmbientLoop3D
	if rolling != null:
		rolling.set_running(rolling_heard(speed, rolling_min_speed_m_s))
	if _clunk_on_rest and at_rest(speed):
		_clunk_on_rest = false
		_play_clunk()


## Whether the cart drawn here, going at [param speed] (m/s), is heard rolling: faster than
## [param min_speed] (rolling_min_speed_m_s).
static func rolling_heard(speed: float, min_speed: float) -> bool:
	return speed > min_speed


## Whether the cart drawn here, going at [param speed] (m/s), is at rest (REST_SPEED_M_S).
static func at_rest(speed: float) -> bool:
	return speed <= REST_SPEED_M_S


func platform_system_spawned() -> void:
	_is_platform_system_spawned = true
	if _sync != null:
		_sync.server_prop_update({
			"is_platformsystem_spawned": _is_platform_system_spawned
	})


# PropSync applies the replicated transform, then calls this with the full payload so the depot can
# apply its own machine state. Replaces the old client_channel_data_update override.
func apply_prop_data(_data: Dictionary) -> void:
	if "name" in _data and not name == _data["name"]:
		name = _data["name"]
	if "notch_width_m" in _data:
		notch_width_m = _data["notch_width_m"]
	if "notch_length_m" in _data:
		notch_length_m = _data["notch_length_m"]
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
	if "target_ratio" in _data:
		_target_ratio = _data["target_ratio"]
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
			_moving_heard = true


## Keep the TerrainNotch child in step with the lift: a box [member notch_width_m] wide and
## [member notch_length_m] long from the edge, down to the lower landing's ground. Created on first
## need, removed when the length goes back to 0. Never owned by the scene: it is derived, not saved.
func _update_notch() -> void:
	if not is_inside_tree():
		return
	var notch := get_node_or_null(NOTCH_NODE_NAME) as TerrainNotch
	if notch_length_m <= 0.0:
		if notch != null:
			notch.queue_free()
		return
	if notch == null:
		notch = TerrainNotch.new()
		notch.name = NOTCH_NODE_NAME
		add_child(notch)
	notch.width_m = notch_width_m
	notch.length_m = notch_length_m
	notch.floor_depth_m = descent_depth + NOTCH_FLOOR_BELOW_LANDING_M


## The notch record of a lift described by its network data [param od], standing at [param rel] in
## the terrain's frame — what the server registers for a lift that is not in the tree (asleep, not
## built yet), the very numbers its live TerrainNotch will state. {} when the lift has no notch.
static func notch_record_from_data(data, rel: Transform3D, od: Dictionary, uuid: String) -> Dictionary:
	var length := float(od.get("notch_length_m", 0.0))
	if length <= 0.0:
		return {}
	var rec := TerrainNotch.record_for(data, rel, float(od.get("notch_width_m", NOTCH_DEFAULT_WIDTH_M)),
			length, float(od.get("descent_depth", 3.0)) + NOTCH_FLOOR_BELOW_LANDING_M, uuid)
	return {} if rec.has("_refusal") else rec
