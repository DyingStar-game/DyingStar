extends GutTest
## The ground's look on a body dressed by Nova: what Nova answers for a direction (its variant, that
## variant's textures and settings), and GroundLook asking Nova first — the ground fringe, the blown dust and
## the rocks' foot copy the ground one SEES, not the planet's older materials (2026-11-25: the fringe at the
## foot of buildings showed the pale corundum marble at 10 m on Tarsis 3, in front of Nova's dark gravel).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_ground_look_nova.gd

const BODY := "test_body_ground_look"
const PLATEAU := {"biome_type": "outcrop-plateau", "rock_type": "corundum_red", "clarity": "milky", "coverage": "full"}
const ROCK_SHADER := "res://scenes/planet/nova/nova_rock.gdshader"


## A PlanetData whose zone lookup answers [member zone] everywhere, and whose baked vertex colour is fixed:
## what is tested here is how Nova and GroundLook read that zone, not the zone pack or the rock catalogue.
class StubData:
	extends PlanetData
	var zone: Dictionary = {}
	var vertex := Color(0.8, 0.5, 0.4)

	func first_zone_at(_dir: Vector3) -> Dictionary:
		return zone

	func ground_vertex_tint_at(_dir: Vector3, _height_m: float = NAN) -> Color:
		return vertex


func _body() -> NovaBody:
	var b := NovaBody.new()
	b.planet_name = BODY
	var vs: Array[Dictionary] = [NovaBody._variant(1, NovaBody.DEFAULT_KEY, {}),
			NovaBody._variant(2, NovaBody.zone_key(PLATEAU), PLATEAU)]
	b.variants = vs
	for v in vs:
		b._id_by_key[v.key] = v.id
	b.material = (load("res://assets/_universe/environment/terrain/terrain_biome.tres") as ShaderMaterial).duplicate()
	return b


func _data(with_nova: bool, zone: Dictionary) -> StubData:
	var d := StubData.new()
	d.planet_name = BODY
	d.radius = 6356000.0
	d.zone = zone
	if with_nova:
		d.nova = _body()
	return d


func test_inside_a_zone_nova_answers_its_variant_and_textures() -> void:
	var data := _data(true, PLATEAU)
	var dir := Vector3(0.3, 0.8, -0.5).normalized()
	assert_eq(data.nova_variant_at(dir), 2, "the zone's variant, as the vertices bake it")
	var got := data.nova_ground_at(dir)
	assert_false(got.is_empty(), "the plateau's archetype names an albedo texture")
	var look: Dictionary = got.look
	var base: Dictionary = look.layers[0]
	assert_eq(base.tex.resource_path, str(data.nova.resolve(2, "ground/albedo_texture")), "the ground's own texture")
	assert_almost_eq(float(base.scale), NovaBody.snap_scale(1.0 / float(data.nova.resolve(2, "ground/tile_m"))), 1e-9,
			"the ground's tile, snapped like the shader's")
	assert_almost_eq(float(base.gain), float(data.nova.resolve(2, "ground/texture_gain")), 1e-6)
	var expected_layers := 1
	for k in 2:
		var key := "ground/layer%d_" % (k + 2)
		if str(data.nova.resolve(2, key + "albedo")) != "" and float(data.nova.resolve(2, key + "share")) > 0.0:
			expected_layers += 1
	assert_eq(look.layers.size(), expected_layers, "the second and third materials the variant lays")
	assert_eq(data.ground_material_at(dir), data.nova.material, "a Nova body's chunks wear Nova's material")


func test_outside_any_zone_the_default_ground_keeps_the_terrains_look() -> void:
	var data := _data(true, {})
	var dir := Vector3(0.3, 0.8, -0.5).normalized()
	assert_eq(data.nova_variant_at(dir), 1, "the ground outside zones")
	assert_true(data.nova_ground_at(dir).is_empty(), "a variant naming no texture: the terrain's own look stands")
	assert_eq(data.ground_material_at(dir), data.nova.material, "and that look is Nova's material, never a biome override")


