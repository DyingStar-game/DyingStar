extends CanvasLayer

var is_ready: bool = false
var settings_scene : PackedScene = preload("res://ui/settings_page/settings_page.tscn")

@onready var spawn_points_list_display: OptionButton = %OptionButton
@onready var settings_button : Button = $Control/Button

func _ready() -> void:
	settings_button.pressed.connect(_on_settings_pressed)
	is_ready = true

	for spawn_point in GameOrchestrator.SPAWN_POINTS_LIST:
		spawn_points_list_display.add_item(spawn_point["label"])

	if spawn_points_list_display.item_count > 0:
		spawn_points_list_display.select(0)

func _on_settings_pressed() -> void:
	add_child(settings_scene.instantiate())

func _on_button_pressed() -> void:
	GameOrchestrator.requested_spawn_point = spawn_points_list_display.selected
	GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
