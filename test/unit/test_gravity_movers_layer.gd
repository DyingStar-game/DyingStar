extends GutTest
## A planet's gravity area pulls only Globals.MASK_MOVERS (player | vehicle | prop): scanning `world`
## made Jolt re-collide every static body of the planet against the gravity sphere each step. So a
## body that falls -- a RigidBody3D that is not frozen, a VehicleBody3D, a CharacterBody3D -- must
## sit on one of those layers, or it floats. Checked on every scene the project declares.

const ROOTS: PackedStringArray = ["res://scenes", "res://assets"]
const MOVER_TYPES: PackedStringArray = ["RigidBody3D", "VehicleBody3D", "CharacterBody3D"]

var _node := RegEx.create_from_string("^\\[node name=\"([^\"]+)\" type=\"([A-Za-z0-9]+)\"")


func test_gravity_does_not_scan_world() -> void:
	assert_eq(Globals.MASK_MOVERS & (1 << (Globals.LAYER_WORLD - 1)), 0, "statics never pay the gravity area")
	for layer: int in [Globals.LAYER_PLAYER, Globals.LAYER_VEHICLE, Globals.LAYER_PROP]:
		assert_ne(Globals.MASK_MOVERS & (1 << (layer - 1)), 0, "layer %d is pulled" % layer)


func test_every_falling_body_is_on_a_mover_layer() -> void:
	var bad: PackedStringArray = []
	for root: String in ROOTS:
		for path: String in _scenes(root):
			bad.append_array(floating(path, FileAccess.get_file_as_string(path)))
	assert_eq(bad.size(), 0, "dynamic bodies out of the gravity's reach:\n" + "\n".join(bad))


func test_the_rule_reads_layer_and_freeze() -> void:
	var src := "\n".join([
		"[node name=\"Ship\" type=\"RigidBody3D\"]",  # default layer 1 = world only
		"mass = 10.0",
		"[node name=\"Crate\" type=\"RigidBody3D\" parent=\".\"]",
		"collision_layer = 8",
		"[node name=\"Mill\" type=\"RigidBody3D\" parent=\".\"]",
		"freeze = true",
		"[node name=\"Wall\" type=\"StaticBody3D\" parent=\".\"]",
		"[node name=\"Npc\" type=\"CharacterBody3D\" parent=\".\"]",
		"collision_layer = 17",  # world | zone: still nothing gravity scans
	])
	assert_eq(floating("x.tscn", src), PackedStringArray(["x.tscn:1 Ship", "x.tscn:8 Npc"]))


## "path:line name" of every non-frozen dynamic body [param source] declares whose layer is not pulled.
func floating(path: String, source: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var lines: PackedStringArray = source.split("\n")
	var i := 0
	while i < lines.size():
		var m: RegExMatch = _node.search(lines[i])
		if m == null or not MOVER_TYPES.has(m.get_string(2)):
			i += 1
			continue
		var at := i
		var layer := 1
		var frozen := false
		i += 1
		while i < lines.size() and not lines[i].begins_with("["):
			if lines[i].begins_with("collision_layer = "):
				layer = int(lines[i].trim_prefix("collision_layer = "))
			elif lines[i] == "freeze = true":
				frozen = true
			i += 1
		if not frozen and layer & Globals.MASK_MOVERS == 0:
			out.append("%s:%d %s" % [path, at + 1, m.get_string(1)])
	return out


func _scenes(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for sub: String in dir.get_directories():
		out.append_array(_scenes(dir_path.path_join(sub)))
	for file: String in dir.get_files():
		if file.ends_with(".tscn"):
			out.append(dir_path.path_join(file))
	return out
