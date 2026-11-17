extends GutTest
## The GDD equipment rules (GarmentRules) against the cases the Python twin is checked with
## (tools/character/garments/test_garment_rules.py): the add-on and the game must agree.

const CASES: String = "res://test/data/character/garment_rules_cases.json"

var _cases: Dictionary = {}
var _items: Dictionary = {}


func before_all() -> void:
	_cases = JSON.parse_string(FileAccess.get_file_as_string(CASES))
	for name: String in _cases["items"]:
		var item: Dictionary = _cases["items"][name].duplicate()
		item["id"] = name
		_items[name] = item


func test_zone_codes() -> void:
	for case: Dictionary in _cases["zones"]:
		assert_eq(not GarmentRules.parse_zone(case["code"]).is_empty(), case["valid"], case["code"])


func test_overlaps() -> void:
	for case: Dictionary in _cases["overlaps"]:
		assert_eq(GarmentRules.zones_overlap(case["a"], case["b"]), case["overlap"], str(case))
		assert_eq(GarmentRules.zones_overlap(case["b"], case["a"]), case["overlap"], "symmetric: %s" % case)


func test_sets() -> void:
	for case: Dictionary in _cases["sets"]:
		var worn: Array = []
		for n: String in case["worn"]:
			worn.append(_items[n])
		assert_eq(GarmentRules.conflict(worn[0], worn[1]), case["conflict"], str(case["worn"]))
		var kept: Array = GarmentRules.keep_compatible(worn).map(func(i: Dictionary) -> String: return i["id"])
		if case["conflict"] != "":
			assert_eq(kept, case["kept"], str(case["worn"]))
			continue
		assert_eq(kept, case["worn"])
		var order: Array = GarmentRules.stack_order(worn).map(func(i: Dictionary) -> String: return i["id"])
		assert_eq(order, case["order"], str(case["worn"]))
		var blocked: Array = worn.filter(func(i: Dictionary) -> bool: return GarmentRules.blocked(i, worn)) \
				.map(func(i: Dictionary) -> String: return i["id"])
		assert_eq(blocked, case["blocked"], str(case["worn"]))


func test_codes() -> void:
	for case: Dictionary in _cases["codes"]:
		assert_eq(GarmentRules.code_of(_items[case["item"]]), case["code"])
