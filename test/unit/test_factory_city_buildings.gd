extends GutTest
## The buildings added for the factory city of the village MVP (level design > village MVP, screen 2):
## CSG placeholders on the template of the mining village's (canteen, refinery). Each one is its own
## scene, a networked fixed prop (simple_building) that levels its ground, named in neon in its ARES
## subsidiary's colour and shown on the map; the variants are their base building under another sign.

const S := "res://scenes/_universe/structures/"
const BUILDINGS := [
	"buildings/civic/prison.tscn", "buildings/civic/courthouse.tscn", "buildings/civic/place_of_worship.tscn",
	"buildings/civic/police_station.tscn", "buildings/civic/fire_station.tscn", "buildings/civic/clinic.tscn",
	"buildings/civic/gymnasium.tscn", "buildings/civic/sports_hall.tscn",
	"buildings/commerce/bank.tscn", "buildings/commerce/small_bar.tscn", "buildings/commerce/party_hall_cinema.tscn",
	"buildings/commerce/driving_school.tscn", "buildings/commerce/car_dealership.tscn",
	"buildings/commerce/grocery_store.tscn", "buildings/commerce/clothing_store.tscn",
	"buildings/commerce/hardware_store.tscn",
	"buildings/houses/motel.tscn", "buildings/houses/refugee_shelters.tscn", "buildings/houses/executive_houses.tscn",
	"industrial/modules/prefab_module_factory.tscn", "industrial/recycling/recycling_centre.tscn",
	"industrial/storage/cold_storage.tscn", "industrial/storage/water_reserve.tscn",
	"industrial/metallurgy/arc_furnace.tscn", "industrial/metallurgy/blast_furnace.tscn",
	"industrial/metallurgy/oxygen_plant.tscn", "industrial/metallurgy/pierce_smith_converter.tscn",
	"industrial/metallurgy/electrolytic_refinery.tscn", "industrial/metallurgy/casting_hall.tscn",
	"industrial/metallurgy/casting_hall_iron.tscn", "industrial/metallurgy/casting_hall_copper.tscn",
	"industrial/metallurgy/casting_hall_rare_earths.tscn", "industrial/metallurgy/pelletizing_plant.tscn",
	"industrial/metallurgy/factory_office.tscn", "industrial/metallurgy/loading_bay.tscn",
	"industrial/metallurgy/loading_bay_iron.tscn", "industrial/metallurgy/loading_bay_copper.tscn",
	"industrial/metallurgy/loading_bay_rare_earths.tscn",
]
## Fixed props with no name to show: the map names them.
const UNSIGNED := ["industrial/power/wind_field_block.tscn", "urban/streets/parking_lot.tscn"]
## Variant -> the building it inherits, under another sign.
const VARIANTS := {
	"buildings/commerce/grocery_store.tscn": "buildings/commerce/retail_shop.tscn",
	"buildings/commerce/clothing_store.tscn": "buildings/commerce/retail_shop.tscn",
	"buildings/commerce/hardware_store.tscn": "buildings/commerce/retail_shop.tscn",
	"industrial/metallurgy/casting_hall_iron.tscn": "industrial/metallurgy/casting_hall.tscn",
	"industrial/metallurgy/casting_hall_copper.tscn": "industrial/metallurgy/casting_hall.tscn",
	"industrial/metallurgy/casting_hall_rare_earths.tscn": "industrial/metallurgy/casting_hall.tscn",
	"industrial/metallurgy/loading_bay_iron.tscn": "industrial/metallurgy/loading_bay.tscn",
	"industrial/metallurgy/loading_bay_copper.tscn": "industrial/metallurgy/loading_bay.tscn",
	"industrial/metallurgy/loading_bay_rare_earths.tscn": "industrial/metallurgy/loading_bay.tscn",
}

## The smallest capitals a sign may shrink to on its facade and still be read from the street (m).
const MIN_LETTER_M := 0.5

var _rows := {}  # translation key -> {en, fr}


func before_all() -> void:
	_rows = LayoutFile.translations()


func test_each_building_is_a_networked_fixed_prop() -> void:
	for scene: String in BUILDINGS + UNSIGNED:
		var root: Node3D = load(S + scene).instantiate()
		var sync := PropSync.of(root)
		assert_not_null(sync, "%s: a layout spawns it" % scene.get_file())
		if sync != null:
			assert_eq(sync.type_name, "simple_building", scene.get_file())
		var ground := root.get_node_or_null("TerrainPad/Ground") as CSGBox3D
		assert_not_null(ground, "%s: levels its ground" % scene.get_file())
		if ground != null:
			assert_lt(ground.position.y + ground.size.y * 0.5, 0.0, "%s: the ground under the floor" % scene.get_file())
		assert_eq(root.find_children("*", "TerrainPad", true, false).size(), 1,
				"%s: one pad (a second would take the same uuid)" % scene.get_file())
		root.free()
	KnownEngineErrors.forgive_floor_material(self)


