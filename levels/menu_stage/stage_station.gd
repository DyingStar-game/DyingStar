class_name StageStation
extends Camera3D
## A viewpoint of the menu stage: the camera rig glides to this camera's place and aim. A Camera3D
## so it can be previewed in the editor (its Preview toggle) while it is placed; it is never made
## current in the game — the rig's camera is.
##
## `key` names it: a menu screen (&"home", &"settings", &"settings_graphics", &"settings_audio",
## &"settings_controls" — MainPage.SCREEN_OF_CATEGORY).

@export var key : StringName = &""
