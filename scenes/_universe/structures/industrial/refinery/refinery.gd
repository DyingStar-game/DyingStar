class_name Refinery
extends OreProcessor

## Factory-city machine: takes crates of crushed ore, one at a time on the belt, and keeps their ore —
## the barren rock goes — until it holds a crate of pure metal (100 %). EXTRACT gives that crate of
## ingots, or a partial one before 100 %. The stock is ONE mineral of ONE holder (or a partner on the
## same mission): their crate of ingots, the miner kept.

## Why the belt is refused, for the screen.
const BLOCKED_NOT_CRUSHED := "not_crushed"
const BLOCKED_MIXED_OWNERS := "mixed_owners"
const BLOCKED_OTHER_MINERAL := "other_mineral"
const BLOCKED_OTHER_OWNER := "other_owner"
## The network type of a hauling crate (its PropSync): what tells a crate from anything else.
const CRATE_TYPE := "crate_container"
## The belt counter's big number, sized for a mass ("34 kg") rather than the Crusher's two-digit purity.
const COUNT_FONT_PX := 140
## What the screen says for each refusal: [text key, pictograms].
const REFUSALS := {
	BLOCKED_NOT_CRUSHED: ["%%HUD_REFINERY_CRUSHED_ONLY", [ICON_INGOT]],
	BLOCKED_MIXED_OWNERS: ["%%HUD_REFINERY_ONE_CRATE", [ICON_CRATE, ICON_ORE]],
	BLOCKED_OTHER_MINERAL: ["%%HUD_REFINERY_OTHER_MINERAL", [ICON_ORE]],
	BLOCKED_OTHER_OWNER: ["%%HUD_REFINERY_OTHER_OWNER", [ICON_CRATE]],
}

## The ore taken in so far, crushed crates summed up (see add_to_stock); {} when empty. Server only.
var _stock: Dictionary = {}
## Why the belt is refused (one of the BLOCKED_* above), for the screen. Server only.
var _blocked_reason := ""
## Whose crate was refused for another owner (its plate's owner), for the screen. Server only.
var _refused_owner := ""
var _count_resized := false


func _accepts(body: Node) -> bool:
	return CrateContent.is_crushed(crate_content_of(body))


## Crates of crushed ore of ONE mineral and ONE owner, as many as the belt holds (playtest 2026-11-08):
## ingots or an empty crate, crates of two owners or two minerals, or one the stock cannot take stop
## the belt, and the screen says which.
func _belt_blocked(bodies: Array) -> bool:
	var first: Dictionary = {}
	for body: Node in bodies:
		if not is_crate(body):
			continue  # not a crate (a rock, a player's foot...) — the belt ignores it
		if not _accepts(body):
			_blocked_reason = BLOCKED_NOT_CRUSHED  # ingots, or an empty crate
			return true
		var reason := _refusal_of(body)
		if reason != "":
			_blocked_reason = reason
			return true
		var content := crate_content_of(body)
		if first.is_empty():
			first = content
		elif str(content.get("mineral", "")) != str(first.get("mineral", "")):
			_blocked_reason = BLOCKED_OTHER_MINERAL
			return true
		elif CrateContent.holder_of(content) != CrateContent.holder_of(first):
			_blocked_reason = BLOCKED_MIXED_OWNERS
			return true
	_blocked_reason = ""
	return false


## Why the stock cannot take [param crate] in, "" when it can: another mineral, or the crate of a player
## who is neither the stock's holder nor on a mission with them. The partner check asks the mission
## service once (WarehouseDelivery.may_deposit caches it on the crate): refused until it answers.
func _refusal_of(crate: Node) -> String:
	if _stock.is_empty():
		return ""
	var content := crate_content_of(crate)
	if str(content.get("mineral", "")) != str(_stock.get("mineral", "")):
		return BLOCKED_OTHER_MINERAL
	var holder := str(_stock.get("holder", ""))
	if WarehouseDelivery.owns_or_unknown(CrateContent.holder_of(content), holder):
		return ""
	var known: Dictionary = crate.get_meta(WarehouseDelivery.DEPOSIT_OK_META, {})
	_refused_owner = str(content.get("owner", ""))
	if not known.has(holder):
		WarehouseDelivery.may_deposit(crate, holder)  # answers on a later tick
		return BLOCKED_OTHER_OWNER
	return "" if bool(known[holder]) else BLOCKED_OTHER_OWNER


