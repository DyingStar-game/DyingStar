@tool
class_name MusicRule
extends Resource

## One line of the "which playlist plays where" table (MusicTable).
##
## Rules are tried in order and the first that fits wins, so the order of the list IS the priority:
## the specific ones go above the general ones, exactly as in PoiIconSet.
##
## A tool script for one reason: each rule names itself (resource_name) from what it holds, so the
## table reads "POI village mining → silence" in the Inspector instead of fourteen times "MusicRule".

enum Situation {
	## No player in the world yet: menu and loading screen.
	MENU,
	## Standing in a MusicZone placed in a scene — a building, a room.
	ZONE,
	## Weightless.
	EVA,
	## Aboard an orbital station.
	STATION,
	## On the ground, inside the influence sphere of a point of interest.
	POI,
	## On the ground, outside every point of interest.
	WILD,
	## Anywhere in the world. A catch-all, to be left at the bottom.
	ANYWHERE,
}

## Where this rule applies.
@export var situation: Situation = Situation.ANYWHERE:
	set(value):
		situation = value
		_relabel()

## Narrows the situation; empty means "all of them". Case is ignored.
## ZONE: the zone's tag. STATION: the StationSite id ("tarsis_3/palaka_pital").
## POI: its poi_type ("city") OR the start of its raw name ("mining_village_", "Palaka-Pital") — both
## are offered because many records ship with an empty poi_type (see PoiIconRule).
## Ignored by the other situations.
@export var only: String = "":
	set(value):
		only = value
		_relabel()

## What plays there. Leave EMPTY for a deliberate silence: the rule still wins, and nothing plays.
@export var playlist: MusicPlaylist = null:
	set(value):
		playlist = value
		_relabel()


func _init() -> void:
	_relabel()


## What this rule says, in one line: "POI village mining → silence", "MENU → menu".
func label() -> String:
	var where: String = Situation.keys()[situation]
	if only != "":
		where += " " + only
	var what: String = "silence"
	if playlist != null:
		what = playlist.resource_path.get_file().get_basename() if playlist.resource_path != "" else "playlist"
	return "%s → %s" % [where, what]


func _relabel() -> void:
	resource_name = label()


## Does this rule fit [param context]?
func matches(context: MusicContext) -> bool:
	if situation == Situation.MENU:
		return context.in_menu
	if context.in_menu:
		return false
	match situation:
		Situation.ZONE:
			return context.zone_tag != &"" and _fits(String(context.zone_tag))
		Situation.EVA:
			return context.floating
		Situation.STATION:
			return context.station_id != "" and _fits(context.station_id)
		Situation.POI:
			return not context.poi.is_empty() and _fits_poi(context.poi)
		Situation.WILD:
			return context.on_ground and context.poi.is_empty()
	return true


func _fits(value: String) -> bool:
	return only == "" or value.to_lower() == only.to_lower()


func _fits_poi(poi: Dictionary) -> bool:
	return _fits(str(poi.get("kind", ""))) or str(poi.get("name", "")).to_lower().begins_with(only.to_lower())
