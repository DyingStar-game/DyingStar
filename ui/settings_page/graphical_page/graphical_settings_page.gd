extends Control

## Wires the graphics options to SettingsManager (apply + persist), and on open reflects the real
## current display state — including auto-filling the screen resolution with the monitor's size.

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i(3840, 2160),
]

## Seconds before a just-applied resolution auto-reverts unless the player confirms (Windows-style
## safety: a resolution too big for the screen must not lock them out of the settings).
const _RES_CONFIRM_SECS: int = 10
var _res_prev_size: Vector2i = Vector2i.ZERO  # resolution to restore if the change is refused
var _res_dialog: ConfirmationDialog = null
var _res_timer: Timer = null
var _res_left: int = 0

@onready var _monitor: OptionButton = $ScrollContainer/MarginContainer/VBoxContainer/Monitor/OptionButton
@onready var _display_mode: OptionButton = $ScrollContainer/MarginContainer/VBoxContainer/DisplayMode/OptionButton
@onready var _resolution: OptionButton = $ScrollContainer/MarginContainer/VBoxContainer/ScreenResolution/OptionButton
@onready var _vsync: Button = $ScrollContainer/MarginContainer/VBoxContainer/VSync/Button
@onready var _dev_mode: Button = $ScrollContainer/MarginContainer/VBoxContainer/DevMode/Button
@onready var _max_fps: OptionButton = $ScrollContainer/MarginContainer/VBoxContainer/MaxFps/OptionButton
@onready var _fov: HSlider = $ScrollContainer/MarginContainer/VBoxContainer/Fov/HSlider
@onready var _fov_value: Label = $ScrollContainer/MarginContainer/VBoxContainer/Fov/Value

func _ready() -> void:
	_init_monitor()
	_init_display_mode()
	_init_resolution()
	_init_vsync()
	_init_dev_mode()
	_init_max_fps()
	_init_fov()
	_monitor.item_selected.connect(func(i: int) -> void: SettingsManager.set_monitor(i))
	# DisplayMode item id 0 = Fullscreen, 1 = Windowed (as authored in the scene).
	_display_mode.item_selected.connect(
		func(i: int) -> void: SettingsManager.set_fullscreen(_display_mode.get_item_id(i) == 0))
	_resolution.item_selected.connect(_on_resolution_selected)
	_vsync.toggled.connect(func(on: bool) -> void:
		_vsync.text = "On" if on else "Off"
		SettingsManager.set_vsync(on))
	_dev_mode.toggled.connect(_on_dev_mode_toggled)
	# The OptionButton item id IS the fps cap (0 = Unlimited), so set_max_fps gets it directly.
	_max_fps.item_selected.connect(func(i: int) -> void: SettingsManager.set_max_fps(_max_fps.get_item_id(i)))
	_fov.value_changed.connect(func(v: float) -> void:
		_fov_value.text = str(int(v))
		SettingsManager.set_fov(v))

## Apply the picked resolution, then ask to keep it with a visible 10 s auto-revert countdown. A too-big
## resolution on a small screen would otherwise leave the player stuck; the timer reverts on its own.
func _on_resolution_selected(index: int) -> void:
	var new_size: Vector2i = _resolution.get_item_metadata(index)
	_res_prev_size = DisplayServer.window_get_size()  # captured BEFORE applying
	if new_size == _res_prev_size:
		return  # re-selected the current size: nothing to confirm
	SettingsManager.set_resolution(new_size)
	_open_resolution_confirm()

## Build the keep/revert dialog (centered → visible even if the window overflows the screen, since
## the window is re-centered on apply) and start the 1 s countdown.
func _open_resolution_confirm() -> void:
	_close_resolution_confirm()
	_res_left = _RES_CONFIRM_SECS
	_res_dialog = ConfirmationDialog.new()
	_res_dialog.title = "Résolution"
	_res_dialog.exclusive = false
	_res_dialog.get_ok_button().text = "Garder"
	_res_dialog.get_cancel_button().text = "Revenir"
	_res_dialog.confirmed.connect(_keep_resolution)
	_res_dialog.canceled.connect(_revert_resolution)  # Revenir button, close (X) or Esc
	add_child(_res_dialog)
	_update_res_dialog_text()
	_res_dialog.popup_centered()
	_res_timer = Timer.new()
	_res_timer.wait_time = 1.0
	_res_timer.timeout.connect(_on_res_tick)
	add_child(_res_timer)
	_res_timer.start()

