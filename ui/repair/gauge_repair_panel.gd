class_name GaugeRepairPanel
extends PanelContainer
## A broken machine's diagnosis, then its repair (MachineRepair): the machine's sensors are read, the fault
## is told, and the player who holds the repair's mission brings three gauges into their bands with three
## linked regulators (GaugePuzzle). Anybody else is told to take the mission.
##
## Shown on the broken machine's own screen (MachineBreakdown lays it there): it fills the screen, laid
## out for the screen's shape (design_for) and scaled as a whole. The players around watch it
## (view_state / apply_view_state, ScreenLock's view contract through MachineBreakdown): the same
## words, the same gauges, and nothing to touch.

## The gauges stayed aligned long enough: the machine can be restarted.
signal aligned
## Closed by the player ("Close").
signal dismissed

## The smallest size (px) the panel is laid out at: a screen of another shape gets a wider or a taller
## layout (design_for), and the whole is scaled to the screen.
const DESIGN_PX := Vector2(680.0, 660.0)
## How long the sensors are read before the fault is told (s).
const DIAGNOSIS_S := 2.0
## How long the gauges must stay in their bands (s): a regulator swept through does not count.
const HOLD_S := 0.8
## A gauge's and a regulator's height (px, at the design size); both are as wide as the panel.
const GAUGE_PX := 40.0
const SLIDER_PX := 32.0
## The least width (px) the wrapped texts are laid out at: under DESIGN_PX less the margins and the frame, so
## that the panel never asks for more than its design size (it ran off a square screen's right edge).
const WRAP_PX := 560.0

enum Phase { CLOSED, DIAGNOSING, FAULT, GAUGES, SENT }

## Whether this panel only shows another player's repair (apply_view_state).
var watched: bool = false

var _phase: Phase = Phase.CLOSED
var _elapsed := 0.0
var _held := 0.0
## Null until the mission was looked for; then whether the player holds it.
var _may_repair: Variant = null
var _targets: Array = []
var _text: Label
var _progress: ProgressBar
var _hint: Label
var _rows: VBoxContainer
var _gauges: Array[Gauge] = []
var _sliders: Array[HSlider] = []


func _init() -> void:
	visible = false
	_build()
	set_process(false)


## The size (px) to lay the panel out at so that, scaled as a whole, it fills a screen of
## [param screen_px]: the screen's shape, never smaller than DESIGN_PX either way. Pure.
static func design_for(screen_px: Vector2) -> Vector2:
	if screen_px.x <= 0.0 or screen_px.y <= 0.0:
		return DESIGN_PX
	var shape: float = screen_px.x / screen_px.y
	if shape >= DESIGN_PX.x / DESIGN_PX.y:
		return Vector2(DESIGN_PX.y * shape, DESIGN_PX.y)
	return Vector2(DESIGN_PX.x, DESIGN_PX.x / shape)


## Fill a screen of [param screen_px] (the panel is a child of something that covers it).
func fit(screen_px: Vector2) -> void:
	var design := design_for(screen_px)
	var by: float = screen_px.x / design.x
	position = Vector2.ZERO
	size = design
	scale = Vector2(by, by)


## Open on the diagnosis. The fault is told once the sensors are read AND set_may_repair() was called.
func open() -> void:
	watched = false
	_phase = Phase.DIAGNOSING
	_elapsed = 0.0
	_may_repair = null
	_text.text = "%%REPAIR_DIAGNOSING"
	_progress.value = 0.0
	_progress.visible = true
	_hint.visible = false
	_rows.visible = false
	visible = true
	set_process(true)


## Whether the player holds the machine's repair mission ([param may]); the gauges are drawn from
## [param puzzle_seed].
func set_may_repair(may: bool, puzzle_seed: int) -> void:
	_may_repair = may
	if may:
		var puzzle: Dictionary = GaugePuzzle.make(puzzle_seed)
		_targets = puzzle["targets"]
		for i: int in GaugePuzzle.COUNT:
			_sliders[i].set_value_no_signal(float(puzzle["start"][i]))
			_gauges[i].target = float(_targets[i])
		_read()


## The repair was sent to the server: nothing more to do here but wait for its answer.
func show_sent() -> void:
	_phase = Phase.SENT
	_text.text = "%%REPAIR_SENDING"
	_hint.visible = false
	for slider: HSlider in _sliders:
		slider.editable = false


func close() -> void:
	_phase = Phase.CLOSED
	visible = false
	set_process(false)


## Close as the player does.
func dismiss() -> void:
	close()
	dismissed.emit()


## What the player repairing sees, for the ones watching: the step, the bands and the regulators.
func view_state() -> Dictionary:
	return {"repair": int(_phase), "targets": _targets.duplicate(),
			"sliders": _sliders.map(func(s: HSlider) -> float: return s.value)}