func _consume(crate: Node) -> void:
	var content := (crate_content_of(crate) as Dictionary).duplicate()
	add_to_stock(_stock, content)
	# The ore leaves its holder into the refinery's hopper: the ingots it becomes are credited at the
	# output (OreProcessor._credit). Without this, the crushed ore stayed carried forever.
	var holder := CrateContent.holder_of(content)
	var units := int(content.get("units", 0))
	if holder != "" and units > 0:
		MissionHeartbeat.drop_carried(holder, CrateContent.good_type(content), units, consumed_holder(uuid))


## Add a crushed crate's [param content] to [param stock]: its ore only, the barren rock is gone. The
## first crate sets the mineral and the holder (whose ingots they will be). Static for the tests.
static func add_to_stock(stock: Dictionary, content: Dictionary) -> void:
	if stock.is_empty():
		stock["mineral"] = str(content.get("mineral", ""))
		stock["holder"] = CrateContent.holder_of(content)
		stock["owner"] = str(content.get("owner", CrateContent.OWNER_ARES))
		stock["miner_id"] = str(content.get("miner_id", ""))
		stock["carrier_id"] = str(content.get("carrier_id", ""))
		stock["ore_m3"] = 0.0
	stock["ore_m3"] = float(stock["ore_m3"]) + float(content.get("ore_m3", 0.0))
	# A mission's ore: as much of the ingots drawn from this stock is that mission's (take_crate). Fed
	# with the player's own ore as well, every ingot came out marked (review 2026-11-10).
	if content.get("for_mission") is Dictionary:
		if not stock.has("for_mission"):
			stock["for_mission"] = content["for_mission"]
		stock["mission_m3"] = float(stock.get("mission_m3", 0.0)) + float(content.get("ore_m3", 0.0))


## How full the next crate of ingots is, 0..1+.
static func fill_of(stock: Dictionary, crate_m3: float) -> float:
	return float(stock.get("ore_m3", 0.0)) / crate_m3


## Where the ore a refinery consumes goes: a `system` holder of its own, the record of what it took
## in — no warehouse anybody draws on.
static func consumed_holder(refinery_uuid: String) -> Dictionary:
	return {"holderType": "system", "holderId": refinery_uuid}


## Any metal in: EXTRACT may take a partial crate.
func _can_pack() -> bool:
	return float(_stock.get("ore_m3", 0.0)) > 0.0


func _is_full() -> bool:
	return fill_of(_stock, crate_volume()) >= 1.0


func _next_crate(_miner_id: String, _miner_name: String) -> Dictionary:
	return take_crate(_stock, crate_volume())


## One crate of ingots out of [param stock]: up to [param crate_m3] of metal, the rest stays in. {} when
## empty; the stock forgets its mineral and holder once nothing is left.
static func take_crate(stock: Dictionary, crate_m3: float) -> Dictionary:
	var ore := float(stock.get("ore_m3", 0.0))
	if ore <= 0.0:
		return {}
	var taken := minf(ore, crate_m3)
	var source := stock.duplicate()
	source["ore_m3"] = taken
	# The mission's share goes out first, and only it carries the mission's mark.
	var mission_left := float(stock.get("mission_m3", 0.0))
	if mission_left <= 1e-9:
		source.erase("for_mission")
	var out := CrateContent.refined(source)
	if ore - taken <= 1e-9:
		stock.clear()
		return out
	stock["ore_m3"] = ore - taken
	if mission_left - taken <= 1e-9:
		stock.erase("for_mission")
		stock.erase("mission_m3")
	else:
		stock["mission_m3"] = mission_left - taken
	return out


func _breakdown_kind() -> String:
	return "refinery"


func _title_key() -> String:
	return "%%SIGN_REFINERY"


