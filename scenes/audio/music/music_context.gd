class_name MusicContext
extends RefCounted

## Where the player is, as far as the music is concerned. Filled by MusicDirector from the live game and
## read by MusicRule — plain values in between, so the rules can be tested without a world.

## No player of ours in the world yet: the menu, the loading screen, a failed connection.
var in_menu: bool = false

## Tag of the MusicZone the player stands in, or empty.
var zone_tag: StringName = &""

## Playlist carried by that zone itself, or null. It wins over every rule of the table.
var zone_playlist: MusicPlaylist = null

## Weightless (Player.floating) away from any ground: an EVA, or a drift through a station without
## gravity. Never true together with on_ground.
var floating: bool = false

## StationSite.id of the station the player is aboard ("tarsis_3/palaka_pital"), or empty.
var station_id: String = ""

## Near the ground of a planet or moon (Planet.within_ground_reach), and not aboard a station.
var on_ground: bool = false

## The point of interest whose influence sphere holds the player, as StarMapPoi gives it
## (name, kind, radius_m…), or empty. Only ever filled while on_ground.
var poi: Dictionary = {}


## All this situation is made of, for the debug panel: a rule can only match what is listed here.
func describe() -> String:
	if in_menu:
		return "menu (no player in the world)"
	var parts: PackedStringArray = []
	if zone_tag != &"" or zone_playlist != null:
		parts.append("zone '%s'%s" % [zone_tag, " (own playlist)" if zone_playlist != null else ""])
	if floating:
		parts.append("weightless")
	if station_id != "":
		parts.append("station %s" % station_id)
	if not poi.is_empty():
		var kind: String = str(poi.get("kind", ""))
		parts.append("POI %s (%s)" % [str(poi.get("name", "?")), kind if kind != "" else "no type"])
	elif on_ground:
		parts.append("wild")
	return " · ".join(parts) if not parts.is_empty() else "in space"
