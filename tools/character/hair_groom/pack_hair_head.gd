extends Node

## Packs build/character/hair_head.npz (tools/character/hair_groom/hair_head.py) into the game's HairHead
## resource. Run headless:
##   godot --headless --path . res://tools/character/hair_groom/pack_hair_head.tscn -- --npz=build/character/hair_head.npz

var _zip := ZIPReader.new()


func _ready() -> void:
	var npz: String = "build/character/hair_head.npz"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--npz="):
			npz = a.trim_prefix("--npz=")
	var code: int = _pack(ProjectSettings.globalize_path("res://" + npz) if not npz.begins_with("/") else npz)
	get_tree().quit(code)


func _pack(path: String) -> int:
	if _zip.open(path) != OK:
		push_error("cannot open %s" % path)
		return 1
	var head := HairHead.new()
	head.centre = _vec3(_floats("centre"))[0]
	head.crown = _vec3(_floats("crown"))[0]
	head.scalp_vertex = PackedInt32Array(_ints("scalp_vertex"))
	head.scalp_position = _vec3(_floats("scalp_position"))
	head.scalp_normal = _vec3(_floats("scalp_normal"))
	head.scalp_density = _floats("scalp_density")
	head.scalp_above = _floats("scalp_above")
	head.scalp_edge = _floats("scalp_edge")
	head.scalp_triangles = _ints("scalp_triangles")
	head.shell_vertex = _ints("shell_vertex")
	var uv: PackedFloat32Array = _floats("shell_uv")
	for k in uv.size() / 2:
		head.shell_uv.append(Vector2(uv[k * 2], uv[k * 2 + 1]))
	head.shell_index = _ints("shell_index")
	head.shell_tangent = _floats("shell_tangent")
	head.sdf_origin = _vec3(_floats("sdf_origin"))[0]
	head.sdf_cell = _floats("sdf_cell")[0]
	var size: PackedInt32Array = _ints("sdf_size")
	head.sdf_size = Vector3i(size[0], size[1], size[2])
	head.sdf = _floats("sdf")
	head.head_bone = _ints("head_bone")[0]
	head.beard_vertex = _ints("beard_vertex")
	head.beard_position = _vec3(_floats("beard_position"))
	head.beard_normal = _vec3(_floats("beard_normal"))
	head.beard_zones = _floats("beard_zones")
	head.beard_triangles = _ints("beard_triangles")
	head.beard_shell_vertex = _ints("beard_shell_vertex")
	var buv: PackedFloat32Array = _floats("beard_shell_uv")
	for k in buv.size() / 2:
		head.beard_shell_uv.append(Vector2(buv[k * 2], buv[k * 2 + 1]))
	head.beard_shell_index = _ints("beard_shell_index")
	head.beard_shell_tangent = _floats("beard_shell_tangent")
	var err: int = ResourceSaver.save(head, HairHead.PATH, ResourceSaver.FLAG_COMPRESS)
	print("PACK hair head: %d scalp vertices, %d triangles, sdf %s -> %s (%s)" % [head.scalp_vertex.size(),
			head.scalp_triangles.size() / 3, head.sdf_size, HairHead.PATH, error_string(err)])
	return 0 if err == OK else 1


func _payload(name: String) -> Array:  # [descr, bytes]
	var bytes: PackedByteArray = _zip.read_file(name + ".npy")
	var start: int = bytes.decode_u16(8) + 10 if bytes[6] < 2 else bytes.decode_u32(8) + 12
	var header: String = bytes.slice(10 if bytes[6] < 2 else 12, start).get_string_from_ascii()
	var descr: String = RegEx.create_from_string("'descr':\\s*'([^']+)'").search(header).get_string(1)
	return [descr, bytes.slice(start)]


func _floats(name: String) -> PackedFloat32Array:
	var p: Array = _payload(name)
	if p[0] != "<f4":
		push_error("%s: expected float32, got %s" % [name, p[0]])
	return (p[1] as PackedByteArray).to_float32_array()


func _ints(name: String) -> PackedInt32Array:
	var p: Array = _payload(name)
	if p[0] != "<i4":
		push_error("%s: expected int32, got %s" % [name, p[0]])
	return (p[1] as PackedByteArray).to_int32_array()


func _vec3(flat: PackedFloat32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for k in flat.size() / 3:
		out.append(Vector3(flat[k * 3], flat[k * 3 + 1], flat[k * 3 + 2]))
	return out
