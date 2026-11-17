extends GutTest
## DustVolume: the cloud layer's step budget follows the atmosphere quality, within bounds; the rays
## averaged per pixel and the grid's weight follow the altitude.


func test_more_rays_are_averaged_the_higher_the_eye() -> void:
	assert_eq(DustVolume.rays_for(500.0), 1, "on the ground: one ray")
	assert_eq(DustVolume.rays_for(DustVolume.RAYS_FROM_M), 1, "up to the first threshold: still one")
	assert_eq(DustVolume.rays_for(2000000.0), DustVolume.RAYS_MAX, "from orbit: the most")
	var last: int = 1
	for km in range(0, 2001, 50):
		var rays: int = DustVolume.rays_for(km * 1000.0)
		assert_true(rays >= last, "never fewer rays higher up (%d km)" % km)
		last = rays


func test_the_grid_fades_out_with_the_altitude() -> void:
	assert_eq(DustVolume.grid_fade(1000.0), 1.0, "near the ground the grid is the weather")
	assert_eq(DustVolume.grid_fade(DustVolume.GRID_FADE_FROM_M), 1.0)
	assert_eq(DustVolume.grid_fade(DustVolume.GRID_FADE_TO_M), 0.0, "high up: the calibrated sea alone")
	var mid: float = DustVolume.grid_fade((DustVolume.GRID_FADE_FROM_M + DustVolume.GRID_FADE_TO_M) * 0.5)
	assert_almost_eq(mid, 0.5, 1e-6, "halfway: half")


func test_the_march_budget_follows_the_atmosphere_quality() -> void:
	assert_eq(DustVolume.steps_for(16), 24, "low: 16 view steps -> 24")
	assert_eq(DustVolume.steps_for(32), 48, "high: 32 -> 48")
	assert_eq(DustVolume.steps_for(48), DustVolume.STEPS_MAX, "ultra: capped")
	assert_eq(DustVolume.steps_for(4), DustVolume.STEPS_MIN, "a debug step count under the floor: the floor")
