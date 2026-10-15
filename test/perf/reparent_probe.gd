extends Node
## Throwaway probe: what a client reparent of the OWN player costs, plain vs under a covered building.

var _out: FileAccess


func say(t: String) -> void:
	if _out == null:
		_out = FileAccess.open("user://reparent_probe.txt", FileAccess.WRITE)
	_out.store_line(t)
	_out.flush()
	print(t)


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c


func _ready() -> void:
	var a := Node3D.new()
	a.name = "A"
	add_child(a)
	var plain := Node3D.new()
	plain.name = "Plain"
	add_child(plain)
	var building := AnimatableBody3D.new()
	building.name = "Building"
	add_child(building)
	StructureDrawRange._cover(building)
	var player: Node = (load("res://scenes/player/player.tscn") as PackedScene).instantiate()
	player.remote_player = false
	a.add_child(player)
	for i in 30:
		await get_tree().process_frame
	say("PROBE nodes in player subtree: %d" % _count(player))
	for round_i in 3:
		for target: Node in [plain, a, building, a]:
			var t0 := Time.get_ticks_usec()
			player.reparent(target)
			var t1 := Time.get_ticks_usec()
			say("PROBE round %d reparent -> %s : %.2f ms" % [round_i, target.name, (t1 - t0) / 1000.0])
			await get_tree().process_frame
			await get_tree().process_frame
	# Which child subtree costs: remove + re-add each direct child alone, recursively into the worst.
	_bisect(player, 0)
	var tracked := 0
	for n in player.find_children("*", "GeometryInstance3D", true, false):
		if DrawRange.is_tracked(n):
			tracked += 1
	say("PROBE player meshes now tracked as building meshes: %d" % tracked)
	get_tree().quit()


func _bisect(node: Node, depth: int) -> void:
	if depth > 6:
		return
	var rows: Array = []
	for ch in node.get_children():
		var t0 := Time.get_ticks_usec()
		node.remove_child(ch)
		var t1 := Time.get_ticks_usec()
		node.add_child(ch)
		var t2 := Time.get_ticks_usec()
		rows.append([ch, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, _count(ch)])
	rows.sort_custom(func(x, y): return x[1] + x[2] > y[1] + y[2])
	for r in rows.slice(0, 6):
		say("PROBE %s%s (%s, %d nodes): exit %.2f ms, enter %.2f ms" % ["  ".repeat(depth), r[0].name,
				r[0].get_class(), r[3], r[1], r[2]])
	if depth <= 1 and not rows.is_empty():
		var w: Node = rows[0][0]
		var owner_script: Node = w
		while owner_script != null and owner_script.get_script() == null:
			owner_script = owner_script.get_parent()
		say("PROBE   worst %s script-owner %s (%s)" % [w.name, owner_script.name if owner_script else "-",
				owner_script.get_script().resource_path if owner_script else "-"])
		var labels := w.find_children("*", "Label", true, false)
		for l in labels.slice(0, 8):
			say("PROBE     label: %s" % (l as Label).text.substr(0, 60))
	if not rows.is_empty() and rows[0][1] + rows[0][2] > 5.0:
		_bisect(rows[0][0], depth + 1)
