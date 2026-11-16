class_name CharacterMaterials
extends RefCounted

## Realistic materials for the MakeHuman character, replacing the ones its glTF came with.
##
## The glTF exported every surface as an alpha-BLENDed StandardMaterial3D (kept out of the depth
## buffer), the skin as a bare diffuse texture, and the eyes, hair and clothes with a mirror clear coat
## (clearcoat roughness 0) that reads as glazed plastic. Here each surface gets a material for what it
## IS: skin (subsurface scattering, transmittance, pores), wet eyes, alpha-cut anisotropic hair, matte
## cloth, glossy teeth.
##
## Materials are built once and shared by every puppet (cached per source texture), and set as SURFACE
## OVERRIDES on each MeshInstance3D: the imported resources are left untouched, and a mirror double,
## which copies the overrides, shows the same look.

const SKIN_SHADER := preload("res://assets/_universe/characters/human/shaders/human_skin.gdshader")
const SKIN_FAR_SHADER := preload("res://assets/_universe/characters/human/shaders/human_skin_far.gdshader")
const EYE_SHADER := preload("res://assets/_universe/characters/human/shaders/human_eye.gdshader")
const EYE_WET_SHADER := preload("res://assets/_universe/characters/human/shaders/human_eye_wet.gdshader")
const IRIS_SHADER := preload("res://assets/_universe/characters/human/shaders/human_iris.gdshader")
const HAIR_SHADER := preload("res://assets/_universe/characters/human/shaders/human_hair.gdshader")
const HAIR_STRANDS_SHADER := preload("res://assets/_universe/characters/human/shaders/human_hair_strands.gdshader")
const HAIR_SHELL_SHADER := preload("res://assets/_universe/characters/human/shaders/human_hair_shell.gdshader")

enum Role { SKIN, EYE, HAIR, TEETH, TONGUE, CLOTH, SHOES }

## Mesh name fragments -> role. The first match wins; anything unmatched is cloth. Eyebrows and
## eyelashes come before the generic "eye", which their names also contain.
const ROLE_BY_NAME: Array = [
	["male_muscle", Role.SKIN], ["female_muscle", Role.SKIN], ["body", Role.SKIN],
	["eyebrow", Role.HAIR], ["eyelash", Role.HAIR], ["short0", Role.HAIR], ["bob0", Role.HAIR],
	["long0", Role.HAIR], ["ponytail", Role.HAIR], ["braid", Role.HAIR], ["afro", Role.HAIR], ["hair", Role.HAIR],
	["high-poly", Role.EYE], ["low-poly", Role.EYE], ["eye", Role.EYE],
	["teeth", Role.TEETH], ["tongue", Role.TONGUE], ["shoes", Role.SHOES],
]

const TEXTURES_DIR := "res://assets/_universe/characters/human/textures/"
const SKIN_DIR := "res://assets/_universe/characters/human/skin/"
## How much darker than the hair the strands of each kind are (human_hair.gdshader darken).
const DARKEN_BY_KIND: Dictionary = {"eyebrows": 0.25, "eyelashes": 0.8}
## Width (m) of a hair of each kind drawn as hairs (human_hair_strands.gdshader); a head of hair's is
## HairStrands.HAIR_WIDTH.
## An eyebrow hair is ~0.1 mm thick at its root (a hair under a pixel covers its share of it:
## human_hair_strands.gdshader); an eyelash ~0.15 mm at its root, tapering: drawn thinner, the lashes made no
## dark line along the lid where a photo has one.
const HAIR_WIDTH_BY_KIND: Dictionary = {"beard": 0.0006, "eyebrows": 0.00012, "eyelashes": 0.00018}
## Highlight band of the hairs of each kind (human_hair_strands.gdshader sheen), when not the shader's: a
## head of hair's band, on lashes a few pixels long, greys them.
const SHEEN_BY_KIND: Dictionary = {"eyelashes": 0.0, "eyebrows": 0.02}
## Least opacity of a hair's strip of each kind (human_hair_strands.gdshader min_coverage), when not the
## shader's: eyebrows and lashes keep all their hairs at any distance, so a thin one may stay faint.
const MIN_COVERAGE_BY_KIND: Dictionary = {"eyebrows": 0.05, "eyelashes": 0.18}
## Tiles of the shell's dot texture across the skin's UV for each kind (human_hair_shell.gdshader tiling, default
## 4): a beard's stubble and a scalp's are finer than 1.5 mm dots, read as a shadow, not as spots (at a hairline, a
## dark ragged rim).
const SHELL_TILING_BY_KIND: Dictionary = {"beard": 12.0, "hair": 12.0}
## The lips' box in the face's UV square (u0, v0, u1, v1; human_skin_detail.gdshaderinc lip_box): measured on the
## bank's face, the nostrils just above it, the eyes far off.
const LIP_BOX := Vector4(0.36, 0.6, 0.64, 0.71)

