extends StaticBody3D

@export var uuid: String = ""

var type_name = "mining_depot"

var spawn_position: Vector3 = Vector3.ZERO
var spawn_rotation: Vector3 = Vector3.UP

@onready var rock_depot_ui: Panel = %RockDepotUI
@onready var danger_light_collect: Node3D = $DangerLightCollect
@onready var conveyorbelt_001: MeshInstance3D = $miningdepot/conveyorbelt_001
@onready var rock_detector: Area3D = $RockDetector


var state = "idle"
var rocks_to_collect = []

func _ready() -> void:
	pass


func _process(delta: float) -> void:
	if state == "idle":
		rock_depot_ui.get_node("VB/Splashscreen").visible = rocks_to_collect.is_empty()
		rock_depot_ui.get_node("VB/RockCounter").visible = rocks_to_collect.size() > 0
		rock_depot_ui.get_node("VB/RockCounter/VB/RockCount").text = str(rocks_to_collect.size())
		danger_light_collect.enabled = false
		conveyorbelt_001.set_instance_shader_parameter("animation_speed", 0.0)
	elif state == "collecting":
		danger_light_collect.enabled = true
		conveyorbelt_001.set_instance_shader_parameter("animation_speed", 1.0)
		for rock: RigidBody3D in rocks_to_collect:
			rock.global_position += (-rock_detector.global_basis.z * 0.5 * delta)
	else:
		danger_light_collect.enabled = false

func client_channel_data_update(_data: Dictionary) -> void:
	pass


func _on_rock_detector_body_entered(body: Node3D) -> void:
	if body.is_in_group("rock_mining"):
		rocks_to_collect.append(body)

func _on_rock_detector_body_exited(body: Node3D) -> void:
	if body.is_in_group("rock_mining"):
		pass

func _on_rock_depot_ui_action_triggered(type: String) -> void:
	if type == "collect":
		state = "collecting"
