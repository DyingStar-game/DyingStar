class_name MissionFeed
extends Node

## The missions on offer where this feed stands, as the local player may take them: one request to
## the mission service shared by every screen of a building (the board and its kiosks). The service
## already keeps to the missions of the player's place (a mission zoned on a town shows in that town
## only) and to the ones with a free slot. Asked again every REFRESH_S while the camera is within
## WATCH_M, and at once when a mission changes hands (PlayerServices.changed "missions"); idle further
## away and on the dedicated server. Read PAGE missions at a time: the first time, the screens fill
## page after page as they arrive; afterwards the list is swapped whole once read, so no screen
## flickers through a half-read list.

signal updated(missions: Array)

const REFRESH_S: float = 30.0
## How close (m) the camera must be for the feed to ask: a town hall across the valley costs nothing.
const WATCH_M: float = 80.0
## Missions per request.
const PAGE: int = 20
## The most missions read in all (a town hall is not a database).
const MAX_MISSIONS: int = 300

## The last answer: mission service dictionaries, as received.
var missions: Array = []
## Players' display names by player id, for the missions they raised ("" when Social had none):
## asked once per player for the whole game, shared by every feed.
static var _creator_names: Dictionary = {}
var _asking: bool = false
var _asked_at_ms: int = -1
## Whether the list has been read once (the first reading shows page after page).
var _loaded: bool = false


## The feed shared by [param screen]'s building: the first MissionFeed met among its ancestors'
## children; one made under [param screen] when there is none, so a lone screen still works.
static func near(screen: Node) -> MissionFeed:
	var at: Node = screen.get_parent()
	while at != null:
		for child: Node in at.get_children():
			if child is MissionFeed:
				return child as MissionFeed
		at = at.get_parent()
	var own := MissionFeed.new()
	own.name = "MissionFeed"
	screen.add_child(own)
	return own


func _ready() -> void:
	if GameOrchestrator.is_server():
		set_process(false)
		return
	PlayerServices.changed.connect(_on_services_changed)


func _process(_delta: float) -> void:
	var due: bool = _asked_at_ms < 0 or Time.get_ticks_msec() - _asked_at_ms > int(REFRESH_S * 1000.0)
	if due and _watched():
		refresh()


## Whether the list has been read whole once: from then on, a mission that shows up is a new one.
func is_loaded() -> bool:
	return _loaded


## Ask the service again now, page after page (a no-op while a reading is on its way).
func refresh() -> void:
	if _asking or not PlayerServices.is_available():
		return
	_asking = true
	_asked_at_ms = Time.get_ticks_msec()
	var read: Array = []
	while read.size() < MAX_MISSIONS:
		var result: Dictionary = await PlayerServices.missions_list("", "", "", "", "", "", PAGE, read.size())
		if not is_inside_tree():
			_asking = false
			return
		var data: Variant = result.get("data")
		if not (bool(result.get("ok", false)) and data is Dictionary and data.get("missions") is Array):
			push_warning("[MissionFeed] the mission service did not answer: %s" % HttpClient.describe_error(result))
			break
		var page: Array = data.get("missions")
		read.append_array(page)
		var done: bool = page.size() < PAGE or read.size() >= int(data.get("total", 0))
		if not _loaded or done:
			_show(read)  # the first reading shows as it comes; the next ones once whole
		if done:
			_loaded = true
			break
	_asking = false
	_ask_creator_names()


func _show(read: Array) -> void:
	missions = read.duplicate()
	name_creators(missions, _creator_names)
	updated.emit(missions)


## Whether [param mission] was raised by a player in their own name (its giver is that player).
static func is_player_made(mission: Dictionary) -> bool:
	return str(mission.get("issuerType", "")) == "player" and str(mission.get("createdBy", "")) != ""


## Write each player-made mission's creator name ([param names], by player id) into its
## "creatorName", where MissionGivers reads it. Returns the creators whose name is not known yet.
static func name_creators(shown: Array, names: Dictionary) -> PackedStringArray:
	var unknown: PackedStringArray = []
	for mission: Variant in shown:
		if not (mission is Dictionary and is_player_made(mission)):
			continue
		var creator: String = str(mission.get("createdBy"))
		if names.has(creator):
			if str(names[creator]) != "":
				mission["creatorName"] = names[creator]
		elif not unknown.has(creator):
			unknown.append(creator)
	return unknown


## Ask Social for the creators not named yet, then show the tiles again with their names.
func _ask_creator_names() -> void:
	var unknown: PackedStringArray = name_creators(missions, _creator_names)
	if unknown.is_empty():
		return
	for creator: String in unknown:
		_creator_names[creator] = ""  # asked: a failure is not asked again every refresh
		var result: Dictionary = await PlayerServices.profile_get_by_id(creator)
		if bool(result.get("ok", false)) and result.get("data") is Dictionary:
			_creator_names[creator] = str((result.get("data") as Dictionary).get("displayName", "")).strip_edges()
	if not is_inside_tree():
		return
	name_creators(missions, _creator_names)
	updated.emit(missions)


func _watched() -> bool:
	var camera: Camera3D = get_viewport().get_camera_3d() if get_viewport() != null else null
	var parent := get_parent() as Node3D
	if camera == null or parent == null:
		return false
	return camera.global_position.distance_to(parent.global_position) < WATCH_M


func _on_services_changed(area: String) -> void:
	if area == "missions" and _watched():
		_asked_at_ms = -1  # due at once, next frame
