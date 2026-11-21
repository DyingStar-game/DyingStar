extends GutTest
## FaceTypes: faces' types per origin, sex, trait and age band (<origin>_face_types.json), and the random faces drawn
## from them.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_face_types.gd -gexit


func test_every_age_keeps_the_types_covering_most_of_its_photos_and_their_shares_sum_to_one() -> void:
	for origin: int in FaceTypes.FILES:
		assert_false(FaceTypes.data(origin).is_empty(), "%s is there" % FaceTypes.FILES[origin])
		for sex: String in ["female", "male"]:
			if not FaceTypes.data(origin).has(sex):
				continue
			var traits: Dictionary = FaceTypes.data(origin)[sex]["traits"]
			for feature: String in FaceTypes.data(origin)["traits"]:
				var what: String = "%d %s %s" % [origin, sex, feature]
				var types: Array = traits[feature]["types"]
				var bands: Array = traits[feature]["bands"]
				assert_eq(int(bands[0]["from"]), 18, "%s: from 18" % what)
				assert_eq(int(bands[bands.size() - 1]["to"]), 90, "%s: to 90" % what)
				for b in bands.size():
					if b > 0:
						assert_eq(int(bands[b]["from"]), int(bands[b - 1]["to"]) + 1, "%s: no gap between bands" % what)
					var shares: Array = bands[b]["types"]
					assert_between(shares.size(), 1, types.size())
					assert_gte(float(bands[b]["cover"]), 0.7, "%s: the kept types cover 70 %% of the band" % what)
					var total: float = 0.0
					for entry: Array in shares:
						assert_between(int(entry[0]), 0, types.size() - 1)
						assert_false(types[int(entry[0])].get("rejected", false), "%s: a type judged wrong is never drawn" % what)
						total += float(entry[1])
					assert_almost_eq(total, 1.0, 0.01, "%s %d-%d" % [what, bands[b]["from"], bands[b]["to"]])
				for t: Dictionary in types:
					assert_gte(int(t["size"]), 40, "a type is the mean of many faces, never one person's")


func test_a_draw_follows_the_shares() -> void:
	var band: Dictionary = {"types": [[4, 0.6], [1, 0.3], [2, 0.1]]}
	assert_eq(FaceTypes.pick(band, 0.0), 4)
	assert_eq(FaceTypes.pick(band, 0.59), 4)
	assert_eq(FaceTypes.pick(band, 0.6), 1)
	assert_eq(FaceTypes.pick(band, 0.95), 2)
	assert_eq(FaceTypes.pick(band, 1.0), 2, "rounding past the last share: the last type")
	var bands: Array = [{"from": 18, "to": 20}, {"from": 21, "to": 30}, {"from": 31, "to": 90}]
	assert_eq(FaceTypes.band_at(bands, 18.0), 0)
	assert_eq(FaceTypes.band_at(bands, 20.9), 0)
	assert_eq(FaceTypes.band_at(bands, 21.0), 1)
	assert_eq(FaceTypes.band_at(bands, 89.0), 2)


func test_the_origins_ffhq_shows_too_little_of_have_no_types() -> void:
	assert_true(FaceTypes.available(CharacterAppearance.ORIGIN_WHITE, true))
	assert_true(FaceTypes.available(CharacterAppearance.ORIGIN_WHITE, false))
	assert_true(FaceTypes.available(CharacterAppearance.ORIGIN_AFRICAN, true))
	assert_true(FaceTypes.available(CharacterAppearance.ORIGIN_AFRICAN, false))
	assert_true(FaceTypes.available(CharacterAppearance.ORIGIN_EAST_ASIAN, true))
	assert_true(FaceTypes.available(CharacterAppearance.ORIGIN_EAST_ASIAN, false), "346 East Asian men: few, but typed")
	for origin in range(3, CharacterAppearance.ORIGINS):
		assert_false(FaceTypes.available(origin, true), "origin %d: too few in FFHQ" % origin)
		assert_true(FaceTypes.face(origin, true, 30.0, func() -> float: return 0.5, func() -> float: return 0.0).is_empty())


func test_random_typed_faces_stay_within_the_limits() -> void:
	var typed: Dictionary = {}
	for seed_value in 400:
		var look: CharacterAppearance = CharacterAppearance.random(seed_value)
		assert_eq(CreatorLimits.limit(look).encode(), look.encode(), "seed %d: within the creator's limits" % seed_value)
		var main: int = 0
		for i in CharacterAppearance.ORIGINS:
			if look.origins[i] > look.origins[main]:
				main = i
		if FaceTypes.available(main, look.is_female()):
			typed[main] = int(typed.get(main, 0)) + 1
	assert_gt(int(typed.get(CharacterAppearance.ORIGIN_WHITE, 0)), 40, "a sixth of random looks are European")
	assert_gt(int(typed.get(CharacterAppearance.ORIGIN_AFRICAN, 0)), 20, "African looks are typed")
	assert_gt(int(typed.get(CharacterAppearance.ORIGIN_EAST_ASIAN, 0)), 20, "East Asian looks are typed")
	assert_eq(CharacterAppearance.random(77).encode(), CharacterAppearance.random(77).encode(), "deterministic")
