extends Panel

signal action_triggered(type: String)

func _on_trigger_collect_pressed() -> void:
	action_triggered.emit("collect")


func _on_trigger_extract_pressed() -> void:
	action_triggered.emit("extract")