func test_ground_look_prefers_nova_on_a_nova_body() -> void:
	var data := _data(true, PLATEAU)
	var dir := Vector3(-0.2, 0.4, 0.9).normalized()
	assert_null(GroundLook.at(data, dir, Color.MAGENTA).material,
			"no fringe before the ground's texture arrays are made (TerrainBlend measures again)")
	_give_arrays(data.nova)
	var nova := data.nova_ground_at(dir)
	var ground_r := data.radius + 12.0
	var look := GroundLook.at(data, dir, Color.MAGENTA, ground_r)
	assert_not_null(look.material)
	var layers: Array = nova.look.layers
	assert_true(bool(look.material.get_shader_parameter(&"blend_nova")), "the band reads Nova's arrays")
	assert_same(look.material.get_shader_parameter(&"blend_nova_albedo"),
			data.nova.material.get_shader_parameter(&"nova_albedo"), "the very arrays the ground reads")
	var a_layer: Vector3 = look.material.get_shader_parameter(&"blend_nova_albedo_layer")
	var scale: Vector3 = look.material.get_shader_parameter(&"blend_nova_scale")
	var gain: Vector3 = look.material.get_shader_parameter(&"blend_nova_gain")
	for i in mini(layers.size(), 3):
		assert_eq(int(a_layer[i]), int(layers[i].albedo_layer), "at the ground's own layers")
		assert_almost_eq(scale[i], float(layers[i].scale), 1e-6, "at the ground's own tiles")
		assert_almost_eq(gain[i], float(layers[i].gain), 1e-6, "with the ground's own gains")
	assert_almost_eq(float(look.material.get_shader_parameter(&"blend_nova_contrast")),
			float(data.nova.resolve(2, "ground/texture_contrast")), 1e-6)
	var pos := dir * ground_r
	assert_eq(look.nova_where, NovaBody.patch_where(nova.look, pos), "the patch noise at the object's foot")
	var t: Color = nova.tint
	assert_almost_eq(look.tint.g, t.g * float(nova.macro), 0.05,
			"tinted like the ground: biome tint x albedo multiplier x its large light and dark")
	assert_eq(GroundLook.colour_at(data, dir, Color.MAGENTA), data.nova_ground_at(dir).colour,
			"the dust takes the colour Nova's ground shows")
	assert_eq(data.ground_albedo_at(dir), data.nova_ground_at(dir).colour, "and so does every other reader")
	assert_same(GroundLook.at(data, dir, Color.MAGENTA, ground_r).material, look.material,
			"one material per variant, shared")


## Texture arrays on the body's material and the paths that place each variant's images in them, as
## NovaBody.build_material leaves them once its worker is done (flat layers: only their places matter here).
func _give_arrays(body: NovaBody) -> void:
	body._arrays_spec()
	body.refresh_ground()
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5))
	var images: Array[Image] = [img]
	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	body.material.set_shader_parameter(&"nova_albedo", arr)
	body.material.set_shader_parameter(&"nova_orh", arr)


func test_ground_look_falls_back_on_a_body_without_nova() -> void:
	var data := _data(false, PLATEAU)
	var dir := Vector3(-0.2, 0.4, 0.9).normalized()
	assert_true(data.nova_ground_at(dir).is_empty())
	assert_eq(data.nova_variant_at(dir), 0)
	var look := GroundLook.at(data, dir, Color.MAGENTA)
	var nova: Variant = look.material.get_shader_parameter(&"blend_nova") if look.material != null else null
	assert_false(nova == true, "the planet's own material path, unchanged")


func test_the_patches_cover_the_ground_once_and_repeat_with_the_tiling() -> void:
	var data := _data(true, PLATEAU)
	var look := data.nova.ground_look(2)
	var whole := NovaBody.layer_weights(look)
	var sum := 0.0
	for w in whole:
		sum += w
	assert_almost_eq(sum, 1.0, 1e-6, "every point is covered once, on the whole")
	var pos := Vector3(1234567.25, -3456789.5, 4567.75)
	var here := NovaBody.layer_weights(look, pos)
	sum = 0.0
	for w in here:
		assert_between(w, 0.0, 1.0)
		sum += w
	assert_almost_eq(sum, 1.0, 1e-6, "and at a point")
	var again := NovaBody.layer_weights(look, pos + Vector3(NovaBody.WRAP, -2.0 * NovaBody.WRAP, 0.0))
	for i in here.size():
		assert_almost_eq(again[i], here[i], 1e-6, "the shader's texture position wraps every WRAP metres")