## Show another player's repair ([param view], a view_state): nothing here answers the watcher.
func apply_view_state(view: Dictionary) -> void:
	# Through the network an int comes back a float.
	var phase := int(view.get("repair", Phase.CLOSED))
	var words: Dictionary = {
		Phase.DIAGNOSING: "%%REPAIR_DIAGNOSING", Phase.FAULT: "%%REPAIR_NO_MISSION",
		Phase.GAUGES: "%%REPAIR_FAULT", Phase.SENT: "%%REPAIR_SENDING",
	}
	if not words.has(phase):
		if watched or not visible:
			close()
		return
	watched = true
	_phase = phase as Phase
	set_process(false)
	_text.text = words[phase]
	_progress.visible = false
	_rows.visible = phase == Phase.GAUGES or phase == Phase.SENT
	_hint.visible = phase == Phase.GAUGES
	var targets: Variant = view.get("targets")
	var sliders: Variant = view.get("sliders")
	if targets is Array and sliders is Array and (targets as Array).size() == GaugePuzzle.COUNT \
			and (sliders as Array).size() == GaugePuzzle.COUNT:
		_targets = targets
		for i: int in GaugePuzzle.COUNT:
			_sliders[i].editable = false
			_sliders[i].set_value_no_signal(float(sliders[i]))
			_gauges[i].target = float(targets[i])
		_read()
	visible = true


func _process(delta: float) -> void:
	match _phase:
		Phase.DIAGNOSING:
			_elapsed += delta
			_progress.value = clampf(_elapsed / DIAGNOSIS_S, 0.0, 1.0)
			if _elapsed >= DIAGNOSIS_S and _may_repair != null:
				_show_fault()
		Phase.GAUGES:
			_held = _held + delta if GaugePuzzle.aligned(_values(), _targets) else 0.0
			if _held >= HOLD_S:
				aligned.emit()


func _show_fault() -> void:
	_progress.visible = false
	if not bool(_may_repair):
		_phase = Phase.FAULT
		_text.text = "%%REPAIR_NO_MISSION"
		return
	_phase = Phase.GAUGES
	_held = 0.0
	_text.text = "%%REPAIR_FAULT"
	_hint.visible = true
	_rows.visible = true
	for slider: HSlider in _sliders:
		slider.editable = true


func _values() -> Array:
	return GaugePuzzle.values(_sliders.map(func(s: HSlider) -> float: return s.value))


## Show what the gauges read for the regulators as they stand.
func _read(_value: float = 0.0) -> void:
	var read: Array = _values()
	for i: int in GaugePuzzle.COUNT:
		_gauges[i].value = float(read[i])
		_gauges[i].queue_redraw()


func _build() -> void:
	ServiceStyle.apply_frame(self)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	margin.add_child(column)
	var title := Label.new()
	title.text = "%%REPAIR_TITLE"
	ServiceStyle.font_of(title, 28, true)
	title.add_theme_color_override("font_color", ServiceStyle.ACCENT)
	column.add_child(title)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size.x = WRAP_PX  # else it asks for one word a line, and all that height
	ServiceStyle.font_of(_text, 20)
	_text.add_theme_color_override("font_color", ServiceStyle.TEXT)
	column.add_child(_text)
	_progress = ProgressBar.new()
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(0, 14)
	column.add_child(_progress)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 6)
	column.add_child(_rows)
	for i: int in GaugePuzzle.COUNT:
		var gauge := Gauge.new()
		gauge.custom_minimum_size = Vector2(0, GAUGE_PX)
		_rows.add_child(gauge)
		_gauges.append(gauge)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.005
		slider.custom_minimum_size = Vector2(0, SLIDER_PX)
		slider.value_changed.connect(_read)
		_rows.add_child(slider)
		_sliders.append(slider)
	_hint = Label.new()
	_hint.text = "%%REPAIR_COUPLED"
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size.x = WRAP_PX
	ServiceStyle.font_of(_hint, 16)
	_hint.add_theme_color_override("font_color", ServiceStyle.TEXT_2)
	column.add_child(_hint)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(buttons)
	var leave := Button.new()
	leave.text = "%%SVC_ACT_CLOSE"
	ServiceStyle.apply_button(leave)
	ServiceStyle.font_of(leave, 18)
	leave.custom_minimum_size = Vector2(170, 46)
	leave.pressed.connect(dismiss)
	buttons.add_child(leave)


## One gauge: a bar, its target band, and the needle where the gauge reads -- green in the band.
class Gauge:
	extends Control

	## Where the band is centred and where the needle is, 0..1.
	var target := 0.5
	var value := 0.0

	func _draw() -> void:
		var box := Rect2(Vector2.ZERO, size)
		draw_rect(box, Color(0.08, 0.09, 0.11))
		var band := GaugePuzzle.TOLERANCE * size.x
		draw_rect(Rect2(target * size.x - band, 0.0, 2.0 * band, size.y), Color(ServiceStyle.GOOD, 0.35))
		var inside := absf(value - target) <= GaugePuzzle.TOLERANCE
		var needle := Color(ServiceStyle.GOOD) if inside else Color(ServiceStyle.ACCENT)
		draw_rect(Rect2(clampf(value, 0.0, 1.0) * size.x - 2.0, 0.0, 4.0, size.y), needle)
		draw_rect(box, Color(ServiceStyle.TEXT_2, 0.5), false, 1.0)
