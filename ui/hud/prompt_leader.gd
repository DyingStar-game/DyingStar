class_name PromptLeader
extends Control
## The interaction prompt ("[E] Open door"...) in a frame beside the crosshair, and a line drawn to it
## from the thing it is about. The line starts at the object's own point (anchor_of: where it is aimed
## at, the middle of its box), the same whatever part of it the look meets -- taken where the look first
## met it, the start jumped about from one look to the next (playtest 2026-10-23). It stays on the
## object as the head turns, growing or shrinking, while the frame keeps its place beside the crosshair. A prompt about nothing under the
## crosshair (getting up from a bed, a cab door seen from its seat) has its frame and no line.
##
## It only draws: what the prompt says, its colour (white, red for a refusal...) and when it shows stay
## where they are decided (PlayerClient, through the prompt Label). The frame's dark ground keeps the
## text readable over a bright ground, the sky, a lit wall.
##
## Settings > General > Framed prompts (on by default): off, the prompt is the plain text of before,
## where the scene places it, on its shade (PromptShade); the switch shows at once.

## Where the frame's lower-left corner sits from the crosshair, in pixels: up and to the right.
const FRAME_OFFSET_PX := Vector2(70.0, -60.0)
## Room between the text and the frame, in pixels.
const PADDING_PX := Vector2(12.0, 6.0)
## The line's and the frame's width, in pixels.
const LINE_PX := 2.0
## The dot on the object the line starts from, its radius in pixels.
const DOT_PX := 3.0
## Opacity of the frame's dark ground.
const GROUND_ALPHA := 0.6
## Fade speed, in opacity per second: aiming across objects does not make it blink.
## What target_rule answers for a prompt about nothing to point at.
const NO_LINE := &"no_line"
const FADE_RATE := 8.0

var _prompt: Label = null
var _camera: Camera3D = null
var _ray: RayCast3D = null
var _anchor_node: Node3D = null  # what the line starts on
var _anchor_local: Vector3 = Vector3.ZERO  # where on it, in its own frame (anchor_of)
## Whether the prompt is framed (Settings > General): read each frame, so the switch shows at once.
var framed_rule: Callable = func() -> bool: return SettingsManager.is_framed_prompts_enabled()
## What the prompt is about, asked each frame by whoever writes it (PlayerClient): null, what the look
## meets (the ray); a Node3D, that node's own point (where a carried load would be fitted or loaded);
## NO_LINE, nothing to point at (dropping what is carried: the line went to the load in the arms).
var target_rule: Callable = func() -> Variant: return null
var _framed: bool = false  # as shown now
var _frame: StyleBoxFlat = null
var _shade: Control = null  # the plain prompt's dark patch (PromptShade), shown when not framed
var _plain_offsets: Array[float] = []  # where the scene places the plain prompt


func _init() -> void:
	name = "PromptLeader"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modulate.a = 0.0


## Draw [param prompt] in a frame, with a line from what [param ray] (cast from [param camera]) meets;
## not framed, as it is, on [param shade].
func follow(prompt: Label, camera: Camera3D, ray: RayCast3D, shade: Control = null) -> void:
	_prompt = prompt
	_camera = camera
	_ray = ray
	_shade = shade
	_plain_offsets = [prompt.offset_left, prompt.offset_top, prompt.offset_right, prompt.offset_bottom]
	var frame := StyleBoxFlat.new()  # tinted with the prompt's own colour (its modulate)
	frame.bg_color = Color(0.0, 0.0, 0.0, GROUND_ALPHA)
	frame.set_border_width_all(int(LINE_PX))
	frame.border_color = Color.WHITE
	frame.content_margin_left = PADDING_PX.x
	frame.content_margin_right = PADDING_PX.x
	frame.content_margin_top = PADDING_PX.y
	frame.content_margin_bottom = PADDING_PX.y
	_frame = frame
	_set_framed(framed_rule.call())


