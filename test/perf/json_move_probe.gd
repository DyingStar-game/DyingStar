extends Node
## Cost of parsing one replicated "move" packet (the client does 30/s per visible player).
func _ready() -> void:
	var pkt := JSON.stringify({"channel": 0, "event_type": "move", "object_id": "82203c32-7acc-47cb-9abe-34fc4ac1318e",
		"object_type": "player", "player_id": "82203c32-7acc-47cb-9abe-34fc4ac1318e", "timestamp": 1762583555,
		"data": {"position": {"x": 1234.567, "y": -2345.678, "z": 3456.789},
			"rotation": {"x": 0.1234, "y": 1.2345, "z": 0.0}, "parent_id": "tarsis_3", "velocity": {"x": 0, "y": 0, "z": 0}}})
	var n := 20000
	var buf := pkt.to_utf8_buffer()
	var t0 := Time.get_ticks_usec()
	for i in n:
		var txt := buf.get_string_from_utf8()
		var e = JSON.parse_string(txt)
		var v := Vector3(e["data"]["position"]["x"], e["data"]["position"]["y"], e["data"]["position"]["z"])
	var dt := Time.get_ticks_usec() - t0
	print("PROBE move packet bytes=%d parse_us=%.1f -> 30 players@30Hz = %.2f ms/s" % [buf.size(), float(dt) / n, float(dt) / n * 900.0 / 1000.0])
	get_tree().quit()
