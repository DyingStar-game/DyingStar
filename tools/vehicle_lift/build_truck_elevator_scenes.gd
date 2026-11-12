extends Node
## Builds the truck elevator's scenes (scenes/_universe/structures/industrial/truck_elevator/) and its
## VehicleLiftModel from the GLB pieces tools/vehicle_lift/export_truck_elevator.py writes. Run it as a scene:
##
##     godot --headless --path . res://tools/vehicle_lift/build_truck_elevator_scenes.tscn
##
## Every scene follows the first lift's contract (LiftLanding, platform.gd, platform_system.gd...), so VehicleLift
## drives it with the same code. Rebuilding overwrites the scenes: change this script, not them.

const ASSETS := "res://assets/_universe/structures/industrial/truck_elevator/"
const OUT := "res://scenes/_universe/structures/industrial/truck_elevator/"
const LIFT := "res://scenes/_universe/structures/industrial/vehicle_lift/"
const SHARED := "res://assets/_universe/_shared/materials/"

# The call kiosks' screens in their piece's frame (export_truck_elevator.py reports them): centre and facing.
const TOP_SCREEN := [Vector3(-0.259, 1.175, -13.911), Vector3(-0.966, 0.259, 0.0)]
const PIT_SCREEN := [Vector3(0.117, -0.834, 20.629), Vector3(0.966, 0.259, 0.0)]
const PLATFORM_SCREEN := [Vector3(-4.49, 1.168, 4.431), Vector3(0.966, 0.259, 0.0)]
# The call kiosk in truck_elevator_kiosk.glb's frame (the top's), and where a level's kiosk stands: on the station's
# floor past the platform's front (8 m out), to one side of the way out, its screen facing the middle.
const KIOSK_IN_GLB := Vector3(-0.265, 0.0, -13.91)
# The platform's front ramp: its hinge (the ramp's origin in the .blend) on the deck's front edge, and its box (in the
# hinge's frame) when laid down: 9 m wide, 0.2 m thick, reaching 1.25 m past the hinge onto the landing.
const RAMP_HINGE := Vector3(0.0, -0.098, 7.853)
const RAMP_BOX_SIZE := Vector3(9.0, 0.2, 1.35)
const RAMP_BOX_CENTER := Vector3(-0.074, 0.0, 0.572)
const LEVEL_KIOSK := Vector3(6.5, 0.0, 10.0)
# The touch screen drawn over a kiosk's own small screen: large enough to read the lift's interface.
const SCREEN_SIZE := Vector2(0.36, 0.216)
const BEACON_HEIGHT := 1.8

# The tower: across x and out z from the guide (the platform's carriage runs in its first 0.8 m).
const TOWER_SIZE := Vector2(6.93, 6.13)
const TOWER_CENTER := Vector2(-0.075, -3.865)

var _beacon: PackedScene
var _interface: PackedScene
var _alarm_script: Script
var _steel: Material


func _ready() -> void:
	_beacon = load(LIFT + "common/beacon/beacon.tscn")
	_interface = load(LIFT + "common/screen/interfaces/lift_base_interface.tscn")
	_alarm_script = load("res://scenes/common/ambient_loop_3d.gd")
	_steel = load(SHARED + "mat_metal_yellow_hauling/mat_metal_yellow_hauling.tres")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_save(_section(), "section.tscn")
	_save(_upper_landing(), "upper_landing.tscn")
	_save(_lower_landing(), "lower_landing.tscn")
	_save(_level_landing(), "level_landing.tscn")
	_save(_platform(), "platform.tscn")
	_save(_platform_system(), "platform_system.tscn")
	_save_model()
	_save(_lift(), "truck_elevator.tscn")
	print("[build_truck_elevator] done")
	get_tree().quit()


func _save(root: Node, file: String) -> void:
	var scene := PackedScene.new()
	var err := scene.pack(root)
	if err == OK:
		err = ResourceSaver.save(scene, OUT + file)
	print("[build_truck_elevator] %s: %s" % [file, error_string(err)])
	root.free()


