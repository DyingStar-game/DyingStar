class_name CreditsSettingsPage
extends Control
## Credits: who made the game's music, sounds, models and textures — "author   work", one line per work
## and author, nothing more (no Discord id, no licence: the page is for the people).
##
## Read like a film's: the whole page under the bar scrolling up on its own, one of the credited tracks
## playing.
## Scrolling by hand (wheel, arrows, stick) takes over; the column moves on again after a while.
## Every track has a play button (or "accept" on its focused line) to hear it; pressed again, it stops
## and the drawn track comes back. A work whose author is lost shows "owner wanted" in their place.
##
## The list is res://assets/credits.json, written by tools/generate_credits.py from the credit .txt
## beside each asset (those files never reach a build, the JSON does). Nobody edits it by hand.

## The generated list: category -> lines.
const CREDITS_PATH : String = "res://assets/credits.json"
## The page's sections, in its order: category in the JSON -> its heading.
const SECTIONS : Dictionary = {
	"music": "%%MENU_CREDITS_SECTION_MUSIC",
	"sfx": "%%MENU_CREDITS_SECTION_SFX",
	"models": "%%MENU_CREDITS_SECTION_MODELS",
}
## Scrolling speed, in pixels per second: slow enough to read a name as it goes by.
const SCROLL_SPEED_PX_S : float = 30.0
## Seconds without a hand on the wheel, arrows or stick before the column moves on by itself.
const HOLD_S : float = 4.0
## Blank space below the last line, in pixels: it leaves at the top before the list starts over.
const TAIL_PX : float = 240.0
## Gap between the author and the work, in pixels.
const GAP_PX : int = 40
## The page's background: dark enough to read over the menu's scene or the game behind.
const COLUMN_COLOR : Color = Color(0.02, 0.025, 0.035, 0.72)
## A stick pushed past this (0..1) counts as scrolling by hand.
const STICK_DEADZONE : float = 0.5
## Gap between a track's play button and its name, in pixels.
const TOGGLE_GAP_PX : int = 8
## The source tools/generate_credits.py gives a work whose author is lost (an "Unknown" credit line).
const UNKNOWN_SOURCE : String = "Unknown"
const _LABEL_SETTINGS : LabelSettings = preload("res://ui/settings_page/settings_label.tres")

## The list read by _ready. A test points it at a fixture before adding the page.
var credits_path : String = CREDITS_PATH

var _auto : AutoScroll
## The track this page asked MusicDirector for, or null.
var _music : MusicPlaylist = null
## The track drawn at random when the page opened: what plays while no line is picked.
var _random : MusicPlaylist = null
## res:// path of the track picked on a line, or "" while the drawn one plays.
var _picked : String = ""
## Play buttons by their track's res:// path: a track with two authors has two lines, so two buttons.
var _toggles : Dictionary = {}

@onready var _rows : VBoxContainer = $ScrollContainer/Content/Column/MarginContainer/VBoxContainer
@onready var _column : PanelContainer = $ScrollContainer/Content/Column


func _ready() -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = COLUMN_COLOR
	_column.add_theme_stylebox_override("panel", box)
	var credits : Dictionary = load_credits(credits_path)
	build(credits)
	_auto = AutoScroll.new($ScrollContainer/Content)
	_auto.speed_px_s = SCROLL_SPEED_PX_S
	_auto.rewind = true
	$ScrollContainer.add_child(_auto)
	_random = drawn(music_paths(credits))
	if _random != null:
		_set_music(_random)


## The music goes back to what the place plays once the credits close.
func _exit_tree() -> void:
	if _music != null and MusicDirector.override() == _music:
		MusicDirector.set_override(null)


## A hand on the wheel, the arrows or a stick: the column stops moving by itself for a while.
func _input(event: InputEvent) -> void:
	if _auto == null or not is_visible_in_tree():
		return
	var by_hand : bool = event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")
	var wheel := event as InputEventMouseButton
	if wheel != null and wheel.pressed \
			and wheel.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		by_hand = true
	var stick := event as InputEventJoypadMotion
	if stick != null and stick.axis in [JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_Y] \
			and absf(stick.axis_value) > STICK_DEADZONE:
		by_hand = true
	if by_hand:
		_auto.hold(HOLD_S)


