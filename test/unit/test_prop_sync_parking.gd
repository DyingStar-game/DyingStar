extends GutTest
## SERVER: a prop that cannot move on its own (a static host, a frozen or sleeping RigidBody3D, no uuid yet)
## has its per-step callback off and is looked at by PropSync.poll_parked, a tenth of them per step. A
## callback per prop per step only to find nothing to do was 23 % of the main thread of a busy preprod
## server (2026-11-26). Nothing a parked prop does may go unreplicated: a static host moved by a script is
## sampled, a body unfrozen or woken gets its callback back, a carried prop never parks.

var _role: Variant = null
var _updates: Array = []


func before_each() -> void:
	_role = GameOrchestrator.current_network_role
	GameOrchestrator.current_network_role = GameOrchestrator.NetworkRole.SERVER
	PropSync._parked.clear()
	PropSync._park_cursor = 0
	_updates = []


func after_each() -> void:
	GameOrchestrator.current_network_role = _role
	PropSync._parked.clear()


## [param host] networked (a PropSync with a uuid) under [param holder], in the tree as on the server.
func _prop(host: Node3D, holder: Node = null) -> PropSync:
	var sync := PropSync.new()
	sync.name = "PropSync"
	host.add_child(sync)
	if holder == null:
		add_child_autofree(host)
	else:
		holder.add_child(host)
	sync.uuid = "prop-%d" % host.get_instance_id()
	sync.hs_server_prop_update.connect(func(uuid: String, data: Dictionary, _type: String, _has: bool) -> void:
		_updates.append([uuid, data]))
	return sync


func _poll(steps: int = PropSync.STATIC_TICK_EVERY) -> void:
	for i: int in steps:
		PropSync.poll_parked()


func test_a_static_host_parks_and_is_still_sampled() -> void:
	var host := Node3D.new()
	var sync := _prop(host)
	sync._physics_process(0.0)
	assert_false(sync.is_physics_processing(), "no callback per step for a host that cannot move")
	assert_eq(PropSync.parked_count(), 1)
	host.position = Vector3(3.0, 0.0, 0.0)  # a script moves it
	_poll()
	assert_eq(_updates.size(), 1, "its new pose sent within STATIC_TICK_EVERY steps")
	assert_eq((_updates[0][1] as Dictionary)["position"], Vector3(3.0, 0.0, 0.0))
	_poll()
	assert_eq(_updates.size(), 1, "nothing more while it stands still")


func test_a_frozen_body_parks_and_comes_back_when_unfrozen() -> void:
	var rb := RigidBody3D.new()
	rb.freeze = true
	var sync := _prop(rb)
	sync._physics_process(0.0)
	assert_false(sync.is_physics_processing(), "a frozen body is parked")
	rb.freeze = false
	_poll()
	assert_true(sync.is_physics_processing(), "unfrozen by anyone: its callback is back")
	assert_eq(PropSync.parked_count(), 0, "and it left the parked list")


func test_a_sleeping_body_parks_and_comes_back_when_woken_by_a_script() -> void:
	var rb := RigidBody3D.new()
	var sync := _prop(rb)
	rb.sleeping = true
	sync._on_host_sleeping_state_changed()
	assert_false(sync.is_physics_processing())
	rb.sleeping = false  # no sleeping_state_changed for a wake-up written by a script
	_poll()
	assert_true(sync.is_physics_processing(), "the poll sees it awake")


func test_an_awake_body_keeps_its_callback() -> void:
	var rb := RigidBody3D.new()
	var sync := _prop(rb)
	sync._physics_process(0.0)
	assert_true(sync.is_physics_processing())
	assert_eq(PropSync.parked_count(), 0)


func test_a_carried_prop_never_parks() -> void:
	var carrier: Node3D = add_child_autofree(Node3D.new())
	carrier.add_to_group(PropNet.RIDE_CARRIER_GROUP)
	var host := Node3D.new()
	var sync := _prop(host, carrier)
	sync._physics_process(0.0)
	assert_true(sync.is_physics_processing(), "riding a carrier: it re-sends every step")


func test_a_prop_given_a_carrier_leaves_the_parked_list() -> void:
	var host := Node3D.new()
	var sync := _prop(host)
	sync._physics_process(0.0)
	var carrier: Node3D = add_child_autofree(Node3D.new())
	carrier.add_to_group(PropNet.RIDE_CARRIER_GROUP)
	host.reparent(carrier)  # _enter_tree re-arms the callback
	_poll()
	assert_true(sync.is_physics_processing())
	assert_eq(PropSync.parked_count(), 0)


func test_a_prop_without_uuid_parks_until_it_gets_one() -> void:
	var rb := RigidBody3D.new()
	var sync := _prop(rb)
	sync.uuid = ""
	sync._physics_process(0.0)
	assert_false(sync.is_physics_processing(), "nothing to replicate without a uuid")
	_poll()
	assert_false(sync.is_physics_processing())
	sync.uuid = "given"
	_poll()
	assert_true(sync.is_physics_processing(), "networked and awake: ticking")


func test_a_freed_prop_leaves_the_parked_list() -> void:
	var host := Node3D.new()
	var sync := _prop(host)
	sync._physics_process(0.0)
	host.free()
	_poll()
	assert_eq(PropSync.parked_count(), 0)
