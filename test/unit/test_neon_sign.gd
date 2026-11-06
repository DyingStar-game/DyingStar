extends GutTest
## The garage, the cargo and mining depots and the teleporter cabin wear a neon sign (NeonSign): a
## translated text that glows, with a light that never takes a place in the shadow atlas. A sign on a
## facade is read from OUTSIDE; the mining depot's is a label on its machine, in the middle of it.

const NEON_SCRIPT := "res://scenes/_universe/props/lighting/neon_sign/neon_sign.gd"
## Scene -> its sign's key.
const BUILDINGS := {
	"res://scenes/_universe/structures/industrial/garage.tscn": "%%SIGN_GARAGE",
	"res://scenes/_universe/structures/buildings/teleporter/teleporter.tscn": "%%SIGN_TELEPORTER",
	"res://scenes/_universe/structures/industrial/cargo_depot.tscn": "%%SIGN_CARGO_DEPOT",
	"res://scenes/_universe/structures/industrial/mines/mining_depot.tscn": "%%SIGN_MINING_DEPOT",
}
## The ones whose sign hangs on a facade, to be read from the street.
const ON_FACADE: Array[String] = [
	"res://scenes/_universe/structures/industrial/garage.tscn",
	"res://scenes/_universe/structures/buildings/teleporter/teleporter.tscn",
	"res://scenes/_universe/structures/industrial/cargo_depot.tscn",
]


## Read from the scene files rather than instantiated: the cargo depot pulls in concrete_floor_001.tres,
## whose triplanar + height mapping raises an engine error that GUT counts against any test loading it.
func test_each_building_wears_its_sign_and_a_facade_sign_faces_out() -> void:
	for path: String in BUILDINGS:
		var text := FileAccess.get_file_as_string(path).replace("\r\n", "\n")
		var sign := _block_with_script(text, NEON_SCRIPT)
		assert_ne(sign, "", "%s has a NeonSign" % path)
		if sign == "":
			continue
		assert_string_contains(sign, "text_key = \"%s\"" % BUILDINGS[path], false)
		if path not in ON_FACADE:
			continue
		# The text is read from the sign's +Z: that side must point away from the building's middle
		# (its levelled ground), not at its wall.
		var at := _transform_of(sign)
		var ground := _block(text, "\\[node name=\"Ground\"[^\\]]*parent=\"TerrainPad\"")
		var out := at.origin - _transform_of(ground).origin
		out.y = 0.0
		assert_gt(out.dot(at.basis.z), 0.0, "%s: the sign faces the street" % path)


func test_the_sign_shows_the_translation_and_glows() -> void:
	var sign := NeonSign.new()
	sign.text_key = "%%SIGN_TELEPORTER"
	add_child_autofree(sign)
	var tube := _internal(sign, MeshInstance3D) as MeshInstance3D
	var light := _internal(sign, OmniLight3D) as OmniLight3D
	assert_eq((tube.mesh as TextMesh).text, sign.shown_text(), "the tube spells the shown text")
	var material := tube.material_override as StandardMaterial3D
	assert_true(material.emission_enabled)
	assert_gt(material.emission_energy_multiplier, 1.0, "bright enough for the glow to bloom")
	assert_false(light.shadow_enabled, "no shadow: LampShadowBudget leaves it alone")
	assert_eq(light.light_color, sign.color, "the light has the tube's colour")
	sign.light_attenuation = 2.0
	assert_eq(light.omni_attenuation, 2.0, "the falloff reaches the built light")


## A sign given its facade's width never runs wider: a long text is drawn with smaller letters, a short
## one keeps its letter height, and no width keeps the letters as set.
func test_a_sign_shrinks_its_letters_to_its_max_width() -> void:
	var sign := NeonSign.new()
	sign.text_key = "A RATHER LONG SIGN FOR A SMALL SHOP"
	sign.letter_height = 1.2
	add_child_autofree(sign)
	var natural := sign.text_width()
	assert_gt(natural, 10.0, "wide at 1.2 m")
	sign.max_width = 8.0
	assert_almost_eq(sign.text_width(), 8.0, 0.01, "shrunk to its facade")
	assert_lt(sign.drawn_letter_height(sign.shown_text()), 1.2)
	var tube := _internal(sign, MeshInstance3D) as MeshInstance3D
	assert_almost_eq((tube.mesh as TextMesh).pixel_size * NeonSign.FONT_SIZE * NeonSign.CAP_HEIGHT,
			sign.drawn_letter_height(sign.shown_text()), 1e-6, "the tube is drawn at the shrunk height")
	sign.max_width = natural + 5.0
	assert_eq(sign.drawn_letter_height(sign.shown_text()), 1.2, "a text that fits keeps its height")
	sign.font = null
	sign.max_width = 8.0
	assert_almost_eq(sign.text_width(), 8.0, 0.01, "the fallback font is held too")


