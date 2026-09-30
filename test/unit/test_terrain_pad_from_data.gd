extends GutTest
## The server registers a building's terrain pad from its DATA (PropRegistry) before the building is
## built, so the chunks under it come out level the first time. That only works if the record stated
## from the data is EXACTLY the one the live TerrainPad registers later — any difference and
## PlanetData.register_pad rebuilds the chunks, pulling the ground from under the players.


func _data() -> PlanetData:
	var pd := PlanetData.new()
	pd.radius = 1000.0
	pd.export_nside = 8
	return pd


## A building: root (networked, PropSync "b1") > wing (offset, turned) > TerrainPad > Ground box.
func _building() -> Node3D:
	var root := Node3D.new()
	root.scale = Vector3(1.5, 1.5, 1.5)
	var sync := PropSync.new()
	sync.name = "PropSync"
	sync.uuid = "b1"
	root.add_child(sync)
	var wing := Node3D.new()
	wing.position = Vector3(4.0, 0.5, -3.0)
	wing.rotation = Vector3(0.0, 0.7, 0.0)
	root.add_child(wing)
	var pad := TerrainPad.new()
	pad.name = "TerrainPad"
	pad.position = Vector3(1.0, 0.0, 2.0)
	wing.add_child(pad)
	var box := CSGBox3D.new()
	box.name = TerrainPad.BOX_NAME
	box.size = Vector3(12.0, 1.0, 30.0)
	box.position = Vector3(0.5, -0.5, 1.0)
	box.rotation = Vector3(0.0, 0.2, 0.0)
	pad.add_child(box)
	return root


func test_the_record_from_data_is_the_one_the_live_pad_registers() -> void:
	var pd := _data()
	var terrain := PlanetTerrain.new()
	terrain.planet_data = pd
	add_child_autofree(terrain)
	var root := _building()
	var pad: TerrainPad = root.get_child(1).get_node("TerrainPad")
	var template: Dictionary = pad.template_relative_to(root)
	assert_false(template.is_empty(), "a template is read off the scene")
	assert_true(GameServer._pad_named_by_root(pad, root), "the pad is named after the root's uuid")
	pad.enabled = false  # keep the live node from registering into a PlanetData with no tiles

	# Where Horizon puts it: on the surface, turned.
	var pos := Vector3(300.0, 900.0, 310.0).normalized() * 1002.0
	var rot := Vector3(0.1, 1.2, -0.05)
	root.position = pos
	root.rotation = rot
	terrain.add_child(root)

	var live: Dictionary = pad.build_record()
	# The root's own scale comes from the scene (the server reads it off its throw-away instance).
	var item := Transform3D(Basis.from_euler(rot).scaled(Vector3(1.5, 1.5, 1.5)), pos)
	var from_data: Dictionary = TerrainPad.record_from(pd,
			terrain.global_transform.affine_inverse() * item * (template["rel"] as Transform3D),
			template["box_size"], template["box_local"], template["apron"], template["h_offset"], "prop:b1")
	assert_false(live.is_empty(), "the live pad states a record")
	assert_eq(from_data, live, "same record, so registering the live one rebuilds nothing")


func test_a_pad_under_another_networked_node_is_not_stated_from_the_data() -> void:
	var root := _building()
	var wing: Node = root.get_child(1)
	var inner := PropSync.new()
	inner.name = "PropSync"
	wing.add_child(inner)  # the wing is a prop of its own: the pad would be named after IT
	var pad: Node = wing.get_node("TerrainPad")
	assert_false(GameServer._pad_named_by_root(pad, root))
	root.free()
