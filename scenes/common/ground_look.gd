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
# The mean colour of each ground texture, read once (see _mean_of).
static var _means: Dictionary = {}
# Which planet's detail array the template currently carries.
static var _detail_source: PlanetData = null

## The fringe material to wear here. Null when the ground cannot be read.
var material: ShaderMaterial = null
## The colour the ground SHOWS here, on average: what the dust it gives up takes (the wheels, the feet,
## the blown layer). Flat ground: the biome colour scaled by the terrain's albedo multiplier. Textured
## ground: the texture's mean colour times the tint its shader applies (see [member tint]). It was the
## raw tint scaled by the FLAT terrain's multiplier on both, and dust off the textured biomes came out
## darker than the ground under it (2026-10-11).
var color: Color = Color(0.45, 0.35, 0.25)
## The colour the fringe material paints with. Flat ground: [member color] itself. Textured ground: the
## tint the ground shader multiplies its texture by (planet_surface.gdshader: tex * mix(1, COLOR,
## vertex_color_strength)); left out, the fringe showed the bare texture, white marble on every
## corundum plateau (2026-10-11).
var tint: Color = Color(0.45, 0.35, 0.25)
## (detail layer, tiling scale) of the ground's own detail texture. Zero means "no detail texture".
var detail: Vector2 = Vector2.ZERO


## Read the ground in body-fixed direction `dir`. `fallback` is used when the biome yields nothing.
static func at(data: PlanetData, dir: Vector3, fallback: Color) -> GroundLook:
	var look := GroundLook.new()
	look.color = fallback
	look.tint = fallback
	if data == null:
		return look
	_share_detail_texture(data)
	var ground: Material = data.ground_material_at(dir)
	look.tint = vertex_colour(data, dir, fallback)
	look.color = _shown(data, ground, look.tint)
	if _albedo_texture_of(ground) == null:
		look.tint = look.color  # flat ground: the fringe paints the colour itself
	look.detail = data.ground_detail_at(dir)
	look.material = material_for(ground)
	return look


## Only the colour the ground shows at [param dir] (see [member color]): what the dust it gives up
## takes, without the fringe's material and detail.
## [param height_m]: the ground's height there over the reference sphere when the caller has it (a ground
## query saved); NAN samples it.
static func colour_at(data: PlanetData, dir: Vector3, fallback: Color, height_m: float = NAN) -> Color:
	if data == null:
		return fallback
	return _shown(data, data.ground_material_at(dir), vertex_colour(data, dir, fallback, height_m))


## The colour the terrain bakes into its vertex at [param dir]: the planet's default rock or the zone's,
## shaded by RockImpurity at the surface (PlanetChunk.road_ground_tint, the terrain's own rule, which
## the roads already use), the biome's colour else. It was RockCatalogue's bare mottle between the
## rock's light and dark shades: one building's fringe came out pale, its neighbour's on the same
## ground rust-red, and the dust off that ground matched neither (2026-10-12).
static func vertex_colour(data: PlanetData, dir: Vector3, fallback: Color, height_m: float = NAN) -> Color:
	var zone: Dictionary = data.first_zone_at(dir)
	if zone.is_empty() and not data.corundum_default_biome:
		var sampled: Color = data.ground_albedo_at(dir)  # no zone here: the biome map
		return fallback if sampled == Color(0, 0, 0, 0) else sampled
	var cor_bd: BiomeDefinition = data.get_biome_by_type(ArideDesertCorundumPlateauTerrain.BIOME_TYPE) \
			if data.corundum_default_biome else null
	return PlanetChunk.road_ground_tint(data, dir, zone, cor_bd, height_m)


## What a ground drawn with [param ground] and the vertex colour [param tint] shows on average.
static func _shown(data: PlanetData, ground: Material, tint: Color) -> Color:
	var tex: Texture2D = _albedo_texture_of(ground)
	if tex != null:
		return shown_colour(_mean_of(tex), tint, _vertex_color_strength_of(ground))
	return _flat_colour(data, tint)


## What a textured ground shows on average: its texture's [param mean] times the vertex [param tint],
## weighed by the ground shader's [param strength] — planet_surface.gdshader's own rule, read off the
## same numbers so the dust and the fringe cannot drift from the ground.
static func shown_colour(mean: Color, tint: Color, strength: float) -> Color:
	var t: Color = Color.WHITE.lerp(tint, clampf(strength, 0.0, 1.0))
	return Color(mean.r * t.r, mean.g * t.g, mean.b * t.b)


## The fringe material for a given ground material, created once per distinct ground texture.
##
## Reads whatever that material exposes: planet_surface.gdshader (the outcrop biomes, and all of
## Tarsis 3) carries the colour in albedo_texture, while terrain_biome.gdshader carries it in a
## vertex colour modulated by a grey detail layer. No parameter name is common to both, which is
## why this asks rather than assumes.
static func material_for(ground: Material) -> ShaderMaterial:
	var tex: Texture2D = _albedo_texture_of(ground)
	var scale: float = 0.1
	var sm := ground as ShaderMaterial
	if tex != null:
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
		mat.set_shader_parameter(&"blend_vertex_color_strength", _vertex_color_strength_of(ground))
	_materials[key] = mat
	return mat


## True when `m` is one of ours, so a foreign overlay is never mistaken for one and cleared.
static func is_ours(m: Material) -> bool:
	return m != null and _materials.values().has(m)


## The ground material's albedo texture, or null for a flat (vertex-coloured) ground.
static func _albedo_texture_of(ground: Material) -> Texture2D:
	var sm := ground as ShaderMaterial
	if sm == null:
		return null
	var t: Variant = sm.get_shader_parameter(&"albedo_texture")
	return t as Texture2D if t is Texture2D else null


## How much of its vertex tint the ground shader applies (planet_surface.gdshader's
## vertex_color_strength; 0 when the material does not say).
static func _vertex_color_strength_of(ground: Material) -> float:
	var sm := ground as ShaderMaterial
	var v: Variant = sm.get_shader_parameter(&"vertex_color_strength") if sm != null else null
	return float(v) if v != null else 0.0


## The mean colour of [param tex], read once per texture from its smallest useful size. White when
## the pixels cannot be read (no renderer, a texture with no image): the tint alone then speaks.
static func _mean_of(tex: Texture2D) -> Color:
	if _means.has(tex):
		return _means[tex]
	var mean: Color = Color.WHITE
	var img: Image = tex.get_image()
	if img != null and not img.is_empty():
		if img.is_compressed():
			img.decompress()
		img.resize(1, 1, Image.INTERPOLATE_TRILINEAR if img.has_mipmaps() else Image.INTERPOLATE_BILINEAR)
		mean = img.get_pixel(0, 0)
		mean.a = 1.0
	_means[tex] = mean
	return mean


static func _flat_colour(data: PlanetData, biome: Color) -> Color:
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
