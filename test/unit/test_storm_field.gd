extends GutTest
## StormField: the regional storm grid the far dust volume reads. Its altitude over the anchor's
## sphere agrees with the plain difference of radii (curvature included, no big-number cancellation);
## the dust is the sampler's τ over DUST_LAYER_M, a debug override included; a grid becomes ready only
## once its ground (main thread) and its dust (worker) are both done, and a refresh keeps its anchor.
## The dust's colour is the planet map's (CloudPlanetMap), not the grid's.

const R: float = 6356000.0
const ANCHOR := Vector3(0.0, R, 0.0)


func _smooth(_dir: Vector3) -> float:
	return R


func _until_ready(f: StormField, at: Vector3, job: Callable) -> void:
	var guard := 0
	while not f.ready and guard < 2000:
		f.update(at, _smooth, job, 0.0, 1000.0)
		OS.delay_msec(1)
		guard += 1


func test_the_altitude_over_the_anchor_sphere_includes_the_curvature() -> void:
	var u := Vector3.UP
	var q := Vector3(100000.0, 2000.0, 0.0)
	var exact: float = (ANCHOR + q).length() - R
	assert_almost_eq(StormField.altitude_over_anchor(q, u, R), exact, 0.01)
	assert_almost_eq(StormField.altitude_over_anchor(Vector3(100000.0, 0.0, 0.0), u, R), 786.7, 1.0,
			"100 km out on the tangent plane: 787 m over the sphere")


func test_the_dust_is_the_sampler_depth_over_its_layer() -> void:
	var profile: ClimateProfile = load("res://scenes/planet/climates/tarsis_3.tres")
	var job: Callable = StormField.dust_sampler(profile, [], {"dust_tau": 2.0})
	assert_almost_eq((job.call(Vector3.UP) as Vector2).x, 2.0 / WeatherSampler.DUST_LAYER_M, 1e-9,
			"an override of τ 2 everywhere: 0.002 /m, a visibility of ~2 km")
	var calm: Callable = StormField.dust_sampler(profile, [], {})
	assert_eq((calm.call(Vector3.UP) as Vector2), Vector2(0.0, 1.0), "no system: no storm, the calibrated cloud sea")


func test_a_grid_is_ready_once_its_ground_and_dust_are_both_done() -> void:
	var f := StormField.new()
	var job: Callable = func(_dir: Vector3) -> Vector2: return Vector2(0.004, 1.0)
	assert_false(f.update(ANCHOR, _smooth, job, 0.0, 0.0), "no budget: a ground row only")
	assert_false(f.ready)
	_until_ready(f, ANCHOR, job)
	assert_true(f.ready)
	assert_almost_eq(f.beta_max, 0.004, 1e-6)
	assert_almost_eq(f.ground_top_m, 0.0, 0.01, "a smooth planet: the ground on the anchor's sphere")
	assert_not_null(f.dust_texture)
	assert_not_null(f.ground_texture)


func test_a_small_move_keeps_the_anchor() -> void:
	var f := StormField.new()
	var job: Callable = func(_dir: Vector3) -> Vector2: return Vector2(0.0, 1.0)
	_until_ready(f, ANCHOR, job)
	var first: Vector3 = f.anchor
	f.update(ANCHOR + Vector3(StormField.REBUILD_M * 0.5, 0.0, 0.0), _smooth, job, 1.0)
	assert_eq(f.anchor, first)


func test_the_lid_smooths_the_relief_away() -> void:
	var flat := PackedFloat32Array()
	flat.resize(StormField.SIZE * StormField.SIZE)
	flat.fill(120.0)
	assert_almost_eq(StormField.smoothed(flat, StormField.LID_CELLS)[500], 120.0, 1e-4, "flat stays flat")
	var peak := PackedFloat32Array()
	peak.resize(StormField.SIZE * StormField.SIZE)
	var mid: int = 64 * StormField.SIZE + 64
	peak[mid] = 1210.0
	var lid: PackedFloat32Array = StormField.smoothed(peak, StormField.LID_CELLS)
	assert_almost_eq(lid[mid], 1210.0 / 121.0, 1e-3, "a lone 1210 m peak: a 10 m swell under the lid")
	assert_almost_eq(lid[mid + 5], 10.0, 1e-3, "spread over the box")
	assert_eq(lid[mid + 6], 0.0, "and no further")


func test_a_field_freed_mid_job_waits_for_it() -> void:
	var f := StormField.new()
	var slow: Callable = func(_dir: Vector3) -> Vector2:
		OS.delay_usec(20)
		return Vector2(0.001, 1.0)
	f.update(ANCHOR, _smooth, slow, 0.0, 1000.0)  # the ground in one go, then the dust job starts
	assert_true(f._task >= 0, "a job is running")
	f = null  # freed mid-job: it must wait, not leave the worker writing into freed memory
	assert_null(f, "still standing")


func test_the_lid_is_read_back_where_the_eye_stands() -> void:
	var f := StormField.new()
	assert_true(is_nan(f.lid_at(Vector3.ZERO)), "no grid yet: unknown")
	var job: Callable = func(_dir: Vector3) -> Vector2: return Vector2(0.0, 1.0)
	_until_ready(f, ANCHOR, job)
	assert_almost_eq(f.lid_at(Vector3.ZERO), 0.0, 0.01, "a smooth planet: the lid on the anchor's sphere")
	assert_false(is_nan(f.lid_at(f.east * 400000.0)), "off the grid: the edge carries on, as in the shader")


func test_the_cloud_sea_follows_the_pressure() -> void:
	assert_almost_eq(StormField.deck_factor(0.0), 1.0, 1e-9, "no system: the calibrated veil")
	assert_almost_eq(StormField.deck_factor(-StormField.DECK_PRESSURE_PA), 2.0, 1e-9, "a depression gathers it")
	assert_almost_eq(StormField.deck_factor(StormField.DECK_PRESSURE_PA), StormField.DECK_MIN, 1e-9,
			"an anticyclone opens holes in it")
	assert_almost_eq(StormField.deck_factor(-10000.0), StormField.DECK_MAX, 1e-9, "clamped")


func test_the_low_ground_is_a_low_quantile() -> void:
	var g := PackedFloat32Array([500.0, 100.0, 400.0, 200.0, 300.0])
	assert_eq(StormField.quantile(g, 0.0), 100.0, "0: the lowest")
	assert_eq(StormField.quantile(g, 0.5), 300.0, "0.5: the median")
	assert_eq(StormField.quantile(PackedFloat32Array(), 0.2), 0.0, "no grid: the anchor's sphere")