func _update_res_dialog_text() -> void:
	if _res_dialog != null:
		_res_dialog.dialog_text = "Garder cette résolution ?\nRetour automatique dans %d s." % _res_left

func _on_res_tick() -> void:
	_res_left -= 1
	if _res_left <= 0:
		_revert_resolution()
		return
	_update_res_dialog_text()

## Keep: already applied + saved by set_resolution, just tear down the confirm UI.
func _keep_resolution() -> void:
	_close_resolution_confirm()

## Revert: re-apply (and re-save) the previous resolution and reflect it back in the dropdown.
func _revert_resolution() -> void:
	if _res_prev_size != Vector2i.ZERO:
		SettingsManager.set_resolution(_res_prev_size)
		_select_resolution(_res_prev_size)
	_close_resolution_confirm()

func _close_resolution_confirm() -> void:
	if _res_timer != null:
		_res_timer.stop()
		_res_timer.queue_free()
		_res_timer = null
	if _res_dialog != null:
		# Avoid re-entering _revert via the canceled signal while we free it.
		if _res_dialog.canceled.is_connected(_revert_resolution):
			_res_dialog.canceled.disconnect(_revert_resolution)
		_res_dialog.queue_free()
		_res_dialog = null

## Select the dropdown entry matching a size (used to snap it back on revert).
func _select_resolution(size: Vector2i) -> void:
	for i in _resolution.item_count:
		if _resolution.get_item_metadata(i) == size:
			_resolution.select(i)
			return

## List the real monitors and pre-select the one the window is on.
func _init_monitor() -> void:
	_monitor.clear()
	for i in DisplayServer.get_screen_count():
		_monitor.add_item("Monitor %d" % (i + 1), i)
	_monitor.select(DisplayServer.window_get_current_screen())

## Pre-select Fullscreen / Windowed from the real window mode.
func _init_display_mode() -> void:
	var fs: bool = DisplayServer.window_get_mode() in [
		DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	_display_mode.select(0 if fs else 1)

## Auto-fill: offer the standard resolutions plus the monitor's current size, selected by default.
func _init_resolution() -> void:
	_resolution.clear()
	var current: Vector2i = DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	var sizes: Array[Vector2i] = RESOLUTIONS.duplicate()
	if not sizes.has(current):
		sizes.append(current)
	for idx in sizes.size():
		var s: Vector2i = sizes[idx]
		_resolution.add_item("%d x %d" % [s.x, s.y], idx)
		_resolution.set_item_metadata(idx, s)
		if s == current:
			_resolution.select(idx)

func _init_vsync() -> void:
	_vsync.toggle_mode = true
	_vsync.button_pressed = DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED
	_vsync.text = "On" if _vsync.button_pressed else "Off"

## Reflect the saved dev-mode flag (it has no live DisplayServer state — it only gates startup).
func _init_dev_mode() -> void:
	_dev_mode.toggle_mode = true
	_dev_mode.button_pressed = SettingsManager.is_dev_mode()
	_dev_mode.text = "On" if _dev_mode.button_pressed else "Off"

func _on_dev_mode_toggled(on: bool) -> void:
	_dev_mode.text = "On" if on else "Off"
	SettingsManager.set_dev_mode(on)

## Reflect the saved field of view on the slider + its value label.
func _init_fov() -> void:
	_fov.value = SettingsManager.get_fov()
	_fov_value.text = str(int(_fov.value))

## Pre-select the entry matching the current Engine.max_fps (0 = Unlimited).
func _init_max_fps() -> void:
	var current: int = Engine.max_fps
	for i in _max_fps.item_count:
		if _max_fps.get_item_id(i) == current:
			_max_fps.select(i)
			return
	_max_fps.select(0)