func test_switched_off_the_tube_keeps_its_colour_without_glow_or_light() -> void:
	var sign := NeonSign.new()
	add_child_autofree(sign)
	var tube := _internal(sign, MeshInstance3D) as MeshInstance3D
	var light := _internal(sign, OmniLight3D) as OmniLight3D
	sign.set_lit(false)
	var material := tube.material_override as StandardMaterial3D
	assert_false(material.emission_enabled, "no glow")
	assert_false(light.visible, "no light on the wall")
	assert_eq(material.albedo_color, sign.color, "it keeps its colour by day, it does not turn black")
	sign.set_lit(true, false)
	assert_true(material.emission_enabled, "back on at once when not animated")
	assert_true(light.visible)


func test_a_branded_sign_wears_its_subsidiary_colour() -> void:
	var sign := NeonSign.new()
	sign.branded = true
	sign.brand = AresBrand.Subsidiary.MINING
	add_child_autofree(sign)
	var tube := _internal(sign, MeshInstance3D) as MeshInstance3D
	var light := _internal(sign, OmniLight3D) as OmniLight3D
	var mining := AresBrand.colour(AresBrand.Subsidiary.MINING)
	assert_eq((tube.material_override as StandardMaterial3D).emission, mining, "the tube: ARES MINING's colour")
	assert_eq(light.light_color, mining, "and its light")
	sign.branded = false
	assert_eq(light.light_color, sign.color, "unbranded, its own colour again")


func test_the_text_follows_the_language() -> void:
	var before := TranslationServer.get_locale()
	var sign := NeonSign.new()
	sign.text_key = "%%SIGN_TELEPORTER"
	add_child_autofree(sign)
	var tube := _internal(sign, MeshInstance3D) as MeshInstance3D
	for locale: String in ["en", "fr"]:
		TranslationServer.set_locale(locale)
		sign.notification(NOTIFICATION_TRANSLATION_CHANGED)
		assert_eq((tube.mesh as TextMesh).text, tr("%%SIGN_TELEPORTER"), "text in %s" % locale)
	TranslationServer.set_locale(before)


func test_the_tube_and_light_are_never_saved_into_the_building() -> void:
	var sign := NeonSign.new()
	add_child_autofree(sign)
	assert_eq(sign.get_child_count(), 0, "no saved child: they are internal")
	assert_eq(sign.get_child_count(true), 2, "the tube and the light")


## The property lines of the first node whose header starts with [param header] (a regex), or "".
func _block(text: String, header: String) -> String:
	var found := RegEx.create_from_string(header + "[^\\n]*\\n((?:(?!\\n\\[)[\\s\\S])*)").search(text)
	return found.get_string(1) if found != null else ""


## The property lines of the node that runs [param script], or "".
func _block_with_script(text: String, script: String) -> String:
	var ext := RegEx.create_from_string(
			"\\[ext_resource [^\\]]*path=\"%s\" id=\"([^\"]+)\"\\]" % script).search(text)
	if ext == null:
		return ""
	var nodes := RegEx.create_from_string("\\[node [^\\n]*\\n((?:(?!\\n\\[)[\\s\\S])*)")
	for node in nodes.search_all(text):
		if node.get_string(1).contains("script = ExtResource(\"%s\")" % ext.get_string(1)):
			return node.get_string(1)
	return ""


func _transform_of(block: String) -> Transform3D:
	var found := RegEx.create_from_string("transform = (Transform3D\\([^)]*\\))").search(block)
	return str_to_var(found.get_string(1)) if found != null else Transform3D.IDENTITY


func _internal(sign: Node, type: Variant) -> Node:
	for child in sign.get_children(true):
		if is_instance_of(child, type):
			return child
	return null


func test_signs_that_read_the_same_share_one_mesh() -> void:
	var a := NeonSign.new()
	a.text_key = "SAME"
	add_child_autofree(a)
	var b := NeonSign.new()
	b.text_key = "SAME"
	add_child_autofree(b)
	assert_same(a.mesh_params()["text"], "SAME")
	assert_eq(a.get_child(0, true).mesh, b.get_child(0, true).mesh, "one mesh for the two")
	var c := NeonSign.new()
	c.text_key = "OTHER"
	add_child_autofree(c)
	assert_ne(c.get_child(0, true).mesh, a.get_child(0, true).mesh, "another text, another mesh")


func test_a_layout_lists_its_signs_once_each() -> void:
	var layout := Node3D.new()
	for key: String in ["ONE", "ONE", "TWO"]:
		var sign := NeonSign.new()
		sign.text_key = key
		layout.add_child(sign)
	var signs: Array = LayoutData._signs_of(layout)
	layout.free()
	assert_eq(signs.size(), 2)

