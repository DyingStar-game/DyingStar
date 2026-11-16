extends Node

## Packs the face survey's landmark correspondences (corr.npz, tools/character/face_survey/correspond.py) into the
## game's FaceFitData resource, for fitting a face to photos in the game, with the learned landmarks -> shape map
## (regress.py train-views' model.npz). Run headless:
##   godot --headless --path . res://tools/character/face_survey/pack_face_fit.tscn -- --npz=<corr.npz> [--model=<model.npz>]
##       [--reader=<ava_reader.npz>]  (the slider reader learnt on real faces: ava/ava_learn.py --export)

var _zip := ZIPReader.new()


func _ready() -> void:
	var npz: String = ""
	var model: String = ""
	var reader: String = ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--npz="):
			npz = a.trim_prefix("--npz=")
		elif a.begins_with("--model="):
			model = a.trim_prefix("--model=")
		elif a.begins_with("--reader="):
			reader = a.trim_prefix("--reader=")
	get_tree().quit(_pack(npz, model, reader))


func _pack(path: String, model: String, reader: String = "") -> int:
	if path.is_empty() or _zip.open(path) != OK:
		push_error("cannot open '%s' (--npz=<corr.npz>)" % path)
		return 1
	var data := FaceFitData.new()
	data.vertices = _payload("vertices", "<i4").to_int32_array()
	data.bary = _payload("bary", "<f4").to_float32_array()
	data.valid = _payload("valid", "|b1")
	if data.vertices.size() != FaceFitData.LANDMARKS * 3 or data.valid.size() != FaceFitData.LANDMARKS:
		push_error("unexpected sizes: %d vertices, %d valid" % [data.vertices.size(), data.valid.size()])
		return 1
	_zip.close()
	if not model.is_empty():
		if _zip.open(model) != OK:
			push_error("cannot open '%s' (--model=<model.npz>)" % model)
			return 1
		data.shape_vertices = _payload("vertices", "<i4").to_int32_array()
		data.shape_mean = _floats("mean_shape")
		data.shape_components = _floats("components")
		data.shape_component_std = _floats("coeff_std")
		data.shape_landmarks = _floats("mean_landmarks")
		data.shape_view_turn = _floats("view_turn")
		for mask in _payload("masks", "<i4").to_int32_array():
			data.shape_regressions.append({"mask": mask, "beta": _floats("beta_%d" % mask), "feature_mean": _floats("x_mean_%d" % mask),
					"feature_std": _floats("x_std_%d" % mask), "error": _floats("error_%d" % mask)[0]})
		if not data.has_shape_model():
			push_error("unexpected model sizes: %d vertices, %d components" % [data.shape_vertices.size(), data.shape_components.size()])
			return 1
		print("PACK shape regression: %d vertices, %d components, views %s, %d regressions" % [data.shape_vertices.size(),
				data.components(), data.shape_view_turn, data.shape_regressions.size()])
	if not reader.is_empty():
		if _zip.open(reader) != OK:
			push_error("cannot open '%s' (--reader=<ava_reader.npz>)" % reader)
			return 1
		data.reader_keys = _payload("reader_keys", "|u1").get_string_from_utf8().split("\n")
		var masks: PackedInt32Array = _payload("reader_masks", "<i4").to_int32_array()
		var female: PackedInt32Array = _payload("reader_female", "<i4").to_int32_array()
		for i in masks.size():
			var tag := "%d_%d" % [female[i], masks[i]]
			data.reader_sets.append({"female": female[i] == 1, "mask": masks[i], "mean_landmarks": _floats("mean_landmarks_" + tag),
					"feature_mean": _floats("feature_mean_" + tag), "feature_std": _floats("feature_std_" + tag),
					"beta": _floats("beta_" + tag), "weight_mean": _floats("weight_mean_" + tag)})
		_zip.close()
		print("PACK slider reader: %d sliders, %d sets" % [data.reader_keys.size(), data.reader_sets.size()])
	var err: int = ResourceSaver.save(data, FaceFitData.PATH, ResourceSaver.FLAG_COMPRESS)
	print("PACK face fit: %d landmarks (%d valid) -> %s (%s)" % [FaceFitData.LANDMARKS, data.valid.count(1), FaceFitData.PATH,
			error_string(err)])
	return 0 if err == OK else 1


## A float array of the npz, float64 (numpy's default) or float32, as float32.
func _floats(name: String) -> PackedFloat32Array:
	var bytes: PackedByteArray = _zip.read_file(name + ".npy")
	var wide: bool = bytes.slice(10, 128).get_string_from_ascii().contains("<f8")  # past the magic (it holds a 0)
	var raw: PackedByteArray = _payload(name, "<f8" if wide else "<f4")
	if not wide:
		return raw.to_float32_array()
	var out := PackedFloat32Array()
	var values: PackedFloat64Array = raw.to_float64_array()
	out.resize(values.size())
	for i in values.size():
		out[i] = values[i]
	return out


func _payload(name: String, want: String) -> PackedByteArray:
	var bytes: PackedByteArray = _zip.read_file(name + ".npy")
	var start: int = bytes.decode_u16(8) + 10 if bytes[6] < 2 else bytes.decode_u32(8) + 12
	var header: String = bytes.slice(10 if bytes[6] < 2 else 12, start).get_string_from_ascii()
	var descr: String = RegEx.create_from_string("'descr':\\s*'([^']+)'").search(header).get_string(1)
	if descr != want:
		push_error("%s: expected %s, got %s" % [name, want, descr])
	return bytes.slice(start)
