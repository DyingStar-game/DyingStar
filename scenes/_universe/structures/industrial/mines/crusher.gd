class_name Crusher
extends OreProcessor

## Mining-village machine: takes rock pieces cut down to carrying size, crushes them and packs crates of
## CRUSHED ore — the ore and its barren rock together, only partly filtered. A crate is ONE mineral
## (service-inventory trades by good type), so the stock is banked per mineral. The output purity is
## the input purity give or take OUTPUT_PURITY_SPREAD: bring 10 % gold rock, get 5..15 % gold crates.

## Absolute spread of the output purity around the stock's purity.
const OUTPUT_PURITY_SPREAD := 0.05

## Matter waiting to be packed, per mineral id: {"ore_m3", "gangue_m3", "gangue_kg"}. Server only.
var _stock: Dictionary = {}


## A piece the miner has cut down to carrying size (the perforator's job), with ore in it. Whole rocks
## never fit the belt, and barren rock has nothing to crush.
func _accepts(body: Node) -> bool:
	return is_crushable(body)


## The belt holds a rock the Crusher refuses: stop and say so instead of quietly ignoring it.
func _belt_blocked(bodies: Array) -> bool:
	for body: Node in bodies:
		if body.is_in_group("miningrock") and not is_crushable(body):
			_log_refusal(body)
			return true
	return false


## Server console: why [param rock] was refused, once per rock.
func _log_refusal(rock: Node) -> void:
	if rock.has_meta(&"crusher_refusal_logged"):
		return
	rock.set_meta(&"crusher_refusal_logged", true)
	print("[Crusher] %s refused: carriable=%s mineral='%s' ore_m3=%.4f volume_m3=%.4f mass=%.1f" % [
		rock.name, rock.can_be_carried() if rock.has_method("can_be_carried") else "?", mineral_id_of(rock),
		rock.get_ore_volume() if rock.has_method("get_ore_volume") else -1.0,
		rock.get_volume() if rock.has_method("get_volume") else -1.0,
		rock.real_mass() if rock.has_method("real_mass") else -1.0])


static func is_crushable(body: Node) -> bool:
	if not body.is_in_group("miningrock"):
		return false
	if body.has_method("can_be_carried") and not body.can_be_carried():
		return false
	return mineral_id_of(body) != "" and body.has_method("get_ore_volume") and body.get_ore_volume() > 0.0


func _consume(rock: Node) -> void:
	var mineral := mineral_id_of(rock)
	var ore: float = rock.get_ore_volume()
	var gangue: float = rock.get_gangue_volume()
	var density: float = float(rock.get("inert_density")) if rock.get("inert_density") != null else 0.0
	bank(_stock, mineral, ore, gangue, gangue * density)


## Add matter to [param stock] (see _stock). Static so a test can feed a plain Dictionary.
static func bank(stock: Dictionary, mineral: String, ore_m3: float, gangue_m3: float, gangue_kg: float) -> void:
	var s: Dictionary = stock.get(mineral, {"ore_m3": 0.0, "gangue_m3": 0.0, "gangue_kg": 0.0})
	s["ore_m3"] += ore_m3
	s["gangue_m3"] += gangue_m3
	s["gangue_kg"] += gangue_kg
	stock[mineral] = s


func _can_pack() -> bool:
	return mineral_to_pack(_stock, crate_volume()) != ""


func _next_crate(miner_id: String, miner_name: String) -> Dictionary:
	return pack(_stock, crate_volume(), randf_range(-1.0, 1.0), miner_id, miner_name)


