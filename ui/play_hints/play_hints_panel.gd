class_name PlayHintsPanel
extends Control
## The play hints on the left of the screen: "[key] what it does", for what the player can do right
## now (PlayHints), minus what they have already learnt (PlayHintsMemory).
##
## A Control under the player's UserInterface, not a CanvasLayer: the pause menu and the F7 photo then
## hide it with the rest of the HUD, for free. Its own visibility is never touched — that is theirs —
## it fades through modulate.
##
## Polled, like the rest of the HUD: the contexts are plain state (seated, carrying, tool out) with no
## signal, and the device in hand or a rebound key change under it the same way. Four times a second
## is plenty for text, and immediately when the device changes.

## How often (s) the lines are asked again.
const REFRESH_S : float = 0.25
## Most lines shown at once: the panel is a reminder, not the controls page (F1 is).
const MAX_ROWS : int = 6
## Distance (px) from the left edge of the window.
const LEFT_PX : float = 20.0
## Top of the panel, as a share of the window height: above the chat (centre left) and the voice
## buttons (bottom left).
const TOP_RATIO : float = 0.18
## Fade speed (alpha per second).
const FADE_RATE : float = 5.0
## The same action is counted as "used" at most once per this many seconds: a stick held over its
## dead zone sends motion events all along, and one push is one use.
const USE_DEBOUNCE_S : float = 0.5

## May the hints show at all (Settings > General). Replaced by tests.
var enabled_rule : Callable = func() -> bool: return SettingsManager.is_play_hints_enabled()
## Must they hide right now (a menu, the chart, the help, the chat are open).
var hidden_rule : Callable = func() -> bool: return false
## What the player has learnt. The game's own unless a test hands one in.
var memory : PlayHintsMemory = null

var _list : GridContainer  # two columns, keys | what they do: the texts line up whatever the key's width
var _shown : Array[Dictionary] = []
var _signature : String = ""
var _age : float = REFRESH_S
var _device : int = -1
var _target_alpha : float = 0.0
var _last_noted : Dictionary = {}


func _init() -> void:
	name = "PlayHintsPanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_top = TOP_RATIO
	anchor_bottom = TOP_RATIO
	offset_left = LEFT_PX
	_list = GridContainer.new()
	_list.columns = 2
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_theme_constant_override(&"h_separation", 10)
	_list.add_theme_constant_override(&"v_separation", 6)
	add_child(_list)
	modulate.a = 0.0


## Step aside while `panel` (the graphics options, on the same edge) is up.
func avoid(panel: OverlayPanel, width_px: float) -> void:
	panel.shown_changed.connect(func(shown: bool) -> void:
		offset_left = LEFT_PX + (width_px + LEFT_PX if shown else 0.0))


func _process(delta: float) -> void:
	_age += delta
	if _age >= REFRESH_S or InputDevice.last != _device:
		_age = 0.0
		refresh()
	modulate.a = move_toward(modulate.a, _target_alpha, delta * FADE_RATE)


## Ask the lines again and redraw them if they changed.
func refresh() -> void:
	_device = InputDevice.last
	var rows : Array[Dictionary] = []
	if bool(enabled_rule.call()) and not bool(hidden_rule.call()):
		for r: Dictionary in PlayHints.active():
			if _memory().is_learned(r["actions"]):
				continue
			var keys : String = PlayHints.keys_of(r["actions"], InputDevice.last)
			if keys.is_empty():
				continue  # nothing to press on this device: not a hint
			rows.append({"actions": r["actions"], "label": r["label"], "keys": keys})
			if rows.size() >= MAX_ROWS:
				break
	_target_alpha = 1.0 if not rows.is_empty() else 0.0
	if rows.is_empty():
		_shown = []  # fading out: keep the old lines on screen, but nothing counts any more
		return
	_shown = rows
	var signature : String = TranslationServer.get_locale() + str(rows)
	if signature == _signature:
		return
	_signature = signature
	_rebuild(rows)


## The lines on screen now: [{actions, label, keys}]. For tests and the debug overlay.
func shown() -> Array[Dictionary]:
	return _shown


func _input(event: InputEvent) -> void:
	if _shown.is_empty() or event.is_echo() or not event.is_pressed():
		return
	var t : float = Time.get_ticks_msec() * 0.001
	for r: Dictionary in _shown:
		for action: StringName in r["actions"]:
			if not event.is_action_pressed(action):
				continue
			if t - float(_last_noted.get(action, -USE_DEBOUNCE_S)) < USE_DEBOUNCE_S:
				continue
			_last_noted[action] = t
			_memory().note_used(action)
			_age = REFRESH_S  # learnt? gone at the next frame, not a quarter of a second later


func _memory() -> PlayHintsMemory:
	if memory == null:
		memory = PlayHintsMemory.shared()
	return memory


func _rebuild(rows: Array[Dictionary]) -> void:
	for child in _list.get_children():
		child.queue_free()
	for r: Dictionary in rows:
		var chip := PanelContainer.new()
		chip.theme_type_variation = &"TooltipPanel"
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.size_flags_horizontal = Control.SIZE_SHRINK_END
		var key := _label(str(r["keys"]))
		key.name = "Keys"
		chip.add_child(key)
		_list.add_child(chip)
		var what := _label(tr(str(r["label"])))
		what.name = "What"
		_list.add_child(what)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	# Already in the player's language (or a key name, which must not be looked up as a key).
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_constant_override(&"outline_size", 4)
	label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.8))
	return label
