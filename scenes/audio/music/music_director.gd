extends Node

## THE music of the game (autoload MusicDirector). Twice a second it works out where the player is,
## asks the MusicTable which playlist goes with that, and crossfades to it when the answer has changed
## and held. Nothing else plays music: a scene that wants its own places a MusicZone.
##
## Polled rather than signalled: none of what it reads (the player's frame, weightlessness, the ground
## position) announces its changes, and music has no use for an answer faster than half a second.

const TABLE_PATH: String = "res://scenes/audio/music/music_table.tres"
const BUS: StringName = &"Music"
## The menu's music plays here instead: it sends into Music, and has a slider of its own (Settings >
## Audio > Menu music) — the menu's tracks can be turned down without the game's.
const MENU_BUS: StringName = &"MenuMusic"
const PROBE_INTERVAL_S: float = 0.5
## Most a fade moves on in one frame, in seconds. Arriving in a town freezes the client for a few
## hundred milliseconds at a time (its props, its levelled ground), and a Tween counts those frames in
## full: the 4 s crossfade went by in a handful of frames and the wild's track cut off dead (preprod,
## 2026-10-05). A long frame now only delays the fade.
const FADE_MAX_STEP_S: float = 0.05

## Set by start(); tests hand their own.
var table: MusicTable = null

var _listener: Player = null
## The last situation read, kept for the debug panel.
var _context: MusicContext = null
## What is playing (null: silence), and what the last probe asked for instead.
var _current: MusicPlaylist = null
var _wanted: MusicPlaylist = null
var _wanted_for_s: float = 0.0
var _probe_in_s: float = 0.0

var _voice: AudioStreamPlayer = null
var _last_track: AudioStream = null
## Seconds of silence left before the next track; negative while a track plays or nothing is due.
var _gap_left_s: float = -1.0

## Volume ramps under way: {voice, from, to, elapsed, length, free_at_end}. Stepped by _step_fades.
var _fades: Array[Dictionary] = []

## Plays instead of what the table would choose, while set (the Credits page's track): set_override.
var _override: MusicPlaylist = null

## body name → its points of interest, read once (StarMapPoi.load_for parses a file).
var _pois_by_body: Dictionary = {}


func _ready() -> void:
	# Asleep until GameOrchestrator starts it, which it only does on a real client: never on the
	# dedicated server, in the GUT runner, or for a lone scene run from the editor.
	set_process(false)
	process_mode = Node.PROCESS_MODE_ALWAYS


## Called once by GameOrchestrator on a client. With no player to follow yet, this is the menu music.
func start() -> void:
	if table == null:
		table = load(TABLE_PATH) as MusicTable
	if table == null:
		push_warning("[Music] %s is missing or is not a MusicTable: no music" % TABLE_PATH)
		return
	set_process(true)
	_context = _read_context()
	_switch_to(table.playlist_for(_context))


## [param playlist] plays instead of the table's choice, at once (no settle time), until it is cleared
## with null — then the table decides again. The Credits page sets its track this way.
func set_override(playlist: MusicPlaylist) -> void:
	_override = playlist
	if table == null or not is_processing():
		return  # not started (server, tests): kept for when it is
	if playlist != null:
		_switch_to(playlist)
	elif _context != null:
		_switch_to(table.playlist_for(_context))  # else the next probe decides


## What plays instead of the table's choice, or null.
func override() -> MusicPlaylist:
	return _override


## The player whose situation decides the music from now on: ours, once it stands in the world. When it
## leaves the tree for good (back to the menu), the music returns to the menu's on its own.
func follow(player: Player) -> void:
	_listener = player
	_probe_in_s = 0.0


## What plays and why, for the debug panel (DevReadouts.music_lines). Empty before start().
func debug_state() -> Dictionary:
	if table == null or _context == null:
		return {}
	var state: Dictionary = {
		"track": _last_track.resource_path.get_file() if _voice != null and _last_track != null else "",
		"position_s": _voice.get_playback_position() if _voice != null else 0.0,
		"length_s": _last_track.get_length() if _last_track != null else 0.0,
		"playlist": _current.resource_path.get_file() if _current != null else "",
		"gap_left_s": _gap_left_s,
		"why": table.why(_context),
		"where": _context.describe(),
	}
	if _wanted != _current:
		state["pending"] = _wanted.resource_path.get_file() if _wanted != null else ""
	return state


func _process(delta: float) -> void:
	_step_fades(delta)
	_probe_in_s -= delta
	if _probe_in_s <= 0.0:
		_probe_in_s = PROBE_INTERVAL_S
		_probe()
	if _gap_left_s >= 0.0:
		_gap_left_s -= delta
		if _gap_left_s < 0.0:
			_play_next(false)


func _probe() -> void:
	var context: MusicContext = _read_context()
	if context == null:
		return
	_context = context
	var target: MusicPlaylist = _override if _override != null else table.playlist_for(context)
	if target == _current:
		_wanted = _current
		return
	if target != _wanted:
		_wanted = target
		_wanted_for_s = 0.0
	else:
		_wanted_for_s += PROBE_INTERVAL_S
	if _wanted_for_s >= table.settle_s:
		_switch_to(target)


