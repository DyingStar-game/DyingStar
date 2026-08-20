extends GutTest
## Suite for [RoadBridge] — finding where a road flies over a procedural chasm.
##
## The corundum crack network is generated at runtime, so there is nothing to
## intersect at export time; the crossings are found by walking the road and
## evaluating the field. Two properties matter and are asserted here:
##
##   · the walk is DETERMINISTIC, so the client and the server find identical
##     spans without exchanging anything (the same property the crack carving
##     itself relies on);
##   · every span has EXACTLY ONE owning chunk, so a 700 m deck straddling
##     several chunks is never built twice — the same failure the road ribbon
##     itself used to suffer.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_road_bridge.gd

const PlanetDataScript := preload("res://scenes/planet/planet_data.gd")

const RADIUS := 6356000.0
## tarsis_4's settings: gorges 250 m wide and 180 m deep, every 4 km.
const SPACING := 4000.0
const WIDTH := 250.0
const DEPTH := 180.0

var _pd: PlanetData


func before_each() -> void:
	_pd = PlanetDataScript.new()
	_pd.planet_name = "testbridge"
	_pd.radius = RADIUS
	_pd.corundum_override_whole_planet = true
	_pd.crack_spacing_m = SPACING
	_pd.crack_width_m = WIDTH
	_pd.crack_depth_m = DEPTH


## A straight east-west road of [param length_m], as a decoded pack record.
func _road(length_m: float, lat: float = 24.8, lon0: float = -39.6,
		fid: int = 7) -> Dictionary:
	var mpd := RADIUS * PI / 180.0
	var clat := cos(deg_to_rad(lat))
	var step_m := 20.0
	var n := int(length_m / step_m) + 1
	var cl := PackedVector2Array()
	var cum := PackedFloat64Array()
	for i in n:
		var d := float(i) * step_m
		cl.append(Vector2(lon0 + d / (mpd * clat), lat))
		cum.append(d)
	return {
		"feature_id": fid, "centerline": cl, "_cum_lengths": cum,
		"road_type": "road", "width_m": 6.0, "half_width_m": 3.0,
		"_total_length": cum[cum.size() - 1],
	}


# ── Detection ──────────────────────────────────────────────────────────

func test_finds_crossings_on_a_long_road() -> void:
	# A 40 km road at 4 km spacing must meet roughly ten gorges.
	var spans := RoadBridge.find_spans_in_road(_pd, _road(40000.0))
	assert_gt(spans.size(), 5, "a 40 km road crosses several gorges")
	assert_lt(spans.size(), 25, "but not absurdly many")


func test_no_crossings_when_corundum_is_off() -> void:
	_pd.corundum_override_whole_planet = false
	assert_eq(RoadBridge.find_spans_in_road(_pd, _road(40000.0)).size(), 0,
			"no crack network → nothing to bridge")


func test_spans_are_within_sane_bounds() -> void:
	for s in RoadBridge.find_spans_in_road(_pd, _road(40000.0)):
		var span: float = s["span_m"]
		assert_gt(span, RoadBridge.MIN_SPAN_M - 0.001,
				"a reported span is never shorter than the minimum")
		assert_almost_eq(float(s["along_end"]) - float(s["along_start"]),
				span, 0.001, "span_m matches its own bounds")
		assert_gt(float(s["max_depth_m"]), 0.0, "a chasm has depth")
		assert_true(float(s["max_depth_m"]) <= DEPTH + 0.001,
				"never deeper than crack_depth_m")


func test_deck_span_adds_abutment_margin() -> void:
	for s in RoadBridge.find_spans_in_road(_pd, _road(20000.0)):
		assert_almost_eq(float(s["deck_span_m"]),
				float(s["span_m"]) + RoadBridge.ABUTMENT_MARGIN_M, 0.001,
				"the deck overhangs the gap so abutments rest on ground")


func test_span_ends_sit_on_solid_ground() -> void:
	# The rim refinement must return the SOLID side; a deck landing in the void
	# is worse than no deck.
	for s in RoadBridge.find_spans_in_road(_pd, _road(20000.0)):
		var a: Vector2 = RoadBridge.lonlat_at(
			_road(20000.0)["centerline"], _road(20000.0)["_cum_lengths"],
			float(s["along_start"]))
		assert_eq(RoadBridge.chasm_depth_at(_pd, a.x, a.y), 0.0,
				"span start is on solid ground")


func test_midpoint_is_inside_the_chasm() -> void:
	for s in RoadBridge.find_spans_in_road(_pd, _road(20000.0)):
		assert_gt(RoadBridge.chasm_depth_at(_pd, s["mid_lon"], s["mid_lat"]), 0.0,
				"the middle of a span is over the void")


func test_detection_is_deterministic() -> void:
	# Client and server must agree with no replication at all.
	var a := RoadBridge.find_spans_in_road(_pd, _road(40000.0))
	var b := RoadBridge.find_spans_in_road(_pd, _road(40000.0))
	assert_eq(a.size(), b.size(), "same number of spans")
	for i in a.size():
		assert_eq(float(a[i]["along_start"]), float(b[i]["along_start"]),
				"span %d starts at exactly the same distance" % i)
		assert_eq(float(a[i]["along_end"]), float(b[i]["along_end"]),
				"span %d ends at exactly the same distance" % i)


