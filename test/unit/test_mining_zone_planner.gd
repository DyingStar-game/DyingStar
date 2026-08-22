extends GutTest
## GUT test suite for MiningZonePlanner's decision logic — the part that must be reproducible.
##
## The planner's promise is that a chunk's fate is DERIVED, never stored: the same (planet uuid,
## chunk key) yields the same uuid, the same deposit verdict, the same mineral and richness, on
## every server and after every restart. That is what makes "has this chunk already been done?"
## answerable without a marker in the database, so it is what these tests pin down.
##
## Everything covered here is static and pure — no planet, no server, no scene tree.
##
##   Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gdir=res://test/unit -gtest=test_mining_zone_planner.gd

const PLANET := "_planet_SandBox"
const KEY_A := "hp_n8192_p123456"
const KEY_B := "hp_n8192_p123457"


# ===================================================================
# 1. Deterministic identity
# ===================================================================

func test_zone_uuid_is_stable_across_calls() -> void:
	var first := MiningZonePlanner.zone_uuid_for(PLANET, KEY_A)
	for _i in 5:
		assert_eq(MiningZonePlanner.zone_uuid_for(PLANET, KEY_A), first,
			"same planet + same chunk must always derive the same uuid — this is what makes "
			+ "Horizon upsert the zone instead of stacking a duplicate on every restart")


func test_zone_uuid_has_uuid_shape() -> void:
	var u := MiningZonePlanner.zone_uuid_for(PLANET, KEY_A)
	assert_eq(u.length(), 36)
	var parts := u.split("-")
	assert_eq(parts.size(), 5)
	assert_eq([parts[0].length(), parts[1].length(), parts[2].length(),
		parts[3].length(), parts[4].length()], [8, 4, 4, 4, 12])


func test_zone_uuid_differs_per_chunk_and_per_planet() -> void:
	assert_ne(MiningZonePlanner.zone_uuid_for(PLANET, KEY_A),
		MiningZonePlanner.zone_uuid_for(PLANET, KEY_B))
	assert_ne(MiningZonePlanner.zone_uuid_for(PLANET, KEY_A),
		MiningZonePlanner.zone_uuid_for("other_planet", KEY_A))


# ===================================================================
# 2. Deposit draw
# ===================================================================

func test_deposit_rate_extremes() -> void:
	assert_false(MiningZonePlanner.has_deposit(PLANET, KEY_A, 0.0),
		"rate 0 must seed nothing at all")
	assert_true(MiningZonePlanner.has_deposit(PLANET, KEY_A, 1.0),
		"rate 1 must seed every candidate cell")


func test_deposit_verdict_is_stable() -> void:
	var first := MiningZonePlanner.has_deposit(PLANET, KEY_A, 0.15)
	for _i in 5:
		assert_eq(MiningZonePlanner.has_deposit(PLANET, KEY_A, 0.15), first,
			"a barren chunk is never written to the database, so its verdict has to be "
			+ "re-derivable identically or the planner would seed it on the next visit")


func test_deposit_rate_is_roughly_honoured() -> void:
	# The draw only has to be flat enough that the configured rate means something. 2000 chunks
	# keeps the tolerance meaningful without making the suite slow.
	var hits := 0
	for i in 2000:
		if MiningZonePlanner.has_deposit(PLANET, "hp_n8192_p%d" % i, 0.25):
			hits += 1
	var ratio := float(hits) / 2000.0
	assert_between(ratio, 0.20, 0.30,
		"deposit rate 0.25 produced %.3f over 2000 chunks" % ratio)


func test_deposit_is_monotonic_in_rate() -> void:
	# A chunk that carries a deposit at 25% must still carry one at 50%: the draw is a single
	# threshold, so raising the rate may only ever add deposits, never move them around.
	for i in 300:
		var key := "hp_n8192_p%d" % i
		if MiningZonePlanner.has_deposit(PLANET, key, 0.25):
			assert_true(MiningZonePlanner.has_deposit(PLANET, key, 0.5),
				"chunk %s dropped out when the rate went up" % key)


# ===================================================================
# 2b. Field size and rock count, derived from the chunk
# ===================================================================

const TARSIS_R := 6356000.0


