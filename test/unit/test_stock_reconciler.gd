extends GutTest

## StockReconciler keeps a warehouse's crates equal to its stock in service-inventory (the crates are the
## truth, the team 2026-11-08): only whole crates move, the two directions never fight over a remainder,
## and a crate kept for a transport is never taken.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_stock_reconciler.gd


func test_stock_a_crate_short_takes_one() -> void:
	assert_eq(StockReconciler.change_for(60, 100, 40), -1)


func test_stock_two_crates_short_takes_two() -> void:
	assert_eq(StockReconciler.change_for(10, 100, 40), -2)


func test_less_than_a_crate_apart_moves_nothing() -> void:
	assert_eq(StockReconciler.change_for(70, 100, 40), 0, "30 short: under a crate")
	assert_eq(StockReconciler.change_for(130, 100, 40), 0, "30 over: under a crate")


func test_fresh_stock_puts_whole_crates() -> void:
	assert_eq(StockReconciler.change_for(130, 0, 40), 3, "130 kg in stock: three crates of 40")


func test_no_crate_size_moves_nothing() -> void:
	assert_eq(StockReconciler.change_for(100, 0, 0), 0)


func test_stock_of_reads_the_holder_view() -> void:
	var view := {"stacks": [{"goodType": "ore.gold", "quantity": 72.0}, {"goodType": "ingot.gold", "quantity": 3}]}
	assert_eq(StockReconciler.stock_of(view), {"ore.gold": 72, "ingot.gold": 3})
	assert_eq(StockReconciler.stock_of(null), {}, "no view: nothing known")


func test_a_reserved_crate_is_never_taken() -> void:
	var kept := _crate({"units": 40, "reserved_for": {"mission": "m1"}})
	var free := _crate({"units": 40})
	StockReconciler._take([free, kept], 2, "ore.gold", "M0001")
	assert_true(free.is_queued_for_deletion(), "the free crate goes")
	assert_false(kept.is_queued_for_deletion(), "the one kept for a transport stays")


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


func _crate(content: Dictionary) -> Node3D:
	var crate := Node3D.new()
	crate.set_script(_CRATE_SCRIPT)
	crate.set("content", content)
	add_child_autofree(crate)
	return crate


const _CRATE_SCRIPT := preload("res://test/unit/fixtures/content_holder.gd")
