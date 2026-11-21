extends GutTest
## FaceTypes: European faces' types per sex, trait and age band (european_face_types.json), and the random European
## faces drawn from them.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_face_types.gd -gexit


func test_every_age_has_at_most_three_types_whose_shares_sum_to_one() -> void:
	assert_true(FaceTypes.available(), "european_face_types.json is there")
	for sex: String in ["female", "male"]:
		var traits: Dictionary = FaceTypes.data()[sex]["traits"]
		for feature: String in FaceTypes.data()["traits"]:
			var types: Array = traits[feature]["types"]
			var bands: Array = traits[feature]["bands"]
			assert_eq(int(bands[0]["from"]), 18, "%s %s: from 18" % [sex, feature])
			assert_eq(int(bands[bands.size() - 1]["to"]), 90, "%s %s: to 90" % [sex, feature])
			for b in bands.size():
				if b > 0:
					assert_eq(int(bands[b]["from"]), int(bands[b - 1]["to"]) + 1, "%s %s: no gap between bands" % [sex, feature])
				var shares: Array = bands[b]["types"]
				assert_between(shares.size(), 1, 3)
				var total: float = 0.0
				for entry: Array in shares:
					assert_between(int(entry[0]), 0, types.size() - 1)
					assert_false(types[int(entry[0])].get("rejected", false), "%s %s: a type judged wrong is never drawn" % [sex, feature])
					total += float(entry[1])
				assert_almost_eq(total, 1.0, 0.01, "%s %s %d-%d" % [sex, feature, bands[b]["from"], bands[b]["to"]])
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


func test_random_european_faces_are_typed_and_stay_within_the_limits() -> void:
	var europeans: int = 0
	for seed_value in 400:
		var look: CharacterAppearance = CharacterAppearance.random(seed_value)
		assert_eq(CreatorLimits.limit(look).encode(), look.encode(), "seed %d: within the creator's limits" % seed_value)
		if look.origins[CharacterAppearance.ORIGIN_WHITE] >= 0.8:
			europeans += 1
	assert_gt(europeans, 40, "a sixth of random looks are European")
	assert_eq(CharacterAppearance.random(77).encode(), CharacterAppearance.random(77).encode(), "deterministic")
