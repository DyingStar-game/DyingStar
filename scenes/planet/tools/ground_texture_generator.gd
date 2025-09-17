@tool
extends Node

class_name GroundTextureGenerator

@export_category("Resizing")
@export var texture_resize = 2048
@export_tool_button("Resize textures") var res = resize_all_textures

@export_category("Packing")
@export var textures_folder = "res://assets/textures/grounds"
@export var output_resource_name = "res://scenes/planet/planet_biomes.res"
@export var texture_size = 1024
@export_tool_button("Pack textures") var gen = generate_textures

func generate_textures():
	
	var packed_images: Array[Image] = []
	for texture_folder in DirAccess.get_directories_at(textures_folder):
		prints("Packing textures for ", texture_folder)
		var texture_files = DirAccess.get_files_at(textures_folder + "/" + texture_folder)
		var albedo: Image
		var normal: Image
		var roughness: Image
		
		var base_path = textures_folder + "/" + texture_folder + "/"
		for file in texture_files:
			if file.contains(".import"): continue
			var filename_lower = file.to_lower()
			
			if filename_lower.contains("color"):
				albedo = Image.load_from_file(base_path + file)
			if filename_lower.contains("normal"):
				normal = Image.load_from_file(base_path + file)
			if filename_lower.contains("roughness"):
				roughness = Image.load_from_file(base_path + file)
			
		if !albedo or !normal or !roughness:
			printerr("missing texture map", albedo, normal, roughness)
			continue
		
		var packed_image = pack_image(albedo, normal, roughness)
		packed_image.compress(Image.COMPRESS_BPTC)
		packed_image.save_png(base_path + texture_folder + "_packed.png")
		
		packed_images.push_back(packed_image)
		
	var texture2DArray = Texture2DArray.new()
	texture2DArray.create_from_images(packed_images)
	texture2DArray.take_over_path(output_resource_name)
	ResourceSaver.save(texture2DArray, output_resource_name, ResourceSaver.FLAG_COMPRESS)
	
	print("Finished !")

func resize_all_textures():
	for texture_folder in DirAccess.get_directories_at(textures_folder):
		var texture_files = DirAccess.get_files_at(textures_folder + "/" + texture_folder)
		for file in texture_files:
			if file.contains(".import"): continue
			var filename_lower = file.to_lower()
			var base_path = textures_folder + "/" + texture_folder + "/"
			
			if filename_lower.contains("4K"):
				file.replace("4K", "2K")
			
			if filename_lower.contains("color"):
				resize_textures(base_path, file)
			if filename_lower.contains("normal"):
				resize_textures(base_path, file)
			if filename_lower.contains("roughness"):
				resize_textures(base_path, file)

func resize_textures(basepath: String, file: String):
	var img = Image.load_from_file(basepath + file)
	#if img.get_size().x == texture_resize: return
	prints("Resizing image", basepath + file)
	img.resize(texture_resize, texture_resize, Image.INTERPOLATE_LANCZOS)
	
	var newfilename = file
	if newfilename.contains("4K"):
		file.replace("4K", "2K")
		
	img.save_jpg(basepath + newfilename, 1.0)

func pack_image(albedo: Image, normal: Image, roughness: Image) -> Image:
	var packed := Image.create_empty(texture_size, texture_size, false, Image.FORMAT_RGBA8)
	for y in texture_size:
		for x in texture_size:
			var n = normal.get_pixel(x, y)  # vec3 (r,g,b)
			var a = albedo.get_pixel(x, y).r
			var r = roughness.get_pixel(x, y).r

			# RGBA packing
			packed.set_pixel(x, y, Color(n.r, n.g, a, r))
	
	packed.generate_mipmaps()
	return packed
	
