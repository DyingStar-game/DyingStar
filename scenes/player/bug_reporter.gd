class_name BugReporter
extends Node
## CLIENT: the "bug_report" key (F9), wherever the player is -- in the world, in the pause menu, the
## settings, the DataPad, the main menu: a bug is reported from where it shows. A child of the Screenshot
## autoload, with the other capture keys. It takes the bug-report capture (Screenshot, the F8 one: the
## screen as it is, debug panels shown), then asks for the report on the QA team's template
## (BugReportDialog: title, severity, description, steps, actual and expected result) and sends it with
## the captures, the build, the machine, where the player stood when there is one, and the end of the
## game's log to service-social, which posts the report in the QA channel on Discord.
##
## A report can be put aside (Stage): to be finished later -- the key then brings the form back as it
## was -- or for one more capture, taken by the same key wherever the player went to show it. What was
## typed stays in the form; the captures and the place of the first one stay here. Kept for the
## session only: nothing is written to disk but the captures' own PNGs.
##
## The game never talks to Discord itself: posting there takes a webhook URL, a secret this open-source
## client cannot hold. Where the service relays none (local dev, a server without the webhook) the form
## says so, and the capture stays in the screenshots folder to be posted by hand.

## Bytes of the log's end sent with a report: enough for what led to the bug, under the service's limit.
const LOG_TAIL_BYTES := 256 * 1024
## The capture is sent as a JPEG no wider than this: a 4K PNG is 10 MB, this is a few hundred kB.
const CAPTURE_MAX_WIDTH := 1920
const JPEG_QUALITY := 0.8
## Width of the capture shown in the form.
const PREVIEW_WIDTH := 480
## The reminder of the key, in the bottom right corner: how often (s) it is written again, its layer
## (over the loading screen, where a game that hangs is reported from; under the toasts), its size
## (px), how see-through it is (0..1) and how far (px) from the right and the bottom edges -- under the
## main menu's own corner (the quality button, the shader warm-up line).
const HINT_REFRESH_S := 0.5
const HINT_LAYER := 110
const HINT_FONT_PX := 12
const HINT_ALPHA := 0.7
const HINT_MARGIN_PX := Vector2(16.0, 2.0)
## The most characters a value of the report's context may hold (service-social's createBugReportBody).
const CONTEXT_VALUE_MAX := 200
## The reminder's look while a report waits for its next capture: plain, so it is not missed.
const HINT_WAITING_ALPHA := 1.0
## Where a report stands. IDLE: none. CAPTURING: the key was pressed, the capture is being taken.
## FORM: the form is up. AWAITING_CAPTURE: put aside for one more capture, the key takes it.
## POSTPONED: put aside to be finished later, the key brings the form back.
enum Stage { IDLE, CAPTURING, FORM, AWAITING_CAPTURE, POSTPONED }
## What the reminder says after the key, by where the report stands (IDLE and the rest: report a bug).
const HINT_WORDS: Dictionary = {
	Stage.AWAITING_CAPTURE: "%%BUG_REPORT_ADD_CAPTURE_HINT",
	Stage.POSTPONED: "%%BUG_REPORT_RESUME",
}
## What a report says of where the player stood, in the order it is listed (locate).
const PLACE_KEYS: Array[String] = ["world", "planet", "frame"]
## The kind of graphics card, as the report names it: a game drawn by the integrated one is a slow game.
const GPU_KINDS: Dictionary = {
	RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU: "integrated",
	RenderingDevice.DEVICE_TYPE_DISCRETE_GPU: "dedicated",
	RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU: "virtual",
	RenderingDevice.DEVICE_TYPE_CPU: "software",
}
## The window's mode, as the report names it.
const WINDOW_MODES: Dictionary = {
	DisplayServer.WINDOW_MODE_WINDOWED: "windowed",
	DisplayServer.WINDOW_MODE_MINIMIZED: "minimized",
	DisplayServer.WINDOW_MODE_MAXIMIZED: "maximized",
	DisplayServer.WINDOW_MODE_FULLSCREEN: "fullscreen",
	DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN: "exclusive fullscreen",
}

