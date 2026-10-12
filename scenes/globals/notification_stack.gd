class_name NotificationStack
extends CanvasLayer
## Social notifications as a stack of lines at the top of the screen, each one fading out on its
## own. Clicking a line opens whatever it is about (see PlayerClient._on_notification_clicked).
##
## Why a stack and not [ScreenToast]: that one shows a SINGLE line and replaces the previous
## message. Notifications arrive in bursts — a friend request and a corporation admission in the
## same minute — and replacing means the player never learns about the first. ScreenToast stays as
## it is, because the screenshot and the benchmark DO want one line that supersedes itself.
##
## Why not lower down: [ScreenToast] already sits at layer 128 with its label 24 px from the top, and
## the game has TWO live instances of it (screenshot.gd, benchmark_runner.gd). A third at the same
## offsets would draw its text straight through theirs. This one starts below that band so the two
## never collide.
##
## Above every game layer and it never takes the mouse: [InterfaceHider] hides CanvasLayers as a
## whole, so a photo (F7) takes none of these — same as the rest of the interface.

## How long a line stays fully visible before it fades, in seconds.
@export var hold_seconds: float = 4.0
## How long (s) the fade takes once hold_seconds is up. 0 = it disappears at once.
@export var fade_seconds: float = 0.6
## Most lines on screen at once. Past this the oldest goes immediately rather than growing down the
## screen: a notification is worth reading the moment it lands, not after the three before it.
@export var max_lines: int = 4
## Gap from the top of the screen, below [ScreenToast]'s band (see the header).
@export var top_offset: float = 70.0

var _column: VBoxContainer = null


func _init() -> void:
	layer = 128
	_column = VBoxContainer.new()
	_column.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_column.offset_top = top_offset
	_column.add_theme_constant_override("separation", 6)
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_column)


## Show [param text] for [param hold_seconds], fading out on its own. [param on_click] runs when the
## line is clicked; omit it and the line is not clickable (it stays a plain, inert message).
##
## A new line pushes the stack down rather than replacing what is on it: [method ScreenToast.show_message]
## replaces, and that is the behaviour notifications must NOT have.
func push(text: String, on_click: Callable = Callable()) -> void:
	if text.strip_edges() == "":
		return
	# The column grows downward from a fixed top, so dropping the oldest from the FRONT is what
	# takes it off the screen.
	while _column.get_child_count() >= max_lines:
		_drop_oldest()

	var line := _make_line(text)
	if on_click.is_valid():
		line.set_meta(ACTION_META, on_click)
	_column.add_child(line)

	var tween := create_tween()
	tween.tween_interval(hold_seconds)
	if fade_seconds > 0.0:
		tween.tween_property(line, "modulate:a", 0.0, fade_seconds)
	tween.tween_callback(line.queue_free)
	# The tween dies with the node it animates; killing it first avoids a callback on a freed line
	# when the line is dismissed early by a click.
	line.tree_exiting.connect(tween.kill)


## One line. NOT a Button, and deliberately so: a clickable Control at the top of the screen takes
## the pointer (MOUSE_FILTER_STOP) for as long as it is up, and a notification lives four seconds —
## four seconds during which the player cannot shoot. A Button would trade the whole game for the
## convenience of clicking the toast.
##
## The click is handled by [method _unhandled_input] instead: the keyboard/mouse reaches gameplay
## untouched, and only a deliberate click that lands on a live line is claimed.
func _make_line(text: String) -> Control:
	var line := Label.new()
	line.text = text
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.add_theme_font_size_override("font_size", 18)
	line.add_theme_constant_override("outline_size", 6)
	line.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	line.add_theme_color_override("font_color", Color(1, 1, 1))
	return line


## Called on a click that landed on the topmost live line. Consumes the event when it serves the
## click, so gameplay never also sees it.
func _unhandled_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click == null or not click.pressed:
		return
	# button_index, not is_left_pressed(): InputEventMouseButton has no such method in Godot 4.
	if click.button_index != MOUSE_BUTTON_LEFT:
		return
	var top := _top_actionable_line()
	if top == null:
		return
	# The click must be ON the line, not merely on the same half of the screen: the stack is full
	# width, so without this a click to the left of the text would open the notification.
	var mouse := (top as Control).get_global_rect().has_point(
			get_viewport().get_mouse_position())
	if not mouse:
		return
	var action := _action_of(top)
	if action.is_valid():
		action.call()
		top.queue_free()
		get_viewport().set_input_as_handled()


## Meta key under which a line carries the action its click runs.
const ACTION_META: StringName = &"notification_action"


## The topmost line that actually does something, or null when every line is inert. Only the top
## one answers: overlapping targets would make a click open whichever node happened to be found
## first, which is not the line the player aimed at.
func _top_actionable_line() -> Control:
	for i: int in range(_column.get_child_count() - 1, -1, -1):
		var line := _column.get_child(i) as Control
		if line != null and _action_of(line).is_valid():
			return line
	return null


## The action bound to [param line], or an invalid Callable when it has none. Never `.is_valid()` on
## the raw meta: a line pushed without a click carries no key, get_meta hands back null, and
## casting null to Callable is exactly the "nonexistent function" crash.
func _action_of(line: Node) -> Callable:
	var action: Variant = line.get_meta(ACTION_META, null)
	return action as Callable if action is Callable else Callable()


## How many lines are on screen — the stack depth, for tests and diagnostics.
func line_count() -> int:
	return _column.get_child_count()


func _drop_oldest() -> void:
	var oldest := _column.get_child(0)
	_column.remove_child(oldest)
	oldest.queue_free()