func test_zone_size_tracks_the_chunk_side() -> void:
	# n8192 on tarsis_4 is a ~794 m chunk; the field is that side scaled by the fill.
	var chunk := HEALPix.pixel_side_length(8192, TARSIS_R)
	assert_almost_eq(chunk, 794.0, 2.0, "chunk side at n8192")
	assert_almost_eq(MiningZonePlanner.zone_size_for(8192, TARSIS_R, 1.0), chunk, 0.01)
	assert_almost_eq(MiningZonePlanner.zone_size_for(8192, TARSIS_R, 0.5), chunk * 0.5, 0.01)


func test_zone_size_follows_the_terrain_lod() -> void:
	# The whole point of deriving it: one level finer halves the chunk, so the field halves too
	# without anyone re-tuning the planet.
	var coarse := MiningZonePlanner.zone_size_for(8192, TARSIS_R, 0.88)
	var fine := MiningZonePlanner.zone_size_for(16384, TARSIS_R, 0.88)
	assert_almost_eq(fine, coarse * 0.5, 0.01)


func test_zone_size_clamps_the_fill() -> void:
	var chunk := HEALPix.pixel_side_length(8192, TARSIS_R)
	assert_almost_eq(MiningZonePlanner.zone_size_for(8192, TARSIS_R, 5.0), chunk, 0.01)
	assert_eq(MiningZonePlanner.zone_size_for(8192, TARSIS_R, -1.0), 0.0)


func test_rock_count_is_a_density() -> void:
	# 120 rocks/km² over a 500 m field is the historical 30-rock look.
	assert_eq(MiningZonePlanner.rock_count_for(500.0, 120.0), 30)
	# Same density, bigger field → proportionally more rocks, so deposits keep their richness.
	assert_eq(MiningZonePlanner.rock_count_for(1000.0, 120.0), 120)


func test_rock_count_never_yields_an_empty_deposit() -> void:
	assert_eq(MiningZonePlanner.rock_count_for(10.0, 0.001), 1,
		"a deposit with no rocks in it is not a deposit")
	assert_eq(MiningZonePlanner.rock_count_for(500.0, 0.0), 1)


func test_rock_count_is_capped() -> void:
	# The spawn throttle releases one rock per 10 physics frames; an absurd density must not turn
	# into a zone that takes an hour to appear.
	assert_eq(MiningZonePlanner.rock_count_for(1000.0, 1_000_000.0),
		MiningZonePlanner.MAX_ROCKS_PER_ZONE)


# ===================================================================
# 3. Mineral and richness draws
# ===================================================================

func test_pick_mineral_is_stable_and_registered() -> void:
	var ids := PackedStringArray(["iron", "gold", "cryptonite"])
	var weights := PackedFloat32Array([0.6, 0.3, 0.1])
	var first := MiningZonePlanner.pick_mineral(PLANET, KEY_A, ids, weights)
	assert_true(MineralRegistry.has_mineral(StringName(first)))
	assert_eq(MiningZonePlanner.pick_mineral(PLANET, KEY_A, ids, weights), first)


func test_pick_mineral_skips_unknown_ids() -> void:
	# An unregistered id must never reach a rock: there it would only surface as a warning per
	# rock at mining time, long after the zone was persisted.
	var ids := PackedStringArray(["unobtanium", "gold"])
	var weights := PackedFloat32Array([1000.0, 1.0])
	for i in 50:
		assert_eq(MiningZonePlanner.pick_mineral(PLANET, "hp_n8192_p%d" % i, ids, weights), "gold")


func test_pick_mineral_falls_back_when_table_is_unusable() -> void:
	var got := MiningZonePlanner.pick_mineral(
		PLANET, KEY_A, PackedStringArray([]), PackedFloat32Array([]))
	assert_true(MineralRegistry.has_mineral(StringName(got)))


func test_pick_mineral_honours_weights() -> void:
	var ids := PackedStringArray(["iron", "gold"])
	var weights := PackedFloat32Array([0.9, 0.1])
	var iron := 0
	for i in 1000:
		if MiningZonePlanner.pick_mineral(PLANET, "hp_n8192_p%d" % i, ids, weights) == "iron":
			iron += 1
	assert_between(float(iron) / 1000.0, 0.85, 0.95)


func test_pick_richness_stays_in_range_and_is_stable() -> void:
	for i in 200:
		var r := MiningZonePlanner.pick_richness(PLANET, "hp_n8192_p%d" % i, 0.25, 0.75)
		assert_between(r, 0.25, 0.75)
	assert_eq(MiningZonePlanner.pick_richness(PLANET, KEY_A, 0.25, 0.75),
		MiningZonePlanner.pick_richness(PLANET, KEY_A, 0.25, 0.75))


