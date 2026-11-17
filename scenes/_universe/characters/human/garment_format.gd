@tool
class_name GarmentFormat
extends RefCounted

## The garment file, `<id>.dsgarment` (tools/character/garments/garment_bind.py writes it, the Blender add-on
## dyingstar_garments exports it): an npz of a worn asset's arrays (the names and types of the bank's assets)
## plus `meta_json` -- its id, GDD zones / support / layer / access, what it hides, its material, the body it
## was bound to. Its textures lie beside it: `<id>_albedo`, `_normal`, `_ao`, `_tint` (.webp or .png).
##
## The editor imports it into a HumanAssetData (addons/dyingstar/garment_importer.gd): the game loads
## `res://assets/_universe/characters/human/garments/<id>/<id>.dsgarment` like any resource.

const DIR: String = "res://assets/_universe/characters/human/garments"
const EXTENSION: String = "dsgarment"
const FORMAT: int = 1
const TEXTURE_ROLES: PackedStringArray = ["albedo", "normal", "ao", "tint"]
const TEXTURE_EXTENSIONS: PackedStringArray = ["webp", "png"]


static func path_of(id: String) -> String:
	return "%s/%s/%s.%s" % [DIR, id, id, EXTENSION]


## Fills the geometry of [param a] from the npz members named [param prefix] + refs, weights...
static func read_geometry(r: NpzReader, prefix: String, a: HumanAssetData) -> void:
	a.refs = PackedInt32Array(r.array(prefix + "refs"))
	a.weights = PackedFloat32Array(r.array(prefix + "weights"))
	a.offsets = r.vec3(prefix + "offsets")
	a.scale_pairs = PackedInt32Array(r.array(prefix + "scale_pairs"))
	a.scale_ref = PackedFloat32Array(r.array(prefix + "scale_ref"))
	a.vertex = PackedInt32Array(r.array(prefix + "vertex"))
	a.uv = r.vec2(prefix + "uv")
	a.index = PackedInt32Array(r.array(prefix + "index"))
	a.tangent = PackedFloat32Array(r.array(prefix + "tangent"))
	a.bones = r.raw(prefix + "bones")
	a.bone_weights = PackedFloat32Array(r.array(prefix + "bone_weights"))
	a.delete = PackedInt32Array(r.array(prefix + "delete"))


## A garment file as a HumanAssetData (kind "garment", no textures yet), or null (the error is pushed).
## [param meta_out], when given, receives the file's meta (its "textures": the garment whose textures it uses).
static func read(path: String, meta_out: Dictionary = {}) -> HumanAssetData:
	var r := NpzReader.new()
	if r.open(path) != OK:
		push_error("garment: cannot open %s" % path)
		return null
	if not r.has("meta_json"):
		push_error("garment: %s has no meta_json" % path)
		r.close()
		return null
	var meta: Variant = JSON.parse_string(r.text("meta_json"))
	if typeof(meta) != TYPE_DICTIONARY or int(meta.get("format", 0)) > FORMAT:
		push_error("garment: %s is not a garment of format <= %d" % [path, FORMAT])
		r.close()
		return null
	meta_out.merge(meta, true)
	var a := HumanAssetData.new()
	a.kind = &"garment"
	read_geometry(r, "", a)
	r.close()
	a.id = StringName(meta.get("id", path.get_file().get_basename()))
	a.gender = StringName(meta.get("gender", "any"))
	a.zones = PackedStringArray(meta.get("zones", []))
	a.support = int(meta.get("support", 0))
	a.layer = int(meta.get("layer", 1))
	a.access = int(meta.get("access", 1))
	a.hides = PackedStringArray(meta.get("hides", []))
	a.material = StringName(meta.get("material", "cloth"))
	a.body_signature = str(meta.get("body_signature", ""))
	return a


## The texture of [param role] beside a garment file (or beside the garment [param textures_of], whose
## textures it shares), or "" when there is none.
static func texture_path(garment_path: String, role: String, textures_of: String = "") -> String:
	var stem: String = (path_of(textures_of) if textures_of != "" else garment_path).get_basename()
	for ext in TEXTURE_EXTENSIONS:
		var p: String = "%s_%s.%s" % [stem, role, ext]
		if ResourceLoader.exists(p) or FileAccess.file_exists(p):
			return p
	return ""


## The body's identity, as tools/character/garments/garment_bind.body_signature computes it: the compact
## vertices (float32) and the welded triangles (int32), SHA-1.
static func bank_signature(bank: HumanBank) -> String:
	var positions := PackedFloat32Array()
	positions.resize(bank.base.size() * 3)
	for i in bank.base.size():
		positions[i * 3] = bank.base[i].x
		positions[i * 3 + 1] = bank.base[i].y
		positions[i * 3 + 2] = bank.base[i].z
	var tris := PackedInt32Array()
	tris.resize(bank.body_index.size())
	for z in bank.zone_names.size():
		for k in range(bank.zone_index_ptr[z], bank.zone_index_ptr[z + 1]):
			tris[k] = bank.body_vertex[bank.body_index[k] + bank.zone_vertex_ptr[z]]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(positions.to_byte_array())
	ctx.update(tris.to_byte_array())
	return "v1-%d-%s" % [bank.base.size(), ctx.finish().hex_encode().substr(0, 16)]