func _own(node: Node, owner_node: Node) -> Node:
	node.owner = owner_node
	return node


func _add(parent: Node, node: Node, owner_node: Node) -> Node:
	parent.add_child(node)
	node.owner = owner_node
	return node


## A piece of the model: a TruckElevatorPiece holding its GLB.
func _piece(parent: Node, piece_name: String, glb: String, root: Node, at := Vector3.ZERO) -> Node3D:
	var piece := Node3D.new()
	piece.name = piece_name
	piece.set_script(load(OUT + "truck_elevator_piece.gd"))
	piece.position = at
	_add(parent, piece, root)
	var model: Node3D = (load(ASSETS + "truck_elevator_%s.glb" % glb) as PackedScene).instantiate()
	model.name = "Model"
	_add(piece, model, root)
	return piece


## The kiosk's touch screen (Gui3D) on the kiosk's own screen, and the SubViewport it shows (a lift interface).
func _screen(parent: Node, root: Node, spec: Array, landing: int, buttons: String, interface_name: String) -> Control:
	var viewport := SubViewport.new()
	viewport.name = "Screen Display Interface"
	viewport.disable_3d = true
	viewport.size = Vector2i(500, 300)
	_add(parent, viewport, root)
	var interface: Control = _interface.instantiate()
	interface.name = interface_name
	interface.unique_name_in_owner = true
	interface.set("button_group_scene", load(LIFT + "common/screen/interfaces/%s.tscn" % buttons))
	interface.set("landing", landing)
	_add(viewport, interface, root)

	var normal: Vector3 = (spec[1] as Vector3).normalized()
	var screen := StaticBody3D.new()
	screen.name = "Screen Display"
	screen.collision_layer = 32
	screen.collision_mask = 0
	screen.set_script(load("res://scenes/interactables/gui_3d.gd"))
	screen.transform = Transform3D(Basis.looking_at(-normal, Vector3.UP), (spec[0] as Vector3) + normal * 0.015)
	_add(parent, screen, root)
	var quad := QuadMesh.new()
	quad.size = SCREEN_SIZE
	var visual := MeshInstance3D.new()
	visual.name = "Screen Display Visual"
	visual.mesh = quad
	var material := StandardMaterial3D.new()
	material.resource_local_to_scene = true
	visual.set_surface_override_material(0, material)
	_add(screen, visual, root)
	var body_shape := BoxShape3D.new()
	body_shape.size = Vector3(SCREEN_SIZE.x, SCREEN_SIZE.y, 0.02)
	var body_collider := CollisionShape3D.new()
	body_collider.name = "Collider"
	body_collider.shape = body_shape
	_add(screen, body_collider, root)
	var area := Area3D.new()
	area.name = "TouchScreen"
	area.monitoring = false
	_add(visual, area, root)
	var touch_shape := BoxShape3D.new()
	touch_shape.size = Vector3(SCREEN_SIZE.x, SCREEN_SIZE.y, 0.03)
	var touch := CollisionShape3D.new()
	touch.name = "CollisionShape3D"
	touch.shape = touch_shape
	_add(area, touch, root)
	screen.set("node_viewport", viewport)
	screen.set("node_quad", visual)
	screen.set("node_area", area)
	return interface


