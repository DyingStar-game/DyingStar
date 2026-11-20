@tool
class_name NovaBody
extends RefCounted
## Nova for ONE body: its variants (found in the QGIS export), their settings through live
## inheritance, the ids the terrain bakes into its vertices, and the GPU data the ground shader reads.
##
## Variants. A variant is a biome_type plus the zone's DISCRETE (text) attributes — rock_type, clarity…
## Numeric attributes (density, depth) never split a biome into variants. Ids: 1 is the body's ground
## outside any zone ("_default"), then 2… in the sorted order of the variant keys found in the export, so an
## id only changes when the regions are re-exported, which already re-keys the chunk cache.
##
## Settings. Resolution walks variant → body biome → archetype → NovaSchema default (see chain_paths).
## Editing a ground setting rewrites a small parameter texture: no chunk is rebuilt.

## Root of every Nova file.
const ROOT := "res://nova"
## Key and file stem of the body's ground outside any zone.
const DEFAULT_KEY := "_default"
## Zone fields that are never a variant axis.
const NOT_AXES := ["name", "color_hex", "biome_type", "biome_index", "coverage", "polygon", "vertices", "lon", "lat"]
## Bump when what a chunk bakes for Nova changes (vertex channels, routing).
const BAKE_VERSION := 5
## Columns of the parameter texture, one RGBA float texel each (see terrain_biome.gdshader, nova_*).
const PARAM_COLUMNS := 8
## The settings that name an albedo texture, and those that name a normal map: one array of each for all.
const ALBEDO_KEYS: Array[String] = ["ground/albedo_texture", "ground/layer2_albedo", "ground/layer3_albedo"]
const NORMAL_KEYS: Array[String] = ["ground/normal_texture", "ground/layer2_normal", "ground/layer3_normal"]
## And those that name an occlusion / roughness / height image (R, G, B).
const ORH_KEYS: Array[String] = ["ground/orh_texture", "ground/layer2_orh", "ground/layer3_orh"]
## Side of every layer of the texture arrays, pixels.
const TEX_SIZE := 1024
## Pack levels read by discover stop past this many tiles (tarsis_3: levels 1 to 16, about 60 ms).
const DISCOVER_MAX_TILES := 4096

## The body ("tarsis_3").
var planet_name := ""
## Variants, index = id - 1: {id, key, biome_type, attrs, slug, label}.
var variants: Array[Dictionary] = []
## The material Nova chunks use: the body's terrain material plus Nova uniforms.
var material: ShaderMaterial

var _id_by_key: Dictionary = {}
var _profiles: Dictionary = {}  # path → NovaProfile, loaded or created on demand
## Guards _profiles: the scatter's models are read on a worker (PlanetTerrain) while the dock resolves.
var _profiles_mutex := Mutex.new()
## Variants already read from a pack in this process, by the pack's path, date and size: reading them is
## 0.4 s on tarsis_3, and the dock and the terrain both ask when a body opens.
static var _discovered: Dictionary = {}
## Variant id → [min, max, wavelength] of the relief its profile sets, read once on the main thread
## ([method fingerprint]); a variant that sets none is absent.
var _relief: Dictionary = {}
var _relief_read := false
## Variant id → the width of its transitions, metres (read with the reliefs).
var _transition: Dictionary = {}
var _transition_max := 0.0
## Variant id → the biome's definition with that relief, made on first use by a chunk builder (any thread).
var _relief_biomes: Dictionary = {}
var _relief_mutex := Mutex.new()
var _params_img: Image
var _params_tex: ImageTexture
var _albedo_paths := PackedStringArray()
var _normal_paths := PackedStringArray()
var _orh_paths := PackedStringArray()


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

## Folder of a body's files.
static func body_dir(body: String) -> String:
	return ROOT.path_join("bodies").path_join(body)


## The file whose existence turns Nova on for [param body].
static func enable_path(body: String) -> String:
	return body_dir(body).path_join(DEFAULT_KEY + ".tres")


## Nova set aside for every body built from now on: the game as it is without it. The game view's
## "before / after" key (nova_world.gd); never set in the editor.
static var disabled := false


