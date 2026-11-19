extends GutTest
## StarMapPoi regions: the named parts of the map ("Rox Planum Centralis") come from <body>_poi.json,
## not from the terrain-modifier pack any more, where they were 180 MB of tarsis_3's biomes. These
## tests pin the parse and the "which region am I in" lookup.


## A square ring of [param half] degrees around ([param lon], [param lat]), as the export writes it.
func _square(lon: float, lat: float, half: float) -> Array:
	return [[lon - half, lat - half], [lon + half, lat - half], [lon + half, lat + half], [lon - half, lat + half]]


func _parsed() -> Dictionary:
	# Smallest first, as export/planet/regions.py sorts them: the enclave before its host.
	return {"regions": [
		{"name": "Inner Planum", "rings": [_square(10.0, 20.0, 1.0)]},
		{"name": "Outer Planitia", "rings": [_square(10.0, 20.0, 5.0)]},
		{"name": "Twin Planum", "rings": [_square(-60.0, -10.0, 2.0), _square(-40.0, -10.0, 2.0)]},
	]}


func test_regions_parse_with_their_box_and_label_direction() -> void:
	var regions: Array[Dictionary] = StarMapPoi.regions_from(_parsed())
	assert_eq(regions.size(), 3)
	assert_eq(str(regions[0]["name"]), "Inner Planum")
	var box: Rect2 = regions[1]["bbox"]
	assert_almost_eq(box.position.x, 5.0, 1e-6)
	assert_almost_eq(box.end.y, 25.0, 1e-6)
	var dir: Vector3 = regions[0]["dir"]
	var ll: Vector2 = HEALPix.vec2lonlat(dir)
	assert_almost_eq(ll.x, 10.0, 0.01, "the label stands at the middle of the ring")
	assert_almost_eq(ll.y, 20.0, 0.05)


func test_a_point_names_the_smallest_region_holding_it() -> void:
	var regions: Array[Dictionary] = StarMapPoi.regions_from(_parsed())
	assert_eq(StarMapPoi.region_in(regions, HEALPix.lonlat2vec(10.0, 20.0)), "Inner Planum")
	assert_eq(StarMapPoi.region_in(regions, HEALPix.lonlat2vec(13.0, 22.0)), "Outer Planitia")


func test_every_ring_of_a_multipart_region_counts() -> void:
	var regions: Array[Dictionary] = StarMapPoi.regions_from(_parsed())
	assert_eq(StarMapPoi.region_in(regions, HEALPix.lonlat2vec(-60.0, -10.0)), "Twin Planum")
	assert_eq(StarMapPoi.region_in(regions, HEALPix.lonlat2vec(-40.0, -10.0)), "Twin Planum")
	assert_eq(StarMapPoi.region_in(regions, HEALPix.lonlat2vec(-50.0, -10.0)), "", "between the two parts")


func test_outside_every_region_is_nameless() -> void:
	var regions: Array[Dictionary] = StarMapPoi.regions_from(_parsed())
	assert_eq(StarMapPoi.region_in(regions, HEALPix.lonlat2vec(100.0, 0.0)), "")
	assert_eq(StarMapPoi.region_in(regions, Vector3.ZERO), "")


func test_malformed_entries_are_dropped_not_fatal() -> void:
	var regions: Array[Dictionary] = StarMapPoi.regions_from({"regions": [
		{"name": "", "rings": [_square(0.0, 0.0, 1.0)]},
		{"name": "Two Points", "rings": [[[0.0, 0.0], [1.0, 1.0]]]},
		"not a region",
		{"name": "Fine", "rings": [_square(0.0, 0.0, 1.0)]},
	]})
	assert_eq(regions.size(), 1)
	assert_eq(str(regions[0]["name"]), "Fine")
	assert_eq(StarMapPoi.regions_from({}).size(), 0, "a file with no regions has none")
