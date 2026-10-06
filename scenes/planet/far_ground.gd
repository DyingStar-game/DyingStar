class_name FarGround
extends RefCounted
## Every ground of a far chunk lights itself: distant chunks live on the celestial layer, where no Godot
## light reaches them, so each surface must emit the star's light itself (terrain_far_light.gdshaderinc).
## The ground shaders do (terrain_biome, planet_surface, rocky_ground); a material that cannot — a
## StandardMaterial3D (grass, leaf litter, lunar regolith, cliff faces) or a shader without the include
## — gets a flat stand-in while its chunk is far: its colour from afar, the average of its texture, lit
## like every other ground. A new ground material therefore shows from afar whatever it is.
##
## Found on Sandbox (2026-10-06): only terrain_biome lit itself, and its corundum outcrops and every
## textured overlay left whole regions of black squares, the stars hidden behind them.

## The include a shader carries when it lights itself from afar.
const FAR_LIGHT_INCLUDE := "terrain_far_light.gdshaderinc"
const FLAT_SHADER := preload("res://assets/_universe/environment/terrain/terrain_far_flat.gdshader")
## Colour from afar of a material whose texture cannot be read (no texture, no image): plain mid-grey.
const DEFAULT_ALBEDO := Color(0.4, 0.4, 0.4)
## A texture is averaged on a copy halved down to this size: each halving is a 2x2 box average.
const AVERAGE_SIZE := 32

## Stand-ins by source material (key: _key_of), and texture averages by path: chunk materials are
## duplicated per chunk (planet_chunk.gd), so the instance cannot be the key.
static var _stand_ins: Dictionary = {}
static var _averages: Dictionary = {}


## Does [param material] light itself from afar.
static func lights_itself(material: Material) -> bool:
	var shader_material := material as ShaderMaterial
	return shader_material != null and shader_material.shader != null \
			and shader_material.shader.code.contains(FAR_LIGHT_INCLUDE)


## What a far chunk draws [param material]'s surface with: null to keep its own (it lights itself),
## else a flat stand-in of its colour from afar.
static func material_for(material: Material) -> Material:
	if material == null or lights_itself(material):
		return null
	var key := _key_of(material)
	if not _stand_ins.has(key):
		var stand_in := ShaderMaterial.new()
		stand_in.shader = FLAT_SHADER
		var albedo := flat_albedo(material)
		stand_in.set_shader_parameter("far_albedo", Vector3(albedo.r, albedo.g, albedo.b))
		_stand_ins[key] = stand_in
	return _stand_ins[key]


## Put [param mi]'s surfaces in their far dress ([param far]) or back in their own.
static func apply(mi: MeshInstance3D, far: bool) -> void:
	if mi.mesh == null:
		return
	for surface in mi.mesh.get_surface_count():
		mi.set_surface_override_material(surface, material_for(mi.mesh.surface_get_material(surface)) if far else null)


## [param material]'s colour from afar: its albedo colour times the average of its albedo texture.
static func flat_albedo(material: Material) -> Color:
	var color := Color.WHITE
	var texture: Texture2D = null
	if material is BaseMaterial3D:
		color = (material as BaseMaterial3D).albedo_color
		texture = (material as BaseMaterial3D).albedo_texture
	elif material is ShaderMaterial:
		for name: String in ["albedo_texture", "texture_albedo", "albedo"]:
			var value: Variant = (material as ShaderMaterial).get_shader_parameter(name)
			if value is Texture2D:
				texture = value
				break
			if value is Color:
				color = value
	if texture == null:
		return DEFAULT_ALBEDO if color == Color.WHITE else color
	return color * texture_average(texture)


## The mean colour of [param texture] (cached by path), or DEFAULT_ALBEDO when its image cannot be read.
static func texture_average(texture: Texture2D) -> Color:
	var key := texture.resource_path if texture.resource_path != "" else str(texture.get_instance_id())
	if _averages.has(key):
		return _averages[key]
	var average := DEFAULT_ALBEDO
	var image := texture.get_image()
	if image != null and not image.is_empty():
		image = image.duplicate() as Image
		if image.is_compressed():
			image.decompress()
		image.clear_mipmaps()
		while image.get_width() > AVERAGE_SIZE or image.get_height() > AVERAGE_SIZE:
			image.resize(maxi(image.get_width() / 2, 1), maxi(image.get_height() / 2, 1),
					Image.INTERPOLATE_BILINEAR)
		var sum := Color(0.0, 0.0, 0.0, 0.0)
		for y in image.get_height():
			for x in image.get_width():
				sum += image.get_pixel(x, y)
		var count := float(image.get_width() * image.get_height())
		average = Color(sum.r / count, sum.g / count, sum.b / count)
	_averages[key] = average
	return average


static func _key_of(material: Material) -> String:
	if material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		return "%s|%s" % [base.albedo_texture.resource_path if base.albedo_texture else "", base.albedo_color]
	return material.resource_path if material.resource_path != "" else str(material.get_instance_id())