## The two beacons on posts and the departure alarm a LiftLanding drives.
func _beacons(parent: Node, root: Node, left: Vector3, right: Vector3) -> void:
	for side: Array in [["Beacon Left", left], ["Beacon Right", right]]:
		var post := MeshInstance3D.new()
		post.name = side[0] + " Post"
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.035
		cylinder.bottom_radius = 0.05
		cylinder.height = BEACON_HEIGHT
		cylinder.material = _steel
		post.mesh = cylinder
		post.position = (side[1] as Vector3) + Vector3(0.0, BEACON_HEIGHT * 0.5, 0.0)
		_add(parent, post, root)
		var beacon: Node3D = _beacon.instantiate()
		beacon.name = side[0]
		beacon.unique_name_in_owner = true
		beacon.position = (side[1] as Vector3) + Vector3(0.0, BEACON_HEIGHT, 0.0)
		_add(parent, beacon, root)
	var alarm := Node3D.new()
	alarm.name = "Departure Alarm"
	alarm.unique_name_in_owner = true
	alarm.set_script(_alarm_script)
	alarm.set("sound", load(LIFT + "sounds/alarm.tres"))
	alarm.set("autoplay", false)
	alarm.position = (left + right) * 0.5 + Vector3(0.0, BEACON_HEIGHT, 0.0)
	_add(parent, alarm, root)


func _prop_sync(root: Node, type_name: String, smooth: bool) -> void:
	var sync := Node.new()
	sync.name = "PropSync"
	sync.set_script(load("res://scenes/globals/prop_sync.gd"))
	sync.set("type_name", type_name)
	if smooth:
		sync.set("smooth_transform", true)
	_add(root, sync, root)


func _landing(landing_name: String, script_path: String) -> StaticBody3D:
	var root := StaticBody3D.new()
	root.name = landing_name
	root.collision_mask = 0
	root.set_script(load(script_path))
	return root


func _section() -> Node:
	var root := Node3D.new()
	root.name = "Section"
	root.set_script(load(OUT + "truck_elevator_piece.gd"))
	var model: Node3D = (load(ASSETS + "truck_elevator_section.glb") as PackedScene).instantiate()
	model.name = "Model"
	_add(root, model, root)
	return root


func _upper_landing() -> Node:
	var root := _landing("Upper Landing", LIFT + "landings/lift_landing.gd")
	root.set("is_upper", true)
	_piece(root, "Top", "top", root)
	_beacons(root, root, Vector3(-3.3, 0.0, -0.4), Vector3(3.2, 0.0, -0.4))
	root.set("landing_interface", _screen(root, root, TOP_SCREEN, 1, "landings_buttons", "Upper Landing Interface"))
	return root


func _lower_landing() -> Node:
	var root := _landing("Lower Landing", LIFT + "landings/lift_landing.gd")
	root.set("is_upper", false)
	_piece(root, "Base", "base", root)
	_piece(root, "Pit", "pit", root)
	_beacons(root, root, Vector3(-4.75, 0.0, 9.0), Vector3(4.6, 0.0, 9.0))
	root.set("landing_interface", _screen(root, root, PIT_SCREEN, 2, "landings_buttons", "Lower Landing Interface"))
	return root


## A stop's landing (a mine's level): no structure, the platform's front reaches the station's floor. On that floor,
## the call kiosk to one side of the way out and the beacons by the platform's front corners.
func _level_landing() -> Node:
	var root := _landing("Level Landing", LIFT + "landings/lift_landing.gd")
	root.set("is_upper", false)
	var shift := LEVEL_KIOSK - KIOSK_IN_GLB
	_piece(root, "Kiosk", "kiosk", root, shift)
	_beacons(root, root, Vector3(-5.2, 0.0, 8.6), Vector3(5.1, 0.0, 8.6))
	var spec := [(TOP_SCREEN[0] as Vector3) + shift, TOP_SCREEN[1]]
	root.set("landing_interface", _screen(root, root, spec, 1, "landings_buttons", "Level Landing Interface"))
	return root


