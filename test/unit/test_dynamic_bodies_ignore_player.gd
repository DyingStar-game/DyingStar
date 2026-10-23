extends GutTest
## No dynamic body (RigidBody3D, VehicleBody3D) of the game scans the player layer: Globals.MASK_DYNAMIC.
## A player is a CharacterBody3D, a Jolt kinematic body of infinite mass; a prop or a vehicle that scans
## it is thrown out of its way whatever it weighs when a step-up or climb glide drives the capsule into
## it (test_kinematic_shove). Not scanning it, the body is pushed only by PlayerServer._push_touched_bodies.
##
## Read as text, like test_export_docs: every scene is checked without instancing a level.

## Folders not checked, under res://.
const SKIPPED : Array[String] = ["res://.godot", "res://addons", "res://test"]
const PLAYER_BIT := 1 << (Globals.LAYER_PLAYER - 1)

var _node := RegEx.create_from_string("^\\[node (.*)\\]$")
var _dynamic := RegEx.create_from_string("type=\"(RigidBody3D|VehicleBody3D)\"")
var _name := RegEx.create_from_string("name=\"([^\"]*)\"")


func test_mask_dynamic_is_solid_minus_player() -> void:
	assert_eq(Globals.MASK_DYNAMIC, Globals.MASK_SOLID & ~PLAYER_BIT)


func test_no_dynamic_body_scans_the_player() -> void:
	var found : PackedStringArray = []
	for path: String in _scenes("res://"):
		found.append_array(scanning_player(path, FileAccess.get_file_as_string(path)))
	assert_eq(found.size(), 0, "dynamic bodies scanning the player layer (use Globals.MASK_DYNAMIC):\n"
			+ "\n".join(found))


func test_the_rule_reads_scene_text() -> void:
	var src := "\n".join([
		"[node name=\"Rock\" type=\"RigidBody3D\"]", "collision_layer = 8", "collision_mask = 15",
		"[node name=\"Zone\" type=\"Area3D\" parent=\".\"]", "collision_mask = 15",
		"[node name=\"Box\" type=\"RigidBody3D\" parent=\".\"]", "collision_mask = 13",
		"[node name=\"Truck\" type=\"VehicleBody3D\" parent=\".\"]", "collision_mask = 2",
	])
	assert_eq(scanning_player("x.tscn", src), PackedStringArray(["x.tscn: Rock", "x.tscn: Truck"]))


## "path: node" of every RigidBody3D / VehicleBody3D in [param source] whose collision_mask has the
## player bit (an absent mask is Godot's default, 1: world only).
func scanning_player(path: String, source: String) -> PackedStringArray:
	var out : PackedStringArray = []
	var current := ""
	for line: String in source.split("\n"):
		if line.begins_with("["):
			var m := _node.search(line)
			current = ""
			if m != null and _dynamic.search(m.get_string(1)) != null:
				var n := _name.search(m.get_string(1))
				current = n.get_string(1) if n != null else "?"
			continue
		if current != "" and line.begins_with("collision_mask = "):
			if int(line.get_slice("=", 1).strip_edges()) & PLAYER_BIT:
				out.append("%s: %s" % [path, current])
	return out


func _scenes(dir_path: String) -> PackedStringArray:
	var out : PackedStringArray = []
	if dir_path.trim_suffix("/") in SKIPPED:
		return out
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for sub: String in dir.get_directories():
		out.append_array(_scenes(dir_path.path_join(sub)))
	for file: String in dir.get_files():
		if file.ends_with(".tscn"):
			out.append(dir_path.path_join(file))
	return out
