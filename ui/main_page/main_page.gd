extends CanvasLayer

var is_ready: bool = false

@onready var spawn_points_list_display: OptionButton = %OptionButton

func _ready() -> void:
	is_ready = true

	for spaw_point in GameOrchestrator.SPAWN_POINTS_LIST:
		spawn_points_list_display.add_item(spaw_point["label"])

	if spawn_points_list_display.item_count > 0:
		spawn_points_list_display.select(0)

func _on_button_pressed() -> void:
	GameOrchestrator.requested_spawn_point = spawn_points_list_display.selected
	GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
