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
## The ground shader with Nova's code compiled in (terrain_biome.gdshader leaves it out, for every other body).
const NOVA_SHADER := "res://assets/_universe/environment/terrain/terrain_biome_nova.gdshader"
## The settings that name an albedo texture, and those that name a normal map: one array of each for all.
const ALBEDO_KEYS: Array[String] = ["ground/albedo_texture", "ground/layer2_albedo", "ground/layer3_albedo"]
const NORMAL_KEYS: Array[String] = ["ground/normal_texture", "ground/layer2_normal", "ground/layer3_normal"]
## And those that name an occlusion / roughness / height image (R, G, B).
const ORH_KEYS: Array[String] = ["ground/orh_texture", "ground/layer2_orh", "ground/layer3_orh"]
## Side of every layer of the texture arrays, pixels.
const TEX_SIZE := 1024
## Pack levels read by discover stop past this many tiles (tarsis_3: levels 1 to 16, about 60 ms).
const DISCOVER_MAX_TILES := 4096
## Bump when what _read_variants keeps per key changes (see zones_cache_path).
const ZONES_FORMAT := 1

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
## The worker making the texture arrays in the game (_refresh_textures_later), -1 when none.
var _textures_task := -1
var _params_img: Image
var _params_tex: ImageTexture
var _albedo_paths := PackedStringArray()
var _normal_paths := PackedStringArray()
var _orh_paths := PackedStringArray()
## Variant id → its ground_look, read once (cleared by refresh_ground); guarded: the scatter reads it on a worker.
var _looks: Dictionary = {}
var _looks_mutex := Mutex.new()
## Mean colour of a texture, linear (an albedo) or raw (a data image), by "instance id|srgb" (texture_mean).
static var _means: Dictionary = {}
static var _means_mutex := Mutex.new()

## The ground shader's constants the ground's look is read with (terrain_biome.gdshaderinc, NOVA_*): the tiling
## grid, the occlusion's weight, where the close-up tile shows (in times its own length), the patches' rim.
const WRAP := 8192.0
const AO_WEIGHT := 0.85
const DETAIL_NEAR := 5.0
const DETAIL_FAR := 18.0
const PATCH_RIM := 0.07
## Cells a side a texture is brought down to before its mean is taken (texture_mean).
const MEAN_SIDE := 32


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
	var keys: Dictionary = {}
	var cache := zones_cache_path(pack)
	var cached: Variant = read_zones(cache) if cache != "" else null
	if cached != null:
		keys = cached
	elif pack != null:
		var complete := true
		var floor_max := (pack as RemoteModifierPack).source.floor_nside_max if pack is RemoteModifierPack else 0
		for level in pack.get_levels():
			if floor_max > 0 and int(level) > floor_max:
				break
			var tiles := pack.get_tile_ipix(int(level))
			if floor_max == 0 and tiles.size() > DISCOVER_MAX_TILES and not keys.is_empty():
				break
			for ipix in tiles:
				var bytes := pack.read_tile(int(level), ipix)
				complete = complete and not bytes.is_empty()
				var tile := pack.decode_tile(bytes, 0.0, ModifierPack.MASK_POPULATE)
				for zone: Dictionary in tile.get("populate_zones", []):
					var k := zone_key(zone)
					if not keys.has(k):
						keys[k] = zone
		if cache != "" and complete:
			write_zones(cache, keys)
	var sorted := keys.keys()
	sorted.sort()
	var out: Array[Dictionary] = [_variant(1, DEFAULT_KEY, {})]
	for k in sorted:
		out.append(_variant(out.size() + 1, k, keys[k]))
	return out


## Where the zones a streamed pack's floor holds are kept once read, beside its tiles: decoding the 3890 tiles
## of tarsis_3's floor again was 2.5 s on the main thread at every arrival on the planet (2026-11-24). A
## version is immutable, and its folder goes with it when the version changes. "" for a pack on disk.
static func zones_cache_path(pack: ModifierPack) -> String:
	if not pack is RemoteModifierPack:
		return ""
	var src: RemoteTileSource = (pack as RemoteModifierPack).source
	if src == null or src.floor_nside_max <= 0 or src.version == "":
		return ""
	# Not .bin: the tile cache's eviction counts every .bin of the folder as a tile.
	return "%s%s/%s/nova_zones.var" % [src.cache_root, src.planet, src.version]


