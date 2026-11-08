extends GutTest
## The town hall's modelled building (assets/_universe/structures/buildings/civic/town_hall.glb, source
## in assets_blender/): no CSG placeholder left, collision boxes that are bodies and not walls to look
## at, the shared materials from the game's library, a glow that never goes out (the gold trims
## and the ARES mark off by day), the neon sign under the mark and the ground pad under the plaza.

const TOWN_HALL := "res://scenes/_universe/structures/buildings/civic/town_hall.tscn"
const LIBRARY := "res://assets/_universe/_shared/materials/"


func _hall() -> Node3D:
	var hall := (load(TOWN_HALL) as PackedScene).instantiate() as Node3D
	add_child_autofree(hall)
	return hall


func _mesh(hall: Node, mesh_name: String) -> MeshInstance3D:
	return hall.get_node("Model").find_child(mesh_name, true, false) as MeshInstance3D


func test_the_model_replaces_the_placeholders() -> void:
	var hall := _hall()
	assert_not_null(hall.get_node_or_null("Model"), "the modelled building")
	# the scene's own nodes: the kiosks and the board, instanced, keep their CSG stands and frames
	var own_csg: Array = hall.get_children().filter(func(n: Node) -> bool: return n is CSGShape3D)
	assert_eq(own_csg.size(), 0, "no CSG block left in the building itself")
	assert_null(hall.get_node_or_null("Counter"), "the counter is the model's")
	for mesh_name: String in ["TH_mat_concrete_wall_rough", "TH_town_hall_dark_metal", "TH_town_hall_gold_trim",
			"TH_town_hall_emblem", "TH_town_hall_glass"]:
		assert_not_null(_mesh(hall, mesh_name), mesh_name)


func test_collisions_are_bodies_not_meshes() -> void:
	var hall := _hall()
	var bodies := hall.get_node("Model").find_children("*", "StaticBody3D", true, false)
	assert_gt(bodies.size(), 30, "walls, roof, portal, counter, stele, ducts, pillars")
	for mesh: Node in hall.get_node("Model").find_children("*", "MeshInstance3D", true, false):
		assert_false(String(mesh.name).contains("colonly"), "%s: a collision box drawn as a wall" % mesh.name)


func test_the_shared_materials_come_from_the_library() -> void:
	var hall := _hall()
	var rough := _mesh(hall, "TH_mat_concrete_wall_rough")
	var material: Material = rough.get_active_material(0)
	assert_not_null(material)
	assert_true(material.resource_path.begins_with(LIBRARY), "the library's material, not the glTF's copy: %s"
			% material.resource_path)


## Playtest 2026-11-08: the gold trims and the mark stay lit by day too -- the glow is no longer one of
## the lights the photocell switches off.
func test_the_glow_stays_lit_day_and_night() -> void:
	var hall := _hall()
	assert_null(hall.get_node_or_null("Lights/Glow"), "not switched with the building's lights")
	assert_true(hall.get_node_or_null("Glow") is EmissiveGlow, "a glow of its own")
	var gold := _mesh(hall, "TH_town_hall_gold_trim")
	var mark := _mesh(hall, "TH_town_hall_emblem")
	for mesh: MeshInstance3D in [gold, mark]:
		var lit := mesh.get_active_material(0) as BaseMaterial3D
		assert_gt(lit.emission_energy_multiplier, 0.0, "%s glowing at night" % mesh.name)
	var floods := hall.get_node("Lights").find_children("Floodlight*", "SpotLight3D", false, false)
	assert_eq(floods.size(), 2, "the tower's floodlights are the building's lights")
	assert_lt((floods[0] as SpotLight3D).global_basis.z.y, -0.5, "aimed down at the plaza (a spot shines along -Z)")


func test_the_neon_sign_sits_under_the_ares_mark() -> void:
	var hall := _hall()
	var sign := hall.get_node("NeonSign") as Node3D
	assert_between(sign.position.y, 4.95, 6.8, "between the door's lintel and the mark")
	assert_almost_eq(sign.position.x, 0.0, 0.01, "centred on the portal")
	assert_lt(sign.position.z, -11.3, "on the face of the portal's back")
	assert_lte(sign.max_width, 5.9, "no wider than the door's frame")


func test_the_ground_pad_carries_the_plaza() -> void:
	var hall := _hall()
	var ground := hall.get_node("TerrainPad/Ground") as CSGBox3D
	var front: float = ground.position.z - ground.size.z / 2
	assert_lte(front, -13.9, "the pad reaches the plaza's edge (3 m in front of the facade)")
	assert_gte(ground.position.z + ground.size.z / 2, 10.9, "and the back wall")


