@tool
extends Control

@export var texture_size := Vector2i(256, 256)
@export var biomes: Array[BiomeDef]

@export_tool_button("Generate") var gen = generate


func generate():
	var tex = generate_lookup_texture(biomes)
	$TextureRect.texture = tex
	tex.get_image().save_png("res://scenes/planet/biomes.png")

func generate_lookup_texture(defs: Array[BiomeDef]) -> ImageTexture:
	var img = Image.create_empty(texture_size.x, texture_size.y, false, Image.FORMAT_RGB8)

	for y in range(texture_size.y):
		var humid = float(y) / float(texture_size.y - 1)
		for x in range(texture_size.x):
			var temp = float(x) / float(texture_size.x - 1)

			# Weighted blend of all biome defs
			var accum = Color(0,0,0)
			var total_weight = 0.0
			for biome in defs:
				var dist = Vector2(temp, humid).distance_to(Vector2(biome.temp, biome.humid))
				var weight = 1.0 / pow(dist + 0.001, 4.0) # inverse square falloff
				accum += biome.color * weight
				total_weight += weight

			var final_color = accum / total_weight
			img.set_pixel(x, y, final_color)

	return ImageTexture.create_from_image(img)