## The zones written at [param path] (zone key -> zone), or null when there are none or they are not of
## this format.
static func read_zones(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var held: Variant = bytes_to_var(FileAccess.get_file_as_bytes(path))
	if not held is Dictionary or int((held as Dictionary).get("format", 0)) != ZONES_FORMAT \
			or not (held as Dictionary).get("zones") is Dictionary:
		return null
	return (held as Dictionary)["zones"]


static func write_zones(path: String, zones: Dictionary) -> void:
	AtomicFile.write_buffer(path, var_to_bytes({"format": ZONES_FORMAT, "zones": zones}))


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
		var rel: Array = _relief[id]
		custom = bd.duplicate()
		custom.relief_min_m = rel[0]
		custom.relief_max_m = rel[1]
		if float(rel[2]) > 0.0:
			custom.relief_wavelength_m = rel[2]
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
# The ground's look (what the ground fringe, the blown dust and the rocks' foot copy)
# ---------------------------------------------------------------------------

## What the ground of variant [param id] is drawn with, read from the settings refresh_ground hands the ground
## shader: {} when the variant names no albedo texture (its ground then keeps the terrain's own look, the detail
## layer of terrain_biome). Else {id, layers, fine_scale, fine_near, fine_far, strength, contrast, macro_strength,
## macro_scale}. [code]layers[/code]: the ground's material first, then its second and third when they load and
## cover a share, each {tex, orh (null without one), scale (per metre, snapped like the shader's), share,
## patch_scale, offset (the noise offset of its patches: 0 for the second, 1 for the third), gain}. The close-up
## tile (fine_*) is the first material's only, as in the shader. Thread-safe.
func ground_look(id: int) -> Dictionary:
	_looks_mutex.lock()
	var known: Variant = _looks.get(id)
	_looks_mutex.unlock()
	if known != null:
		return known
	var look := _read_look(id)
	_looks_mutex.lock()
	_looks[id] = look
	_looks_mutex.unlock()
	return look


func _read_look(id: int) -> Dictionary:
	var base := _texture_at(id, "ground/albedo_texture")
	if base == null:
		return {}
	var layers: Array = [{"tex": base, "orh": _texture_at(id, "ground/orh_texture"),
			"scale": snap_scale(1.0 / maxf(float(resolve(id, "ground/tile_m")), 0.01)), "share": 1.0,
			"patch_scale": 0.0, "offset": -1, "gain": float(resolve(id, "ground/texture_gain"))}]
	for k in 2:
		var key := "ground/layer%d_" % (k + 2)
		var tex := _texture_at(id, key + "albedo")
		var share := float(resolve(id, key + "share"))
		if tex == null or share <= 0.0:
			continue
		layers.append({"tex": tex, "orh": _texture_at(id, key + "orh"),
				"scale": snap_scale(1.0 / maxf(float(resolve(id, key + "tile_m")), 0.01)), "share": share,
				"patch_scale": snap_scale(1.0 / maxf(float(resolve(id, key + "patch_m")), 1.0)), "offset": k,
				"gain": float(resolve(id, key + "gain"))})
	var fine_tile := float(resolve(id, "ground/detail_tile_m"))
	return {
		"id": id,
		"layers": layers,
		"fine_scale": snap_scale(1.0 / maxf(fine_tile, 0.05)) if fine_tile > 0.0 else 0.0,
		"fine_near": fine_tile * DETAIL_NEAR,
		"fine_far": fine_tile * DETAIL_FAR,
		"strength": float(resolve(id, "ground/texture_strength")),
		"contrast": float(resolve(id, "ground/texture_contrast")),
		"macro_strength": float(resolve(id, "ground/macro_strength")),
		"macro_scale": snap_scale(1.0 / maxf(float(resolve(id, "ground/macro_size_m")), 1.0)),
	}


## The texture variant [param id] names at [param key], null when it names none or the file is gone (the ground
## shader then leaves that material out: refresh_ground finds no layer for it).
func _texture_at(id: int, key: String) -> Texture2D:
	var path := str(resolve(id, key))
	return load(path) as Texture2D if path != "" and ResourceLoader.exists(path) else null


## The colour the ground shader starts from for the vertex colour [param vertex]: mix(base_color, COLOR,
## vertex_color_strength) × albedo_multiplier, read off the body's material (the terrain's defaults without one).
func biome_tint(vertex: Color) -> Color:
	var base := Color(0.45, 0.35, 0.25)
	var strength := 1.0
	var mult := 0.4
	if material != null:
		var b: Variant = material.get_shader_parameter(&"base_color")
		var s: Variant = material.get_shader_parameter(&"vertex_color_strength")
		var m: Variant = material.get_shader_parameter(&"albedo_multiplier")
		base = b if b is Color else base
		strength = float(s) if s != null else strength
		mult = float(m) if m != null else mult
	# base_color is a source_color uniform (decoded); the vertex colour is read as it is.
	var c := base.srgb_to_linear().lerp(vertex, clampf(strength, 0.0, 1.0))
	return Color(c.r * mult, c.g * mult, c.b * mult)


## How much of each of [param look]'s layers covers the ground at [param pos] (a point of the ground in the
## body's frame, metres), as the ground shader lays its patches there: the same noise, at the same place (its
## texture position is the body's frame wrapped every WRAP metres), the same rim. Without a position, the share
## each covers on the whole. The shader also lets a patch fill the hollows of the ground's own image first,
## which is not known here: near a rim the answer may be the other side's.
static func layer_weights(look: Dictionary, pos: Variant = null) -> PackedFloat32Array:
	var layers: Array = look.get("layers", [])
	var w := PackedFloat32Array()
	w.resize(layers.size())
	if w.is_empty():
		return w
	w[0] = 1.0
	var p := wrapped(pos) if pos is Vector3 else Vector3.ZERO
	for i in range(1, layers.size()):
		var l: Dictionary = layers[i]
		var share := clampf(float(l.share), 0.0, 1.0)
		var over := share
		if pos is Vector3:
			var sp := float(l.patch_scale)
			var off := Vector3(17.0, 31.0, 5.0) * float(l.offset)
			var where := noise(p * sp + off, WRAP * sp) * 0.65 + noise(p * sp * 2.0 + off, WRAP * sp * 2.0) * 0.35
			where = clampf((where - 0.5) * 1.8 + 0.5, 0.0, 1.0)
			over = smoothstep(1.0 - share - PATCH_RIM, 1.0 - share + PATCH_RIM, where)
		# Laid one over the other, as the shader mixes them: what lies under keeps the rest.
		for j in i:
			w[j] *= 1.0 - over
		w[i] = over
	return w


## The index of the layer covering most of [param weights] (layer_weights).
static func main_layer(weights: PackedFloat32Array) -> int:
	var best := 0
	for i in weights.size():
		if weights[i] > weights[best]:
			best = i
	return best


## The large-scale light and dark of [param look]'s ground at [param pos] (the body's frame, metres), the factor
## the shader multiplies it by: 1 without a position or without that variation.
static func macro_factor(look: Dictionary, pos: Variant = null) -> float:
	var strength := float(look.get("macro_strength", 0.0))
	if strength <= 0.0 or not pos is Vector3:
		return 1.0
	var p := wrapped(pos)
	var sm := float(look.macro_scale)
	var m := noise(p * sm, WRAP * sm) * 0.65 + noise(p * sm * 2.0, WRAP * sm * 2.0) * 0.35
	return 1.0 + (m - 0.5) * 2.0 * strength


## What layer [param i] of [param look] multiplies the biome tint by, on average: mix(1, texture × gain,
## strength) × mix(1, occlusion, AO_WEIGHT), read off the means of its images (the contrast keeps the mean).
static func layer_factor(look: Dictionary, i: int) -> Color:
	var l: Dictionary = look.layers[i]
	var mean := texture_mean(l.tex, true)
	var g := float(l.gain)
	var c := Color.WHITE.lerp(Color(mean.r * g, mean.g * g, mean.b * g), clampf(float(look.strength), 0.0, 1.0))
	var ao := ao_factor(l)
	return Color(c.r * ao, c.g * ao, c.b * ao)


## mix(1, the occlusion image's mean, AO_WEIGHT): what a layer's hollows darken it by on average; 1 without one.
static func ao_factor(layer: Dictionary) -> float:
	var orh: Texture2D = layer.get("orh")
	return lerpf(1.0, texture_mean(orh, false).r, AO_WEIGHT) if orh != null else 1.0


## The colour [param look]'s ground shows under the biome tint [param tint] (biome_tint), its layers weighed by
## [param weights] (layer_weights), times [param macro] (macro_factor): the shader's ALBEDO on average.
static func shown_colour(look: Dictionary, tint: Color, weights: PackedFloat32Array, macro: float = 1.0) -> Color:
	var sum := Color(0, 0, 0)
	for i in mini(weights.size(), (look.get("layers", []) as Array).size()):
		var f := layer_factor(look, i)
		sum += Color(f.r * weights[i], f.g * weights[i], f.b * weights[i])
	return Color(clampf(tint.r * sum.r * macro, 0.0, 1.0), clampf(tint.g * sum.g * macro, 0.0, 1.0),
			clampf(tint.b * sum.b * macro, 0.0, 1.0))


## The mean colour of [param tex], read once: linear when [param srgb] (an albedo, which the shader decodes before
## averaging), the raw numbers otherwise (an occlusion / roughness / height image). White when its pixels cannot
## be read (no renderer). Any thread.
static func texture_mean(tex: Texture2D, srgb: bool) -> Color:
	if tex == null:
		return Color.WHITE
	var key := "%d|%s" % [tex.get_instance_id(), srgb]
	_means_mutex.lock()
	var known: Variant = _means.get(key)
	_means_mutex.unlock()
	if known != null:
		return known
	var mean := Color.WHITE
	var img: Image = tex.get_image()
	if img != null and not img.is_empty():
		img = img.duplicate() as Image  # the texture's own image is left as it is
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
		# Brought down to MEAN_SIDE² cells first (trilinear: each cell the average of its block), then decoded
		# cell by cell before the last average, as the GPU decodes before it blends: the mean of a contrasted
		# albedo is darker decoded than encoded. Texel by texel was 4 million reads for a 2048 px texture.
		img.resize(MEAN_SIDE, MEAN_SIDE, Image.INTERPOLATE_TRILINEAR)
		var sum := Color(0, 0, 0)
		for y in MEAN_SIDE:
			for x in MEAN_SIDE:
				var c := img.get_pixel(x, y)
				sum += c.srgb_to_linear() if srgb else c
		mean = Color(sum.r / (MEAN_SIDE * MEAN_SIDE), sum.g / (MEAN_SIDE * MEAN_SIDE), sum.b / (MEAN_SIDE * MEAN_SIDE))
	_means_mutex.lock()
	_means[key] = mean
	_means_mutex.unlock()
	return mean


## A tiling scale snapped to the seamless grid, as the ground shader's snap_scale.
static func snap_scale(raw: float) -> float:
	return maxf(roundf(raw * WRAP), 1.0) / WRAP


## [param pos] (the body's frame) where the ground shader reads its textures and noises: wrapped every WRAP metres,
## like its texture position (chunk_origin_mod + the vertex), whose patterns repeat on that period.
static func wrapped(pos: Vector3) -> Vector3:
	return Vector3(fposmod(pos.x, WRAP), fposmod(pos.y, WRAP), fposmod(pos.z, WRAP))


## The ground shader's value noise (nova_noise): [param x] in lattice cells, wrapping every [param period] cells.
static func noise(x: Vector3, period: float) -> float:
	var i := x.floor()
	var f := x - i
	f = f * f * (Vector3(3.0, 3.0, 3.0) - 2.0 * f)
	var n000 := _hash(_wrap_cell(i, period))
	var n100 := _hash(_wrap_cell(i + Vector3(1, 0, 0), period))
	var n010 := _hash(_wrap_cell(i + Vector3(0, 1, 0), period))
	var n110 := _hash(_wrap_cell(i + Vector3(1, 1, 0), period))
	var n001 := _hash(_wrap_cell(i + Vector3(0, 0, 1), period))
	var n101 := _hash(_wrap_cell(i + Vector3(1, 0, 1), period))
	var n011 := _hash(_wrap_cell(i + Vector3(0, 1, 1), period))
	var n111 := _hash(_wrap_cell(i + Vector3(1, 1, 1), period))
	return lerpf(lerpf(lerpf(n000, n100, f.x), lerpf(n010, n110, f.x), f.y),
			lerpf(lerpf(n001, n101, f.x), lerpf(n011, n111, f.x), f.y), f.z)


static func _wrap_cell(c: Vector3, period: float) -> Vector3:
	return Vector3(fposmod(c.x, period), fposmod(c.y, period), fposmod(c.z, period))


## The ground shader's nova_hash.
static func _hash(q: Vector3) -> float:
	var p := q * 0.1031
	p -= p.floor()
	p += Vector3.ONE * p.dot(Vector3(p.z, p.y, p.x) + Vector3.ONE * 31.32)
	var h := (p.x + p.y) * p.z
	return h - floorf(h)


# ---------------------------------------------------------------------------
# GPU data
# ---------------------------------------------------------------------------

## Nova's material built on the body's terrain material [param base] (a terrain_biome ShaderMaterial): its
## settings, drawn by terrain_biome_nova.gdshader (the same shader with Nova's palette compiled in).
func build_material(base: Material) -> ShaderMaterial:
	if base is ShaderMaterial:
		material = (base as ShaderMaterial).duplicate() as ShaderMaterial
	else:
		material = ShaderMaterial.new()
	material.shader = load(NOVA_SHADER)
	material.set_shader_parameter("nova_on", true)
	if Engine.is_editor_hint():
		refresh_textures()
	else:
		_refresh_textures_later()
	refresh_ground()
	return material


## In the game: the texture arrays made on a worker, set on the material once made (the chunks take longer to be
## built). Made here they were 1.2 s on the main thread in the frame the player's planet arrived (2026-11-24).
## The paths are read now: refresh_ground places each variant's layers by them.
func _refresh_textures_later() -> void:
	join_textures()
	var spec := _arrays_spec()
	_textures_task = WorkerThreadPool.add_task(func() -> void:
		_set_arrays.call_deferred(_texture_arrays(spec)), false, "nova textures")


## Wait for the texture arrays still being made, from the main thread (PlanetTerrain._exit_tree, before the body
## goes). Their textures' images are read through the RenderingServer, which answers another thread only when
## this one flushes it: the queue is kept moving meanwhile, as PlanetTerrain.join_task does.
func join_textures() -> void:
	if _textures_task < 0:
		return
	while not WorkerThreadPool.is_task_completed(_textures_task):
		RenderingServer.force_sync()
		OS.delay_usec(500)
	WorkerThreadPool.wait_for_task_completion(_textures_task)
	_textures_task = -1


func _set_arrays(made: Dictionary) -> void:
	join_textures()  # done: releases the task
	if material == null:
		return
	for parameter: String in made:
		material.set_shader_parameter(parameter, made[parameter])


## Rewrites the parameter texture from the resolved settings: the ground shows it at once.
func refresh_ground() -> void:
	_looks_mutex.lock()
	_looks.clear()  # the ground's look follows the settings (ground_look)
	_looks_mutex.unlock()
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
		# The depth of the steep parallax, in metres; the textures' contrast round their mean colour.
		_params_img.set_pixel(7, id, Color(float(resolve(id, "ground/parallax_cm")) * 0.01,
				float(resolve(id, "ground/texture_contrast")), 0.0, 0.0))
	if _params_tex == null:
		_params_tex = ImageTexture.create_from_image(_params_img)
		material.set_shader_parameter("nova_params", _params_tex)
	else:
		_params_tex.update(_params_img)


## Rebuilds the albedo and normal texture arrays from the textures the variants name, now.
func refresh_textures() -> void:
	if material == null:
		return
	join_textures()  # an older making would set its arrays over these
	_set_arrays(_texture_arrays(_arrays_spec()))


## Reads the variants' texture paths, and gives what each array is made of: [shader parameter, paths, the flat
## colour of a layer that does not load].
func _arrays_spec() -> Array:
	_albedo_paths = _texture_paths(ALBEDO_KEYS)
	_normal_paths = _texture_paths(NORMAL_KEYS)
	_orh_paths = _texture_paths(ORH_KEYS)
	return [["nova_orh", _orh_paths, Color(1.0, 0.9, 0.5)], ["nova_albedo", _albedo_paths, Color(0.5, 0.5, 0.5)],
			["nova_normal", _normal_paths, Color(0.5, 0.5, 1.0)]]


## The arrays of [param spec] (_arrays_spec): shader parameter -> Texture2DArray. Any thread.
static func _texture_arrays(spec: Array) -> Dictionary:
	var paths := PackedStringArray()
	var fallbacks: Array[Color] = []
	for a: Array in spec:
		for path: String in a[1]:
			paths.append(path)
			fallbacks.append(a[2])
	var layers := _layer_images(paths, fallbacks)
	var made := {}
	var at := 0
	for a: Array in spec:
		var n := (a[1] as PackedStringArray).size()
		made[a[0]] = _texture_array(layers.slice(at, at + n), a[2])
		at += n
	return made


func _texture_paths(keys: Array[String]) -> PackedStringArray:
	var out := PackedStringArray()
	for v in variants:
		for key in keys:
			var p := str(resolve(v.id, key))
			if p != "" and not out.has(p) and ResourceLoader.exists(p):
				out.append(p)
	return out


static func _texture_array(images: Array[Image], fallback: Color) -> Texture2DArray:
	if images.is_empty():
		images = [_flat_image(fallback)]
	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	return arr


## The layer of every texture of [param paths], TEX_SIZE square with its mipmaps; [param fallbacks]' flat colour
## for one that does not load. Read on the calling thread, fitted on the workers, all at once: one at a time on
## the main thread, the 2048 and 4096 px ones took 2.1 s when the body opened (tarsis_3, 2026-11-24). Called from
## a worker, the main thread must not wait for it without flushing the RenderingServer (join_textures).
static func _layer_images(paths: PackedStringArray, fallbacks: Array[Color]) -> Array[Image]:
	var slots: Array = []  # [image] per layer, each its own array: a worker writes its slot alone
	var read: Array[bool] = []  # false: the flat colour, already a layer
	for i in paths.size():
		var tex := load(paths[i]) as Texture2D
		var img: Image = tex.get_image() if tex != null else null
		read.append(img != null)
		slots.append([img if img != null else _flat_image(fallbacks[i])])
	var fit := func(i: int) -> void:
		if read[i]:
			slots[i][0] = _fit_layer(slots[i][0])
	if slots.size() > 1:
		WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(fit, slots.size()))
	elif slots.size() == 1:
		fit.call(0)
	var images: Array[Image] = []
	for slot: Array in slots:
		images.append(slot[0])
	return images


## [param source] as a layer: RGBA8, TEX_SIZE square, its mipmaps made again. A copy: the texture's own image
## is left as it is. Any thread.
static func _fit_layer(source: Image) -> Image:
	var img := source.duplicate() as Image
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
