extends GutTest

## A planet body never turns dynamic over terrain collision that is not built yet
## (GameServer._hold_if_no_ground / _release_ground_holds).
##
## When a zone split or merged, the trucks of the zone handed over were woken at once, sank through
## the chunk still being generated, and were thrown anywhere when it appeared around them
## (2026-10-01). Every wake path — the zone hand-over, the settle-culler's wake on approach — must
## hold the body frozen until its ground exists, then let it go. The ground is staged here: the
## question "is the collision under this body built?" is the one seam overridden.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_ground_hold.gd


class _Server extends GameServer:
	var ground := false

	func _ground_missing_under(_body: Node3D) -> bool:
		return not ground


var _srv: _Server
var _rb: RigidBody3D


func before_each() -> void:
	_srv = _Server.new()  # never enters the tree: no _ready, no network
	_rb = RigidBody3D.new()
	_rb.add_child(CollisionShape3D.new())
	add_child_autofree(_rb)


func after_each() -> void:
	_srv.free()


func test_zone_hand_over_holds_until_the_ground_is_built() -> void:
	# Another server simulated it: zone-frozen, dynamic before that.
	_srv._zone_freeze_prop(_rb)
	assert_true(_rb.freeze)
	# Merge: the zone is ours again, the chunk under it is not built.
	_srv._zone_unfreeze_prop(_rb)
	assert_true(_rb.freeze, "held frozen while the ground is missing")
	assert_true(_rb.has_meta(GameServer.GROUND_HOLD_META))
	_srv._release_ground_holds()
	assert_true(_rb.freeze, "still held: nothing was built")
	_srv.ground = true
	_srv._release_ground_holds()
	assert_false(_rb.freeze, "released onto its ground")
	assert_false(_rb.has_meta(GameServer.GROUND_HOLD_META))
	assert_true(_srv._ground_held.is_empty())


func test_ground_already_there_wakes_at_once() -> void:
	_srv.ground = true
	_srv._zone_freeze_prop(_rb)
	_srv._zone_unfreeze_prop(_rb)
	assert_false(_rb.freeze)
	assert_true(_srv._ground_held.is_empty())


func test_a_design_frozen_body_is_not_held_nor_released() -> void:
	# A crate settled in a container: frozen for its own reason, before and after the zone change.
	_rb.freeze = true
	_srv._zone_freeze_prop(_rb)
	_srv._zone_unfreeze_prop(_rb)
	assert_true(_rb.freeze)
	assert_true(_srv._ground_held.is_empty(), "not ours to hold")
	_srv.ground = true
	_srv._release_ground_holds()
	assert_true(_rb.freeze, "and never woken by the release")


func test_split_while_held_comes_back_dynamic() -> void:
	_srv._zone_freeze_prop(_rb)
	_srv._zone_unfreeze_prop(_rb)
	assert_true(_srv._ground_held.has(_rb.get_instance_id()))
	# Split again before the ground came: the zone freeze takes over from the hold...
	_srv._zone_freeze_prop(_rb)
	assert_true(_srv._ground_held.is_empty())
	# ...and the next merge must not restore "frozen" as if it had been the body's own state.
	_srv.ground = true
	_srv._zone_unfreeze_prop(_rb)
	assert_false(_rb.freeze)


func test_culler_wake_holds_until_the_ground_is_built() -> void:
	_srv._freeze_culled_body(_rb)
	assert_true(_rb.freeze)
	_srv._unfreeze_culled_body(_rb)
	assert_true(_rb.freeze, "a player's approach says nothing about the chunk under this body")
	_srv.ground = true
	_srv._release_ground_holds()
	assert_false(_rb.freeze)


func test_a_carried_body_is_never_held() -> void:
	var truck := Vehicle.new()
	add_child_autofree(truck)
	var crate := RigidBody3D.new()
	truck.add_child(crate)
	assert_false(_srv._hold_if_no_ground(crate), "the truck owns its cargo's freeze")
	assert_false(crate.freeze)