## Framed (the frame round the text, the line, no shade) or plain (the scene's place, its shade).
func _set_framed(on: bool) -> void:
	_framed = on
	if on:
		_prompt.add_theme_stylebox_override("normal", _frame)
	else:
		_prompt.remove_theme_stylebox_override("normal")
		_prompt.offset_left = _plain_offsets[0]
		_prompt.offset_top = _plain_offsets[1]
		_prompt.offset_right = _plain_offsets[2]
		_prompt.offset_bottom = _plain_offsets[3]
		_anchor_node = null
	if _shade != null:
		_shade.visible = not on


## The frame's place on screen for a text [param text_size] px wide and high (padding included), the
## crosshair at [param centre]: its lower-left corner FRAME_OFFSET_PX from it. Pure, for the tests.
static func frame_rect(centre: Vector2, text_size: Vector2) -> Rect2:
	var bottom_left: Vector2 = centre + FRAME_OFFSET_PX
	return Rect2(Vector2(bottom_left.x, bottom_left.y - text_size.y), text_size)


## Where the line meets [param frame]: always its lower-left corner, the one facing the crosshair. Met at
## its nearest point instead, the line slid along an edge as the look moved (playtest 2026-10-23). Pure,
## for the tests.
static func line_end(frame: Rect2) -> Vector2:
	return Vector2(frame.position.x, frame.end.y)


func _process(delta: float) -> void:
	if _prompt != null and framed_rule.call() != _framed:
		_set_framed(not _framed)
	var showing: bool = is_instance_valid(_prompt) and _prompt.visible and _framed
	if showing:
		_prompt.reset_size()
		var centre: Vector2 = get_viewport_rect().size * 0.5
		_prompt.global_position = frame_rect(centre, _prompt.size).position
		_track_anchor()
	modulate.a = move_toward(modulate.a, 1.0 if showing else 0.0, delta * FADE_RATE)
	queue_redraw()


## The line starts on what the prompt is about (target_rule), else on what the look meets, at its own
## point (anchor_of); nothing, no line.
func _track_anchor() -> void:
	var target: Variant = target_rule.call()
	if typeof(target) == TYPE_STRING_NAME and target == NO_LINE:
		_anchor_node = null
		return
	if target is Node3D:
		_anchor_node = target
		_anchor_local = Vector3.ZERO
		return
	if _ray == null or not _ray.is_colliding():
		_anchor_node = null
		return
	var hit := _ray.get_collider() as Node3D
	if hit != _anchor_node:
		_anchor_node = hit
		_anchor_local = anchor_of(hit, hit.to_local(_ray.get_collision_point())) if hit != null else Vector3.ZERO


## The point of [param target] a prompt about it is drawn from, in its own frame: the point it is aimed
## at (aim_point: a piece of furniture, a seat -- what the server checks the reach against), else the
## middle of the collision box the look is in -- the one nearest [param hit] (where the look met it, its
## own frame): a vehicle's door handle has a box outside and one inside the cab, and their average fell
## in the middle of the door, off the handle (playtest 2026-10-23) -- else [param hit] itself.
static func anchor_of(target: Node3D, hit: Vector3) -> Vector3:
	if target.has_method("aim_point"):
		return target.to_local(target.aim_point())
	var best: Vector3 = hit
	var best_d: float = INF
	for child in target.get_children():
		var shape := child as CollisionShape3D
		if shape == null or shape.shape == null or shape.disabled:
			continue
		var middle: Vector3 = shape.transform * shape.shape.get_debug_mesh().get_aabb().get_center()
		if middle.distance_squared_to(hit) < best_d:
			best_d = middle.distance_squared_to(hit)
			best = middle
	return best


func _draw() -> void:
	if not is_instance_valid(_prompt) or not _prompt.visible or _camera == null \
			or not is_instance_valid(_anchor_node):
		return
	var at: Vector3 = _anchor_node.to_global(_anchor_local)
	if _camera.is_position_behind(at):
		return
	var from: Vector2 = _camera.unproject_position(at) - global_position
	var frame := Rect2(_prompt.global_position - global_position, _prompt.size)
	var colour := Color(_prompt.modulate, 1.0)
	draw_line(from, line_end(frame), colour, LINE_PX, true)
	draw_circle(from, DOT_PX, colour)