func test_nothing_stands_across_the_door_and_the_stele_clears_the_duct() -> void:
	var hall := _hall()
	var space: Dictionary = {}
	for body: Node in hall.get_node("Model").find_children("*", "StaticBody3D", true, false):
		# the glTF's "-colonly" boxes come in as triangle shapes: their extent is their debug mesh's box
		for shape_node: Node in body.find_children("*", "CollisionShape3D", false, false):
			var shape: Shape3D = (shape_node as CollisionShape3D).shape
			if shape == null:
				continue
			var box: AABB = (shape_node as Node3D).global_transform * shape.get_debug_mesh().get_aabb()
			space[String(body.name)] = AABB(box.position - hall.global_position, box.size)
	# the doorway: 4 m wide, 2.5 m high, from the plaza (z -13) into the hall (z -10)
	var door := AABB(Vector3(-2.0, 0.05, -13.0), Vector3(4.0, 2.5, 3.0))
	for body_name: String in space:
		if body_name.begins_with("ColFloor"):
			continue
		assert_false((space[body_name] as AABB).intersects(door), "%s blocks the door" % body_name)
	var stele: AABB = _named(space, "ColStele")
	var duct: AABB = _named(space, "ColDuctL")
	assert_ne(stele.size, Vector3.ZERO, "the stele has its collision")
	assert_false(stele.intersects(duct), "the stele stands clear of the heating duct")


func _named(space: Dictionary, prefix: String) -> AABB:
	for key: String in space:
		if key.begins_with(prefix):
			return space[key]
	return AABB()


func test_the_back_rooms_are_closed_and_lit() -> void:
	var hall := _hall()
	# the archives under the mezzanine and the guard post: walls all round, no way in
	var bodies := hall.get_node("Model").find_children("*", "StaticBody3D", true, false).map(
			func(b: Node) -> String: return String(b.name))
	for room: String in ["ColArchive", "ColArchiveSide", "ColBooth"]:
		assert_true(bodies.any(func(n: String) -> bool: return n.begins_with(room)), "%s is walled" % room)
	for lamp: String in ["SupervisorOffice", "GuardPost"]:
		assert_true(hall.get_node("Lights/" + lamp) is OmniLight3D, "%s lit behind its glass" % lamp)


func test_footsteps_read_metal_inside_and_concrete_on_the_plaza() -> void:
	var hall := _hall()
	# as in the game: the ray hits the floor's collision body (a "-colonly" body beside the meshes), at
	# the walking plane, its top, y = 0
	var floor_body: Node = hall.get_node("Model").find_children("ColFloor*", "StaticBody3D", true, false)[0]
	var at_hall := SurfaceProbe.family_of_material(SurfaceProbe._material_of(floor_body, Vector3(3.0, 0.0, 2.0)))
	var at_plaza := SurfaceProbe.family_of_material(SurfaceProbe._material_of(floor_body, Vector3(-6.0, 0.0, -12.8)))
	var at_grate := SurfaceProbe.family_of_material(SurfaceProbe._material_of(floor_body, Vector3(0.0, 0.0, -12.5)))
	assert_eq(at_hall, &"metal", "the hall's diamond plate")
	assert_eq(at_plaza, &"concrete", "the plaza")
	assert_eq(at_grate, &"metal", "the heated grating at the door")


func test_an_artist_wanted_board_stands_on_the_plaza() -> void:
	var hall := _hall()
	var board := hall.get_node("ArtistWanted") as StaticBody3D
	assert_eq((board.get_node("Text") as Label3D).text, "%%SIGN_ARTIST_WANTED", "a translated text")
	assert_between(board.position.z, -14.0, -12.7, "on the plaza, in front of the heating duct")
	assert_gt(absf(board.position.x), 4.0, "clear of the queue rails and the door")
	assert_lt(board.global_basis.z.z, -0.9, "its text read by those walking up to the door")


func test_footsteps_hold_on_a_tilted_planet_frame() -> void:
	# On a planet the building stands tilted to the world's axes: a world-aligned box around a thin
	# floor turns metres thick, and the probe then picked any mesh. It must read the same floors.
	var hall := _hall()
	hall.global_transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(38), deg_to_rad(-71), deg_to_rad(24))),
			Vector3(1200.5, -3400.25, 815.75))
	var floor_body: Node = hall.get_node("Model").find_children("ColFloor*", "StaticBody3D", true, false)[0]
	var cases := {Vector3(3.0, 0.0, 2.0): &"metal", Vector3(-15.0, 0.0, -4.0): &"metal",
			Vector3(20.0, 0.0, 9.0): &"metal", Vector3(-6.0, 0.0, -12.8): &"concrete", Vector3(0.0, 0.0, -12.5): &"metal"}
	for local: Vector3 in cases:
		var world: Vector3 = hall.global_transform * local
		var fam := SurfaceProbe.family_of_material(SurfaceProbe._material_of(floor_body, world))
		assert_eq(fam, cases[local], "at %s in the hall" % local)
