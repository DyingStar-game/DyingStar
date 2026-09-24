## What the ground LOOKS LIKE at a point, and the fringe material that reproduces it.
##
## The other half of the pair whose first half is TerrainBlend: that one answers "where is the
## ground under this object", this one answers "what does the ground look like there". They meet on
## this small value object and nothing else — the same split SurfaceProbe/SurfaceSounds already uses
## here, for the same reason: the question "which surface am I on" and the question "what does that
## surface do" have different answers, different owners, and change for different reasons.
##
## Everything here is client-side and read-only with respect to the terrain: it reads the materials
## the terrain is drawn with, never writes them.
class_name GroundLook
extends RefCounted

const MATERIAL_PATH := "res://assets/_universe/_shared/materials/terrain_blend.tres"

# ONE fringe material PER GROUND TEXTURE -- never per object. A texture cannot be a per-instance
# uniform, so objects standing on different ground need different materials; but they GROUP, and a
# planet has a handful of ground materials, not thousands. Everything that varies per object rides
# set_instance_shader_parameter(), which duplicates nothing. rock_debug.gd measured 23-30 fps
# between a material per rock and a shared one on forty rocks, and Mining_Zone asks for three
# hundred: a material per object is precisely what this design exists to avoid.
static var _template: ShaderMaterial = null
static var _materials: Dictionary = {}
# Which planet's detail array the template currently carries.
static var _detail_source: PlanetData = null

## The fringe material to wear here. Null when the ground cannot be read.
var material: ShaderMaterial = null
## Flat ground colour, already scaled by the terrain's albedo multiplier. Used by the biomes that
## have no texture yet — which is most of them, and will be for a while.
var color: Color = Color(0.45, 0.35, 0.25)
## (detail layer, tiling scale) of the ground's own detail texture. Zero means "no detail texture".
var detail: Vector2 = Vector2.ZERO


## Read the ground in body-fixed direction `dir`. `fallback` is used when the biome yields nothing.
static func at(data: PlanetData, dir: Vector3, fallback: Color) -> GroundLook:
	var look := GroundLook.new()
	look.color = fallback
	if data == null:
		return look
	_share_detail_texture(data)
	look.color = _colour_of(data, dir, fallback)
	look.detail = data.ground_detail_at(dir)
	look.material = material_for(data.ground_material_at(dir))
	return look


## The fringe material for a given ground material, created once per distinct ground texture.
##
## Reads whatever that material exposes: planet_surface.gdshader (the outcrop biomes, and all of
## Tarsis 3) carries the colour in albedo_texture, while terrain_biome.gdshader carries it in a
## vertex colour modulated by a grey detail layer. No parameter name is common to both, which is
## why this asks rather than assumes.
static func material_for(ground: Material) -> ShaderMaterial:
	var tex: Texture2D = null
	var scale: float = 0.1
	var sm := ground as ShaderMaterial
	if sm != null:
		var t: Variant = sm.get_shader_parameter(&"albedo_texture")
		if t is Texture2D:
			tex = t as Texture2D
			var ts: Variant = sm.get_shader_parameter(&"tile_scale")
			if ts != null:
				scale = float(ts)
	var key: Variant = tex if tex != null else "flat"
	if _materials.has(key):
		return _materials[key]
	var base: ShaderMaterial = _template_material()
	if base == null:
		return null
	# The flat path reuses the template itself, so a planet with no textured biome still ends up
	# with exactly one material, as before.
	var mat: ShaderMaterial = base if tex == null else (base.duplicate() as ShaderMaterial)
	if tex != null:
		mat.set_shader_parameter(&"blend_albedo_tex", tex)
		mat.set_shader_parameter(&"blend_use_albedo", true)
		mat.set_shader_parameter(&"blend_albedo_scale", scale)
	_materials[key] = mat
	return mat


## True when `m` is one of ours, so a foreign overlay is never mistaken for one and cleared.
static func is_ours(m: Material) -> bool:
	return m != null and _materials.values().has(m)


static func _colour_of(data: PlanetData, dir: Vector3, fallback: Color) -> Color:
	var biome: Color = data.ground_albedo_at(dir)
	# What the terrain renders is the biome colour scaled by albedo_multiplier -- see
	# terrain_biome.gdshader:345, ALBEDO = biome_color * mod * albedo_multiplier, where mod sits at
	# ~1.0 for neutral detail. Read the factor off the real material rather than copying 0.4 here:
	# a disagreement would raise nothing, it would just tint the band differently from the ground.
	var mult: float = 1.0
	var mat := data.terrain_material as ShaderMaterial
	if mat != null:
		var p: Variant = mat.get_shader_parameter(&"albedo_multiplier")
		if p != null:
			mult = float(p)
	if biome == Color(0, 0, 0, 0):
		return fallback
	return Color(biome.r * mult, biome.g * mult, biome.b * mult)


## Hand the terrain's LIVE detail array to the template. A reference, never a copy: retune the
## terrain's textures or its strength and the band follows, instead of drifting into a second look
## nobody remembers maintaining. Re-runs when the planet changes, because each body has its own
## array -- a moon wearing Sandbox's textures is a mistake this project has already made once.
static func _share_detail_texture(data: PlanetData) -> void:
	if _detail_source == data:
		return
	var terrain := data.terrain_material as ShaderMaterial
	var mat: ShaderMaterial = _template_material()
	if terrain == null or mat == null:
		return
	mat.set_shader_parameter(&"blend_detail", terrain.get_shader_parameter(&"detail_textures"))
	var strength: Variant = terrain.get_shader_parameter(&"detail_strength")
	if strength != null:
		mat.set_shader_parameter(&"blend_detail_strength", float(strength))
	var fine: Variant = terrain.get_shader_parameter(&"detail_fine_ratio")
	if fine != null:
		mat.set_shader_parameter(&"blend_detail_fine", float(fine))
	_detail_source = data


static func _template_material() -> ShaderMaterial:
	if _template == null:
		_template = load(MATERIAL_PATH) as ShaderMaterial
	return _template
