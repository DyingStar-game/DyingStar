extends GutTest
## The ARES Energy machine: rations, three to a delivery, each a networked prop one can carry.

const FOOD_ITEMS := "res://scenes/_universe/props/food/dispenser_items/"
const SCENE := "res://scenes/_universe/structures/dispenser/food_dispenser.tscn"


func test_the_rations_come_three_at_a_time() -> void:
	var items: Array[Resource] = DispenserCatalog.all(FOOD_ITEMS)
	assert_eq(items.size(), 2, "nutrigris and biscuit")
	for item: Resource in items:
		assert_eq(DispenserCatalog.count_of(item), 3, "%s: a batch of three" % item.resource_path)
		assert_not_null(item.get("icon"), "with its pictogram")


func test_a_ration_is_a_networked_prop_one_can_carry() -> void:
	for item: Resource in DispenserCatalog.all(FOOD_ITEMS):
		var ration: Node = (load(str(item.get("scene_path"))) as PackedScene).instantiate()
		assert_true(ration is GenericProp, "carried like a crate")
		var sync: PropSync = PropSync.of(ration)
		assert_not_null(sync)
		assert_eq(str(sync.type_name), "food")
		assert_true(sync.enable_carry)
		ration.free()


func test_the_machine_is_run_by_ares_energy() -> void:
	var machine: ItemDispenser = (load(SCENE) as PackedScene).instantiate()
	assert_eq(machine.brand, AresBrand.Subsidiary.ENERGY)
	assert_eq(machine.catalogue_dir, FOOD_ITEMS)
	machine.free()