func test_the_shown_colour_is_the_shaders_rule_on_the_means() -> void:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5).linear_to_srgb())
	var tex := ImageTexture.create_from_image(img)
	var look := {"layers": [{"tex": tex, "orh": null, "gain": 2.0, "share": 1.0}], "strength": 1.0}
	var c := NovaBody.shown_colour(look, Color(0.4, 0.2, 0.1), PackedFloat32Array([1.0]))
	# mean 0.5 (linear) × gain 2 = 1: the tint itself.
	assert_almost_eq(c.r, 0.4, 0.02)
	assert_almost_eq(c.g, 0.2, 0.02)
	assert_almost_eq(c.b, 0.1, 0.02)


func test_the_scattered_rocks_wear_the_grounds_fringe() -> void:
	var body := _body()
	var m := ShaderMaterial.new()
	m.shader = load(ROCK_SHADER)
	var aabb := AABB(Vector3(-1.0, -0.2, -1.0), Vector3(2.0, 2.0, 2.0))
	NovaScatter.set_fringe(m, body, 2, aabb, 0.05)
	assert_true(bool(m.get_shader_parameter("fringe_on")))
	assert_eq(m.get_shader_parameter("ground_albedo_0"), body.ground_look(2).layers[0].tex, "the ground's texture")
	assert_almost_eq(float(m.get_shader_parameter("fringe_ground_y")), maxf(-0.2, 0.05 * 2.0), 1e-6,
			"where the ground meets the sunk model")
	var other := ShaderMaterial.new()
	other.shader = m.shader
	NovaScatter.set_fringe(other, body, 1, aabb, 0.05)
	assert_false(bool(other.get_shader_parameter("fringe_on")), "no Nova texture under it: no fringe")


func test_the_fringe_reads_its_textures_anchored_to_the_planet() -> void:
	# Two copies of one model side by side read two pieces of ground: the coordinate along an axis is the
	# vertex's place in the planet's frame (wrapped), not its place in the model (2026-11-25).
	var up_p := Vector3(0.3, 0.8, -0.52).normalized()
	var t: Array[Vector3] = TerrainBlend.local_tangents(up_p)
	assert_almost_eq(t[0].dot(up_p), 0.0, 1e-9, "tangent 1 lies flat")
	assert_almost_eq(t[1].dot(up_p), 0.0, 1e-9, "tangent 2 lies flat")
	assert_almost_eq(t[0].dot(t[1]), 0.0, 1e-9, "and they are square")
	var basis := Basis(Vector3(0.0, 1.0, 0.0), 0.7).scaled(Vector3(1.0, 2.0, 1.0))
	var a := Vector3(1234567.0, 4321000.0, -2222222.0)
	var b := a + t[0] * 6.0  # the same model six metres further along the tangent
	var v := Vector3(0.4, 0.1, -0.3)
	var row_a := TerrainBlend.anchor_row(basis, t[0], t[0], a)
	var row_b := TerrainBlend.anchor_row(basis, t[0], t[0], b)
	var at_a := Vector3(row_a.x, row_a.y, row_a.z).dot(v) + row_a.w
	var expected := fposmod(t[0].dot(a + basis * v), TerrainBlend.ANCHOR_WRAP_M)
	assert_almost_eq(at_a, expected, 1e-4, "metres along the axis, in the planet's frame")
	var at_b := Vector3(row_b.x, row_b.y, row_b.z).dot(v) + row_b.w
	assert_almost_eq(fposmod(at_b - at_a, TerrainBlend.ANCHOR_WRAP_M), 6.0, 1e-4, "the copy reads six metres on")


func test_the_box_axis_is_in_model_units() -> void:
	# A mesh scaled by 2 along its X: 3 m of box half extent are 1.5 model units along that axis.
	var inv := Basis.from_scale(Vector3(2.0, 1.0, 1.0)).inverse()
	var row := TerrainBlend.box_axis(inv, Vector3.RIGHT, 3.0)
	assert_almost_eq(row.x, 1.0, 1e-9)
	assert_almost_eq(row.w, 1.5, 1e-9)