## True when [param body] has Nova data (its terrain then uses it).
static func is_enabled_for(body: String) -> bool:
	return not disabled and body != "" and ResourceLoader.exists(enable_path(body))


## Archetype file of a biome type ("_default" for the ground outside zones).
static func archetype_path(biome_type: String) -> String:
	return ROOT.path_join("archetypes").path_join(_file_stem(biome_type) + ".tres")


## The body's own file of a biome type.
static func body_biome_path(body: String, biome_type: String) -> String:
	return body_dir(body).path_join(_file_stem(biome_type) + ".tres")


## The file of [param variant] on [param body]; the body biome file when the variant has no attribute.
static func variant_path(body: String, variant: Dictionary) -> String:
	if variant.key == DEFAULT_KEY:
		return enable_path(body)
	if str(variant.slug) == "":
		return body_biome_path(body, variant.biome_type)
	return body_dir(body).path_join(_file_stem(variant.biome_type)).path_join(str(variant.slug) + ".tres")


## Files that set [param variant]'s values, most specific first.
static func chain_paths(body: String, variant: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if variant.key == DEFAULT_KEY:
		out.append(enable_path(body))
		out.append(archetype_path(DEFAULT_KEY))
		return out
	var vp := variant_path(body, variant)
	out.append(vp)
	var bp := body_biome_path(body, variant.biome_type)
	if bp != vp:
		out.append(bp)
	out.append(archetype_path(variant.biome_type))
	return out


static func _file_stem(s: String) -> String:
	return "_none" if s == "" else s.validate_filename()


# ---------------------------------------------------------------------------
# Variants
# ---------------------------------------------------------------------------

## The discrete attributes of a populate zone: text fields that are not identity or geometry.
static func attrs_of(zone: Dictionary) -> Dictionary:
	var out := {}
	for k in zone.keys():
		var ks := str(k)
		if ks.begins_with("_") or NOT_AXES.has(ks):
			continue
		if typeof(zone[k]) == TYPE_STRING and str(zone[k]) != "":
			out[ks] = str(zone[k])
	return out


## Variant key of a zone: "outcrop-plateau|clarity=milky|rock_type=corundum_red".
static func zone_key(zone: Dictionary) -> String:
	if zone.is_empty():
		return DEFAULT_KEY
	var attrs := attrs_of(zone)
	var names := attrs.keys()
	names.sort()
	var key := str(zone.get("biome_type", ""))
	for n in names:
		key += "|%s=%s" % [n, attrs[n]]
	return key


## File-name slug of a variant's attributes: "clarity-milky__rock_type-corundum_red".
static func slug_of(attrs: Dictionary) -> String:
	var names := attrs.keys()
	names.sort()
	var parts := PackedStringArray()
	for n in names:
		parts.append(("%s-%s" % [n, attrs[n]]).validate_filename())
	return "__".join(parts)


## Every variant found in a modifier pack, sorted by key, the "_default" ground first. Ids are 1-based
## positions. The coarse levels are read: the coarsest alone is not enough, a small zone can vanish from it.
## Of a streamed pack, the levels that arrive whole (its floor: every client and the server hold the same);
## of a pack on disk, the levels until one holds more than [constant DISCOVER_MAX_TILES] tiles. A null
## pack (no tile service) gives the "_default" ground alone.
static func discover(pack: ModifierPack) -> Array[Dictionary]:
	var known := pack.get_path() if pack != null else ""
	if not _discovered.has(known):
		_discovered[known] = _read_variants(pack)
	var out: Array[Dictionary] = []
	for v: Dictionary in _discovered[known]:
		out.append(v.duplicate(true))
	return out


static func _read_variants(pack: ModifierPack) -> Array[Dictionary]:
	var keys := {}
	if pack != null:
		var floor_max := (pack as RemoteModifierPack).source.floor_nside_max if pack is RemoteModifierPack else 0
		for level in pack.get_levels():
			if floor_max > 0 and int(level) > floor_max:
				break
			var tiles := pack.get_tile_ipix(int(level))
			if floor_max == 0 and tiles.size() > DISCOVER_MAX_TILES and not keys.is_empty():
				break
			for ipix in tiles:
				var tile := pack.decode_tile(pack.read_tile(int(level), ipix), 0.0, ModifierPack.MASK_POPULATE)
				for zone: Dictionary in tile.get("populate_zones", []):
					var k := zone_key(zone)
					if not keys.has(k):
						keys[k] = zone
	var sorted := keys.keys()
	sorted.sort()
	var out: Array[Dictionary] = [_variant(1, DEFAULT_KEY, {})]
	for k in sorted:
		out.append(_variant(out.size() + 1, k, keys[k]))
	return out


static func _variant(id: int, key: String, zone: Dictionary) -> Dictionary:
	if key == DEFAULT_KEY:
		return {"id": id, "key": key, "biome_type": "", "attrs": {}, "slug": "", "label": "Sol hors zone"}
	var attrs := attrs_of(zone)
	var bt := str(zone.get("biome_type", ""))
	# What tells the variants of a biome apart comes first, the rock before the rest: "corundum red, milky".
	var names := attrs.keys()
	names.sort()
	if names.has("rock_type"):
		names.erase("rock_type")
		names.push_front("rock_type")
	var vals := PackedStringArray()
	for n in names:
		vals.append(str(attrs[n]).replace("_", " "))
	var label := bt if bt != "" else "(zone sans biome)"
	if not vals.is_empty():
		label = "%s — %s" % [", ".join(vals), label]
	return {"id": id, "key": key, "biome_type": bt, "attrs": attrs, "slug": slug_of(attrs), "label": label}


## The modifier pack of [param body] ("tarsis_3"): streamed from the tile service, as the terrain reads it
## (RemoteModifierPack). Null when no service serves it.
static func pack_for(body: String) -> ModifierPack:
	return RemoteModifierPack.shared_for(body)


## A body with the variants of its modifier pack.
static func open_body(body: String) -> NovaBody:
	var b := NovaBody.new()
	b.planet_name = body
	b.variants = discover(pack_for(body))
	for v in b.variants:
		b._id_by_key[v.key] = v.id
	return b


## Id baked for a vertex whose first zone is [param zone] (empty = no zone). Thread-safe (read-only).
func variant_id_for_zone(zone: Dictionary) -> int:
	return int(_id_by_key.get(zone_key(zone), 1))


## The variant of id [param id] ({} when out of range).
func variant(id: int) -> Dictionary:
	return variants[id - 1] if id >= 1 and id <= variants.size() else {}


## The rock (rocks.json slug) of variant [param id]'s ground, "" when it has none: its rock_type, or
## [param default_rock] for the ground outside any zone. The one answer for the ground's tint at a
## frontier, the scattered rocks' colour and the dock's map.
func rock_of(id: int, default_rock := "") -> String:
	var v := variant(id)
	if v.is_empty():
		return ""
	return default_rock if v.key == DEFAULT_KEY else str((v.attrs as Dictionary).get("rock_type", ""))


## What the chunk cache folds into its key: the variant ids, how they are baked, and the settings a chunk
## bakes into its mesh (relief, transition width). Main thread, before any chunk is built: it reads the
## settings the builders will ask for from their threads.
func fingerprint() -> String:
	var keys := PackedStringArray()
	for v in variants:
		keys.append(v.key)
	_read_baked()
	for id: int in _relief:
		keys.append("relief %d %s" % [id, _relief[id]])
	for id: int in _transition:
		keys.append("transition %d %s" % [id, _transition[id]])
	return ("v%d|%s" % [BAKE_VERSION, "\n".join(keys)]).md5_text().substr(0, 12)


func _read_baked() -> void:
	_relief.clear()
	_transition.clear()
	_transition_max = 0.0
	for v in variants:
		var low := float(resolve(v.id, "ground/relief_min_m"))
		var high := float(resolve(v.id, "ground/relief_max_m"))
		if high > low:
			_relief[v.id] = [low, high, float(resolve(v.id, "ground/relief_wavelength_m"))]
		_transition[v.id] = float(resolve(v.id, "ground/transition_m"))
		_transition_max = maxf(_transition_max, _transition[v.id])
	_relief_read = true


## How wide the ground of variant [param id] blends into its neighbours, metres (0 before
## [method fingerprint] ran). Thread-safe (read-only).
func transition_m(id: int) -> float:
	return float(_transition.get(id, 0.0))


## The widest transition of the body's variants, metres.
func max_transition_m() -> float:
	return _transition_max


## The definition whose relief [param zone]'s ground follows: [param bd] (its biome's), or a copy of it
## with the relief the zone's variant sets in Nova. One copy per variant, so the chunk builders can tell
## two reliefs of one biome apart by the definition they hold. Thread-safe once [method fingerprint] ran.
func relief_biome(zone: Dictionary, bd: BiomeDefinition) -> BiomeDefinition:
	if bd == null or not _relief_read:
		return bd
	var id := variant_id_for_zone(zone)
	if not _relief.has(id):
		return bd
	_relief_mutex.lock()
	var custom: BiomeDefinition = _relief_biomes.get(id)
	if custom == null:
		var set: Array = _relief[id]
		custom = bd.duplicate()
		custom.relief_min_m = set[0]
		custom.relief_max_m = set[1]
		if float(set[2]) > 0.0:
			custom.relief_wavelength_m = set[2]
		_relief_biomes[id] = custom
	_relief_mutex.unlock()
	return custom


# ---------------------------------------------------------------------------
# Settings (live inheritance)
# ---------------------------------------------------------------------------

## The profile stored at [param path], or null when the file does not exist (and was not created here).
func profile_at(path: String) -> NovaProfile:
	_profiles_mutex.lock()
	if not _profiles.has(path):
		var p: NovaProfile = null
		if ResourceLoader.exists(path):
			p = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as NovaProfile
		_profiles[path] = p  # null too: a missing file is asked for once, not at every resolve
	var found: NovaProfile = _profiles[path]
	_profiles_mutex.unlock()
	return found


## The profile at [param path], created in memory when missing (saved by save_profile).
func profile_for_edit(path: String) -> NovaProfile:
	var p := profile_at(path)
	if p == null:
		p = NovaProfile.new()
		_profiles_mutex.lock()
		_profiles[path] = p
		_profiles_mutex.unlock()
	return p


## Writes the profile at [param path] to disk (creating its folder).
func save_profile(path: String) -> Error:
	var p := profile_at(path)
	if p == null:
		return ERR_DOES_NOT_EXIST
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	return ResourceSaver.save(p, path)


## Resolved value of [param key] for variant [param id].
func resolve(id: int, key: String) -> Variant:
	var path := origin_of(id, key)
	return profile_at(path).own(key) if path != "" else NovaSchema.default_of(key)


## Where [param key] of variant [param id] comes from: the file that sets it, or "" for the default.
func origin_of(id: int, key: String) -> String:
	var v := variant(id)
	if v.is_empty():
		return ""
	for path in chain_paths(planet_name, v):
		var p := profile_at(path)
		if p != null and p.has_own(key):
			return path
	return ""


# ---------------------------------------------------------------------------
# GPU data
# ---------------------------------------------------------------------------

## Nova's material built on the body's terrain material [param base] (a terrain_biome ShaderMaterial).
func build_material(base: Material) -> ShaderMaterial:
	if base is ShaderMaterial:
		material = (base as ShaderMaterial).duplicate() as ShaderMaterial
	else:
		material = ShaderMaterial.new()
		material.shader = load("res://assets/_universe/environment/terrain/terrain_biome.gdshader")
	material.set_shader_parameter("nova_on", true)
	refresh_textures()
	refresh_ground()
	return material


## Rewrites the parameter texture from the resolved settings: the ground shows it at once.
func refresh_ground() -> void:
	if material == null:
		return
	var albedo := _texture_paths(ALBEDO_KEYS)
	var normal := _texture_paths(NORMAL_KEYS)
	if albedo != _albedo_paths or normal != _normal_paths or _texture_paths(ORH_KEYS) != _orh_paths:
		refresh_textures()
	var rows := variants.size() + 1
	if _params_img == null or _params_img.get_height() != rows:
		_params_img = Image.create(PARAM_COLUMNS, rows, false, Image.FORMAT_RGBAF)
		_params_tex = null
	for v in variants:
		var id: int = v.id
		var a_layer := _albedo_paths.find(str(resolve(id, "ground/albedo_texture")))
		var n_layer := _normal_paths.find(str(resolve(id, "ground/normal_texture")))
		_params_img.set_pixel(0, id, Color(a_layer, n_layer,
				float(resolve(id, "ground/tile_m")), float(resolve(id, "ground/texture_strength"))))
		_params_img.set_pixel(1, id, Color(float(resolve(id, "ground/texture_gain")),
				float(resolve(id, "ground/normal_strength")), float(resolve(id, "ground/roughness")),
				float(resolve(id, "ground/blend_sharpness"))))
		# The fourth number: the layer of the occlusion / roughness / height image, -1 without one.
		_params_img.set_pixel(2, id, Color(float(resolve(id, "ground/macro_strength")),
				float(resolve(id, "ground/macro_size_m")), float(resolve(id, "ground/anti_tiling")),
				_orh_paths.find(str(resolve(id, "ground/orh_texture")))))
		# The second and third materials, two columns each (the shader reads both with one loop): its layers,
		# its tile, its share of the ground; then its patches, its gain and its occlusion image. The last
		# number is the ground's own: its close-up tile beside the second, its hex tiling beside the third.
		for k in 2:
			var layer := "ground/layer%d_" % (k + 2)
			_params_img.set_pixel(3 + 2 * k, id, Color(_albedo_paths.find(str(resolve(id, layer + "albedo"))),
					_normal_paths.find(str(resolve(id, layer + "normal"))),
					float(resolve(id, layer + "tile_m")), float(resolve(id, layer + "share"))))
			_params_img.set_pixel(4 + 2 * k, id, Color(float(resolve(id, layer + "patch_m")),
					float(resolve(id, layer + "gain")), _orh_paths.find(str(resolve(id, layer + "orh"))),
					float(resolve(id, "ground/detail_tile_m")) if k == 0
					else (1.0 if bool(resolve(id, "ground/hex_tiling")) else 0.0)))
		# The depth of the steep parallax, in metres.
		_params_img.set_pixel(7, id, Color(float(resolve(id, "ground/parallax_cm")) * 0.01, 0.0, 0.0, 0.0))
	if _params_tex == null:
		_params_tex = ImageTexture.create_from_image(_params_img)
		material.set_shader_parameter("nova_params", _params_tex)
	else:
		_params_tex.update(_params_img)


## Rebuilds the albedo and normal texture arrays from the textures the variants name.
func refresh_textures() -> void:
	if material == null:
		return
	_albedo_paths = _texture_paths(ALBEDO_KEYS)
	_normal_paths = _texture_paths(NORMAL_KEYS)
	_orh_paths = _texture_paths(ORH_KEYS)
	material.set_shader_parameter("nova_orh", _texture_array(_orh_paths, Color(1.0, 0.9, 0.5)))
	material.set_shader_parameter("nova_albedo", _texture_array(_albedo_paths, Color(0.5, 0.5, 0.5)))
	material.set_shader_parameter("nova_normal", _texture_array(_normal_paths, Color(0.5, 0.5, 1.0)))


func _texture_paths(keys: Array[String]) -> PackedStringArray:
	var out := PackedStringArray()
	for v in variants:
		for key in keys:
			var p := str(resolve(v.id, key))
			if p != "" and not out.has(p) and ResourceLoader.exists(p):
				out.append(p)
	return out


static func _texture_array(paths: PackedStringArray, fallback: Color) -> Texture2DArray:
	var images: Array[Image] = []
	for p in paths:
		images.append(_layer_image(p, fallback))
	if images.is_empty():
		images.append(_flat_image(fallback))
	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	return arr


static func _layer_image(path: String, fallback: Color) -> Image:
	var tex := load(path) as Texture2D
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		return _flat_image(fallback)
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != TEX_SIZE or img.get_height() != TEX_SIZE:
		img.resize(TEX_SIZE, TEX_SIZE, Image.INTERPOLATE_CUBIC)
	img.generate_mipmaps()
	return img


static func _flat_image(c: Color) -> Image:
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(c)
	img.generate_mipmaps()
	return img
