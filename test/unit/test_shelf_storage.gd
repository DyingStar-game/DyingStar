extends GutTest

## A crate stored on a shelf lives UNDER the shelf (Shelf.store_at_nearest_slot), settles onto its tier
## before it is frozen, frees its slot when picked up (release_cargo), binds back to its slot when it is
## re-created under the shelf, and is frozen again when something else wakes it (_watch_stored).
##
## Stored crates used to stay world props beside the shelf, frozen by it: on a zone split / merge they
## came back awake before their shelf and fell through every tier (2026-10-23).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_shelf_storage.gd

const SHELF_SCENE := "res://scenes/_universe/props/furniture/metal_shelf.tscn"

var _shelf: Shelf


func before_each() -> void:
	_shelf = (load(SHELF_SCENE) as PackedScene).instantiate() as Shelf
	add_child_autofree(_shelf)


func _crate_at(world_point: Vector3) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.add_child(CollisionShape3D.new())
	add_child_autofree(rb)
	rb.global_position = world_point
	rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC  # as the carry leaves it
	rb.freeze = true
	return rb


func test_store_takes_the_crate_under_the_shelf_dynamic() -> void:
	var slot: Vector3 = _shelf.shelf_slots[5]
	var crate := _crate_at(_shelf.to_global(slot) + Vector3(0.05, 0.1, 0.0))
	assert_true(_shelf.store_at_nearest_slot(crate))
	assert_eq(crate.get_parent(), _shelf, "reparented under the shelf")
	assert_almost_eq(crate.position, slot, Vector3.ONE * 1e-4, "origin on the slot, shelf frame")
	assert_false(crate.freeze, "left dynamic to settle onto its tier")
	assert_true(_shelf.shelf_slots_occupied[5])


func test_settled_crate_is_frozen_static() -> void:
	var crate := _crate_at(_shelf.to_global(_shelf.shelf_slots[0]))
	_shelf.store_at_nearest_slot(crate)
	# No physics step between the calls: the crate reads at rest every frame.
	for i in range(Shelf._SETTLE_FRAMES):
		assert_false(crate.freeze, "not before %d frames at rest" % Shelf._SETTLE_FRAMES)
		_shelf._settle_step()
	assert_true(crate.freeze, "frozen once it rests")
	assert_eq(crate.freeze_mode, RigidBody3D.FREEZE_MODE_STATIC)


func test_full_shelf_refuses_and_leaves_the_crate_alone() -> void:
	_shelf.shelf_slots_occupied.fill(true)
	var crate := _crate_at(_shelf.to_global(_shelf.shelf_slots[0]))
	assert_false(_shelf.store_at_nearest_slot(crate))
	assert_ne(crate.get_parent(), _shelf)
	assert_true(crate.freeze)


func test_release_cargo_frees_the_slot() -> void:
	var crate := _crate_at(_shelf.to_global(_shelf.shelf_slots[3]))
	_shelf.store_at_nearest_slot(crate)
	_shelf.release_cargo(crate)
	assert_false(_shelf.shelf_slots_occupied[3])
	assert_true(_shelf.can_store(_shelf.to_global(_shelf.shelf_slots[3])))
	assert_false(_shelf._settling.has(crate), "no longer settled by the shelf")


func test_crate_recreated_under_the_shelf_binds_its_slot() -> void:
	_shelf.shelf_slots_occupied[7] = true  # restored from Horizon with the shelf
	var crate := RigidBody3D.new()
	crate.position = _shelf.shelf_slots[7] + Vector3(0.0, -0.03, 0.0)  # settled a little under it
	_shelf.add_child(crate)
	_shelf._bind_arrived(crate)
	assert_eq(_shelf._slot_bodies[7], crate)
	assert_true(_shelf._settling.has(crate), "created awake: settles, then freezes")


func test_woken_crate_is_settled_again_and_a_gone_one_frees_its_slot() -> void:
	var kept := _crate_at(_shelf.to_global(_shelf.shelf_slots[1]))
	var gone := _crate_at(_shelf.to_global(_shelf.shelf_slots[2]))
	_shelf.store_at_nearest_slot(kept)
	_shelf.store_at_nearest_slot(gone)
	for i in range(Shelf._SETTLE_FRAMES):
		_shelf._settle_step()
	assert_true(kept.freeze)
	kept.freeze = false  # the settle-culler / a zone hand-over woke it
	gone.free()
	_shelf._watch_stored()
	assert_true(_shelf._settling.has(kept), "woken: settled and frozen again")
	assert_false(_shelf.shelf_slots_occupied[2], "its crate is gone: slot free")
	assert_true(_shelf.shelf_slots_occupied[1])


func test_admin_fill_reserves_one_to_all_free_slots_never_a_taken_one() -> void:
	_shelf.shelf_slots_occupied[0] = true  # a crate already there
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var picked: Array[int] = _shelf.reserve_random_slots(rng)
	assert_between(picked.size(), 1, _shelf.shelf_slots.size() - 1, "between one and every FREE slot")
	assert_false(picked.has(0), "never the slot already taken")
	for idx in picked:
		assert_true(_shelf.shelf_slots_occupied[idx], "reserved until its crate arrives")
	var unique := {}
	for idx in picked:
		unique[idx] = true
	assert_eq(unique.size(), picked.size(), "each slot once")


func test_admin_fill_of_a_full_shelf_reserves_nothing() -> void:
	_shelf.shelf_slots_occupied.fill(true)
	assert_eq(_shelf.reserve_random_slots(RandomNumberGenerator.new()).size(), 0)


func test_crate_spawned_on_a_reserved_slot_binds_it() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var idx: int = _shelf.reserve_random_slots(rng)[0]
	var crate := RigidBody3D.new()
	crate.position = _shelf.shelf_slots[idx]  # where server_fill_shelves spawns it
	_shelf.add_child(crate)
	_shelf._bind_arrived(crate)
	assert_eq(_shelf._slot_bodies[idx], crate)