static var _cache: Dictionary = {}  # [role, texture id] -> Material
static var _pores: NoiseTexture2D


## Give every surface of a character model its realistic material (no-op on a dedicated server).
static func apply(model: Node) -> void:
	if model == null or OS.has_feature("dedicated_server"):
		return
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var inst := node as MeshInstance3D
		if inst.mesh == null:
			continue
		var role: Role = role_of(String(inst.name))
		for i in inst.mesh.get_surface_count():
			var source := inst.mesh.surface_get_material(i) as BaseMaterial3D
			inst.set_surface_override_material(i, material_for(role, source))


## The role a mesh plays, from its (imported) node name.
static func role_of(mesh_name: String) -> Role:
	var lower: String = mesh_name.to_lower()
	for pair in ROLE_BY_NAME:
		if lower.contains(pair[0]):
			return pair[1]
	return Role.CLOTH


## The shared realistic material for a role, built from the imported material's textures.
static func material_for(role: Role, source: BaseMaterial3D) -> Material:
	var albedo: Texture2D = source.albedo_texture if source != null else null
	var key: Array = [role, albedo.get_rid().get_id() if albedo != null else 0]
	if _cache.has(key):
		return _cache[key]
	var made: Material
	match role:
		Role.SKIN, Role.EYE:
			# The imported character is only shown until its baked body is ready: plain, opaque.
			var plain := StandardMaterial3D.new()
			plain.albedo_texture = albedo
			plain.roughness = 0.6 if role == Role.SKIN else 0.25
			plain.subsurf_scatter_enabled = role == Role.SKIN
			plain.subsurf_scatter_strength = 0.3
			if role == Role.EYE:
				plain.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			made = plain
		Role.HAIR:
			made = _shader_material(HAIR_SHADER, albedo)
		Role.TEETH, Role.TONGUE:
			made = _mouth_material(role, source)
		_:
			made = _cloth_material(role, source)
	_cache[key] = made
	return made


## The material of one surface of a baked body (HumanBuilder). [param what] is the body zone's name
## (StringName: "Face", "Torso", "Iris"...) or the worn asset (HumanAssetData). Shared between avatars:
## what differs per person is instance uniforms (skin_look, hair_colour), set by HumanAppearance.
static func human_material(what: Variant, _appearance: CharacterAppearance, near: bool = true) -> Material:
	if what is StringName or what is String:
		return _zone_material(String(what), near)
	var asset := what as HumanAssetData
	match String(asset.kind):
		"hair", "eyebrows", "eyelashes", "beard":
			return _hair_material(asset, near)
	var cloth_role: Role = Role.SHOES if asset.part > 0 else Role.CLOTH
	return _shared(cloth_role, asset.albedo, func() -> Material:
		var source := StandardMaterial3D.new()
		source.albedo_texture = asset.albedo
		if asset.normal != null:
			source.normal_enabled = true
			source.normal_texture = asset.normal
		if asset.ao != null:
			source.ao_enabled = true
			source.ao_texture = asset.ao
		return _cloth_material(cloth_role, source))


