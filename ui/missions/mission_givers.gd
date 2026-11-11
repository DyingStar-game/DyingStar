class_name MissionGivers
extends RefCounted

## Every mission giver the game knows, and the one behind a mission. The ARES subsidiaries are made
## from AresBrand; any other faction is a MissionGiver .tres in DIR (a new faction = a new file).
## A mission whose giver is not known keeps a neutral look named after its issuer (the system, a
## player, a corporation…): a tile is never left blank.

## Where the other factions' givers live, one .tres each.
const DIR: String = "res://ui/missions/givers/"
## The neutral look of a mission without a known giver.
const NEUTRAL_TINT := Color(0.55, 0.58, 0.63)

static var _all: Array[MissionGiver] = []


## The filters' value for a faction's division: "ares/mining", "freeport/" for the faction itself.
static func key_of(faction: String, division: String) -> String:
	return "%s/%s" % [faction, division]


## Every known giver: the ARES subsidiaries first (in AresBrand's order), then DIR's in file order.
static func all() -> Array[MissionGiver]:
	if _all.is_empty():
		for subsidiary: int in AresBrand.Subsidiary.values():
			_all.append(AresMissionGiver.make(subsidiary))
		var files: PackedStringArray = ResourceLoader.list_directory(DIR) if DirAccess.dir_exists_absolute(DIR) \
				else PackedStringArray()
		files.sort()
		for file: String in files:
			if file.ends_with(".tres"):
				var giver := load(DIR.path_join(file)) as MissionGiver
				if giver != null and giver.faction_id() != "":
					_all.append(giver)
	return _all


## The giver of [param faction]'s [param division]: that division, else the faction itself when the
## division is unknown or empty, else null.
static func find(faction: String, division: String) -> MissionGiver:
	if faction == "":
		return null
	var whole: MissionGiver = null
	for giver: MissionGiver in all():
		if giver.faction_id() != faction:
			continue
		if division != "" and giver.division_id() == division:
			return giver
		if giver.is_faction_itself():
			whole = giver
	return whole


## The giver of [param mission] (a mission service dictionary): its named giver when the game knows
## it, else a neutral one named after the player who raised it (its "creatorName", MissionFeed) or
## after its issuer type.
static func of_mission(mission: Dictionary) -> MissionGiver:
	var faction: String = _slug(mission.get("giverFaction"))
	var known: MissionGiver = find(faction, _slug(mission.get("giverDivision")))
	if known != null:
		return known
	var neutral := MissionGiver.new()
	neutral.faction = faction
	neutral.tint = NEUTRAL_TINT
	var creator: String = str(mission.get("creatorName", "")).strip_edges()
	if faction != "":
		neutral.name_key = faction.to_upper()
	elif creator != "":
		neutral.name_key = creator
		neutral.faction = "player:" + str(mission.get("createdBy", ""))  # one giver filter per player
	else:
		# The entity that says who it is (the simulator's issuer), else the issuer type.
		var named := ServiceTypes.entity_text(ServiceTypes.mission_issuer(mission))
		neutral.name_key = named if named != "" else ServiceTypes.issuer_type_label(mission.get("issuerType", "system"))
	return neutral


static func _slug(value: Variant) -> String:
	return "" if value == null else str(value)