func _platform() -> Node:
	var root := RigidBody3D.new()
	root.name = "Platform"
	root.collision_layer = 4
	root.collision_mask = 4
	root.input_ray_pickable = false
	root.axis_lock_linear_x = true
	root.axis_lock_linear_z = true
	root.axis_lock_angular_x = true
	root.axis_lock_angular_y = true
	root.axis_lock_angular_z = true
	root.mass = 4000.0
	var rough := PhysicsMaterial.new()
	rough.rough = true
	root.physics_material_override = rough
	root.freeze = true
	root.linear_damp = 1.0
	root.angular_damp = 1.0
	root.set_script(load(LIFT + "platform/platform.gd"))
	_prop_sync(root, "vehicle_lift_platform", true)
	_piece(root, "Platform Visuals", "platform", root)
	# The deck and the two side fences; open at the back (the tower) and the front.
	for part: Array in [["Platform Collider 01", Vector3(9.0, 0.3, 8.8), Vector3(-0.07, -0.15, 3.6)],
			["Platform Collider 02", Vector3(0.12, 1.1, 7.8), Vector3(-4.5, 0.55, 3.9)],
			["Platform Collider 03", Vector3(0.12, 1.1, 7.8), Vector3(4.37, 0.55, 3.9)]]:
		var shape := BoxShape3D.new()
		shape.size = part[1]
		var collider := CollisionShape3D.new()
		collider.name = part[0]
		collider.shape = shape
		collider.position = part[2]
		_add(root, collider, root)
	var ramp := AnimatableBody3D.new()
	ramp.name = "Ramp"
	ramp.collision_layer = root.collision_layer
	ramp.collision_mask = 0
	ramp.input_ray_pickable = false
	ramp.sync_to_physics = false
	ramp.position = RAMP_HINGE
	ramp.set_script(load(OUT + "truck_elevator_ramp.gd"))
	_add(root, ramp, root)
	_piece(ramp, "Ramp Visuals", "ramp", root, -RAMP_HINGE)
	var ramp_shape := BoxShape3D.new()
	ramp_shape.size = RAMP_BOX_SIZE
	var ramp_collider := CollisionShape3D.new()
	ramp_collider.name = "Ramp Collider"
	ramp_collider.shape = ramp_shape
	ramp_collider.position = RAMP_BOX_CENTER
	_add(ramp, ramp_collider, root)
	var area := Area3D.new()
	area.name = "Area Detection"
	area.collision_layer = 0
	area.collision_mask = 14
	area.input_ray_pickable = false
	area.monitorable = false
	area.set_script(load(LIFT + "platform/platform_area_detection.gd"))
	_add(root, area, root)
	area.add_to_group(&"active_monitor", true)
	var area_shape := BoxShape3D.new()
	area_shape.size = Vector3(8.8, 4.0, 9.0)
	var area_collider := CollisionShape3D.new()
	area_collider.name = "Collider"
	area_collider.shape = area_shape
	area_collider.position = Vector3(-0.07, 2.0, 4.1)
	_add(area, area_collider, root)
	root.set("_platform_interface", _screen(root, root, PLATFORM_SCREEN, 3, "platform_buttons", "Platform Interface"))
	return root


