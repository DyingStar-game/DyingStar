class_name Refinery
extends OreProcessor

## Factory-city machine: takes crates of crushed ore, one at a time on the belt, and keeps their ore —
## the barren rock goes — until it holds a crate of pure metal (100 %). EXTRACT gives that crate of
## ingots, or a partial one before 100 %. The stock is ONE mineral of ONE holder (or a partner on the
## same mission): their crate of ingots, the miner kept.

## Why the belt is refused, for the screen.
const BLOCKED_NOT_CRUSHED := "not_crushed"
const BLOCKED_TOO_MANY := "too_many"
const BLOCKED_OTHER_MINERAL := "other_mineral"
const BLOCKED_OTHER_OWNER := "other_owner"
## The network type of a hauling crate (its PropSync): what tells a crate from anything else.
const CRATE_TYPE := "crate_container"
## The belt counter's big number, sized for a mass ("34 kg") rather than the Crusher's two-digit purity.
const COUNT_FONT_PX := 140
## What the screen says for each refusal: [text key, pictograms].
const REFUSALS := {
	BLOCKED_NOT_CRUSHED: ["%%HUD_REFINERY_CRUSHED_ONLY", [ICON_INGOT]],
	BLOCKED_TOO_MANY: ["%%HUD_REFINERY_ONE_CRATE", [ICON_CRATE, ICON_ORE]],
	BLOCKED_OTHER_MINERAL: ["%%HUD_REFINERY_OTHER_MINERAL", [ICON_ORE]],
	BLOCKED_OTHER_OWNER: ["%%HUD_REFINERY_OTHER_OWNER", [ICON_CRATE]],
}

## The ore taken in so far, crushed crates summed up (see add_to_stock); {} when empty. Server only.
var _stock: Dictionary = {}
## Why the belt is refused (one of the BLOCKED_* above), for the screen. Server only.
var _blocked_reason := ""
var _count_resized := false


func _accepts(body: Node) -> bool:
	return CrateContent.is_crushed(crate_content_of(body))


## One crate at a time, and only crushed ore: two crates, ingots or an empty crate stop the belt.
func _belt_blocked(bodies: Array) -> bool:
	var crates := 0
	for body: Node in bodies:
		if not is_crate(body):
			continue  # not a crate (a rock, a player's foot...) — the belt ignores it
		crates += 1
		if not _accepts(body):
			_blocked_reason = BLOCKED_NOT_CRUSHED  # ingots, or an empty crate
			return true
		var reason := _refusal_of(body)
		if reason != "":
			_blocked_reason = reason
			return true
	_blocked_reason = BLOCKED_TOO_MANY if crates > 1 else ""
	return crates > 1


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
	var out := CrateContent.refined(source)
	if ore - taken <= 1e-9:
		stock.clear()
	else:
		stock["ore_m3"] = ore - taken
	return out


func _title_key() -> String:
	return "%%SIGN_REFINERY"


## Top right: how full the crate of ingots being gathered is.
func _corner_caption_key() -> String:
	return "%%HUD_CRATE_FILL"


func _processing_key() -> String:
	return "%%HUD_REFINING"


func _extra_state() -> Dictionary:
	var crates: Array = filter_accepted(rock_detector.get_overlapping_bodies())
	var preview: Dictionary = crate_content_of(crates[0]) if crates.size() == 1 else {}
	return {"preview_mass": float(preview.get("mass_kg", 0.0)),
		"blocked_reason": _blocked_reason, "fill": fill_of(_stock, crate_volume())}


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
	var pct := int(clampf(fill, 0.0, 1.0) * 100.0)
	(_ui("RockTotalLabel/RockTotal") as Label).text = "%d%%" % pct
	var can_extract := fill > 0.0
	if state == "full":
		_show_screen(true, "%%HUD_REFINERY_FULL", true, [ICON_INGOT], true)
	elif state == "blocked":
		var shown: Array = REFUSALS.get(str(extra.get("blocked_reason", "")), REFUSALS[BLOCKED_TOO_MANY])
		_show_screen(true, shown[0], can_extract, shown[1], true)
	elif state == "idle":
		if belt_count > 0:
			_show_screen(false, "", false)
			(_ui("VB/RockCounter/VB/RockCount") as Label).text = "%.0f kg" % float(extra.get("preview_mass", 0.0))
			(_ui("VB/RockCounter/VB/RockCountLabel") as Label).text = "%%HUD_REFINERY_READY"
		elif can_extract:
			_show_screen(true, tr("%%HUD_DEPOT_FILLING") % pct, true, [ICON_INGOT])
		else:
			_show_screen(true, "%%HUD_REFINERY_PLACE", false, [ICON_CRATE, ICON_ORE])


## Whether [param body] is a hauling crate, empty or not.
static func is_crate(body: Node) -> bool:
	var sync := PropSync.of(body) if body != null else null
	return sync != null and sync.type_name == CRATE_TYPE


## The `content` of a hauling crate, {} for an empty one and for anything else.
static func crate_content_of(body: Node) -> Dictionary:
	var c: Variant = body.get("content") if body != null else null
	return c if c is Dictionary else {}
