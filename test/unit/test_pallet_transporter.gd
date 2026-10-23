extends GutTest
## The cargo pallet transporter: a plain networked physics prop, nothing to do with it yet, that every
## garage holds from the start (FixtureSpawn), once, under a uuid drawn from the garage's.

const PROP := "res://scenes/_universe/props/handling/cargo_pallet_transporter.tscn"
const GARAGE := "res://scenes/_universe/structures/industrial/garage.tscn"


func test_it_is_a_networked_physics_prop_with_no_action() -> void:
	var prop := (load(PROP) as PackedScene).instantiate() as RigidBody3D
	add_child_autofree(prop)
	assert_eq(MarkerSpawn.scene_type(load(PROP)), "box", "networked, as the pallets are")
	assert_eq(prop.collision_layer, 1 << (Globals.LAYER_PROP - 1), "on the prop layer")
	assert_eq(prop.collision_mask, Globals.MASK_DYNAMIC, "rests on the world, pushed by vehicles (players: PlayerServer)")
	assert_eq(prop.mass, 75.0, "a manual pallet truck's weight")
	assert_false(prop.is_in_group("carriable"), "not carried")
	assert_false(PropSync.of(prop).interact(), "no action offered")
	assert_eq(prop.find_children("*", "Area3D", true, false).size(), 0, "nothing for the look to aim at")
	assert_gt(prop.find_children("*", "CollisionShape3D", false, false).size(), 0, "solid")


func test_its_model_wears_the_shared_paint_and_decals() -> void:
	var prop := (load(PROP) as PackedScene).instantiate() as Node3D
	var by_name := {}
	for node in prop.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		by_name[mesh_node.name] = mesh_node.get_active_material(0).resource_path
	assert_string_contains(str(by_name["Cube_002"]), "mat_metal_smart_painted", "the body: shared paint")
	assert_string_contains(str(by_name["square_003"]), "mat_metal_ares_misc_decal", "the decals: ARES sheet")
	prop.free()


func test_every_garage_holds_one_from_the_start() -> void:
	var garage := (load(GARAGE) as PackedScene).instantiate() as Node3D
	var spawns: Array = garage.find_children("*", "FixtureSpawn", true, false)
	assert_eq(spawns.size(), 1, "one pallet transporter per garage")
	assert_eq((spawns[0] as FixtureSpawn).scene.resource_path, PROP, "the pallet transporter")
	garage.free()


func test_its_uuid_is_the_same_on_every_boot_and_per_garage() -> void:
	var a := FixtureSpawn.uuid_for("garage-a", "PalletTransporterSpawn")
	assert_eq(a, FixtureSpawn.uuid_for("garage-a", "PalletTransporterSpawn"), "stable: never a second one")
	assert_ne(a, FixtureSpawn.uuid_for("garage-b", "PalletTransporterSpawn"), "each garage its own")
	assert_ne(a, FixtureSpawn.uuid_for("garage-a", "OtherSpawn"), "each marker its own")
	assert_eq(a.length(), 36, "a uuid's shape")
