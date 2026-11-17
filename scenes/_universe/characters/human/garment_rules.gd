@tool
class_name GarmentRules
extends RefCounted

## What can be worn together: the GDD's equipment rules (technical-docs,
## project/3_GDD/5_personnage/4_personnage_équipement.md). Pure functions over catalogue entries
## ({zones, support, layer, access}), so the dedicated server applies them without loading a mesh.
## Twin of tools/character/garments/garment_rules.py (the Blender add-on): both are checked against
## test/data/character/garment_rules_cases.json -- keep them alike.
##
## Zones: 1 head, 2 neck, 3 torso, 4 arms, 5 hands, 6 wrists, 7 fingers, 8 legs, 9 feet, 0 the whole body; a
## code may add a side (G left, D right) and a finger (1 thumb .. 5): "5G4" = left ring finger.
## An item's GDD code is zone - support - layer - access: support = the highest layer it can rest on,
## layer = the layer it counts as (0 underwear, 1 clothing, 2 light jacket, 3 coat, 4 light armour, 5 heavy
## armour), access 0 = what is under it cannot be reached. Trousers 8-0-1-0, holster 8D-4-3-0 (a coat-level
## item that sits on light armour).
##
## Items sharing a zone are worn inside-out by (support, layer); each inner / outer pair needs
## inner.layer <= outer.support, and two items with the same (support, layer) on a zone cannot both be worn.

const SIDED: String = "456789"
const FINGERED: String = "57"
## A zone that holds another (hands hold fingers, arms wrists), and wrists also meet the hands.
const CONTAINS: Dictionary = {"5": "7", "4": "6"}
const ALSO: Dictionary = {"6": "5"}

static var _code: RegEx = RegEx.create_from_string("^([0-9])([GD])?([1-5])?$")


## [zone, side, finger] of a GDD zone code ("5G4" -> ["5", "G", "4"]), or [] when it is not one.
static func parse_zone(code: String) -> PackedStringArray:
	var m: RegExMatch = _code.search(code)
	if m == null:
		return PackedStringArray()
	var zone: String = m.get_string(1)
	var side: String = m.get_string(2)
	var finger: String = m.get_string(3)
	if side != "" and not SIDED.contains(zone):
		return PackedStringArray()
	if finger != "" and not FINGERED.contains(zone):
		return PackedStringArray()
	if zone == "0" and (side != "" or finger != ""):
		return PackedStringArray()
	return PackedStringArray([zone, side, finger])


static func zones_overlap(a: String, b: String) -> bool:
	var za: PackedStringArray = parse_zone(a)
	var zb: PackedStringArray = parse_zone(b)
	if za.is_empty() or zb.is_empty():
		return false
	if za[0] == "0" or zb[0] == "0":
		return true
	if za[0] != zb[0]:
		var related: bool = CONTAINS.get(za[0], "") == zb[0] or CONTAINS.get(zb[0], "") == za[0] \
				or ALSO.get(za[0], "") == zb[0] or ALSO.get(zb[0], "") == za[0]
		if not related:
			return false
		return not (za[1] != "" and zb[1] != "" and za[1] != zb[1])
	if za[1] != "" and zb[1] != "" and za[1] != zb[1]:
		return false
	return not (za[2] != "" and zb[2] != "" and za[2] != zb[2])


static func overlap(a: Dictionary, b: Dictionary) -> bool:
	for x in a.get("zones", []):
		for y in b.get("zones", []):
			if zones_overlap(str(x), str(y)):
				return true
	return false


## Where an item sits in a stack: compared as (support, layer), lower = further in.
static func stack_less(a: Dictionary, b: Dictionary) -> bool:
	var sa: int = int(a.get("support", 0))
	var sb: int = int(b.get("support", 0))
	if sa != sb:
		return sa < sb
	return int(a.get("layer", 0)) < int(b.get("layer", 0))


## Why a and b cannot be worn together: "" when they can, else "same_place" or "cannot_rest".
static func conflict(a: Dictionary, b: Dictionary) -> String:
	if not overlap(a, b):
		return ""
	if not stack_less(a, b) and not stack_less(b, a):
		return "same_place"
	var inner: Dictionary = a if stack_less(a, b) else b
	var outer: Dictionary = b if stack_less(a, b) else a
	if int(inner.get("layer", 0)) > int(outer.get("support", 0)):
		return "cannot_rest"
	return ""


## The items in order, each left out when it conflicts with one kept before it.
static func keep_compatible(items: Array) -> Array:
	var kept: Array = []
	for item in items:
		var ok: bool = true
		for k in kept:
			if conflict(item, k) != "":
				ok = false
				break
		if ok:
			kept.append(item)
	return kept


## The items inside out (drawing order; what is under is hidden by what is over).
static func stack_order(items: Array) -> Array:
	var out: Array = items.duplicate()
	out.sort_custom(stack_less)
	return out


## True when an item worn over [param item] (sharing a zone) blocks access to it.
static func blocked(item: Dictionary, worn: Array) -> bool:
	for other in worn:
		if is_same(other, item):
			continue
		if overlap(item, other) and stack_less(item, other) and int(other.get("access", 1)) == 0:
			return true
	return false


## The GDD code of an item, from its first zone: "8D-4-3-0".
static func code_of(item: Dictionary) -> String:
	var zones: Array = item.get("zones", [])
	return "%s-%d-%d-%d" % [str(zones[0]) if not zones.is_empty() else "?", int(item.get("support", 0)),
		int(item.get("layer", 0)), int(item.get("access", 1))]