## The shared material of generated hair (tools/character/hair_groom): hairs -- a head of hair, a beard,
## eyebrows, eyelashes -- or the shell that is hair seen end-on. One per kind.
static func _hair_material(asset: HumanAssetData, _near: bool) -> Material:
	var shell: bool = asset.style == &"shell"
	var shader: Shader = HAIR_SHELL_SHADER if shell else HAIR_STRANDS_SHADER
	var key: Array = [shader.get_rid().get_id(), asset.kind, asset.albedo.get_rid().get_id() if asset.albedo != null else 0]
	if _cache.has(key):
		return _cache[key]
	var mat := ShaderMaterial.new()
	mat.shader = shader
	if shell:
		mat.set_shader_parameter(&"dot_texture", asset.albedo)
		if SHELL_TILING_BY_KIND.has(String(asset.kind)):
			mat.set_shader_parameter(&"tiling", SHELL_TILING_BY_KIND[String(asset.kind)])
	else:
		mat.set_shader_parameter(&"hair_width", HAIR_WIDTH_BY_KIND.get(String(asset.kind), HairStrands.HAIR_WIDTH))
	mat.set_shader_parameter(&"darken", DARKEN_BY_KIND.get(String(asset.kind), 0.0))
	if not shell and MIN_COVERAGE_BY_KIND.has(String(asset.kind)):
		mat.set_shader_parameter(&"min_coverage", MIN_COVERAGE_BY_KIND[String(asset.kind)])
	if not shell and SHEEN_BY_KIND.has(String(asset.kind)):
		mat.set_shader_parameter(&"sheen", SHEEN_BY_KIND[String(asset.kind)])
		mat.set_shader_parameter(&"glow", SHEEN_BY_KIND[String(asset.kind)])
	mat.set_shader_parameter(&"is_beard", 1.0 if asset.kind == &"beard" else 0.0)
	_cache[key] = mat
	return mat


static var _zones: Dictionary = {}  # zone name -> Material
static var _warm: Array[Resource] = []  # the zones' textures, held so the cache keeps them


## Load every body zone's textures (a 4K face among them: ~0.7 s) and keep them cached. Called on the
## worker that loads the bank, so the first avatar does not stall the main thread on them.
static func warm_textures() -> void:
	if not _warm.is_empty() or OS.has_feature("dedicated_server"):
		return
	var dir := DirAccess.open(SKIN_DIR)
	if dir == null:
		return
	for file in dir.get_files():
		# Exported builds list the .import (or .remap) beside each texture, not always the source file.
		var path: String = SKIN_DIR + file.trim_suffix(".import").trim_suffix(".remap")
		if path.ends_with(".webp") and ResourceLoader.exists(path):
			var texture: Resource = load(path)
			if texture != null and not _warm.has(texture):
				_warm.append(texture)


## The shared material of a body zone, made on first use from the zone's maps (SKIN_DIR). [param near]:
## the close-up skin (its own lighting, micro relief) or the light one for avatars seen from afar.
static func _zone_material(zone: String, near: bool) -> Material:
	var key: String = zone if near else zone + ":far"
	if _zones.has(key):
		return _zones[key]
	var made: Material
	var name: String = zone.to_lower()
	match zone:
		"Face", "Torso", "Arms", "Legs":
			var mat := ShaderMaterial.new()
			mat.shader = SKIN_SHADER if near else SKIN_FAR_SHADER
			mat.set_shader_parameter(&"albedo_light", load(SKIN_DIR + "vitruvian_%s_light.webp" % name))
			mat.set_shader_parameter(&"albedo_dark", load(SKIN_DIR + "vitruvian_%s_dark.webp" % name))
			mat.set_shader_parameter(&"normal_texture", load(SKIN_DIR + "vitruvian_%s_normal.webp" % name))
			mat.set_shader_parameter(&"age_normal_texture", load(SKIN_DIR + "vitruvian_%s_age_normal.webp" % name))
			mat.set_shader_parameter(&"roughness_texture", load(SKIN_DIR + "vitruvian_%s_roughness.webp" % name))
			mat.set_shader_parameter(&"region_texture", load(SKIN_DIR + "skin_detail_%s_regions.webp" % name))
			if zone == "Face":
				mat.set_shader_parameter(&"wrinkle_texture", load(SKIN_DIR + "skin_detail_face_wrinkles.webp"))
				mat.set_shader_parameter(&"smile_texture", load(SKIN_DIR + "skin_detail_face_smile.webp"))
				mat.set_shader_parameter(&"smile_map", 1.0)
				mat.set_shader_parameter(&"lip_box", LIP_BOX)
			else:  # a face's square is a head, a limb's a whole limb: same freckle and mole size everywhere
				mat.set_shader_parameter(&"freckle_scale", 360.0)
				mat.set_shader_parameter(&"mole_scale", 48.0)
			if near:
				mat.set_shader_parameter(&"micro_detail_texture", load(SKIN_DIR + "humanshaders_micro_detail.png"))
				# The face's map covers a head, the others a whole limb or trunk: same pore size on all.
				mat.set_shader_parameter(&"micro_scale", 45.0 if zone == "Face" else 110.0)
			made = mat
		"Iris":
			var iris := ShaderMaterial.new()
			iris.shader = IRIS_SHADER
			iris.set_shader_parameter(&"albedo_texture", load(SKIN_DIR + "vitruvian_iris_colour.webp"))
			iris.set_shader_parameter(&"normal_texture", load(SKIN_DIR + "vitruvian_iris_normal.webp"))
			made = iris
		"Pupil":
			var pupil := StandardMaterial3D.new()
			pupil.albedo_color = Color.BLACK
			# Matte: the shine on a pupil is the tear film's, over it (a glossy pupil showed a black dome).
			pupil.roughness = 1.0
			pupil.metallic_specular = 0.0
			made = pupil
		"Sclera_Cornea":
			var sclera := ShaderMaterial.new()
			sclera.shader = EYE_SHADER
			sclera.set_shader_parameter(&"albedo_texture", load(SKIN_DIR + "vitruvian_sclera_colour.webp"))
			sclera.set_shader_parameter(&"normal_texture", load(SKIN_DIR + "vitruvian_sclera_normal.webp"))
			sclera.next_pass = _wet_film() if near else null
			made = sclera
		"Mouth":
			var mouth: StandardMaterial3D = _plain(load(SKIN_DIR + "vitruvian_mouth_colour.webp"),
					load(SKIN_DIR + "vitruvian_mouth_normal.webp"), 0.3)
			mouth.subsurf_scatter_enabled = true
			mouth.subsurf_scatter_strength = 0.3
			made = mouth
		"Tearline":
			made = _wet_film()
		_:
			var hidden := StandardMaterial3D.new()
			hidden.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			hidden.albedo_color = Color(1.0, 1.0, 1.0, 0.0)
			made = hidden
	_zones[key] = made
	return made


