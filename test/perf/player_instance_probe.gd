extends Node
## What instancing the player's scene costs (server/client.gd create_player: me:instantiate, 171 ms as the
## player appeared, 2026-11-28), headless: the whole scene a few times, then each scene it instances alone.
##   <godot> --headless --path . res://test/perf/player_instance_probe.tscn

const PLAYER := "res://scenes/player/player.tscn"


func _ms(t: int) -> float:
	return (Time.get_ticks_usec() - t) / 1000.0


func _ready() -> void:
	var scene := load(PLAYER) as PackedScene
	for k in 3:
		var t := Time.get_ticks_usec()
		var p := scene.instantiate()
		var ms := _ms(t)
		print("[PlayerInst] instantiate %d: %.1f ms, %d nodes" % [k, ms, p.find_children("*", "", true, false).size() + 1])
		p.free()
	var state := scene.get_state()
	var subs: Array = []
	for i in state.get_node_count():
		var inner: PackedScene = state.get_node_instance(i)
		if inner != null:
			var t := Time.get_ticks_usec()
			var n := inner.instantiate()
			subs.append([_ms(t), inner.resource_path, n.find_children("*", "", true, false).size() + 1])
			n.free()
	subs.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	for e: Array in subs.slice(0, 10):
		print("[PlayerInst]   %s: %.1f ms, %d nodes" % [e[1], e[0], e[2]])
	get_tree().quit()
