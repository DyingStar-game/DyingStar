class_name PhotoDialog
extends Control

## The creator's "From photos": the player gives a front photo of their face, and one or two from the side, from
## files or the webcam; each is checked as soon as it is given (FacePhotoCheck: what to fix, in words) and its
## detected points drawn over its thumbnail, then FaceFromPhoto makes the look over the body already chosen
## (gender, age, height from the Body tab). The webcam opens a large live view, mirrored, with an oval to put the
## face in that turns green when the frame passes the checks (run on a worker a few times a second), and the head's
## turn; the photo is taken after a countdown, so a side one is posed, not clicked. The photos stay in memory, read
## once: nothing of them is kept or sent.
##
## Godot lists the cameras on a thread once CameraServer monitors them (camera_feeds_updated, about a second later),
## and a Linux feed needs a format before it starts. Godot 4.7 has no camera on Windows (its CameraWindows is a
## stub): the webcam buttons stay hidden there.

## The look made, for the creator to show (undoable like any other change).
signal made(look: CharacterAppearance)

const SLOTS: Array[String] = ["%%PHOTO_SLOT_FRONT", "%%PHOTO_SLOT_SIDE", "%%PHOTO_SLOT_OTHER_SIDE", "%%PHOTO_SLOT_PROFILE"]
## The slot of the true profile (the nose's bridge), apart from the photos the face is made from.
const PROFILE_SLOT: int = 3
## A photo's longest side once loaded (px): enough for MediaPipe's landmarks, quick to measure.
const MAX_SIDE: int = 1280
const PREVIEW_PX: Vector2 = Vector2(180.0, 180.0)
const PANEL_WIDTH_PX: float = 860.0
const LIVE_PX: Vector2 = Vector2(640.0, 480.0)  # webcams are mostly 4:3
## The webcam format sought: the most pixels up to this width, at this frame rate at least when the camera has it.
const CAMERA_MAX_WIDTH: int = 1280
const CAMERA_MIN_FPS: float = 15.0
## Seconds between two live checks of the webcam's frame (each about 150 ms on a worker).
const LIVE_CHECK_EVERY: float = 0.4
## Seconds counted down before the webcam photo is taken.
const COUNTDOWN: float = 3.0
## The face oval's height in the live view, as a share of the view's.
const GUIDE_HEIGHT: float = 0.62
const GOOD_COLOUR: Color = Color(0.35, 0.9, 0.45)
const BAD_COLOUR: Color = Color(1.0, 0.65, 0.25)
## The points drawn over a thumbnail: the face's outline (MediaPipe's FACE_OVAL, in order), then the irises' centres,
## the nose's tip and the mouth's corners.
const OUTLINE: Array[int] = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152,
		148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109, 10]
const MARKS: Array[int] = [468, 473, 1, 61, 291]
## FaceFit.turn() against the head's yaw (degrees), from our renders: 40 degrees turn 0.57, 75 turn 1.24.
const TURN_DEGREES: Array[Vector2] = [Vector2(0.0, 0.0), Vector2(0.57, 40.0), Vector2(1.24, 75.0), Vector2(1.6, 90.0)]

## The body the look is made over (the creator's current look).
var base: CharacterAppearance

