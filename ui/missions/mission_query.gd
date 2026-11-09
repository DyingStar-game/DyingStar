class_name MissionQuery
extends RefCounted

## The mission screens' filters and orders, on a list of mission service dictionaries: by category,
## by giver, best paid / soonest due / newest first. Pure functions, no screen and no network, so the
## kiosk, the board and their tests share the very same rules.

enum Sort { REWARD, EXPIRY, NEWEST }

## The translation key naming each order on a kiosk.
const SORT_KEYS: Dictionary = {
	Sort.REWARD: "%%MISSION_SORT_REWARD",
	Sort.EXPIRY: "%%MISSION_SORT_EXPIRY",
	Sort.NEWEST: "%%MISSION_SORT_NEWEST",
}


## Each order's own direction: the best paid and the newest first (values going down), the soonest
## due first (dates going up). [param reverse] in apply() turns it round.
const NATURAL_DESCENDING: Dictionary = {Sort.REWARD: true, Sort.EXPIRY: false, Sort.NEWEST: true}


## The missions of [param missions] in [param category] (MissionCategories.id_of, "" = all) given by
## [param giver_key] (MissionGiver.key, "" = all), in [param sort] order, turned round when
## [param reverse]. A new array: the list given is left as it was.
static func apply(missions: Array, category: String = "", giver_key: String = "",
		sort: Sort = Sort.REWARD, reverse: bool = false) -> Array:
	var kept: Array = []
	for mission: Variant in missions:
		if not (mission is Dictionary):
			continue
		if category != "" and MissionCategories.id_of(mission.get("category")) != category:
			continue
		if giver_key != "" and MissionGivers.of_mission(mission).key() != giver_key:
			continue
		kept.append(mission)
	kept.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _before(a, b, sort))
	if reverse:
		kept.reverse()
	return kept


## Whether [param sort], [param reverse]d or not, lists its values going down.
static func is_descending(sort: Sort, reverse: bool) -> bool:
	return bool(NATURAL_DESCENDING[sort]) != reverse


## The arrow that says which way [param sort] goes: ↓ values going down, ↑ going up.
static func arrow(sort: Sort, reverse: bool) -> String:
	return "↓" if is_descending(sort, reverse) else "↑"


## The credits [param mission] pays (its credits reward components), 0 when none.
static func credits_of(mission: Dictionary) -> int:
	var total: int = 0
	var rewards: Variant = mission.get("rewards")
	if rewards is Array:
		for component: Variant in rewards:
			if component is Dictionary and str(component.get("type", "")) == "credits":
				total += ServiceTypes.num(component.get("amount"))
	elif mission.get("reward") is Dictionary and mission.get("reward").get("economic") is Dictionary:
		total = ServiceTypes.num(mission.get("reward").get("economic").get("amount"))  # legacy shape
	return total


## When [param field] of [param mission] falls (an ISO date), in Unix seconds; INF when it has none.
static func time_of(mission: Dictionary, field: String) -> float:
	var value: Variant = mission.get(field)
	if value == null or str(value).length() < 19:
		return INF
	# "2026-11-04T22:00:00.000Z": the seconds are enough, and the parser wants no fraction nor zone.
	return float(Time.get_unix_time_from_datetime_string(str(value).substr(0, 19)))


## How long [param mission] has left from [param now] (Unix s), in seconds; -1 when it has no end. Once
## taken, the player's own deadline ([param assignment]'s `deadlineAt`) comes first.
static func seconds_left(mission: Dictionary, now: float, assignment: Variant = null) -> int:
	var end: float = time_of(assignment, "deadlineAt") if assignment is Dictionary else INF
	if is_inf(end):
		end = time_of(mission, "expiresAt")
	return -1 if is_inf(end) else maxi(int(end - now), 0)


## The categories and the givers found in [param missions], for the filters: [categories, givers],
## each in first-seen order (a giver as itself, a category as its id).
static func facets(missions: Array) -> Array:
	var categories: PackedStringArray = []
	var givers: Array[MissionGiver] = []
	var seen: Dictionary = {}
	for mission: Variant in missions:
		if not (mission is Dictionary):
			continue
		var category: String = MissionCategories.id_of(mission.get("category"))
		if category != "" and not categories.has(category):
			categories.append(category)
		var giver: MissionGiver = MissionGivers.of_mission(mission)
		if not seen.has(giver.key()):
			seen[giver.key()] = true
			givers.append(giver)
	return [categories, givers]


static func _before(a: Dictionary, b: Dictionary, sort: Sort) -> bool:
	match sort:
		Sort.REWARD:
			if credits_of(a) != credits_of(b):
				return credits_of(a) > credits_of(b)
		Sort.EXPIRY:
			if time_of(a, "expiresAt") != time_of(b, "expiresAt"):
				return time_of(a, "expiresAt") < time_of(b, "expiresAt")
		Sort.NEWEST:
			if time_of(a, "createdAt") != time_of(b, "createdAt"):
				return time_of(a, "createdAt") > time_of(b, "createdAt")
	# Equal on the order asked for: by title, then id, so the tiles never swap places between refreshes.
	if str(a.get("title", "")) != str(b.get("title", "")):
		return str(a.get("title", "")) < str(b.get("title", ""))
	return str(a.get("id", "")) < str(b.get("id", ""))
