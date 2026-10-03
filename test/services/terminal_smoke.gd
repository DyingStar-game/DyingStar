extends Control

## Throwaway smoke scene for the services terminal: mounts [TerminalUI] full-screen on its own, so
## the REST layer and every section can be exercised without launching a game session. In game the
## same component is opened with F3 (see PlayerClient); here it is the whole scene.
##
## The scheme and base URLs come from client.ini, exactly as in game:
##   [services] scheme="http"   (or "https")
##   [social]/[mission]/[economie] url="…"
## A token can be supplied on the command line (as the game client does), e.g.:
##   godot --path . res://test/services/terminal_smoke.tscn -- --token=<jwt>
##
## No server is needed: with nothing listening the sections simply show the service error on their
## status line.

const TERMINAL_UI := preload("res://ui/services/terminal_ui.gd")

var _terminal: TerminalUI = null


func _ready() -> void:
	# A dark backdrop so the terminal's rounded window reads as a window, not a full-screen page.
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.02, 0.022, 0.03, 1.0)
	add_child(backdrop)

	_terminal = TERMINAL_UI.new()
	add_child(_terminal)
	_terminal.open()

	# Footer naming what we are talking to — the one thing not obvious on screen.
	var info := Label.new()
	info.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	info.offset_left = 22.0
	info.offset_right = -22.0
	info.offset_top = -24.0
	info.offset_bottom = -6.0
	info.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(info, 13)
	info.text = "scheme=%s    social=%s    mission=%s    economie=%s" % [
		PlayerServices.scheme(),
		PlayerServices.base_url("social"),
		PlayerServices.base_url("mission"),
		PlayerServices.base_url("economie"),
	]
	add_child(info)


## Escape closes the smoke scene instead of pausing (there is no game behind it here).
func _unhandled_input(event: InputEvent) -> void:
	if _terminal != null and _terminal.is_typing():
		return
	if event.is_action_pressed("pause"):
		get_tree().quit()
		get_viewport().set_input_as_handled()