func test_absolute_distances_survive_a_clipped_record() -> void:
	# A record clipped to a tile keeps parent-relative distances, so the spans
	# it reports are stated in the road's own coordinate system.
	var full := _road(20000.0)
	var cl: PackedVector2Array = full["centerline"]
	var cum: PackedFloat64Array = full["_cum_lengths"]
	var piece_cl := PackedVector2Array()
	var piece_cum := PackedFloat64Array()
	for i in range(cl.size() / 2, cl.size()):
		piece_cl.append(cl[i])
		piece_cum.append(cum[i])
	var piece := full.duplicate()
	piece["centerline"] = piece_cl
	piece["_cum_lengths"] = piece_cum

	var from_piece := RoadBridge.find_spans_in_road(_pd, piece)
	assert_gt(from_piece.size(), 0, "the second half still crosses gorges")
	for s in from_piece:
		assert_gt(float(s["along_start"]), piece_cum[0] - 1.0,
				"distances are absolute, not restarted at zero")


func test_lonlat_at_interpolates_and_clamps() -> void:
	var r := _road(1000.0)
	var cl: PackedVector2Array = r["centerline"]
	var cum: PackedFloat64Array = r["_cum_lengths"]
	assert_eq(RoadBridge.lonlat_at(cl, cum, -50.0), cl[0], "clamps below")
	assert_eq(RoadBridge.lonlat_at(cl, cum, 1e9), cl[cl.size() - 1], "clamps above")
	var mid := RoadBridge.lonlat_at(cl, cum, 0.5 * cum[cum.size() - 1])
	assert_almost_eq(mid.y, cl[0].y, 1e-9, "stays on the road")
	assert_true(mid.x > cl[0].x and mid.x < cl[cl.size() - 1].x,
			"lands between the ends")


# ── Ownership: the anti-duplication guarantee ──────────────────────────

func test_every_span_has_exactly_one_owner() -> void:
	# A span can be longer than a chunk. Quadtree leaves are disjoint, so
	# assigning by midpoint gives each span one and only one builder.
	var spans := RoadBridge.find_spans_in_road(_pd, _road(40000.0))
	assert_gt(spans.size(), 0, "there is something to own")
	for nside in [1024, 8192]:
		for s in spans:
			var owner_ipix := HEALPix.vec2pix_nest(nside, s["mid_dir"])
			var claimed := 0
			# Probe the owner and its 8 neighbours: only one may claim it.
			var probes: Array = [owner_ipix]
			for d in HEALPix.get_neighbors_nest(nside, owner_ipix).values():
				if d >= 0:
					probes.append(d)
			for ip in probes:
				for m in RoadBridge.spans_owned_by(spans, nside, ip):
					if m["along_start"] == s["along_start"]:
						claimed += 1
			assert_eq(claimed, 1,
					"n%d: span at %.0f m is claimed exactly once"
					% [nside, float(s["along_start"])])


func test_spans_owned_by_is_empty_for_an_unrelated_pixel() -> void:
	var spans := RoadBridge.find_spans_in_road(_pd, _road(40000.0))
	# The antipode of the first span's midpoint cannot own anything here.
	var away: Vector3 = -(spans[0]["mid_dir"] as Vector3)
	var ip := HEALPix.vec2pix_nest(64, away)
	assert_eq(RoadBridge.spans_owned_by(spans, 64, ip).size(), 0,
			"a chunk on the far side owns no span")


func test_owner_partition_covers_all_spans() -> void:
	var spans := RoadBridge.find_spans_in_road(_pd, _road(40000.0))
	var seen := {}
	for s in spans:
		var ip := HEALPix.vec2pix_nest(2048, s["mid_dir"])
		for m in RoadBridge.spans_owned_by(spans, 2048, ip):
			seen[float(m["along_start"])] = true
	assert_eq(seen.size(), spans.size(),
			"the union of all owners rebuilds the whole set — none is orphaned")


# ── Degenerate input ───────────────────────────────────────────────────

func test_short_or_malformed_roads_are_ignored() -> void:
	assert_eq(RoadBridge.find_spans_in_road(_pd, {}).size(), 0, "empty record")
	assert_eq(RoadBridge.find_spans_in_road(_pd, _road(5.0)).size(), 0,
			"a road shorter than the minimum span")
	var bad := _road(1000.0)
	bad["_cum_lengths"] = PackedFloat64Array([0.0])
	assert_eq(RoadBridge.find_spans_in_road(_pd, bad).size(), 0,
			"centerline and distances out of step")


func test_find_all_spans_concatenates_roads() -> void:
	var a := _road(20000.0, 24.8, -39.6, 1)
	var b := _road(20000.0, 25.4, -39.6, 2)
	var total := RoadBridge.find_all_spans(_pd, [a, b])
	var sa := RoadBridge.find_spans_in_road(_pd, a)
	var sb := RoadBridge.find_spans_in_road(_pd, b)
	assert_eq(total.size(), sa.size() + sb.size(), "every road contributes")
	var ids := {}
	for s in total:
		ids[int(s["feature_id"])] = true
	assert_true(ids.has(1) and ids.has(2), "both roads are represented")
