extends Label

func _ready() -> void:
	while true:
		await get_tree().create_timer(1.0).timeout
		var messages = Performance.get_custom_monitor('network/events_sent')
		text = str(messages) + " messages sent / second"