## Says where the local player stands: {"world", "planet", "frame"}, short texts, any of them missing
## (DevReadouts.coordinates). PlayerClient sets it; invalid in the menus and once the world is gone.
## A Callable and not the body: reading a planet here would name Planet, and this node is built by
## an autoload, which must not load the gameplay scripts (test_boot_light_autoloads).
var locate: Callable = Callable()
var _notify: Callable
var _dialog: BugReportDialog = null
## The reminder of the key in the corner of the screen (_refresh_hint).
var _hint: Label = null
var _stage: Stage = Stage.IDLE
## The captures of the report under way, in the order they were taken: {"jpeg": as it will be sent
## (base64), "small": the picture the form shows, "path": where its PNG was saved}.
var _captures: Array[Dictionary] = []
## Where the player stood at the first capture (locate): where the bug showed.
var _place: Dictionary = {}
## Why the report cannot be sent from here, "" when it can: asked once a report, at its first capture.
var _off_text: String = ""
## The bugs already posted that are not closed ({id, title, status}), for the form to offer adding
## to one: asked once a report too, and empty where the service cannot list them.
var _known_bugs: Array = []


## [param notify] shows a line to the player (the report left).
func setup(notify: Callable) -> void:
	_notify = notify


## The reminder is looked after from the start, a few times a second: nothing tells of a key bound
## again or of a language changed, and a line of text is cheap to write twice.
func _ready() -> void:
	var clock := Timer.new()
	clock.wait_time = HINT_REFRESH_S
	clock.timeout.connect(_refresh_hint)
	add_child(clock)
	clock.start()


## The line in the corner of the screen, wherever the player is: "[F9] Report a bug", with the key as
## it is bound now. Gone while the form is up (it has done its job), with a key unbound, and on a
## server, which has no screen -- known only once the game has chosen its role, hence made here and
## not at the start. A CanvasLayer: the F7 photo hides it with the rest of the interface.
func _refresh_hint() -> void:
	if GameOrchestrator.is_server():
		return
	if _hint == null:
		var layer := CanvasLayer.new()
		layer.layer = HINT_LAYER
		add_child(layer)
		_hint = Label.new()
		_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hint.add_theme_font_size_override("font_size", HINT_FONT_PX)
		_hint.add_theme_constant_override("outline_size", 4)
		_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		_hint.modulate = Color(1.0, 1.0, 1.0, HINT_ALPHA)
		layer.add_child(_hint)
		_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
		_hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
		_hint.offset_right = -HINT_MARGIN_PX.x
		_hint.offset_bottom = -HINT_MARGIN_PX.y
	_hint.text = hint_text(InputLabel.for_action(&"bug_report"), tr(HINT_WORDS.get(_stage, "%%BUG_REPORT_TITLE")))
	_hint.modulate.a = HINT_WAITING_ALPHA if _stage == Stage.AWAITING_CAPTURE else HINT_ALPHA
	_hint.visible = _hint.text != "" and not is_open()


## The reminder's line: the key in brackets, as the game's prompts write it, then what it does. ""
## with no [param key]: nothing to press, nothing to say. Static and pure.
static func hint_text(key: String, what: String) -> String:
	return "" if key == "" else "[%s] %s" % [key, what]


## The form has the keyboard and the mouse: the game under it stands still (PlayerClient._modal_open),
## and the DataPad no longer takes the clicks (WristDatapad).
func is_open() -> bool:
	return _dialog != null and _dialog.is_open()


## No lock: the key answers under a menu, the DataPad or the chart as it does in the world -- that is
## where half the bugs are. A key being bound in Settings > Controls never comes this far (handled there).
func _unhandled_input(event: InputEvent) -> void:
	if GameOrchestrator.is_server() or not InputCombo.pressed(event, &"bug_report"):
		return
	press()