## Take one crate of [param crate_m3] out of [param stock] and return its content, or {} when no
## mineral fills a crate. [param roll] in [-1, 1] places the output purity in its spread.
static func pack(stock: Dictionary, crate_m3: float, roll: float, miner_id: String,
		miner_name: String = "") -> Dictionary:
	var mineral := mineral_to_pack(stock, crate_m3)
	if mineral == "":
		return {}
	var s: Dictionary = stock[mineral]
	var ore: float = s["ore_m3"]
	var gangue: float = s["gangue_m3"]
	var purity := CrateContent.crushed_purity(ore / (ore + gangue), roll, OUTPUT_PURITY_SPREAD)
	# Aim at the rolled purity, but never take more of a part than the stock holds: a stock richer or
	# poorer than the roll fills the rest of the crate with the other part.
	var ore_take := minf(crate_m3 * purity, ore)
	var gangue_take := minf(crate_m3 - ore_take, gangue)
	ore_take = minf(crate_m3 - gangue_take, ore)
	var gangue_kg_take: float = s["gangue_kg"] * (gangue_take / gangue) if gangue > 0.0 else 0.0
	s["ore_m3"] = ore - ore_take
	s["gangue_m3"] = gangue - gangue_take
	s["gangue_kg"] = s["gangue_kg"] - gangue_kg_take
	return CrateContent.crushed(mineral, ore_take, gangue_take, gangue_kg_take, miner_id, miner_name)


## The first mineral (alphabetical, so it does not depend on Dictionary order) whose ore + barren rock
## fills a crate of [param crate_m3], or "".
static func mineral_to_pack(stock: Dictionary, crate_m3: float) -> String:
	var keys := stock.keys()
	keys.sort()
	for key: Variant in keys:
		var s: Dictionary = stock[key]
		if float(s["ore_m3"]) > 0.0 and float(s["ore_m3"]) + float(s["gangue_m3"]) >= crate_m3:
			return str(key)
	return ""


## The mineral this rock carries ("gold"), or "" for barren rock and for anything unnamed. An inert
## mineral's `get_ore_volume()` is already 0, so this mostly guards a rock that never had its mineral.
static func mineral_id_of(rock: Node) -> String:
	var mineral: Variant = rock.get("mineral")
	if mineral == null or not (mineral is Resource):
		return ""
	var id: Variant = (mineral as Resource).get("id")
	return "" if id == null else str(id)


func _title_key() -> String:
	return "%%SIGN_CRUSHER"


func _corner_caption_key() -> String:
	return "%%HUD_CRATE_FILL"


func _processing_key() -> String:
	return "%%HUD_CRUSHING"


func _extra_state() -> Dictionary:
	var rock_m3 := 0.0
	var ore_m3 := 0.0
	for r in filter_accepted(rock_detector.get_overlapping_bodies()):
		rock_m3 += r.get_volume()
		ore_m3 += r.get_ore_volume()
	# Fill of the fullest mineral: that is the crate the next EXTRACT packs.
	var fill := 0.0
	for s: Dictionary in _stock.values():
		fill = maxf(fill, (float(s["ore_m3"]) + float(s["gangue_m3"])) / crate_volume())
	return {"conveyor_rock_volume": rock_m3, "conveyor_ore_volume": ore_m3, "fill": fill}


func _client_ui() -> void:
	var rock_m3 := float(extra.get("conveyor_rock_volume", 0.0))
	var ore_m3 := float(extra.get("conveyor_ore_volume", 0.0))
	var fill := float(extra.get("fill", 0.0))
	(_ui("RockTotalLabel/RockTotal") as Label).text = "%d%%" % int(clampf(fill, 0.0, 1.0) * 100.0)
	if state == "blocked":
		_show_screen(true, "%%HUD_CRUSHER_REFUSED", false, [ICON_ROCKS], true)
		return
	if state != "idle":
		return
	if belt_count > 0:
		_show_screen(false, "", false)
		var purity := ore_m3 / rock_m3 * 100.0 if rock_m3 > 0.0 else 0.0
		(_ui("VB/RockCounter/VB/RockCount") as Label).text = "%d%%" % int(round(purity))
		(_ui("VB/RockCounter/VB/RockCountLabel") as Label).text = tr("%%HUD_ORE_PURITY") % [rock_m3, ore_m3]
	elif packable:
		_show_screen(true, "%%HUD_DEPOT_FULL", true, [ICON_ORE])
	elif fill > 0.0:
		_show_screen(true, tr("%%HUD_DEPOT_FILLING") % int(clampf(fill, 0.0, 1.0) * 100.0), false, [ICON_ORE])
	else:
		_show_screen(true, "%%HUD_DEPOT_PLACE", false, [ICON_ROCKS])