var _photos: Array[Image] = [null, null, null, null]
var _points: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array(), PackedVector3Array(), PackedVector3Array()]
var _profile_outline := PackedVector2Array()  # the profile slot's face edge as PhotoProfile read it
var _previews: Array[TextureRect] = []
var _notes: Array[Label] = []
var _camera_buttons: Array[Button] = []
var _row: HBoxContainer
var _make: Button
var _status: Label
var _file_dialog: FileDialog
var _file_slot: int = 0
# The live webcam view.
var _live: VBoxContainer
var _live_view: TextureRect
var _live_guide: Control
var _live_hint: Label
var _live_state: Label
var _live_count: Label
var _take_button: Button
var _camera_slot: int = -1
var _camera_feed: CameraFeed = null
var _camera_picker: OptionButton
var _feed_id: int = -1  # the camera the player picked (CameraFeed id), -1: the first that starts
var _check_task: int = -1
var _check_clock: float = 0.0
var _live_result: Dictionary = {}  # written by the worker, read once its task is done
var _live_good: bool = false
var _live_found: bool = false
var _countdown: float = -1.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.6)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_WIDTH_PX, 0.0)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.05, 0.05, 0.06, 0.97)
	box.set_corner_radius_all(6)
	box.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", box)
	panel.theme = load("res://ui/settings_page/settings_theme.tres") as Theme
	centre.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)
	column.add_child(_label("%%PHOTO_TITLE", 22))
	column.add_child(_label("%%PHOTO_HOW", 15, true))
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 16)
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(_row)
	for i in SLOTS.size():
		_row.add_child(_slot(i))
	_live = _live_panel()
	_live.visible = false
	column.add_child(_live)
	column.add_child(_label("%%PHOTO_PRIVACY", 13, true))
	_status = _label("", 15, true)
	column.add_child(_status)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(actions)
	var cancel := _button("%%PHOTO_CANCEL", queue_free)
	actions.add_child(cancel)
	_make = _button("%%PHOTO_MAKE", _on_make)
	_make.add_theme_color_override("font_color", SettingsStyle.ACTIVE_COLOR)
	_make.disabled = true
	actions.add_child(_make)
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	_file_dialog.file_selected.connect(_on_file)
	add_child(_file_dialog)
	if not FaceFromPhoto.available():
		_status.text = "%%PHOTO_UNAVAILABLE"
	else:
		_status.text = "%%PHOTO_BODY_NOTE"
	# The cameras come a moment later, listed on CameraServer's thread (and as they are plugged in).
	CameraServer.camera_feeds_updated.connect(_on_feeds_updated)
	CameraServer.monitoring_feeds = true
	_on_feeds_updated()


func _exit_tree() -> void:
	_stop_camera()
	if CameraServer.camera_feeds_updated.is_connected(_on_feeds_updated):
		CameraServer.camera_feeds_updated.disconnect(_on_feeds_updated)
	# The monitoring stays on: stopping it joins CameraServer's thread, which sleeps a second between two scans.


# --- slots -------------------------------------------------------------------------------------------------------

func _slot(i: int) -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(PREVIEW_PX.x, 0.0)
	column.add_child(_label(SLOTS[i], 16))
	var frame := PanelContainer.new()
	var frame_box := StyleBoxFlat.new()
	frame_box.bg_color = Color(0.12, 0.12, 0.14)
	frame_box.set_corner_radius_all(4)
	frame.add_theme_stylebox_override("panel", frame_box)
	frame.custom_minimum_size = PREVIEW_PX
	column.add_child(frame)
	var preview := TextureRect.new()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = PREVIEW_PX
	frame.add_child(preview)
	var points := Control.new()
	points.mouse_filter = Control.MOUSE_FILTER_IGNORE
	points.draw.connect(_draw_points.bind(i, points))
	frame.add_child(points)
	preview.set_meta(&"points", points)
	_previews.append(preview)
	column.add_child(_button("%%PHOTO_CHOOSE_FILE", _choose_file.bind(i)))
	var camera := _button("%%PHOTO_WEBCAM", _open_camera.bind(i))
	camera.visible = false
	column.add_child(camera)
	_camera_buttons.append(camera)
	var note := _label("", 13, true)
	_notes.append(note)
	column.add_child(note)
	return column


func _choose_file(i: int) -> void:
	_close_camera()
	_file_slot = i
	_file_dialog.popup_centered_ratio(0.7)


func _on_file(path: String) -> void:
	var image := Image.new()
	if image.load(path) != OK:
		_notes[_file_slot].text = "%%PHOTO_CHECK_NO_FACE"
		return
	_take(_file_slot, image)