## The key, by where the report stands: a new report, one more capture for the one put aside, or the
## form back on the one to finish. Nothing while a capture is being taken or the form is up.
func press() -> void:
	match _stage:
		Stage.IDLE, Stage.AWAITING_CAPTURE:
			start()
		Stage.POSTPONED:
			_show_form(false)


## The form, made at the first report. Under the tree's root and not under whoever is on screen: it
## outlives the menu or the world it was opened over.
func _form() -> BugReportDialog:
	if _dialog == null:
		_dialog = BugReportDialog.new()
		_dialog.submitted.connect(_on_submitted)
		_dialog.dismissed.connect(_forget)
		_dialog.postponed.connect(func() -> void: _stage = Stage.POSTPONED)
		_dialog.capture_asked.connect(func() -> void: _stage = Stage.AWAITING_CAPTURE)
		_dialog.capture_removed.connect(_on_capture_removed)
		get_tree().root.add_child(_dialog)
	return _dialog


## Take a capture, then open the form over it: a new report's first one, or one more for the report
## put aside, whose form comes back as it was typed.
func start() -> void:
	var first: bool = _stage == Stage.IDLE
	var back_to: Stage = _stage
	_stage = Stage.CAPTURING
	if await Screenshot.take(Screenshot.Kind.DEBUG) == "":
		_stage = back_to  # a capture was already under way
		return
	var saved: Array = await Screenshot.saved  # once its PNG is written
	var image := saved[1] as Image
	if first:
		_captures.clear()
		_place = locate.call() if locate.is_valid() else {}
	_captures.append({"jpeg": encode_capture(image), "small": preview_of(image), "path": str(saved[0])})
	if first:
		var status: Dictionary = await PlayerServices.bug_report_status()
		var relayed: bool = bool(status.get("ok", false)) and status.get("data") is Dictionary \
				and bool((status["data"] as Dictionary).get("enabled", false))
		_off_text = "" if relayed else tr("%%BUG_REPORT_OFF") % _captures_dir()
		_known_bugs = []
		if relayed:
			_load_known_bugs()  # not waited for: the form opens now, the list joins it when it comes
	_show_form(first)


## The form, on the report under way. [param fresh]: a new report, on empty fields.
func _show_form(fresh: bool) -> void:
	_stage = Stage.FORM
	_form().open_with(_small_captures(), _off_text, ProjectSettings.globalize_path(log_path()), _place, fresh)
	_dialog.set_known_bugs(_known_bugs)


## Ask service-social for the open bugs and hand them to the form, if the report is still there.
func _load_known_bugs() -> void:
	var bugs: Array = known_bugs_of(await PlayerServices.bug_report_open())
	if _stage == Stage.IDLE:
		return
	_known_bugs = bugs
	if _dialog != null:
		_dialog.set_known_bugs(_known_bugs)


## The bugs of [param answer] (PlayerServices.bug_report_open) a report can be added to: those with
## an id and a title. None when the service did not answer or lists none. Static and pure.
static func known_bugs_of(answer: Dictionary) -> Array:
	var data: Variant = answer.get("data")
	if not bool(answer.get("ok", false)) or not data is Dictionary or not (data as Dictionary).get("bugs") is Array:
		return []
	return ((data as Dictionary)["bugs"] as Array).filter(func(bug: Variant) -> bool:
		return bug is Dictionary and str((bug as Dictionary).get("id", "")) != "" \
				and str((bug as Dictionary).get("title", "")) != "")


func _small_captures() -> Array:
	return _captures.map(func(capture: Dictionary) -> Texture2D: return capture["small"])


## The folder the captures' PNGs are in, to tell the player where to find them.
func _captures_dir() -> String:
	return "" if _captures.is_empty() else str(_captures[0]["path"]).get_base_dir()


## The report is over, sent or dropped: nothing of it is kept.
func _forget() -> void:
	_stage = Stage.IDLE
	_captures.clear()
	_place = {}
	_off_text = ""
	_known_bugs = []


