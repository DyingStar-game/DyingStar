extends GutTest
## Suite for [method PlayerServer.node_by_uuid] — how an NPC order's reference uuid (a building, a
## depot…) is resolved to a node without walking the whole tree each time:
##
##   · a uuid in the server's props_list is answered from the index, no walk;
##   · a uuid only found by walking (a PropSync child, a scene-placed depot) is walked once, then cached;
##   · a cached node that was freed or left the tree is walked for again;
##   · an unknown uuid answers null.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_player_server_uuid_lookup.gd


## Stand-in for GameServer: only its props_list is read.
class FakeServer:
	extends RefCounted
	var props_list: Dictionary = {}


## A node carrying its uuid itself (a scene-placed depot).
class Tagged:
	extends Node3D
	var uuid: String = ""


var _root: Node3D
var _server: FakeServer


func before_each() -> void:
	PlayerServer._uuid_walk_cache.clear()
	_root = Node3D.new()
	add_child_autofree(_root)
	_server = FakeServer.new()
	_server.props_list = {"simple_building": {}}


func after_each() -> void:
	PlayerServer._uuid_walk_cache.clear()


func _tagged(uuid: String, parent: Node) -> Tagged:
	var n := Tagged.new()
	n.uuid = uuid
	parent.add_child(n)
	return n


func test_indexed_uuid_is_answered_from_props_list() -> void:
	# Not tagged: a walk could not find it, so finding it proves the index answered.
	var building := Node3D.new()
	_root.add_child(building)
	_server.props_list["simple_building"]["b-1"] = building
	assert_same(PlayerServer.node_by_uuid(_root, _server, "b-1"), building)
	assert_false(PlayerServer._uuid_walk_cache.has("b-1"), "an index hit is not cached")


func test_index_entry_out_of_the_tree_falls_back_to_the_walk() -> void:
	var stale := Node3D.new()
	autofree(stale)
	_server.props_list["simple_building"]["d-1"] = stale
	var placed := _tagged("d-1", _root)
	assert_same(PlayerServer.node_by_uuid(_root, _server, "d-1"), placed)


func test_walked_uuid_is_cached() -> void:
	var depot := _tagged("depot-1", _root)
	assert_same(PlayerServer.node_by_uuid(_root, _server, "depot-1"), depot)
	# Untag it: only the cache can still answer.
	depot.uuid = ""
	assert_same(PlayerServer.node_by_uuid(_root, _server, "depot-1"), depot)


func test_freed_cached_node_is_walked_for_again() -> void:
	var first := _tagged("depot-2", _root)
	assert_same(PlayerServer.node_by_uuid(_root, _server, "depot-2"), first)
	first.free()
	var second := _tagged("depot-2", _root)
	assert_same(PlayerServer.node_by_uuid(_root, _server, "depot-2"), second)


func test_unknown_uuid_is_null() -> void:
	assert_null(PlayerServer.node_by_uuid(_root, _server, "nope"))
	assert_null(PlayerServer.node_by_uuid(_root, null, "nope"))
	assert_null(PlayerServer.node_by_uuid(_root, _server, ""))
