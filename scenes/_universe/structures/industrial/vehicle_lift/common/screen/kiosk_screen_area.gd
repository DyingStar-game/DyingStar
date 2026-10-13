@tool
extends StaticBody3D


var screen_display_visual: MeshInstance3D:
	get:
		if screen_display_visual == null:
			screen_display_visual = get_node_or_null("%Screen Display Visual") as MeshInstance3D
		return screen_display_visual

var screen_display_viewport: SubViewport:
	set(value):
		if value != screen_display_viewport:
			screen_display_viewport = value
			
			if screen_display_viewport == null:
				display_size = Vector2i.ZERO
				return
			
			if not screen_display_viewport.is_inside_tree():
				if not screen_display_viewport.ready.is_connected(_update_viewport_texture):
					screen_display_viewport.ready.connect(_update_viewport_texture, CONNECT_ONE_SHOT)
				return
			
			_update_viewport_texture()

var display_size: Vector2i
var canvas_interface: Control


func _ready() -> void:
	if not screen_display_viewport or not screen_display_viewport.is_inside_tree():
		return
	
	display_size = screen_display_viewport.size


func hover_screen(local_hit_point: Vector3) -> void:
	if screen_display_viewport.get_child_count() > 0:
		canvas_interface = screen_display_viewport.get_child(0)
	
	if not canvas_interface:
		return
	
	var event: InputEventMouseMotion = InputEventMouseMotion.new()
	event.position = _get_2d_pos(local_hit_point)
	
	screen_display_viewport.push_input(event)
	canvas_interface.display_mouse_coord(event.position)
	canvas_interface.move_mouse_cursor(event.position)


func click_screen(local_hit_point: Vector3) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = _get_2d_pos(local_hit_point)
	screen_display_viewport.push_input(event)
	
	var release_event:InputEventMouseButton = event.duplicate()
	release_event.pressed = false
	screen_display_viewport.push_input(release_event)


func _get_2d_pos(local_pos: Vector3) -> Vector2i:
	if screen_display_visual == null or screen_display_visual.mesh == null:
		return Vector2i.ZERO
	
	var screen_size: Vector2 = screen_display_visual.mesh.size
	
	var percent_x: float = (local_pos.x / screen_size.x) + 0.5
	var percent_y: float = 0.5 - (local_pos.y / screen_size.y)
	
	var px = clamp(percent_x * display_size.x, 0.0, display_size.x)
	var py = clamp(percent_y * display_size.y, 0.0, display_size.y)
	
	return Vector2i(px, py)


func _update_viewport_texture() -> void:
	if screen_display_viewport == null:
		return
	
	if not screen_display_viewport.is_inside_tree():
		return
	
	display_size = screen_display_viewport.size
	
	if screen_display_visual != null and screen_display_visual.is_inside_tree():
		var screen_display_material: StandardMaterial3D = screen_display_visual.get_active_material(0)
		if screen_display_material != null:			
			screen_display_material.albedo_texture = screen_display_viewport.get_texture()
