extends GutTest

## StockReconciler keeps a warehouse's crates equal to its stock in service-inventory (the crates are the
## truth, the team 2026-11-08): only whole crates move, of weights drawn above a least one, the two directions
## never fight over a remainder, and a crate kept for a transport is never taken.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_stock_reconciler.gd


func test_crates_go_only_when_the_excess_covers_them() -> void:
	assert_eq(StockReconciler.take_plan([20, 15, 18], [false, false, false], 33), [2, 1] as Array[int],
			"the last first: 18 then 15, the 20 would be too much")
	assert_eq(StockReconciler.take_plan([20, 15], [false, false], 10), [] as Array[int], "under a crate: nothing")


func test_a_kept_crate_is_never_in_the_plan() -> void:
	assert_eq(StockReconciler.take_plan([20, 15], [false, true], 50), [0] as Array[int])


func test_new_crates_weigh_between_the_least_and_full() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var fills := StockReconciler.fills_for(100, 20, rng)
	var total := 0
	for fill: float in fills:
		assert_between(fill, StockReconciler.MIN_FILL - 0.0001, 1.0, "never lighter than the least")
		total += roundi(20 * fill)
	assert_between(total, 100 - ceili(20 * StockReconciler.MIN_FILL), 100, "what is missing, to a crate")
	assert_gt(fills.size(), 4, "not all full")


func test_less_than_the_lightest_crate_missing_adds_nothing() -> void:
	assert_eq(StockReconciler.fills_for(11, 20, RandomNumberGenerator.new()).size(), 0, "11 < 12 kg")
	assert_eq(StockReconciler.fills_for(100, 0, RandomNumberGenerator.new()).size(), 0, "no crate size")


func test_stock_of_reads_the_holder_view() -> void:
	var view := {"stacks": [{"goodType": "ore.gold", "quantity": 72.0}, {"goodType": "ingot.gold", "quantity": 3}]}
	assert_eq(StockReconciler.stock_of(view), {"ore.gold": 72, "ingot.gold": 3})
	assert_eq(StockReconciler.stock_of(null), {}, "no view: nothing known")


func test_the_planned_crates_are_taken() -> void:
	var kept := _crate({"units": 40, "reserved_for": {"mission": "m1"}})
	var free := _crate({"units": 40})
	StockReconciler._take([free, kept], [0] as Array[int], "ore.gold", "M0001")
	assert_true(free.is_queued_for_deletion(), "the free crate goes")
	assert_false(kept.is_queued_for_deletion(), "the one out of the plan stays")


func test_a_depot_just_stocked_is_left_alone() -> void:
	var depot := Node3D.new()
	add_child_autofree(depot)
	assert_false(StockReconciler._moving(depot), "nothing on its way")
	StockReconciler.hold_off(depot)
	assert_true(StockReconciler._moving(depot), "crates on their way: not counted yet")


func test_a_crate_that_never_becomes_the_warehouse_s_stops_blocking() -> void:
	var depot := Node3D.new()
	add_child_autofree(depot)
	var shelf := Shelf.new()
	depot.add_child(shelf)
	var stray := _crate({"units": 20, "delivered_to": "another-warehouse"})
	stray.reparent(shelf)
	assert_true(StockReconciler._moving(depot), "just shelved: maybe on its way in")
	stray.set_meta(StockReconciler.UNMARKED_META, Time.get_ticks_msec() - int(StockReconciler.UNMARKED_S * 1000.0) - 1)
	assert_false(StockReconciler._moving(depot), "a minute on: a stray, left out")


func test_the_depots_awake_on_the_server_are_found() -> void:
	var depot := Node3D.new()
	depot.add_to_group(TransportReservations.DEPOTS_GROUP)
	add_child_autofree(depot)
	assert_true(TransportReservations.live_depots(get_tree()).has(depot), "by the group every depot joins")


func _crate(content: Dictionary) -> Node3D:
	var crate := Node3D.new()
	crate.set_script(_CRATE_SCRIPT)
	crate.set("content", content)
	add_child_autofree(crate)
	return crate


const _CRATE_SCRIPT := preload("res://test/unit/fixtures/content_holder.gd")
