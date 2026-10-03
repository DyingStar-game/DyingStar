class_name CreditsSettingsPage
extends Control
## Credits: who made the game's music, sounds, models and textures — "author   work", one line per work
## and author, nothing more (no Discord id, no licence: the page is for the people).
##
## Read like a film's: the whole page under the bar scrolling up on its own, one of the credited tracks
## playing.
## Scrolling by hand (wheel, arrows, stick) takes over; the column moves on again after a while.
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
const _LABEL_SETTINGS : LabelSettings = preload("res://ui/settings_page/settings_label.tres")

## The list read by _ready. A test points it at a fixture before adding the page.
var credits_path : String = CREDITS_PATH

var _auto : AutoScroll
## The track this page asked MusicDirector for, or null.
var _music : MusicPlaylist = null

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
	_play(music_paths(credits))


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


## One of [param paths], drawn at random, played over everything else while the page is open. Only
## the drawn one is loaded: a whole playlist would read every track from disk.
func _play(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var track : AudioStream = load(paths[randi() % paths.size()]) as AudioStream
	if track == null:
		return
	_music = MusicPlaylist.new()
	_music.tracks = [track]
	_music.shuffle = false  # one track, round and round
	MusicDirector.set_override(_music)


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
			_rows.add_child(_line(factory, line.author, line.work))
	_rows.add_child(_spacer())


## One section's credits as {author, work}, once each, sorted by author then work.
static func lines_of(credits: Array) -> Array[Dictionary]:
	var seen : Dictionary = {}
	for credit: Variant in credits:
		if not credit is Dictionary:
			continue
		var line : Dictionary = {"author": str(credit.get("author", "")),
				"work": work_name(str(credit.get("asset", "")))}
		seen["%s|%s" % [line.author, line.work]] = line
	var lines : Array[Dictionary] = []
	lines.assign(seen.values())
	lines.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
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
## lit on hover and on focus like any settings line.
func _line(factory: SettingsRowFactory, author: String, work: String) -> SettingsRow:
	var line : HBoxContainer = factory.row(author)
	line.add_theme_constant_override("separation", GAP_PX)
	var caption : Label = line.get_child(0)
	# A person's name is shown as written, never looked up as a translation key.
	caption.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_half(caption, HORIZONTAL_ALIGNMENT_RIGHT)
	var title := Label.new()
	title.text = work
	title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	title.label_settings = _LABEL_SETTINGS
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	_half(title, HORIZONTAL_ALIGNMENT_LEFT)
	line.add_child(title)
	var row := SettingsRow.new()
	row.focus_mode = Control.FOCUS_ALL
	row.add_child(line)
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
