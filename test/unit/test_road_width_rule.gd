extends GutTest
## Suite for the highway lane rule in [RoadTerrain]: a highway is
## lanes × LANE_WIDTH_M + MEDIAN_GAP_M whatever its QGIS `width` says, its
## cross-section is two carriageways around the median, and on the corundum
## plateau it gets the melted-corundum surface.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_road_width_rule.gd


func test_highway_half_width_follows_lanes_not_width() -> void:
	assert_almost_eq(RoadTerrain.get_half_width_m({"road_type": "highway"}), 7.25, 1e-9,
			"4 lanes by default: (4 × 3.5 + 0.5) / 2")
	assert_almost_eq(RoadTerrain.get_half_width_m({"road_type": "highway", "width": 12.0}),
			7.25, 1e-9, "the QGIS pre-fill is ignored")
	assert_almost_eq(RoadTerrain.get_half_width_m({"road_type": "highway", "lanes": 2}),
			3.75, 1e-9, "2 lanes")
	assert_almost_eq(RoadTerrain.get_half_width_m({"road_type": "highway", "lanes": 3}),
			5.5, 1e-9, "3 lanes")
	assert_almost_eq(RoadTerrain.get_half_width_m({"road_type": "highway", "lanes": 0}),
			7.25, 1e-9, "a legacy GeoJSON zone stores 0 for unset")
	assert_almost_eq(RoadTerrain.HALF_WIDTH_M["highway"], 7.25, 1e-9,
			"the type default states the same number")


func test_other_types_keep_the_width_rule() -> void:
	assert_almost_eq(RoadTerrain.get_half_width_m({"road_type": "road", "width": 8.0}),
			4.0, 1e-9, "a road's width is halved")
	assert_almost_eq(RoadTerrain.get_half_width_m({"road_type": "road", "lanes": 6}),
			3.0, 1e-9, "a road's lanes do not size it")
	assert_almost_eq(RoadTerrain.get_half_width_m({"road_type": "trail"}), 0.5, 1e-9)


func test_lanes_of() -> void:
	assert_eq(RoadTerrain.lanes_of({"road_type": "highway"}), 4)
	assert_eq(RoadTerrain.lanes_of({"road_type": "highway", "lanes": 0}), 4)
	assert_eq(RoadTerrain.lanes_of({"road_type": "highway", "lanes": 6}), 6)
	assert_eq(RoadTerrain.lanes_of({"road_type": "road"}), 0, "no default outside MEDIAN_TYPES")
	assert_eq(RoadTerrain.lanes_of({"road_type": "road", "lanes": 2}), 2)


func test_lane_layout_of_a_four_lane_highway() -> void:
	var layout := RoadTerrain.lane_layout("highway", 4, 7.25)
	var strips: Array = layout["strips"]
	assert_eq(strips.size(), 2, "two carriageways")
	assert_eq(strips[0], Vector2(-7.25, -0.25), "from the -hw edge to the median")
	assert_eq(strips[1], Vector2(0.25, 7.25), "from the median to the +hw edge")
	assert_eq(layout["median"], Vector2(-0.25, 0.25), "the median is centred")
	assert_almost_eq(float(strips[0].y - strips[0].x), 7.0, 1e-9, "2 lanes each")


func test_lane_layout_of_a_three_lane_highway() -> void:
	var layout := RoadTerrain.lane_layout("highway", 3, 5.5)
	assert_eq(layout["median"], Vector2(-2.0, -1.5),
			"after floor(3 / 2) = 1 lane counted from the -hw edge")
	assert_eq(layout["strips"][0], Vector2(-5.5, -2.0))
	assert_eq(layout["strips"][1], Vector2(-1.5, 5.5))


func test_lane_layout_without_a_median() -> void:
	var road := RoadTerrain.lane_layout("road", 2, 3.0)
	assert_eq((road["strips"] as Array).size(), 1, "a road is one strip")
	assert_eq(road["strips"][0], Vector2(-3.0, 3.0))
	assert_eq(road["median"], Vector2.ZERO)
	var one_lane := RoadTerrain.lane_layout("highway", 1, 2.0)
	assert_eq((one_lane["strips"] as Array).size(), 1, "fewer than 2 lanes: no median")
	assert_eq(RoadTerrain.lane_layout_of({"road_type": "highway"})["median"],
			Vector2(-0.25, 0.25))


func test_material_selection() -> void:
	assert_eq(RoadTerrain.get_material_path("highway", "", true),
			RoadTerrain.CORUNDUM_HIGHWAY_MATERIAL_PATH, "a highway on default corundum")
	assert_eq(RoadTerrain.get_material_path("highway", RoadTerrain.CORUNDUM_BIOME_TYPE),
			RoadTerrain.CORUNDUM_HIGHWAY_MATERIAL_PATH, "or in a zone naming the plateau")
	assert_eq(RoadTerrain.get_material_path("highway", "meadow_steppe-meadow"),
			RoadTerrain.ASPHALT_MATERIAL_PATH, "elsewhere: asphalt")
	assert_eq(RoadTerrain.get_material_path("road", "", true),
			RoadTerrain.ASPHALT_MATERIAL_PATH, "a road stays asphalt on corundum")
	assert_eq(RoadTerrain.get_material_path("highway", "aride_desert-corundum_sand_desert"),
			RoadTerrain.CORUNDUM_HIGHWAY_MATERIAL_PATH, "every corundum biome")


func test_corundum_ground_rule() -> void:
	assert_true(RoadTerrain.is_corundum_ground("", "", true), "the corundum default")
	assert_true(RoadTerrain.is_corundum_ground("aride_desert-corundum_plateau"))
	assert_true(RoadTerrain.is_corundum_ground("outcrop-plateau", "corundum_white"),
			"an outcrop of a corundum variety (tarsis_3's zones)")
	assert_true(RoadTerrain.is_corundum_ground("outcrop-plateau", "emery"), "impure corundum")
	assert_false(RoadTerrain.is_corundum_ground("outcrop-plateau", "hercynite_oxidised"))
	assert_false(RoadTerrain.is_corundum_ground("meadow_steppe-meadow"))
	assert_false(RoadTerrain.is_corundum_ground("", "", false), "no zone, no default: not corundum")
	assert_true(RoadTerrain.keeps_parallax(RoadTerrain.CORUNDUM_HIGHWAY_MATERIAL_PATH))
	assert_false(RoadTerrain.keeps_parallax(RoadTerrain.ASPHALT_MATERIAL_PATH))
	assert_true(RoadTerrain.is_corundum_surface(RoadTerrain.CORUNDUM_HIGHWAY_MATERIAL_PATH))


func test_surface_constants() -> void:
	assert_almost_eq(RoadTerrain.SURFACE_THICKNESS_M, 0.08, 1e-9, "an 8 cm slab")
	assert_almost_eq(RoadTerrain.LANE_WIDTH_M, 3.5, 1e-9)
	assert_almost_eq(RoadTerrain.MEDIAN_GAP_M, 0.5, 1e-9)
	assert_almost_eq(RoadTerrain.GAUFRAGE_ACROSS_M, RoadTerrain.LANE_WIDTH_M, 1e-9,
			"the engraved tile is one lane wide")
