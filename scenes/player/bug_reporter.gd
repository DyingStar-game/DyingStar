class_name BugReporter
extends Node
## CLIENT, own player only: the "bug_report" key (F9). It takes the bug-report capture (Screenshot, the
## F8 one: the screen as it is, debug panels shown), then asks for a title and a description
## (BugReportDialog) and sends them with the capture, where the player stands, the build and the end of
## the game's log to service-social, which posts the report in the QA channel on Discord.
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

var _player: Node3D = null
var _notify: Callable
var _input_locked: Callable
var _dialog: BugReportDialog = null
## A report is under way, from the key press to the form closed: one at a time.
var _busy: bool = false
## The capture as it will be sent (base64 JPEG), and where its PNG was saved.
var _capture: String = ""
var _capture_path: String = ""


## [param screens] holds the form; [param notify] shows a line to the player; [param input_locked]
## says when something else owns the keyboard (the key then does nothing).
func setup(player: Node3D, screens: Node, notify: Callable, input_locked: Callable) -> void:
	_player = player
	_notify = notify
	_input_locked = input_locked
	_dialog = BugReportDialog.new()
	_dialog.submitted.connect(_on_submitted)
	_dialog.dismissed.connect(func() -> void: _busy = false)
	screens.add_child(_dialog)


## The form has the keyboard (PlayerClient._modal_open).
func is_open() -> bool:
	return _dialog != null and _dialog.is_open()


func _unhandled_input(event: InputEvent) -> void:
	if _busy or _dialog == null or not InputCombo.pressed(event, &"bug_report"):
		return
	if _input_locked.is_valid() and _input_locked.call():
		return
	start()


## Take the capture, then open the form over it.
func start() -> void:
	_busy = true
	if await Screenshot.take(Screenshot.Kind.DEBUG) == "":
		_busy = false  # a capture was already under way
		return
	var saved: Array = await Screenshot.saved  # once its PNG is written
	_capture_path = str(saved[0])
	var image := saved[1] as Image
	_capture = encode_capture(image)
	var status: Dictionary = await PlayerServices.bug_report_status()
	var relayed: bool = bool(status.get("ok", false)) and status.get("data") is Dictionary \
			and bool((status["data"] as Dictionary).get("enabled", false))
	var off_text: String = "" if relayed else tr("%%BUG_REPORT_OFF") % _capture_path.get_base_dir()
	_dialog.open_with(preview_of(image), off_text)


func _on_submitted(title: String, description: String, with_log: bool) -> void:
	_dialog.set_sending(true)
	var result: Dictionary = await PlayerServices.bug_report_create(title, description, context_of(_player),
			_capture, log_tail() if with_log else "")
	if bool(result.get("ok", false)):
		_dialog.close()
		_busy = false
		if _notify.is_valid():
			_notify.call(tr("%%BUG_REPORT_SENT"))
		return
	_dialog.set_sending(false)
	_dialog.show_status(tr("%%BUG_REPORT_FAILED") % [HttpClient.describe_error(result), _capture_path.get_base_dir()])


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


## What the report says of where and on what it happened: the build, the machine, and the body's place.
## The capture carries the rest (the debug panels are on it). Values are short texts or numbers, as the
## service takes them.
static func context_of(body: Node3D) -> Dictionary:
	var out: Dictionary = {
		"version": BuildInfo.version_text(),
		"os": "%s %s" % [OS.get_name(), OS.get_version()],
		"gpu": RenderingServer.get_video_adapter_name(),
		"fps": roundi(Engine.get_frames_per_second()),
		"language": TranslationServer.get_locale(),
	}
	if is_instance_valid(body):
		var planet: Planet = Planet.of(body)
		if planet != null:
			out["body"] = str(planet.name)
		var parent: Node = body.get_parent()
		if parent != null:
			out["frame"] = str(parent.name)
		out["position"] = "%.1f, %.1f, %.1f" % [body.position.x, body.position.y, body.position.z]
	return out


## The end of the game's log ([param max_bytes] of it), with no token in it (scrub). "" when the log
## cannot be read.
static func log_tail(path: String = "", max_bytes: int = LOG_TAIL_BYTES) -> String:
	if path == "":
		path = str(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log"))
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
