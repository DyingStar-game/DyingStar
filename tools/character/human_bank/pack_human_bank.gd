extends Node

## Packs the bank's .npz (tools/character/vitruvian/build_vitruvian_bank.py; textures.json, when given,
## names the worn assets' textures) into the game's HumanBank resource. Run headless after the textures
## are imported:
##   godot --headless --path . res://tools/character/human_bank/pack_human_bank.tscn -- \
##       --npz=build/character/human_bank.npz --textures=build/character/textures.json
## Writes res://assets/_universe/characters/human/human_bank.res (compressed).

const OUT_PATH := "res://assets/_universe/characters/human/human_bank.res"

var _zip: ZIPReader = ZIPReader.new()


func _ready() -> void:
	var npz_path: String = ""
	var textures_path: String = ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--npz="):
			npz_path = arg.trim_prefix("--npz=")
		elif arg.begins_with("--textures="):
			textures_path = arg.trim_prefix("--textures=")
	var status: int = _pack(npz_path, textures_path)
	print("PACK %s" % ("done" if status == OK else "FAILED (%s)" % error_string(status)))
	get_tree().quit(0 if status == OK else 1)


func _pack(npz_path: String, textures_path: String) -> int:
	if _zip.open(ProjectSettings.globalize_path(npz_path) if npz_path.begins_with("res://") else npz_path) != OK:
		push_error("cannot open %s" % npz_path)
		return ERR_FILE_CANT_OPEN
	var textures: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(textures_path)) if textures_path else {}
	var bank := HumanBank.new()
	bank.base = _vec3(_array("base"))
	bank.keep = PackedInt32Array(_array("keep"))
	bank.target_names = PackedStringArray(_array("target_names"))
	bank.target_scale = PackedFloat32Array(_array("target_scale"))
	bank.target_delta_start = PackedInt32Array(_array("target_delta_start"))
	bank.target_count = PackedInt32Array(_array("target_count"))
	bank.target_dense = _raw("target_dense")
	bank.target_sparse_start = PackedInt32Array(_array("target_sparse_start"))
	bank.sparse_index = _raw("sparse_index")
	bank.delta = _raw("delta")
	bank.face_units = PackedStringArray(_array("face_units"))
	bank.beard_mask = _raw("beard_mask")
	bank.macro_config = JSON.parse_string(_array("macro_json")[0])
	bank.catalogue = JSON.parse_string(_array("catalogue_json")[0])
	bank.asset_catalogue = JSON.parse_string(_array("assets_json")[0])
	bank.bone_names = PackedStringArray(_array("bone_names"))
	bank.bone_parents = PackedStringArray(_array("bone_parents"))
	bank.joint_ptr = PackedInt32Array(_array("joint_ptr"))
	bank.joint_index = PackedInt32Array(_array("joint_index"))
	if _has("joint_weight"):
		bank.joint_weight = PackedFloat32Array(_array("joint_weight"))
		bank.bone_aim = PackedInt32Array(_array("bone_aim"))
		bank.sole_vertex = PackedInt32Array(_array("sole_vertex"))
		bank.zone_names = PackedStringArray(_array("zone_names"))
		bank.zone_vertex_ptr = PackedInt32Array(_array("zone_vertex_ptr"))
		bank.zone_index_ptr = PackedInt32Array(_array("zone_index_ptr"))
	bank.body_vertex = PackedInt32Array(_array("body_vertex"))
	bank.body_uv = _vec2(_array("body_uv"))
	bank.body_index = PackedInt32Array(_array("body_index"))
	bank.body_tangent = PackedFloat32Array(_array("body_tangent"))
	bank.skin_bones = _raw("skin_bones")
	bank.skin_weights = PackedFloat32Array(_array("skin_weights"))
	var meta: Array = JSON.parse_string(_array("asset_meta_json")[0])
	for i in meta.size():
		var m: Dictionary = meta[i]
		var p: String = "asset%d_" % i
		var a := HumanAssetData.new()
		a.kind = StringName(m["kind"])
		a.slot = int(m["slot"])
		a.part = int(m["part"])
		a.id = StringName(m["id"])
		a.gender = StringName(m["gender"])
		a.refs = PackedInt32Array(_array(p + "refs"))
		a.weights = PackedFloat32Array(_array(p + "weights"))
		a.offsets = _vec3(_array(p + "offsets"))
		a.scale_pairs = PackedInt32Array(_array(p + "scale_pairs"))
		a.scale_ref = PackedFloat32Array(_array(p + "scale_ref"))
		a.vertex = PackedInt32Array(_array(p + "vertex"))
		a.uv = _vec2(_array(p + "uv"))
		a.index = PackedInt32Array(_array(p + "index"))
		a.tangent = PackedFloat32Array(_array(p + "tangent"))
		a.bones = _raw(p + "bones")
		a.bone_weights = PackedFloat32Array(_array(p + "bone_weights"))
		a.delete = PackedInt32Array(_array(p + "delete"))
		a.style = StringName(m.get("style", ""))
		if _has(p + "strand_points"):
			a.strand_points = _vec3(_array(p + "strand_points"))
			a.strand_size = int(m.get("strand_size", 0))
			a.strand_params = m.get("strand_params", {})
		if _has(p + "normal"):
			a.normal_fixed = _vec3(_array(p + "normal"))
		if _has(p + "lods"):
			a.lods = PackedFloat32Array(_array(p + "lods"))
		if _has(p + "color"):
			var rgba: PackedByteArray = _raw(p + "color")
			var colours := PackedColorArray()
			colours.resize(rgba.size() / 4)
			for k in colours.size():
				colours[k] = Color(rgba[k * 4] / 255.0, rgba[k * 4 + 1] / 255.0, rgba[k * 4 + 2] / 255.0, rgba[k * 4 + 3] / 255.0)
			a.color = colours
		var tex: Dictionary = textures.get(str(i), {})
		if tex.has("albedo"):
			a.albedo = load(tex["albedo"])
		if tex.has("normal"):
			a.normal = load(tex["normal"])
		if tex.has("ao"):
			a.ao = load(tex["ao"])
		bank.assets.append(a)
	_zip.close()
	print("PACK %d vertices, %d targets, %d assets, %.1f MB of deltas" % [
		bank.base.size(), bank.target_names.size(), bank.assets.size(), bank.delta.size() / 1e6])
	return ResourceSaver.save(bank, OUT_PATH, ResourceSaver.FLAG_COMPRESS)


