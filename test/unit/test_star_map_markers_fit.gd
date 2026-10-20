extends GutTest
## Every pictogram stands in the same square on screen, wide or tall (StarMapMarkers.fit_square).


func test_a_wide_picture_fills_the_width() -> void:
	assert_eq(StarMapMarkers.fit_square(200.0, 100.0), Vector2(1.0, 0.5))


func test_a_tall_picture_fills_the_height() -> void:
	assert_eq(StarMapMarkers.fit_square(100.0, 200.0), Vector2(0.5, 1.0))


func test_a_square_is_the_square() -> void:
	assert_eq(StarMapMarkers.fit_square(150.0, 150.0), Vector2(1.0, 1.0))


func test_coordinates_are_copied_latitude_first_to_six_decimals() -> void:
	var text: String = StarMapGestures.coordinates_text(Vector3(1.0, 0.0, 0.0))
	var parts: PackedStringArray = text.split(", ")
	assert_eq(parts.size(), 2, "latitude, longitude")
	assert_eq(parts[0].get_slice(".", 1).length(), 6)
	assert_almost_eq(float(parts[0]), 0.0, 1e-6, "on the equator")


func _item(id: int, key: String, x: float, importance: int = 2) -> Dictionary:
	return {"id": id, "key": key, "px": Vector2(x, 100.0), "radius_px": 10.0, "importance": importance}


func test_alike_pictograms_over_each_other_are_drawn_as_one() -> void:
	var groups: Array = StarMapMarkers.overlapping_groups([_item(1, "home", 0.0), _item(2, "home", 5.0),
			_item(3, "home", 200.0)])
	assert_eq(groups.size(), 1)
	assert_eq(groups[0], [1, 2], "the one far off stays on its own")


func test_different_pictograms_never_merge() -> void:
	assert_eq(StarMapMarkers.overlapping_groups([_item(1, "home", 0.0), _item(2, "garage", 2.0)]).size(), 0)


func test_the_more_important_leads_its_group() -> void:
	var groups: Array = StarMapMarkers.overlapping_groups([_item(1, "home", 0.0, 3), _item(2, "home", 5.0, 1)])
	assert_eq(groups[0][0], 2)


func test_a_group_reads_its_count() -> void:
	assert_eq(StarMapMarkers.group_id(0), -2, "never a marker's id, never -1")
