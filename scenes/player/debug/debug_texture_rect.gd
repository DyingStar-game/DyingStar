@tool
extends ColorRect


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var background_texture_array: Texture2DArray
	
	if FileAccess.file_exists("res://ui/ingame/debug/background_texture_2d_array.tres"):
		background_texture_array = load("res://ui/ingame/debug/background_texture_2d_array.tres")
	else:
		var background_image_01: Image = load("res://ui/ingame/debug/background_large.02_OK.002.png").get_image()
		var background_image_02: Image = load("res://ui/ingame/debug/background_large.03_OK.002.png").get_image()
		
		background_image_01.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
		background_image_02.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
		
		background_texture_array = Texture2DArray.new()
		background_texture_array.create_from_images([background_image_01, background_image_02])
		
		ResourceSaver.save(background_texture_array, "res://ui/ingame/debug/background_texture_2d_array.tres")
	
	if material is ShaderMaterial:
		material.set_shader_parameter("background_textures", background_texture_array)
		set_instance_shader_parameter("instance_seed", randf() * 1000.0)
	
	if not item_rect_changed.is_connected(_on_item_rect_changed):
		item_rect_changed.connect(_on_item_rect_changed)
	
	_on_item_rect_changed()


func _on_item_rect_changed() -> void:
	if material is ShaderMaterial:
		set_instance_shader_parameter("rect_size", size)