func _platform_system() -> Node:
	var root := AnimatableBody3D.new()
	root.name = "Platform System"
	root.collision_layer = 4
	root.collision_mask = 0
	root.input_ray_pickable = false
	root.axis_lock_linear_x = true
	root.axis_lock_linear_z = true
	root.axis_lock_angular_x = true
	root.axis_lock_angular_y = true
	root.axis_lock_angular_z = true
	root.sync_to_physics = false
	root.set_script(load(LIFT + "platform/platform_system.gd"))
	root.set("platform_scene_path", (OUT + "platform.tscn").trim_prefix("res://"))
	root.set("platform_offset", Vector3.ZERO)
	root.set("platform_railing_json", "")
	var cart := StaticBody3D.new()
	cart.name = "Cart"
	cart.collision_layer = 0
	cart.collision_mask = 0
	cart.input_ray_pickable = false
	_add(root, cart, root)
	var cart_shape := BoxShape3D.new()
	cart_shape.size = Vector3(1.3, 1.3, 0.3)
	var cart_collider := CollisionShape3D.new()
	cart_collider.name = "Cart Collider"
	cart_collider.shape = cart_shape
	cart_collider.position = Vector3(0.0, -0.65, -0.4)
	_add(cart, cart_collider, root)
	var spring := Generic6DOFJoint3D.new()
	spring.name = "Spring"
	_add(root, spring, root)
	spring.node_a = NodePath("../Cart")
	spring.set("linear_limit_y/upper_distance", 0.15)
	spring.set("linear_limit_y/lower_distance", -0.15)
	spring.set("linear_spring_y/enabled", true)
	spring.set("linear_spring_y/stiffness", 1500000.0)
	# ~0.6 of critical for the empty 4 t deck (2 * sqrt(k m) = 155 000), ~0.4 with a truck on it: 15 000 (0.1) rang
	# at 3 Hz for seconds after every bump, a truck hopping on it on the way down (playtest 2026-11-12).
	spring.set("linear_spring_y/damping", 90000.0)
	_prop_sync(root, "vehicle_lift_platformsystem", true)
	var rolling := Node3D.new()
	rolling.name = "RollingNoise"
	rolling.set_script(_alarm_script)
	rolling.set("sound", load(LIFT + "sounds/rolling.tres"))
	rolling.set("autoplay", false)
	_add(root, rolling, root)
	return root


func _save_model() -> void:
	var model: Resource = load(LIFT + "vehicle_lift_model.gd").new()
	model.set("upper_landing_scene", load(OUT + "upper_landing.tscn"))
	model.set("lower_landing_scene", load(OUT + "lower_landing.tscn"))
	model.set("stop_landing_scene", load(OUT + "level_landing.tscn"))
	model.set("rail_segment_scene", load(OUT + "section.tscn"))
	model.set("platform_system_scene", load(OUT + "platform_system.tscn"))
	model.set("platform_system_offset", Vector3.ZERO)  # level with the upper landing (the road on the tower)
	# The deck rests on the pit's slab at the foot: 36 cm up (playtest 2026-11-12: 3-4 cm high at 0.4). The levels'
	# floors are at the levels' height (MineLayout), the deck level with them, raised by nothing, like the top.
	model.set("stop_raise_m", 0.0)
	model.set("foot_raise_m", 0.36)
	model.set("lower_landing_offset", Vector3.ZERO)
	# The top piece carries the tower's first 11.47 m, the base its last 9.30 m above the foot's deck; the 10 m
	# sections hang from their top and fill what is between, the last one sinking into the base.
	model.set("segment_height_m", 10.0)
	model.set("segment_top_m", 11.47)
	model.set("segment_bottom_m", 9.30)
	model.set("segment_origin_m", 0.0)
	model.set("segment_extra", 0)
	model.set("rail_collider_size", TOWER_SIZE)
	model.set("rail_collider_center", TOWER_CENTER)
	print("[build_truck_elevator] truck_elevator_model.tres: %s" % error_string(
		ResourceSaver.save(model, OUT + "truck_elevator_model.tres")))


func _lift() -> Node:
	var root := Node3D.new()
	root.name = "Truck Elevator"
	root.set_script(load(LIFT + "vehicle_lift.gd"))
	root.set("model", load(OUT + "truck_elevator_model.tres"))
	root.set("sound_rolling", load(LIFT + "sounds/rolling.tres"))
	root.set("sound_alarm", load(LIFT + "sounds/alarm.tres"))
	_prop_sync(root, "vehicle_lift", false)
	var marker := Node3D.new()
	marker.name = "MapMarker"
	marker.set_script(load("res://scenes/common/map_marker.gd"))
	marker.set("label", "%%MAP_MARKER_VEHICLE_LIFT")
	marker.set("icon", load("res://assets/textures/map_markers/vehicle_lift.png"))
	marker.set("importance", 1)
	marker.set("max_view_m", 5000.0)
	_add(root, marker, root)
	return root
