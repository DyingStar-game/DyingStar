extends GutTest
## The settle-culler asks _is_cullable_body about every prop it tracks — including one deleted
## meanwhile (a mining tool taken into the kit): the answer must be "no", not a script error
## every frame (5000+ in a few minutes) with the entry never forgotten.


func test_a_freed_prop_is_not_cullable() -> void:
	var server: Node = load("res://server/server.gd").new()
	var prop := RigidBody3D.new()
	assert_true(server._is_cullable_body(prop), "a loose prop: cullable")
	prop.free()
	assert_false(server._is_cullable_body(prop), "deleted while tracked: forgotten, no error")
	server.free()