func _has(name: String) -> bool:
	return _zip.file_exists(name + ".npy")


## The raw little-endian payload of an .npy member (no dtype conversion).
func _raw(name: String) -> PackedByteArray:
	var bytes: PackedByteArray = _zip.read_file(name + ".npy")
	return bytes.slice(_header_end(bytes))


## An .npy member as a flat Array (numbers or strings).
func _array(name: String) -> Array:
	var bytes: PackedByteArray = _zip.read_file(name + ".npy")
	var start: int = _header_end(bytes)
	var header: String = bytes.slice(10 if bytes[6] < 2 else 12, start).get_string_from_ascii()
	var descr: String = RegEx.create_from_string("'descr':\\s*'([^']+)'").search(header).get_string(1)
	var payload: PackedByteArray = bytes.slice(start)
	match descr:
		"<f4":
			return Array(payload.to_float32_array())
		"<f8":
			return Array(payload.to_float64_array())
		"<i4":
			return Array(payload.to_int32_array())
		"<i8":
			return Array(payload.to_int64_array())
		"<i2":
			var out_i16: Array = []
			for k in payload.size() / 2:
				out_i16.append(payload.decode_s16(k * 2))
			return out_i16
		"|u1", "<u1":
			return Array(payload)
	if descr.begins_with("<U"):
		var width: int = int(descr.substr(2)) * 4
		var out: Array = []
		for k in payload.size() / maxi(width, 1):
			# Fixed-width UTF-32: shorter strings are padded with NULs, which must not stay in the name.
			out.append(payload.slice(k * width, (k + 1) * width).get_string_from_utf32().get_slice(char(0), 0))
		return out
	push_error("unsupported dtype %s in %s" % [descr, name])
	return []


func _header_end(bytes: PackedByteArray) -> int:
	if bytes[6] < 2:
		return 10 + bytes.decode_u16(8)
	return 12 + bytes.decode_u32(8)


func _vec3(flat: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(flat.size() / 3)
	for k in out.size():
		out[k] = Vector3(flat[k * 3], flat[k * 3 + 1], flat[k * 3 + 2])
	return out


func _vec2(flat: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(flat.size() / 2)
	for k in out.size():
		out[k] = Vector2(flat[k * 2], flat[k * 2 + 1])
	return out
