extends Control


enum landing_list {UNDEFINED, UPPER_LANDING, LOWER_LANDING, PLATFORM}


@export var button_group_scene: PackedScene
@export var landing: landing_list = landing_list.UNDEFINED


@onready var lift_name_value: Label = %"Lift Name"

@onready var buttons_container: MarginContainer = %"Buttons Container"

@onready var state_value: Label = %"Lift State"
@onready var arrival_value: Label = %"Arrival Value"
@onready var distance_value: Label = %"Distance Value"
@onready var distance_max_value: Label = %"Distance Max Value"

@onready var segment_controls: Array[Control] = [
	%"Upper Landing",
	%"Up Segment",
	%"Middle Segment",
	%"Bottom Segment",
	%"Lower Landing"
]


var weight_value_display: Label
var mouse_coord_value_display: Label
var mouse_cursor: TextureRect

var vehicle_lift: VehicleLift


func _ready() -> void:
	if Engine.is_editor_hint() or GameOrchestrator.is_server():
		return
	
	weight_value_display = get_node_or_null("Screen Global/Bottom Container/Infos Container/VBoxContainer/HBoxContainer/Weight Value")
	mouse_coord_value_display = get_node_or_null("Screen Global/Bottom Container/Infos Container/VBoxContainer/HBoxContainer2/Mouse Coord Value")
	mouse_cursor = get_node_or_null("Mouse Cursor")
	
	var current_node_to_check: Node = get_parent()
	while current_node_to_check != null:
		if current_node_to_check is VehicleLift:
			vehicle_lift = current_node_to_check
			break
		
		current_node_to_check = current_node_to_check.get_parent()
	
	if not vehicle_lift:
		return
	
	lift_name_value.text = vehicle_lift.get_name()
	distance_max_value.text = str(vehicle_lift.descent_depth)
	display_progress(vehicle_lift.platform_progress_ratio)
	
	if button_group_scene:
		var buttons_instance = button_group_scene.instantiate()
		buttons_container.add_child(buttons_instance)
		
		if buttons_instance.has_method("setup"):
			buttons_instance.setup(vehicle_lift, self)
	
	match landing:
		landing_list.UPPER_LANDING:
			var segment_background: TextureRect = segment_controls[0].get_node_or_null("Background")
			if segment_background:
				segment_background.texture = load("res://addons/vehicle_lift/common/screen/interfaces/lift_element_upper_landing_on.png")
		landing_list.LOWER_LANDING:
			var segment_background: TextureRect = segment_controls[segment_controls.size()-1].get_node_or_null("Background")
			if segment_background:
				segment_background.texture = load("res://addons/vehicle_lift/common/screen/interfaces/lift_element_lower_landing_on.png")


func display_new_weight(weight_on_platform: int) -> void:
	if weight_value_display:
		weight_value_display.set_text("%d kg" % weight_on_platform)


func display_mouse_coord(coord: Vector2) -> void:
	if mouse_coord_value_display:
		mouse_coord_value_display.set_text("%.0v" % coord)


func display_progress(progress: float, eta: int = 0, status: String = "Stopped") -> void:
	if not vehicle_lift:
		return
	
	if distance_value and arrival_value:
		var distance_to_show: float = 0.0
		
		match landing:
			landing_list.UPPER_LANDING:
				distance_to_show = (progress / 100.0) * vehicle_lift.descent_depth
			landing_list.LOWER_LANDING:
				distance_to_show = (1 - (progress / 100.0)) * vehicle_lift.descent_depth
			landing_list.PLATFORM:
				match status:
					"Going Up":
						distance_to_show = (progress / 100.0) * vehicle_lift.descent_depth
					"Going Down":
						distance_to_show = (1 - (progress / 100.0)) * vehicle_lift.descent_depth
		
		distance_value.text = "%.1f" % distance_to_show
		arrival_value.text = "%d" % eta
		state_value.text = status
	
	var active_segment_index: int = int(floor((progress / 100.0) * segment_controls.size()))
	if active_segment_index >= segment_controls.size():
		active_segment_index = segment_controls.size() - 1
	
	var active_segment_control = segment_controls[active_segment_index]
	
	var desaturate_amount: float = 0.0
	for i in range(segment_controls.size()):
		if segment_controls[i]:
			var segment_platform: TextureRect = segment_controls[i].get_node_or_null("Platform")
			if i == active_segment_index:
				desaturate_amount = 0.0
				if segment_platform:
					segment_platform.show()
			else:
				desaturate_amount = 0.5
				if segment_platform:
					segment_platform.hide()
			
			for icon_display in segment_controls[i].get_children():
				if icon_display is TextureRect and icon_display.material is ShaderMaterial:
					icon_display.set_instance_shader_parameter("amount", desaturate_amount)


func move_mouse_cursor(coord: Vector2) -> void:
	if mouse_cursor:
		mouse_cursor.position = coord


func set_landing(passed_landing: int) -> void:
	landing = passed_landing
