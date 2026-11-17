@tool
class_name NpzReader
extends RefCounted

## Reads numpy's .npz archives (a zip of .npy members), the format the character tools write: the bank
## (tools/character/human_bank/pack_human_bank.gd) and the garments (.dsgarment, GarmentImporter).
## Little-endian dtypes only: <f4 <f8 <i4 <i8 <i2 u1 and fixed-width unicode <U.

var _zip: ZIPReader = ZIPReader.new()


func open(path: String) -> Error:
	return _zip.open(ProjectSettings.globalize_path(path) if path.begins_with("res://") else path)


func close() -> void:
	_zip.close()


func has(name: String) -> bool:
	return _zip.file_exists(name + ".npy")


## The raw little-endian payload of an .npy member (no dtype conversion).
func raw(name: String) -> PackedByteArray:
	var bytes: PackedByteArray = _zip.read_file(name + ".npy")
	return bytes.slice(_header_end(bytes))


## An .npy member as a flat Array (numbers or strings).
func array(name: String) -> Array:
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


## A one-string member (a JSON document numpy stored as a 0-d unicode array).
func text(name: String) -> String:
	var values: Array = array(name)
	return str(values[0]) if not values.is_empty() else ""


func vec3(name: String) -> PackedVector3Array:
	var flat: Array = array(name)
	var out := PackedVector3Array()
	out.resize(flat.size() / 3)
	for k in out.size():
		out[k] = Vector3(flat[k * 3], flat[k * 3 + 1], flat[k * 3 + 2])
	return out


func vec2(name: String) -> PackedVector2Array:
	var flat: Array = array(name)
	var out := PackedVector2Array()
	out.resize(flat.size() / 2)
	for k in out.size():
		out[k] = Vector2(flat[k * 2], flat[k * 2 + 1])
	return out


func _header_end(bytes: PackedByteArray) -> int:
	if bytes[6] < 2:
		return 10 + bytes.decode_u16(8)
	return 12 + bytes.decode_u32(8)