## The generated list, or an empty one when the file is missing or broken (the page then shows only
## its thanks, never an error to the player).
static func load_credits(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[Credits] %s is missing: run tools/generate_credits.py" % path)
		return {}
	var parsed : Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_warning("[Credits] %s is not a JSON object" % path)
		return {}
	return parsed


## The credited music that is in the project, as res:// paths.
static func music_paths(credits: Dictionary) -> PackedStringArray:
	var paths := PackedStringArray()
	for credit: Variant in credits.get("music", []):
		if credit is Dictionary:
			var path : String = str(credit.get("path", ""))
			if not path.is_empty() and not path in paths and ResourceLoader.exists(path):
				paths.append(path)
	return paths


## One of [param paths], drawn at random, to play over everything else while the page is open; null when
## there is none. Only the drawn one is loaded: a whole playlist would read every track from disk.
static func drawn(paths: PackedStringArray) -> MusicPlaylist:
	if paths.is_empty():
		return null
	return looping(load(paths[randi() % paths.size()]) as AudioStream)


## A playlist of [param track] alone, round and round; null for no track.
static func looping(track: AudioStream) -> MusicPlaylist:
	if track == null:
		return null
	var playlist := MusicPlaylist.new()
	playlist.tracks = [track]
	playlist.shuffle = false
	return playlist


## Play the track of a line, or stop it when it is the one playing: the drawn track comes back.
func toggle_track(path: String) -> void:
	if _picked == path:
		_picked = ""
		_set_music(_random)
	else:
		var picked : MusicPlaylist = looping(load(path) as AudioStream)
		if picked == null:
			return
		_picked = path
		_set_music(picked)
	for toggle_path: String in _toggles:
		for toggle: PlayToggle in _toggles[toggle_path]:
			toggle.playing = toggle_path == _picked


func _set_music(playlist: MusicPlaylist) -> void:
	_music = playlist
	MusicDirector.set_override(playlist)


## The thanks at the very top, then one centred heading per non-empty section and one line per work and
## author, sorted by author then work, then a blank tail. Every line takes the focus, so the cross,
## the stick and the arrows can move through the page.
func build(credits: Dictionary) -> void:
	var factory := SettingsRowFactory.new()
	var thanks := Label.new()
	thanks.text = "%%MENU_CREDITS_THANKS"
	thanks.label_settings = _LABEL_SETTINGS
	thanks.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	thanks.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rows.add_child(thanks)
	for category: String in SECTIONS:
		var lines : Array[Dictionary] = lines_of(credits.get(category, []))
		if lines.is_empty():
			continue
		var heading : Label = factory.header(SECTIONS[category])
		heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_rows.add_child(heading)
		for line: Dictionary in lines:
			_rows.add_child(_line(factory, line, category == "music"))
	_rows.add_child(_spacer())


## One section's credits as {author, work, path, owner_wanted}, once each, sorted by author then work;
## the works still looking for their owner come last.
static func lines_of(credits: Array) -> Array[Dictionary]:
	var seen : Dictionary = {}
	for credit: Variant in credits:
		if not credit is Dictionary:
			continue
		var line : Dictionary = {"author": str(credit.get("author", "")),
				"work": work_name(str(credit.get("asset", ""))),
				"path": str(credit.get("path", "")),
				"owner_wanted": str(credit.get("source", "")) == UNKNOWN_SOURCE}
		seen["%s|%s" % [line.author, line.work]] = line
	var lines : Array[Dictionary] = []
	lines.assign(seen.values())
	lines.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.owner_wanted != b.owner_wanted:
			return b.owner_wanted
		var by_author : int = a.author.naturalnocasecmp_to(b.author)
		return by_author < 0 if by_author != 0 else a.work.naturalnocasecmp_to(b.work) < 0)
	return lines


## The name a file is shown under: no extension, no texture-set "_*", words apart, first letter up
## (a_starry_night.ogg -> "A starry night").
static func work_name(asset: String) -> String:
	var work : String = asset.trim_suffix("_*") if asset.ends_with("_*") else asset.get_basename()
	work = work.replace("_", " ").replace("-", " ").strip_edges()
	return work.left(1).to_upper() + work.substr(1)


## The author right-aligned against the middle, the work left-aligned from it — a film's credits —
## lit on hover and on focus like any settings line. A lost author reads "owner wanted"; a [param playable]
## line whose track is in the project gets a play button before the work, and "accept" on it plays too.
func _line(factory: SettingsRowFactory, line: Dictionary, playable: bool) -> SettingsRow:
	var owner_wanted : bool = line.owner_wanted
	var hbox : HBoxContainer = factory.row("%%MENU_CREDITS_OWNER_WANTED" if owner_wanted else line.author)
	hbox.add_theme_constant_override("separation", GAP_PX)
	var caption : Label = hbox.get_child(0)
	# A person's name is shown as written, never looked up as a translation key; "owner wanted" is one.
	if not owner_wanted:
		caption.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_half(caption, HORIZONTAL_ALIGNMENT_RIGHT)
	var title := Label.new()
	title.text = line.work
	title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	title.label_settings = _LABEL_SETTINGS
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	_half(title, HORIZONTAL_ALIGNMENT_LEFT)
	var path : String = line.path
	var toggle : PlayToggle = null
	if playable and not path.is_empty() and ResourceLoader.exists(path):
		toggle = PlayToggle.new()
		toggle.pressed.connect(toggle_track.bind(path))
		if not _toggles.has(path):
			_toggles[path] = []
		(_toggles[path] as Array).append(toggle)
		var work := HBoxContainer.new()
		work.add_theme_constant_override("separation", TOGGLE_GAP_PX)
		work.mouse_filter = Control.MOUSE_FILTER_PASS
		work.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		work.add_child(toggle)
		work.add_child(title)
		hbox.add_child(work)
	else:
		hbox.add_child(title)
	var row := SettingsRow.new()
	row.focus_mode = Control.FOCUS_ALL
	row.add_child(hbox)
	if toggle != null:
		row.gui_input.connect(func(event: InputEvent) -> void:
			if event.is_action_pressed("ui_accept"):
				toggle_track(path)
				row.accept_event())
	return row


## Half of a credit line, cut with an ellipsis rather than widening the column.
func _half(label: Label, align: HorizontalAlignment) -> void:
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.horizontal_alignment = align
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.clip_text = true


func _spacer() -> Control:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, TAIL_PX)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return gap