## Top right: the metal held so far against a full crate's ("38 / 50 kg").
func _corner_caption_key() -> String:
	return "%%HUD_REFINERY_HELD"


func _processing_key() -> String:
	return "%%HUD_REFINING"


func _extra_state() -> Dictionary:
	var crates: Array = filter_accepted(rock_detector.get_overlapping_bodies())
	var on_belt_kg := 0.0
	for crate: Node in crates:
		on_belt_kg += float(crate_content_of(crate).get("mass_kg", 0.0))
	# The mineral of the stock, else of the crates waiting: a full crate's metal is reckoned on it.
	var mineral := str(_stock.get("mineral", ""))
	if mineral == "" and not crates.is_empty():
		mineral = str(crate_content_of(crates[0]).get("mineral", ""))
	return {"preview_mass": on_belt_kg,
		"blocked_reason": _blocked_reason, "fill": fill_of(_stock, crate_volume()),
		# What the screen shows: the metal held in kg against a full crate's, whose it is, whose was refused.
		"stock_kg": CrateContent.game_mass(mineral, float(_stock.get("ore_m3", 0.0)), 0.0),
		"stock_cap_kg": CrateContent.game_mass(mineral, crate_volume(), 0.0),
		"stock_owner": str(_stock.get("owner", "")), "refused_owner": _refused_owner}


func _client_ui() -> void:
	if not _count_resized:
		_count_resized = true
		var count := _ui("VB/RockCounter/VB/RockCount") as Label
		count.label_settings = count.label_settings.duplicate()
		count.label_settings.font_size = COUNT_FONT_PX
		# The counter tucks its caption under the Crusher's 235 px digits (separation -51): with the
		# smaller mass the caption would ride over it.
		(_ui("VB/RockCounter/VB") as Control).add_theme_constant_override("separation", 0)
	var fill := float(extra.get("fill", 0.0))
	var held := held_text(float(extra.get("stock_kg", 0.0)), float(extra.get("stock_cap_kg", 0.0)))
	(_ui("RockTotalLabel/RockTotal") as Label).text = held
	var can_extract := fill > 0.0
	var owner := str(extra.get("stock_owner", ""))
	var whose := tr("%%HUD_REFINERY_HELD_BY") % [owner, held] if owner != "" else held
	if state == "full":
		_show_screen(true, tr("%%HUD_REFINERY_FULL") + "\n" + whose, true, [ICON_INGOT], true)
	elif state == "blocked":
		var reason := str(extra.get("blocked_reason", ""))
		var shown: Array = REFUSALS.get(reason, REFUSALS[BLOCKED_MIXED_OWNERS])
		var message: String = tr(shown[0])
		if reason == BLOCKED_OTHER_OWNER:
			message = tr("%%HUD_REFINERY_OTHER_OWNER") % [str(extra.get("refused_owner", "")), owner]
		_show_screen(true, message, can_extract, shown[1], true)
	elif state == "idle":
		if belt_count > 0:
			_show_screen(false, "", false)
			(_ui("VB/RockCounter/VB/RockCount") as Label).text = "%.0f kg" % float(extra.get("preview_mass", 0.0))
			(_ui("VB/RockCounter/VB/RockCountLabel") as Label).text = "%%HUD_REFINERY_READY"
		elif can_extract:
			_show_screen(true, whose, true, [ICON_INGOT])
		else:
			_show_screen(true, "%%HUD_REFINERY_PLACE", false, [ICON_CRATE, ICON_ORE])


## "38 / 50 kg": the metal held against a full crate's, whole kilograms.
static func held_text(held_kg: float, cap_kg: float) -> String:
	return "%d / %d kg" % [roundi(held_kg), roundi(cap_kg)]


## Whether [param body] is a hauling crate, empty or not.
static func is_crate(body: Node) -> bool:
	var sync := PropSync.of(body) if body != null else null
	return sync != null and sync.type_name == CRATE_TYPE


## The `content` of a hauling crate, {} for an empty one and for anything else.
static func crate_content_of(body: Node) -> Dictionary:
	var c: Variant = body.get("content") if body != null else null
	return c if c is Dictionary else {}
