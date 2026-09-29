class_name StageStation
extends Camera3D
## A viewpoint of the menu stage: the camera rig glides to this camera's place and aim. A Camera3D
## so it can be previewed in the editor (its Preview toggle) while it is placed; it is never made
## current in the game — the rig's camera is.
##
## `key` names it: a menu screen (&"home", &"settings", &"settings_graphics", &"settings_audio",
## &"settings_controls" — MainPage.SCREEN_OF_CATEGORY), or
## any key for a tuning-scene viewpoint, which then carries a `label` (a translation key) to be listed.

@export var key : StringName = &""
## Translation key shown in the tuning scene's viewpoint list; empty for a menu screen's station.
@export var label : String = ""


func is_tuning() -> bool:
	return label != ""