func test_each_building_is_named_in_both_languages() -> void:
	for scene: String in BUILDINGS:
		var root: Node3D = load(S + scene).instantiate()
		var sign := root.get_node_or_null("NeonSign") as NeonSign
		assert_not_null(sign, "%s: its name in neon" % scene.get_file())
		if sign != null:
			assert_true(sign.branded, "%s: in its subsidiary's colour" % scene.get_file())
			_assert_translated(sign.text_key, scene)
		root.free()


## A sign never overhangs its facade: its max_width is within the wall (or board) it hangs on, and in
## every language its letters shrink to it without becoming too small to read.
func test_each_sign_holds_on_its_facade_in_both_languages() -> void:
	var locale := TranslationServer.get_locale()
	for scene: String in BUILDINGS:
		var root: Node3D = load(S + scene).instantiate()
		var sign := root.get_node_or_null("NeonSign") as NeonSign
		var wall := _facade_of(root)
		if sign != null and wall != null:
			assert_gt(sign.max_width, 0.0, "%s: its sign knows its facade's width" % scene.get_file())
			assert_lte(sign.max_width, wall.size.x, "%s: its sign within its %s" % [scene.get_file(), wall.name])
			for lang: String in ["en", "fr"]:
				TranslationServer.set_locale(lang)
				var shown := sign.shown_text()
				assert_gte(sign.drawn_letter_height(shown), MIN_LETTER_M,
						"%s (%s): %s still readable" % [scene.get_file(), lang, shown])
		root.free()
	TranslationServer.set_locale(locale)


func test_each_one_is_on_the_map() -> void:
	for scene: String in BUILDINGS + UNSIGNED:
		var root: Node3D = load(S + scene).instantiate()
		var marker := root.get_node_or_null("MapMarker") as MapMarker
		assert_not_null(marker, "%s: a map marker" % scene.get_file())
		if marker != null:
			assert_not_null(marker.icon, "%s: its icon" % scene.get_file())
			_assert_translated(marker.label, scene)
		root.free()


func test_a_variant_is_its_base_under_another_sign() -> void:
	for scene: String in VARIANTS:
		assert_eq(LayoutFile.base_of(S + scene), S + VARIANTS[scene], "%s inherits its base" % scene.get_file())
		var root: Node3D = load(S + scene).instantiate()
		var base: Node3D = load(S + VARIANTS[scene]).instantiate()
		assert_ne((root.get_node("NeonSign") as NeonSign).text_key, (base.get_node("NeonSign") as NeonSign).text_key,
				"%s: its own sign" % scene.get_file())
		assert_ne((root.get_node("MapMarker") as MapMarker).label, (base.get_node("MapMarker") as MapMarker).label,
				"%s: its own map label" % scene.get_file())
		root.free()
		base.free()


func test_the_wind_field_block_is_nine_turbines_on_the_sketch_grid() -> void:
	var root: Node3D = load(S + "industrial/power/wind_field_block.tscn").instantiate()
	var turbines := root.get_children().filter(func(n: Node) -> bool: return n.name.begins_with("WindTurbine"))
	assert_eq(turbines.size(), 9)
	var ground := root.get_node("TerrainPad/Ground") as CSGBox3D
	for t: Node3D in turbines:
		assert_lt(absf(t.position.x), ground.size.x * 0.5, "%s on the pad" % t.name)
		assert_lt(absf(t.position.z), ground.size.z * 0.5, "%s on the pad" % t.name)
	root.free()


func _assert_translated(key: String, scene: String) -> void:
	assert_true(_rows.has(key), "%s: %s in the localisation table" % [scene.get_file(), key])
	if _rows.has(key):
		assert_ne(str(_rows[key]["en"]), "", "%s: %s in English" % [scene.get_file(), key])
		assert_ne(str(_rows[key]["fr"]), "", "%s: %s in French" % [scene.get_file(), key])


## The box the sign hangs on: the loading bay's fascia, a lot's sign board, the water reserve's pump house,
## else the building's block.
func _facade_of(root: Node) -> CSGBox3D:
	for path: String in ["Blockout/Fascia", "SignBoard", "PumpHouse", "Blockout"]:
		var box := root.get_node_or_null(path) as CSGBox3D
		if box != null:
			return box
	return null