## A capture taken off the report in the form. Its PNG stays in the screenshots folder.
func _on_capture_removed(index: int) -> void:
	if index >= 0 and index < _captures.size():
		_captures.remove_at(index)
		_dialog.show_captures(_small_captures())


## [param report]: the form's texts, on the QA template ({title, description, steps, actual, expected}).
func _on_submitted(report: Dictionary, with_log: bool) -> void:
	_dialog.set_sending(true)
	var pictures: Array = _captures.map(func(capture: Dictionary) -> String: return capture["jpeg"])
	var folder: String = _captures_dir()
	var result: Dictionary = await PlayerServices.bug_report_create(report, context_of(_place), pictures,
			log_tail() if with_log else "")
	if bool(result.get("ok", false)):
		_dialog.close()
		_forget()
		if _notify.is_valid():
			_notify.call(tr("%%BUG_REPORT_SENT"))
		return
	_dialog.set_sending(false)
	_dialog.show_status(tr("%%BUG_REPORT_FAILED") % [HttpClient.describe_error(result), folder])


## [param image] as the report carries it: a JPEG no wider than CAPTURE_MAX_WIDTH, in base64. "" for none.
static func encode_capture(image: Image) -> String:
	if image == null or image.is_empty():
		return ""
	var sent: Image = _no_wider_than(image, CAPTURE_MAX_WIDTH)
	return Marshalls.raw_to_base64(sent.save_jpg_to_buffer(JPEG_QUALITY))


## The small picture of [param image] the form shows, null for none.
static func preview_of(image: Image) -> Texture2D:
	if image == null or image.is_empty():
		return null
	return ImageTexture.create_from_image(_no_wider_than(image, PREVIEW_WIDTH))


## A copy of [param image] scaled down to [param width] at most, its shape kept; the image is left as it is.
static func _no_wider_than(image: Image, width: int) -> Image:
	var copy: Image = image.duplicate()
	if copy.get_width() > width:
		copy.resize(width, maxi(1, roundi(float(copy.get_height()) * width / copy.get_width())),
				Image.INTERPOLATE_BILINEAR)
	return copy


## What the report says of where and on what it happened: the build, the machine (machine_of), and
## [param place], where the player stood ({"world", "planet", "frame"}, see locate). The captures carry
## the rest (the debug panels are on them). Values are short texts or numbers, as the service takes
## them (20 keys at most, 200 characters each).
static func context_of(place: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"version": BuildInfo.version_text(),
		"build": build_of(),
		"fps": roundi(Engine.get_frames_per_second()),
		"language": TranslationServer.get_locale(),
	}
	out.merge(machine_of())
	for key: String in PLACE_KEYS:
		if str(place.get(key, "")) != "":
			out[key] = str(place[key]).left(CONTEXT_VALUE_MAX)
	return out


## Which game this is: the export's build id, or -- run from its sources, where nothing was exported --
## the branch and the commit they stand at ("sources develop@1a2b3c4"), read from the project's .git.
## [param project_dir]: the project's folder (the running one's by default).
static func build_of(project_dir: String = "") -> String:
	if BuildInfo.build_id() != "" and project_dir == "":
		return BuildInfo.build_id()
	if project_dir == "":
		project_dir = ProjectSettings.globalize_path("res://")
	var git: String = project_dir.path_join(".git")
	if not FileAccess.file_exists(git.path_join("HEAD")):
		return "sources"
	var head: String = FileAccess.get_file_as_string(git.path_join("HEAD")).strip_edges()
	if not head.begins_with("ref: "):
		return "sources @%s" % head.left(7)  # a commit checked out by itself
	var ref: String = head.trim_prefix("ref: ")
	var branch: String = ref.trim_prefix("refs/heads/")
	if not FileAccess.file_exists(git.path_join(ref)):
		return "sources %s" % branch  # the branch's commit is in the packed refs: the name is enough
	var commit: String = FileAccess.get_file_as_string(git.path_join(ref)).strip_edges().left(7)
	return ("sources %s@%s" % [branch, commit]).left(CONTEXT_VALUE_MAX)


