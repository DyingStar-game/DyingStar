class_name PlaceWatcher
extends Node
## CLIENT, own player only: which discoverable place the player stands in — a cave for now — so that on
## entering it a banner names it (PlaceBanner) and, if they discovered it and it has no name yet, they are
## asked for one (PlaceNameDialog). The server decides who discovered what (server/discoveries.gd); this only
## reads the Discovery it replicates, which arrives about a second after the first entry.
##
## It also tells the cave's ambience how deep the player stands in it (CaveAmbience).

const INTERVAL_S := 0.25
## The words for a place with no approved name, per kind.
const UNCHARTED_KEYS := {"cave": "%%PLACE_UNCHARTED_CAVE"}

var _player: Node3D = null
var _notify: Callable
var _input_locked: Callable
var _dialog: PlaceNameDialog = null
var _banner: PlaceBanner = null
var _ambience: CaveAmbience = null
## How much of the weather's sound the rock around takes off, 0..1 (CaveAmbience.buried_at).
var _buried: float = 0.0
var _elapsed := 0.0
## The cave stood in at the last check, "" outside.
var _place_id := ""
## Places whose discoverer was already asked during this visit (asked, dismissed or answered).
var _asked: Dictionary = {}
## Places whose proposal was sent: the player is told once the server took it (status PENDING).
var _awaiting: Dictionary = {}


## [param screens] holds the dialog and the banner; [param notify] shows a line to the player;
## [param input_locked] says when something else owns the keyboard (no dialog is opened over it).
func setup(player: Node3D, screens: Node, notify: Callable, input_locked: Callable) -> void:
	_player = player
	_notify = notify
	_input_locked = input_locked
	_dialog = PlaceNameDialog.new()
	_dialog.proposed.connect(_on_proposed)
	screens.add_child(_dialog)
	_banner = PlaceBanner.new()
	screens.add_child(_banner)
	_ambience = CaveAmbience.new()
	add_child(_ambience)


## How much of the weather's sound the rock around the player takes off, 0 (open air) .. 1 (deep in a cave
## or a mine): the wind is not heard down there (WeatherListener).
func buried() -> float:
	return _buried


## The name dialog has the keyboard (PlayerClient._modal_open).
func is_open() -> bool:
	return _dialog != null and _dialog.visible


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < INTERVAL_S or not is_instance_valid(_player):
		return
	_elapsed = 0.0
	_check()


func _check() -> void:
	for place_id: String in _awaiting.keys():
		var sent := Discovery.of_place("cave", place_id)
		if sent != null and sent.status() == Discovery.PENDING:
			_awaiting.erase(place_id)
			_notify.call(TranslationServer.translate("%%PLACE_NAME_SENT"))
	var site := _site_here()
	var place_id := site.placement_id if site != null else ""
	var depth: float = _depth_in(site)
	var mine: float = MineSite.underground_at(_player.global_position)
	_buried = CaveAmbience.buried_at(depth, mine)
	if _ambience != null:
		_ambience.hear(depth, mine)
	if place_id != _place_id:
		_asked.erase(_place_id)  # a new visit asks again
		_place_id = place_id
		if place_id != "":
			var lines := banner_lines("cave", Discovery.of_place("cave", place_id))
			_banner.show_place(lines[0], lines[1])
	if place_id == "" or _asked.has(place_id) or is_open() or bool(_input_locked.call()):
		return
	var discovery := Discovery.of_place("cave", place_id)
	if discovery != null and discovery.needs_name_from(Player.own_horizon_id()):
		_asked[place_id] = true
		_dialog.open_for("cave")


func _on_proposed(name: String) -> void:
	if _place_id == "" or not is_instance_valid(_player):
		return
	_player.client_send_action_to_server({"action": "place_name_propose",
		"uuid": Discovery.uuid_for("cave", _place_id), "name": name})
	_awaiting[_place_id] = true


## The cave whose rock the player is in, or null.
func _site_here() -> CavePlacement:
	var planet := Planet.of(_player.get_parent())
	if planet == null or planet.planet_data == null or planet.planet_data.stargrot_plans.is_empty():
		return null
	return CavePlanetRegistry.site_at(planet.planet_data, planet.to_local(_player.global_position))


## How far (m) the player stands from the nearest opening of [param site], the cave they are in; -1 in none.
func _depth_in(site: CavePlacement) -> float:
	var planet := Planet.of(_player.get_parent()) if site != null else null
	if planet == null:
		return -1.0
	var mouths := PackedVector3Array()
	for opening: Dictionary in site.openings():
		mouths.append((opening.frame as Transform3D).origin)
	return CaveAmbience.depth_from(mouths, planet.to_local(_player.global_position))


## The banner's two lines for a place of kind [param kind] and its [param discovery] (null: none yet).
static func banner_lines(kind: String, discovery: Discovery) -> PackedStringArray:
	var uncharted := TranslationServer.translate(str(UNCHARTED_KEYS.get(kind, UNCHARTED_KEYS["cave"])))
	if discovery == null:
		return PackedStringArray([uncharted, ""])
	var who := discovery.discoverer_name()
	if discovery.status() == Discovery.APPROVED and discovery.approved_name() != "":
		return PackedStringArray([discovery.approved_name(), TranslationServer.translate("%%PLACE_DISCOVERED_BY") % who])
	if discovery.status() == Discovery.PENDING:
		return PackedStringArray([uncharted, TranslationServer.translate("%%PLACE_DISCOVERED_BY_PENDING") % who])
	return PackedStringArray([uncharted, TranslationServer.translate("%%PLACE_DISCOVERED_BY") % who])