## The eyes' tear film (additive shine), one for every eye.
static func _wet_film() -> ShaderMaterial:
	if not _zones.has("wet"):
		var wet := ShaderMaterial.new()
		wet.shader = EYE_WET_SHADER
		_zones["wet"] = wet
	return _zones["wet"]


static func _plain(albedo: Texture2D, normal: Texture2D, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = albedo
	mat.normal_enabled = normal != null
	mat.normal_texture = normal
	mat.roughness = roughness
	mat.metallic_specular = 0.5
	return mat


static func _shared(role: Role, texture: Texture2D, make: Callable) -> Material:
	var key: Array = [role, texture.get_rid().get_id() if texture != null else 0]
	if not _cache.has(key):
		_cache[key] = make.call()
	return _cache[key]


## A tileable micro-normal for skin pores, generated in-engine (no texture file to ship or credit).
static func pore_texture() -> NoiseTexture2D:
	if _pores != null:
		return _pores
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.06
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	_pores = NoiseTexture2D.new()
	_pores.width = 256
	_pores.height = 256
	_pores.seamless = true
	_pores.as_normal_map = true
	_pores.bump_strength = 6.0
	_pores.generate_mipmaps = true
	_pores.noise = noise
	return _pores


static func _shader_material(shader: Shader, albedo: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	if albedo != null:
		mat.set_shader_parameter(&"albedo_texture", albedo)
	return mat


## Teeth and tongue: wet, slightly translucent, opaque.
static func _mouth_material(role: Role, source: BaseMaterial3D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	if source != null:
		mat.albedo_texture = source.albedo_texture
		mat.albedo_color = source.albedo_color
	mat.roughness = 0.25 if role == Role.TEETH else 0.4
	mat.metallic_specular = 0.5
	mat.subsurf_scatter_enabled = true
	mat.subsurf_scatter_strength = 0.2 if role == Role.TEETH else 0.4
	return mat


## Clothes and shoes: the imported textures on an opaque, matte, coat-free material.
static func _cloth_material(role: Role, source: BaseMaterial3D) -> StandardMaterial3D:
	var mat: StandardMaterial3D = (source.duplicate() as StandardMaterial3D) if source is StandardMaterial3D else StandardMaterial3D.new()
	var has_alpha: bool = mat.albedo_texture != null and mat.albedo_texture.has_alpha()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR if has_alpha else BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.alpha_scissor_threshold = 0.5
	mat.clearcoat_enabled = false
	mat.metallic = 0.0
	mat.roughness = 0.6 if role == Role.SHOES else 0.88
	mat.metallic_specular = 0.3
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	return mat
