extends GutTest
## Regression suite for the populate-zone outline key split.
##
## Two producers disagreed on where a zone's outline lives:
##   · recipe/pack exports write `vertices` — an Array of [lon, lat] pairs
##     (tools/qgis/export/planet/recipe.py)
##   · PlanetData.inject_biome_feature() wrote `polygon` — a PackedVector2Array
##
## The client cliff displacement (PlanetChunk.generate_mesh) read `polygon`
## while the server collision path (PlanetChunk.generate_collision_shape) read
## `vertices`, so recipe-sourced cliffs were carved on the server and NOT on the
## client — a silent divergence of up to RockyLandformCliffTerrain.DROP_M (50 m)
## between what a player sees and what they collide with. Injected zones had the
## mirror problem: `_dir_in_populate_zone()` only ever reads `vertices`, so a
## zone injected with `polygon` alone was invisible to every per-vertex test.
##
## Both sides now go through PlanetChunk._zone_outline(), and
## inject_biome_feature() writes both keys.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gdir=res://test/unit -gtest=test_cliff_zone_keys.gd

const PlanetChunkScript := preload("res://scenes/planet/planet_chunk.gd")
const PlanetDataScript := preload("res://scenes/planet/planet_data.gd")

## A square around lon 10°, lat 20°, 2° on a side.
const LON_C := 10.0
const LAT_C := 20.0
const HALF := 1.0


func _square_vertices() -> Array:
	return [
		[LON_C - HALF, LAT_C - HALF],
		[LON_C + HALF, LAT_C - HALF],
		[LON_C + HALF, LAT_C + HALF],
		[LON_C - HALF, LAT_C + HALF],
	]


func _square_packed() -> PackedVector2Array:
	var p := PackedVector2Array()
	for v in _square_vertices():
		p.append(Vector2(v[0], v[1]))
	return p


# ── _zone_outline() reads both producers ────────────────────────────────

func test_outline_from_vertices_key() -> void:
	var zone := {"vertices": _square_vertices()}
	var outline := PlanetChunkScript._zone_outline(zone)
	assert_eq(outline.size(), 4, "recipe-style `vertices` must yield 4 points")
	assert_almost_eq(outline[0].x, LON_C - HALF, 1e-6, "lon of first vertex")
	assert_almost_eq(outline[0].y, LAT_C - HALF, 1e-6, "lat of first vertex")


func test_outline_from_polygon_key() -> void:
	var zone := {"polygon": _square_packed()}
	var outline := PlanetChunkScript._zone_outline(zone)
	assert_eq(outline.size(), 4, "injected-style `polygon` must yield 4 points")
	assert_almost_eq(outline[2].x, LON_C + HALF, 1e-6, "lon of third vertex")
	assert_almost_eq(outline[2].y, LAT_C + HALF, 1e-6, "lat of third vertex")


func test_outline_agrees_across_keys() -> void:
	# This is the actual regression: the visual path and the collision path must
	# see the SAME outline whichever key the producer used.
	var from_verts := PlanetChunkScript._zone_outline({"vertices": _square_vertices()})
	var from_poly := PlanetChunkScript._zone_outline({"polygon": _square_packed()})
	assert_eq(from_verts.size(), from_poly.size(), "same point count")
	for i in from_verts.size():
		assert_almost_eq(from_verts[i].x, from_poly[i].x, 1e-6, "lon[%d]" % i)
		assert_almost_eq(from_verts[i].y, from_poly[i].y, 1e-6, "lat[%d]" % i)


func test_outline_empty_when_degenerate() -> void:
	assert_eq(PlanetChunkScript._zone_outline({}).size(), 0, "no keys → empty")
	assert_eq(PlanetChunkScript._zone_outline({"vertices": []}).size(), 0,
			"empty vertices → empty")
	assert_eq(PlanetChunkScript._zone_outline(
			{"vertices": [[0.0, 0.0], [1.0, 1.0]]}).size(), 0,
			"a 2-point outline is not a polygon")


func test_outline_prefers_vertices_when_both_present() -> void:
	# Both keys are written by inject_biome_feature(); they must describe the
	# same ring, and `vertices` is the canonical one.
	var zone := {"vertices": _square_vertices(), "polygon": _square_packed()}
	var outline := PlanetChunkScript._zone_outline(zone)
	assert_eq(outline.size(), 4, "both keys present → still 4 points")


# ── inject_biome_feature() writes both keys ─────────────────────────────

func _inject_polygon_zone() -> Dictionary:
	var data = PlanetDataScript.new()
	data.planet_name = "testcliff"
	data.radius = 1000.0
	var verts: Array = []
	for v in _square_vertices():
		verts.append([v[0], v[1]])
	# inject_biome_feature() keys on the nside it is given, while
	# get_chunk_populate_zones() always reads at export_nside — they must match.
	data.inject_biome_feature(data.export_nside, 123, {
		"biome_type": "rocky_landform-cliff",
		"action": "add",
		"geometry": {"type": "polygon", "vertices": verts},
	})
	var zones: Array = data.get_chunk_populate_zones(123)
	assert_eq(zones.size(), 1, "one zone injected")
	return zones[0] if zones.size() > 0 else {}


func test_injected_zone_has_both_outline_keys() -> void:
	var zone := _inject_polygon_zone()
	assert_true(zone.has("vertices"), "injected zone must carry `vertices`")
	assert_true(zone.has("polygon"), "injected zone must carry `polygon`")
	assert_eq((zone.get("vertices", []) as Array).size(), 4, "4 vertices")
	assert_eq((zone.get("polygon", PackedVector2Array()) as PackedVector2Array).size(),
			4, "4 polygon points")


func test_injected_zone_coverage_is_partial() -> void:
	# "polygon" was never a coverage value any consumer understood;
	# _dir_in_populate_zone() only special-cases "full" and "point".
	var zone := _inject_polygon_zone()
	assert_eq(zone.get("coverage", ""), "partial",
			"outlined injected zones use the recipe vocabulary")


func test_injected_zone_is_visible_to_containment_test() -> void:
	# The mirror bug: a zone injected with `polygon` only was invisible here,
	# because _dir_in_populate_zone() reads `vertices`.
	var zone := _inject_polygon_zone()
	var lon_r := deg_to_rad(LON_C)
	var lat_r := deg_to_rad(LAT_C)
	var inside_dir := Vector3(
		cos(lat_r) * cos(lon_r), sin(lat_r), cos(lat_r) * sin(lon_r))
	assert_true(PlanetChunkScript._dir_in_populate_zone(inside_dir, zone),
			"a direction at the zone centre must test as inside")

	var out_lon_r := deg_to_rad(LON_C + 10.0)
	var outside_dir := Vector3(
		cos(lat_r) * cos(out_lon_r), sin(lat_r), cos(lat_r) * sin(out_lon_r))
	assert_false(PlanetChunkScript._dir_in_populate_zone(outside_dir, zone),
			"a direction 10° away must test as outside")