## A photo in slot [param i]: shrunk, shown, checked at once, its detected points drawn over it.
func _take(i: int, image: Image) -> void:
	image.convert(Image.FORMAT_RGB8)
	var longest: int = maxi(image.get_width(), image.get_height())
	if longest > MAX_SIDE:
		var scale: float = float(MAX_SIDE) / longest
		image.resize(int(image.get_width() * scale), int(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	_photos[i] = image
	_previews[i].texture = ImageTexture.create_from_image(image)
	var read: Dictionary = FaceFromPhoto.read(image, _role(i)) if FaceFromPhoto.available() else {"problems": []}
	var detection: Dictionary = read.get("detection", {})
	_points[i] = detection["points"] if detection.get("found", false) else PackedVector3Array()
	if i == PROFILE_SLOT:
		_profile_outline = read.get("profile", {}).get("points", PackedVector2Array())
	(_previews[i].get_meta(&"points") as Control).queue_redraw()
	_notes[i].text = _problems_text(read["problems"])
	_make.disabled = not FaceFromPhoto.available() or _photos[0] == null


## What slot [param i]'s photo is for.
static func _role(i: int) -> FacePhotoCheck.Role:
	if i == 0:
		return FacePhotoCheck.Role.FRONT
	return FacePhotoCheck.Role.PROFILE if i == PROFILE_SLOT else FacePhotoCheck.Role.SIDE


## The face found on slot [param i]'s thumbnail (drawn on [param over], the preview's size): its outline, eyes,
## nose and mouth; on the profile, the face's edge read for the bridge (the landmarks are loose there).
func _draw_points(i: int, over: Control) -> void:
	if _photos[i] == null or _points[i].is_empty():
		return
	var size: Vector2 = Vector2(_photos[i].get_size())
	var scale: float = minf(over.size.x / size.x, over.size.y / size.y)
	var offset: Vector2 = 0.5 * (over.size - size * scale)
	if i == PROFILE_SLOT:
		if _profile_outline.size() > 1:
			var edge := PackedVector2Array()
			for p in _profile_outline:
				edge.append(offset + p * scale)
			over.draw_polyline(edge, Color(GOOD_COLOUR, 0.85), 1.5, true)
		return
	var at := func(k: int) -> Vector2: return offset + Vector2(_points[i][k].x, _points[i][k].y) * scale
	var outline := PackedVector2Array()
	for k in OUTLINE:
		outline.append(at.call(k))
	over.draw_polyline(outline, Color(GOOD_COLOUR, 0.85), 1.5, true)
	for k in MARKS:
		over.draw_circle(at.call(k), 1.8, Color(GOOD_COLOUR, 0.85))


func _problems_text(problems: Array) -> String:
	if problems.is_empty():
		return tr("%%PHOTO_OK")
	var lines: PackedStringArray = []
	for problem: int in problems:
		lines.append(tr(FacePhotoCheck.TEXT[problem]))
	return "\n".join(lines)


# --- webcam ------------------------------------------------------------------------------------------------------

func _on_feeds_updated() -> void:
	var any: bool = CameraServer.get_feed_count() > 0 and FaceFromPhoto.available()
	for button in _camera_buttons:
		button.visible = any


func _live_panel() -> VBoxContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	var frame := PanelContainer.new()
	var frame_box := StyleBoxFlat.new()
	frame_box.bg_color = Color(0.0, 0.0, 0.0)
	frame.add_theme_stylebox_override("panel", frame_box)
	frame.custom_minimum_size = LIVE_PX
	column.add_child(frame)
	_live_view = TextureRect.new()
	_live_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_live_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_live_view.flip_h = true  # a mirror: the player moves as they see
	_live_view.custom_minimum_size = LIVE_PX
	frame.add_child(_live_view)
	_live_guide = Control.new()
	_live_guide.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_live_guide.draw.connect(_draw_guide)
	frame.add_child(_live_guide)
	_live_count = _label("", 96)
	_live_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_live_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_live_count.add_theme_constant_override("outline_size", 12)
	_live_count.add_theme_color_override("font_outline_color", Color.BLACK)
	frame.add_child(_live_count)
	_live_hint = _label("", 15, true)
	column.add_child(_live_hint)
	_live_state = _label("", 14, true)
	column.add_child(_live_state)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 16)
	column.add_child(actions)
	actions.add_child(_button("%%PHOTO_BACK", _close_camera))
	_camera_picker = OptionButton.new()
	_camera_picker.add_theme_font_override("font", SettingsRowFactory.FONT)
	_camera_picker.item_selected.connect(_on_camera_picked)
	actions.add_child(_camera_picker)
	_take_button = _button("%%PHOTO_CAPTURE", _start_countdown)
	_take_button.add_theme_color_override("font_color", SettingsStyle.ACTIVE_COLOR)
	actions.add_child(_take_button)
	return column


## The webcam, live, for slot [param i]: the camera picked if it starts, else the first that does (a camera
## another program holds -- OBS, a browser, a call -- will not start).
func _open_camera(i: int) -> void:
	_close_camera()
	var feeds: Array[CameraFeed] = []
	for k in CameraServer.get_feed_count():
		var feed: CameraFeed = CameraServer.get_feed(k)
		if feed.get_id() == _feed_id:
			feeds.push_front(feed)
		else:
			feeds.append(feed)
	for feed in feeds:
		if _start_feed(feed):
			_camera_feed = feed
			break
	if _camera_feed == null:
		_notes[i].text = "%%PHOTO_WEBCAM_BUSY"
		return
	var picked_busy: bool = _feed_id >= 0 and _camera_feed.get_id() != _feed_id
	_feed_id = _camera_feed.get_id()
	_camera_slot = i
	_fill_camera_picker()
	var live := CameraTexture.new()
	live.camera_feed_id = _camera_feed.get_id()
	_live_view.texture = live
	_live_hint.text = ["%%PHOTO_LIVE_FRONT", "%%PHOTO_LIVE_SIDE", "%%PHOTO_LIVE_SIDE", "%%PHOTO_LIVE_PROFILE"][i]
	_live_state.text = "%%PHOTO_WEBCAM_BUSY" if picked_busy else ""
	_live_count.text = ""
	_live_good = false
	_live_found = false
	_live_result = {}
	_check_clock = LIVE_CHECK_EVERY
	_countdown = -1.0
	_take_button.disabled = false
	_row.visible = false
	_live.visible = true
	_live_guide.queue_redraw()


func _start_feed(feed: CameraFeed) -> bool:
	if feed.feed_is_active:
		return true
	var format: int = _choose_format(feed)
	if format >= 0 and not feed.set_format(format, {}):
		return false
	feed.feed_is_active = true
	return feed.feed_is_active


## The cameras to pick from, shown when there are several (a webcam and OBS' virtual camera, say).
func _fill_camera_picker() -> void:
	_camera_picker.clear()
	for k in CameraServer.get_feed_count():
		var feed: CameraFeed = CameraServer.get_feed(k)
		_camera_picker.add_item("%d. %s" % [k + 1, feed.get_name()], feed.get_id())
		if feed.get_id() == _feed_id:
			_camera_picker.select(k)
	_camera_picker.visible = _camera_picker.item_count > 1


func _on_camera_picked(index: int) -> void:
	_feed_id = _camera_picker.get_item_id(index)
	_open_camera(_camera_slot)


## The feed's format with the most pixels up to CAMERA_MAX_WIDTH, among those at CAMERA_MIN_FPS when there are
## any (-1 when it lists none).
static func _choose_format(feed: CameraFeed) -> int:
	var best := -1
	var best_score := -1.0
	var formats: Array = feed.get_formats()
	for k in formats.size():
		var f: Dictionary = formats[k]
		var width: int = int(f.get("width", 0))
		var height: int = int(f.get("height", 0))
		var numerator: float = float(f.get("frame_numerator", 0))
		var fps: float = float(f.get("frame_denominator", 0)) / numerator if numerator > 0.0 else CAMERA_MIN_FPS
		if width > CAMERA_MAX_WIDTH or width <= 0:
			continue
		var score: float = float(width * height) * (1.0 if fps >= CAMERA_MIN_FPS else 0.001) + minf(fps, 60.0)
		if score > best_score:
			best_score = score
			best = k
	return best


func _close_camera() -> void:
	_stop_camera()
	if _live != null:
		_live.visible = false
		_row.visible = true


func _stop_camera() -> void:
	if _check_task >= 0:
		PerfTasks.wait(_check_task, "photo_dialog")
		_check_task = -1
	if _camera_feed != null:
		_camera_feed.feed_is_active = false
	if _live_view != null:
		_live_view.texture = null
	_camera_feed = null
	_camera_slot = -1
	_countdown = -1.0


func _process(delta: float) -> void:
	if _camera_feed == null:
		return
	if _check_task >= 0 and WorkerThreadPool.is_task_completed(_check_task):
		PerfTasks.wait(_check_task, "photo_dialog")
		_check_task = -1
		_show_live(_live_result)
	if _countdown >= 0.0:
		_countdown -= delta
		_live_count.text = str(ceili(_countdown)) if _countdown > 0.0 else ""
		if _countdown <= 0.0:
			_capture()
		return
	_check_clock -= delta
	if _check_clock <= 0.0 and _check_task < 0:
		_check_clock = LIVE_CHECK_EVERY
		var frame: Image = _frame()
		if frame != null:
			_check_task = PerfTasks.add_task("creator:photo_check", _check_frame.bind(frame, _role(_camera_slot)), false, "photo live check")


## The webcam's current frame (read back from its texture), or null before the first.
func _frame() -> Image:
	var texture: Texture2D = _live_view.texture
	if texture == null:
		return null
	var image: Image = texture.get_image()
	if image == null or image.is_empty():
		return null
	return image


## On a worker: the frame's checks, without the segmentation (a fifth of the cost).
func _check_frame(frame: Image, role: FacePhotoCheck.Role) -> void:
	frame.convert(Image.FORMAT_RGB8)
	var read: Dictionary = FaceFromPhoto.read(frame, role, false)
	var detection: Dictionary = read["detection"]
	_live_result = {
		"problems": read["problems"], "found": detection.get("found", false),
		"turn": float(read["check"].get("turn", 0.0)),
	}


func _show_live(result: Dictionary) -> void:
	if result.is_empty():
		return
	var problems: Array = result["problems"]
	_live_found = bool(result["found"])
	_live_good = problems.is_empty()
	var text: String = _problems_text(problems)
	if _live_found:
		text = tr("%%PHOTO_LIVE_TURN") % roundi(_degrees(absf(float(result["turn"])))) + "\n" + text
	_live_state.text = text
	_live_state.add_theme_color_override("font_color", GOOD_COLOUR if _live_good else BAD_COLOUR)
	_live_guide.queue_redraw()


## The head's yaw (degrees) for a FaceFit.turn() of [param turn].
static func _degrees(turn: float) -> float:
	for k in range(1, TURN_DEGREES.size()):
		if turn <= TURN_DEGREES[k].x:
			var a: Vector2 = TURN_DEGREES[k - 1]
			var b: Vector2 = TURN_DEGREES[k]
			return lerpf(a.y, b.y, (turn - a.x) / (b.x - a.x))
	return TURN_DEGREES[-1].y


## The oval the face goes in, green once the frame passes the checks.
func _draw_guide() -> void:
	var size: Vector2 = _live_guide.size
	var ry: float = 0.5 * GUIDE_HEIGHT * size.y
	var rx: float = 0.74 * ry
	var centre := Vector2(0.5 * size.x, 0.48 * size.y)
	var points := PackedVector2Array()
	for k in 65:
		var a: float = TAU * k / 64.0
		points.append(centre + Vector2(cos(a) * rx, sin(a) * ry))
	var colour: Color = GOOD_COLOUR if _live_good else (BAD_COLOUR if _live_found else Color(1.0, 1.0, 1.0, 0.6))
	_live_guide.draw_polyline(points, colour, 3.0, true)


func _start_countdown() -> void:
	_countdown = COUNTDOWN
	_take_button.disabled = true


func _capture() -> void:
	var slot: int = _camera_slot
	var image: Image = _frame()
	_close_camera()
	if image != null:
		_take(slot, image)


# --- making ------------------------------------------------------------------------------------------------------

func _on_make() -> void:
	_close_camera()
	_make.disabled = true
	_status.text = "%%PHOTO_WORKING"
	await get_tree().process_frame  # the words shown before the work holds the frame
	await get_tree().process_frame
	var photos: Array[Image] = []
	for i in PROFILE_SLOT:
		if _photos[i] != null:
			photos.append(_photos[i])
	var result: Dictionary = FaceFromPhoto.make(base, photos, _photos[PROFILE_SLOT])
	var problems: Array = result["problems"]
	var slot := 0
	for i in PROFILE_SLOT:
		if _photos[i] != null:
			_notes[i].text = _problems_text(problems[slot])
			slot += 1
	if _photos[PROFILE_SLOT] != null:
		_notes[PROFILE_SLOT].text = _problems_text(result["profile_problems"])
	if result["look"] == null:
		_status.text = "%%PHOTO_FAILED"
		_make.disabled = false
		return
	made.emit(result["look"])
	queue_free()


func _label(text_key: String, size: int, wrap: bool = false) -> Label:
	var label := Label.new()
	label.text = text_key
	label.add_theme_font_override("font", SettingsRowFactory.FONT)
	label.add_theme_font_size_override("font_size", size)
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _button(text_key: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text_key
	button.add_theme_font_override("font", SettingsRowFactory.FONT)
	button.pressed.connect(action)
	return button
