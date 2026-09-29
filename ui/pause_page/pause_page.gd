class_name PausePage
extends Control
## The pause menu's screen: the same top bar as the home screen (TopBar) with the in-game entries,
## over the running game — PauseMenu opens the settings under it at once. It decides what each does.

const RESUME : StringName = &"resume"
const SETTINGS : StringName = &"settings"
const RETURN_MENU : StringName = &"return_menu"
const QUIT : StringName = &"quit"

var bar : TopBar


func _init() -> void:
	bar = TopBar.new()
	bar.add_entry(RESUME, "%%PAUSEPAGE_RESUMEGAME")
	bar.add_entry(SETTINGS, "%%MENU_SETTINGS")
	bar.add_entry(RETURN_MENU, "%%PAUSEPAGE_RETURNMENU")
	bar.add_entry(QUIT, "%%PAUSEPAGE_QUITGAME")


func _ready() -> void:
	add_child(bar)
	# A CanvasLayer does not follow its parent Control's visibility: the bar is shown with the page.
	bar.visible = is_visible_in_tree()
	visibility_changed.connect(func() -> void: bar.visible = is_visible_in_tree())


func _unhandled_input(_event: InputEvent) -> void:
	if not is_multiplayer_authority(): return
