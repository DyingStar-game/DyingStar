extends GutTest
## SurfaceDust: how much dust each ground gives up, and its colour. The shipped table must keep the
## physical order — loose fine grains lift, hard or bound surfaces do not.

const GROUND_DUST := "res://scenes/common/ground_dust.tres"


func test_sand_gives_more_than_rock_and_metal_gives_none() -> void:
	var dust := load(GROUND_DUST) as SurfaceDust
	assert_not_null(dust)
	assert_gt(dust.amount(&"sand"), dust.amount(&"dirt"))
	assert_gt(dust.amount(&"dirt"), dust.amount(&"rock"))
	assert_gt(dust.amount(&"rock"), dust.amount(&"metal"))
	assert_eq(dust.amount(&"metal"), 0.0)


func test_an_unknown_surface_takes_the_default() -> void:
	var dust := SurfaceDust.new()
	dust.default_amount = 0.2
	assert_eq(dust.amount(&""), 0.2)
	assert_eq(dust.amount(&"never_heard_of_it"), 0.2)


func test_the_amount_stays_within_zero_and_one() -> void:
	var dust := SurfaceDust.new()
	dust.amount_by_family = {&"sand": 3.0, &"metal": -1.0}
	assert_eq(dust.amount(&"sand"), 1.0)
	assert_eq(dust.amount(&"metal"), 0.0)


func test_the_dust_is_the_ground_s_colour_lightened_unless_the_family_states_one() -> void:
	var dust := SurfaceDust.new()
	dust.lift_tint = 0.0
	dust.color_by_family = {&"concrete": Color(0.6, 0.6, 0.6)}
	var ground := Color(0.5, 0.3, 0.1)
	assert_eq(dust.color(&"sand", ground), ground, "no entry: the ground's own colour")
	assert_eq(dust.color(&"concrete", ground), Color(0.6, 0.6, 0.6), "an entry wins over the ground")
	dust.lift_tint = 0.5
	assert_gt(dust.color(&"sand", ground).r, ground.r, "lighter in the air than on the ground")