## The player's machine, as QA needs it to tell a bug from a setup: system, processor, memory, graphics
## card and its driver, what draws the game and on which screen. One line a subject, so a report stays
## readable in Discord. No name, no path, no serial number: nothing that says whose machine it is.
static func machine_of() -> Dictionary:
	var memory: Dictionary = OS.get_memory_info()
	var driver: PackedStringArray = OS.get_video_adapter_driver_info()  # [name, version], may be empty
	var screen: Vector2i = DisplayServer.screen_get_size()
	var window: Vector2i = DisplayServer.window_get_size()
	var out: Dictionary = {
		"os": "%s %s (%s)" % [OS.get_distribution_name(), OS.get_version(), Engine.get_architecture_name()],
		"cpu": "%s, %d threads" % [OS.get_processor_name(), OS.get_processor_count()],
		"ram": ram_text(memory, OS.get_static_memory_usage()),
		"gpu": "%s (%s, %s)" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_vendor(),
				GPU_KINDS.get(RenderingServer.get_video_adapter_type(), "other")],
		"gpu_driver": " ".join(driver) if not driver.is_empty() else "unknown",
		"vram": "%s used" % size_text(int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED))),
		"renderer": "%s %s, %s" % [RenderingServer.get_current_rendering_driver_name(),
				RenderingServer.get_video_adapter_api_version(), RenderingServer.get_current_rendering_method()],
		"display": "%dx%d at %d Hz, window %dx%d (%s)" % [screen.x, screen.y,
				roundi(DisplayServer.screen_get_refresh_rate()), window.x, window.y,
				WINDOW_MODES.get(DisplayServer.window_get_mode(), "windowed")],
		"engine": str(Engine.get_version_info().get("string", "")),
	}
	for key: String in out:
		out[key] = str(out[key]).left(CONTEXT_VALUE_MAX)
	return out


## The memory line of a report, from [param memory] (OS.get_memory_info) and what the game holds
## ([param game_bytes]): "31.2 GB, 6.8 GB free, 1.6 GB used by the game". Its "free" and not its
## "available", which counts the page file with it: a 32 GB machine read "61 GB free". Static and pure.
static func ram_text(memory: Dictionary, game_bytes: int) -> String:
	return "%s, %s free, %s used by the game" % [size_text(int(memory.get("physical", 0))),
			size_text(int(memory.get("free", 0))), size_text(game_bytes)]


## [param bytes] as a size a person reads: "31.9 GB", "512 MB". "unknown" for what the system did not say
## (0 or less: OS.get_memory_info gives -1 for a value it cannot read).
static func size_text(bytes: int) -> String:
	if bytes <= 0:
		return "unknown"
	var gigabytes: float = bytes / 1073741824.0
	if gigabytes >= 1.0:
		return "%.1f GB" % gigabytes
	return "%d MB" % roundi(bytes / 1048576.0)


## Where the game writes its log: user://logs/godot.log unless the project says otherwise (on Windows,
## %APPDATA%\Godot\app_userdata\DyingStar\logs\godot.log). The sessions before this one are kept beside
## it, dated: after a crash, the one to send is the newest of those.
static func log_path() -> String:
	return str(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log"))


## The end of the game's log ([param max_bytes] of it), with no token in it (scrub). "" when the log
## cannot be read.
static func log_tail(path: String = "", max_bytes: int = LOG_TAIL_BYTES) -> String:
	if path == "":
		path = log_path()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var size: int = file.get_length()
	file.seek(maxi(0, size - max_bytes))
	return scrub(file.get_buffer(mini(size, max_bytes)).get_string_from_utf8())


## [param text] with what must never leave the machine taken out: the player's token, whether it shows
## as a JWT, a "Bearer ..." header or a "--token=" argument.
static func scrub(text: String) -> String:
	var jwt := RegEx.create_from_string("eyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}")
	var named := RegEx.create_from_string("(?i)(--token=|bearer\\s+)\\S+")
	return named.sub(jwt.sub(text, "<token>", true), "$1<token>", true)
