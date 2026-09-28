extends GutTest
## A prop tells Horizon it is gone when it is DESTROYED, never when it merely moves. Reparenting any
## ancestor takes the whole subtree out of the tree and back in: a crate in the hands of a player being
## teleported was deleted from Horizon — and from the base — while the server still held it.

var _deleted: Array = []


## A networked prop (body + PropSync) hanging from [param holder], live on the server as it would be.
func _crate(holder: Node) -> PropSync:
	var body := Node3D.new()
	var sync := PropSync.new()
	sync.name = "PropSync"
	body.add_child(sync)
	holder.add_child(body)
	sync.uuid = "crate-uuid"
	sync._server_live = true  # a unit test is not the server; this is what _enter_tree latches there
	sync.hs_server_prop_delete.connect(func(uuid: String, _type: String) -> void: _deleted.append(uuid))
	return sync


func before_each() -> void:
	_deleted = []


func test_moving_what_carries_it_does_not_delete_it() -> void:
	var planet: Node3D = add_child_autofree(Node3D.new())
	var station: Node3D = add_child_autofree(Node3D.new())
	var carrier := Node3D.new()
	planet.add_child(carrier)
	var sync: PropSync = _crate(carrier)
	carrier.reparent(station)  # the teleport: the PLAYER changes frame, the crate goes with it
	assert_eq(_deleted, [], "a crate in hand survives its carrier changing frame")
	assert_true(sync.is_inside_tree())


func test_moving_it_does_not_delete_it() -> void:
	var a: Node3D = add_child_autofree(Node3D.new())
	var b: Node3D = add_child_autofree(Node3D.new())
	var sync: PropSync = _crate(a)
	sync.get_parent().reparent(b)  # a raw reparent of the prop itself
	assert_eq(_deleted, [])


func test_destroying_it_deletes_it() -> void:
	var holder: Node3D = add_child_autofree(Node3D.new())
	var sync: PropSync = _crate(holder)
	sync.get_parent().free()
	assert_eq(_deleted, ["crate-uuid"], "freed: gone for everybody")


func test_destroying_what_carries_it_deletes_it_too() -> void:
	var holder: Node3D = add_child_autofree(Node3D.new())
	var carrier := Node3D.new()
	holder.add_child(carrier)
	_crate(carrier)
	carrier.free()
	assert_eq(_deleted, ["crate-uuid"], "freed with its carrier: gone as well")


func test_a_handover_is_not_a_deletion() -> void:
	var holder: Node3D = add_child_autofree(Node3D.new())
	var sync: PropSync = _crate(holder)
	sync.server_reparenting = true  # what the server sets before freeing a prop it hands over
	sync.get_parent().free()
	assert_eq(_deleted, [], "another server owns it now")


func test_a_prop_never_on_the_server_deletes_nothing() -> void:
	var holder: Node3D = add_child_autofree(Node3D.new())
	var sync: PropSync = _crate(holder)
	sync._server_live = false  # a client, or a prop freed before it ever entered the server's tree
	sync.get_parent().free()
	assert_eq(_deleted, [])