## Where the player is, or null when that cannot be told this instant (mid-reparent).
func _read_context() -> MusicContext:
	var context: MusicContext = MusicContext.new()
	if not is_instance_valid(_listener):
		_listener = null
		context.in_menu = true
		return context
	if not _listener.is_inside_tree():
		return null

	var detector: Area3D = _listener.get_node_or_null("AreaDetector") as Area3D
	if detector != null and detector.monitoring:
		var zone: MusicZone = MusicZone.strongest(detector.get_overlapping_areas())
		if zone != null:
			context.zone_tag = zone.tag
			context.zone_playlist = zone.playlist

	context.floating = _listener.floating

	var station: OrbitalStation = OrbitalStation.of(_listener)
	if station != null:
		var site: StationSite = station.site()
		context.station_id = site.id if site != null else String(station.name)
		return context

	var body: Planet = Planet.of(_listener)
	var where: Vector3 = _listener.global_position
	if body == null or body.planet_data == null or not body.within_ground_reach(where):
		return context
	# Near the ground of a body, the ground decides and `floating` is not asked: down here it is only
	# ever true for the dev flight (god mode), and flying over a town is still being in that town.
	# Seen in game: standing on Tarsis 3 after a dev flight, with the EVA music playing.
	context.floating = false
	context.on_ground = true
	context.poi = MusicPoi.containing(
		_pois_of(body.planet_data.planet_name), body.local_dir_of(where), body.planet_data.radius)
	return context


func _pois_of(body_key: String) -> Array[Dictionary]:
	if not _pois_by_body.has(body_key):
		_pois_by_body[body_key] = StarMapPoi.load_for(body_key)
	return _pois_by_body[body_key]


func _switch_to(playlist: MusicPlaylist) -> void:
	_wanted = playlist
	_wanted_for_s = 0.0
	if playlist == _current:
		return
	print("[Music] now playing: %s" % (playlist.resource_path if playlist != null else "silence"))
	_fade_out(_voice)
	_voice = null
	_current = playlist
	_last_track = null
	_gap_left_s = -1.0
	_play_next(true)


## Start the next track of the current playlist. Faded in only when it replaces other music: within a
## playlist a track starts as it was mastered.
func _play_next(fade_in: bool) -> void:
	_gap_left_s = -1.0
	if _current == null:
		return
	var track: AudioStream = _current.next_after(_last_track)
	if track == null:
		return
	_last_track = track
	var level: float = db_to_linear(_current.volume_db)
	var voice: AudioStreamPlayer = AudioStreamPlayer.new()
	voice.stream = track
	voice.bus = bus_for(_context)  # so the Audio settings sliders control it
	voice.volume_linear = 0.0 if fade_in and table.crossfade_s > 0.0 else level
	add_child(voice)
	voice.finished.connect(_on_track_finished.bind(voice))
	voice.play()
	_voice = voice
	if voice.volume_linear < level:
		_fade(voice, level, false)


## The bus a track plays on in [param context]: the menu's own while in the menu (no player yet),
## Music everywhere else. Music when the layout has no menu bus, rather than a bus that does not exist.
static func bus_for(context: MusicContext) -> StringName:
	if context != null and context.in_menu and AudioServer.get_bus_index(MENU_BUS) >= 0:
		return MENU_BUS
	return BUS


func _on_track_finished(voice: AudioStreamPlayer) -> void:
	if voice != _voice:
		return  # a voice fading out reached its end: _fade_out frees it
	voice.queue_free()
	_voice = null
	_gap_left_s = _current.draw_gap() if _current != null else -1.0


func _fade_out(voice: AudioStreamPlayer) -> void:
	if voice == null:
		return
	if table.crossfade_s <= 0.0:
		voice.queue_free()
		return
	_fade(voice, 0.0, true)


## Ramp [param voice] from where it is now to [param to] over the table's crossfade, freed at the end
## when [param free_at_end]. A ramp already running on it is replaced: a track faded in and out again
## before the end starts down from where it got to.
func _fade(voice: AudioStreamPlayer, to: float, free_at_end: bool) -> void:
	_fades = _fades.filter(func(f: Dictionary) -> bool: return f["voice"] != voice)
	_fades.append({"voice": voice, "from": voice.volume_linear, "to": to, "elapsed": 0.0,
			"length": table.crossfade_s, "free_at_end": free_at_end})


## Move every ramp on by [param delta], at most FADE_MAX_STEP_S of it: a frozen frame delays a
## crossfade, it never skips it.
func _step_fades(delta: float) -> void:
	if _fades.is_empty():
		return
	var step: float = minf(delta, FADE_MAX_STEP_S)
	var running: Array[Dictionary] = []
	for f: Dictionary in _fades:
		var voice: AudioStreamPlayer = f["voice"]
		if not is_instance_valid(voice):
			continue
		f["elapsed"] = float(f["elapsed"]) + step
		var t: float = clampf(float(f["elapsed"]) / maxf(float(f["length"]), 0.001), 0.0, 1.0)
		voice.volume_linear = lerpf(float(f["from"]), float(f["to"]), t)
		if t < 1.0:
			running.append(f)
		elif f["free_at_end"]:
			voice.queue_free()
	_fades = running