func test_pick_richness_tolerates_swapped_bounds() -> void:
	assert_between(MiningZonePlanner.pick_richness(PLANET, KEY_A, 0.75, 0.25), 0.25, 0.75)


# ===================================================================
# 4. Chunk key parsing — must agree with PlanetTerrain.collision_chunk_key
# ===================================================================

func test_parse_zone_key_round_trips_the_terrain_format() -> void:
	# The key is produced by PlanetTerrain.collision_chunk_key and read back here, so the two have
	# to agree on the format.
	var parsed := MiningZonePlanner._parse_zone_key("hp_n8192_p123456")
	assert_eq(parsed.x, 8192)
	assert_eq(parsed.y, 123456)


func test_parse_zone_key_rejects_malformed_keys() -> void:
	for bad in ["", "hp_n8192", "garbage", "hp_x8192_p1", "hp_n8192_q1"]:
		assert_eq(MiningZonePlanner._parse_zone_key(bad).y, -1,
			"'%s' should not parse as a chunk key" % bad)


# ===================================================================
# 4b. POI exclusion — one definition shared by the siting and the rocks
# ===================================================================

func _village(pos: Vector3, radius: float) -> Dictionary:
	return {"name": "mining_village_01", "position": pos, "radius": radius}


func test_poi_blocks_exactly_at_radius_plus_margin() -> void:
	# mining_village_01: radius 1000, margin 10 -> the boundary sits at 1010 m and nowhere else.
	var spheres := [_village(Vector3.ZERO, 1000.0)]
	assert_false(PlanetTerrain.first_blocking_poi(Vector3(1009.0, 0, 0), spheres, 10.0).is_empty(),
		"1009 m from the centre is inside 1010 -> blocked")
	assert_true(PlanetTerrain.first_blocking_poi(Vector3(1011.0, 0, 0), spheres, 10.0).is_empty(),
		"1011 m from the centre is outside 1010 -> clear")


func test_poi_hit_reports_the_offender() -> void:
	var spheres := [_village(Vector3.ZERO, 1000.0)]
	var hit := PlanetTerrain.first_blocking_poi(Vector3(500, 0, 0), spheres, 10.0)
	assert_eq(hit["name"], "mining_village_01")
	assert_almost_eq(float(hit["distance"]), 500.0, 0.01)
	assert_almost_eq(float(hit["radius"]), 1000.0, 0.01)


func test_poi_empty_list_blocks_nothing() -> void:
	assert_true(PlanetTerrain.first_blocking_poi(Vector3.ZERO, [], 10.0).is_empty())


func test_poi_picks_the_first_offender_among_many() -> void:
	var spheres := [
		_village(Vector3(10000, 0, 0), 1000.0),
		{"name": "city", "position": Vector3.ZERO, "radius": 25000.0},
	]
	assert_eq(PlanetTerrain.first_blocking_poi(Vector3(500, 0, 0), spheres, 10.0)["name"], "city")


# ===================================================================
# 5. Road exclusion margin (RoadTerrain, extended for footprint-sized callers)
# ===================================================================

func _straight_road(half_width_m: float) -> Array:
	# A road along the equator, from lon 0 to lon 1.
	return [{
		"centerline": PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 0.0)]),
		"half_width_m": half_width_m,
	}]


const M_PER_DEG := 6356000.0 * PI / 180.0


func test_point_on_any_road_default_margin_is_unchanged() -> void:
	# Non-regression for the three vegetation spawners, which call the 4-argument form.
	var roads := _straight_road(10.0)
	assert_true(RoadTerrain.point_on_any_road(0.5, 0.0, roads, M_PER_DEG),
		"a point on the centreline is on the road")
	# 200 m off the centreline of a road 10 m wide either side → clear.
	assert_false(RoadTerrain.point_on_any_road(0.5, 200.0 / M_PER_DEG, roads, M_PER_DEG))


func test_point_on_any_road_extra_margin_widens_the_test() -> void:
	var roads := _straight_road(10.0)
	var off := 200.0 / M_PER_DEG
	# The same point, now standing in for the CENTRE of a field: with a 300 m half-extent the field
	# reaches the road (10 + 300 > 200), with 100 m it does not (10 + 100 < 200).
	assert_true(RoadTerrain.point_on_any_road(0.5, off, roads, M_PER_DEG, 300.0))
	assert_false(RoadTerrain.point_on_any_road(0.5, off, roads, M_PER_DEG, 100.0))
