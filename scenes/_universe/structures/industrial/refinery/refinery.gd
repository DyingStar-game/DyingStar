class_name Refinery
extends OreProcessor

## Factory-city machine: takes ONE crate of crushed ore at a time and gives back one crate of ingots —
## the same ore, the barren rock gone, so a lighter crate. Owner and miner are kept. It
## refines on its own once the crate is in: SEND feeds it, no EXTRACT press.

## The crushed crate being refined (its content), {} when the machine is empty. Server only.
var _pending: Dictionary = {}
## Why the belt is refused, for the screen: BLOCKED_NOT_CRUSHED or BLOCKED_TOO_MANY. Server only.
var _blocked_reason := ""
const BLOCKED_NOT_CRUSHED := "not_crushed"
const BLOCKED_TOO_MANY := "too_many"


func _accepts(body: Node) -> bool:
	return CrateContent.is_crushed(crate_content_of(body))


## One crate at a time, and only crushed ore: two crates, ingots or an empty crate stop the belt.
func _belt_blocked(bodies: Array) -> bool:
	var crates := 0
	for body: Node in bodies:
		if crate_content_of(body) == null_content():
			continue  # not a crate (a rock, a player's foot...) — the belt ignores it
		crates += 1
		if not _accepts(body):
			_blocked_reason = BLOCKED_NOT_CRUSHED  # ingots, or an empty crate
			return true
	_blocked_reason = BLOCKED_TOO_MANY if crates > 1 else ""
	return crates > 1


func _consume(crate: Node) -> void:
	_pending = (crate_content_of(crate) as Dictionary).duplicate()
	# The ore leaves its holder into the refinery's hopper: the ingots it becomes are credited at the
	# output (OreProcessor._credit). Without this, the crushed ore stayed carried forever.
	var holder := CrateContent.holder_of(_pending)
	var units := int(_pending.get("units", 0))
	if holder != "" and units > 0:
		MissionHeartbeat.drop_carried(holder, CrateContent.good_type(_pending), units,
			WarehouseDelivery.warehouse(uuid))


func _can_pack() -> bool:
	return not _pending.is_empty()


func _auto_extract() -> bool:
	return true


func _next_crate(_miner_id: String, _miner_name: String) -> Dictionary:
	if _pending.is_empty():
		return {}
	var out := CrateContent.refined(_pending)
	_pending = {}
	return out


func _title_key() -> String:
	return "%%SIGN_REFINERY"


## Top right: the purity of the crate on the belt, the one about to be refined.
func _corner_caption_key() -> String:
	return "%%PLATE_PURITY"


func _processing_key() -> String:
	return "%%HUD_REFINING"


func _extra_state() -> Dictionary:
	var crates: Array = filter_accepted(rock_detector.get_overlapping_bodies())
	var preview: Dictionary = crate_content_of(crates[0]) if crates.size() == 1 else {}
	return {"preview_purity": float(preview.get("purity", 0.0)), "preview_mass": float(preview.get("mass_kg", 0.0)),
		"blocked_reason": _blocked_reason}


## The belt counter's big number, sized for a mass ("34 kg") rather than the Crusher's two-digit purity.
const COUNT_FONT_PX := 140

var _count_resized := false


func _client_ui() -> void:
	if not _count_resized:
		_count_resized = true
		var count := _ui("VB/RockCounter/VB/RockCount") as Label
		count.label_settings = count.label_settings.duplicate()
		count.label_settings.font_size = COUNT_FONT_PX
		# The counter tucks its caption under the Crusher's 235 px digits (separation -51): with the
		# smaller mass the caption would ride over it.
		(_ui("VB/RockCounter/VB") as Control).add_theme_constant_override("separation", 0)
	(_ui("RockTotalLabel/RockTotal") as Label).text = "%d%%" % int(float(extra.get("preview_purity", 0.0)) * 100.0)
	_ui("RockTotalLabel").visible = state == "idle" and belt_count == 1
	if state == "blocked":
		if str(extra.get("blocked_reason", "")) == BLOCKED_NOT_CRUSHED:
			_show_screen(true, "%%HUD_REFINERY_CRUSHED_ONLY", false, [ICON_INGOT], true)
		else:
			_show_screen(true, "%%HUD_REFINERY_ONE_CRATE", false, [ICON_CRATE, ICON_ORE], true)
	elif state == "idle":
		if belt_count > 0:
			_show_screen(false, "", false)
			(_ui("VB/RockCounter/VB/RockCount") as Label).text = "%.0f kg" % float(extra.get("preview_mass", 0.0))
			(_ui("VB/RockCounter/VB/RockCountLabel") as Label).text = "%%HUD_REFINERY_READY"
		else:
			_show_screen(true, "%%HUD_REFINERY_PLACE", false, [ICON_CRATE, ICON_ORE])


## The `content` of a hauling crate, or null_content() for anything else.
static func crate_content_of(body: Node) -> Dictionary:
	var c: Variant = body.get("content") if body != null else null
	return c if c is Dictionary else null_content()


static func null_content() -> Dictionary:
	return {}
