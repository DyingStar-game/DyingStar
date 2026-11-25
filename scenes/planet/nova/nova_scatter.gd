@tool
class_name NovaScatter
## Nova scatter: rocks and props laid on a variant, the same for every player.
##
## Each layer owns a fixed HEALPix grid of the planet (level chosen from its spacing, see scatter_nside).
## A cell holds at most one object, and everything about it — present or not, where inside the cell, which
## model, yaw, scale — is an integer hash of (layer seed, face, ix, iy). No random generator, no order of
## generation: any machine, any chunk, any LOD that covers the cell computes the same object.
##
## A chunk's cells are exactly the sub-pixels of its tile (NESTED ordering), so a fine chunk and its
## coarser parent lay the same rocks. A layer is laid only on chunks fine enough to hold at most
## 4^MAX_DEPTH of its cells: the small stones appear close by, the boulders from farther away.
## The height comes from the chunk's own grid, so an object sits on the ground the player sees.

## A chunk carries at most 4^MAX_DEPTH cells of one layer.
const MAX_DEPTH := 8
## Finest grid a layer may use (HEALPix level).
const MAX_NSIDE := 1 << 24

const _M32 := 0xFFFFFFFF
## Clumps: what tells their pattern from the layer's own, and how soft their rim is (share of the noise).
const CLUMP_SALT := 0x5BD1E995
const CLUMP_SOFT := 0.07
## The terrain material's albedo multiplier (terrain_biome), applied to the rocks' colour as to the ground's.
const ROCK_ALBEDO_MULT := 0.4
const ROCK_TRIPLANAR_SHARPNESS := 14.0
const ROCK_SHADER := preload("res://scenes/planet/nova/nova_rock.gdshader")
## load_mesh's meshes by path, in the game ([mesh or null]); guarded: the scatter's layers are read on a worker.
static var _meshes_read: Dictionary = {}
static var _meshes_mutex := Mutex.new()
## How far an object is drawn, in times its own size: a 2 m stone to 240 m, a 15 m outcrop to 1.8 km. Beyond,
## it is a few pixels and only costs. Measured on tarsis_3 without it: 1.2 million objects drawn, 13 fps.
const VIEW_PER_SIZE := 120.0
## A chunk's objects are drawn in blocks, so the distance above cuts close to the object and not to the
## middle of a chunk hundreds of metres wide: blocks of half the layer's view distance, never under BLOCK_M.
## Each block of each model is a node: at 100 m a flight over scatter on every biome made 2 200 nodes of 4
## objects each and lost images making them (2026-11-20); at 200 m, a quarter of the nodes.
const BLOCK_M := 200.0
const MAX_BLOCKS := 8
## The rocks' fade in (nova_rock.gdshader) measures distances in the planet's frame, positions split in whole
## cells of this size and a rest: both parts are exact in the shader's single floats.
const FADE_CELL_M := 1024.0
## The rocks' ground fringe (set_fringe): the band climbs this share of a rock's height above the ground, and
## never more than FRINGE_MAX_M metres — TerrainBlend's max_height_ratio and height, for placed objects.
const FRINGE_RATIO := 0.3
const FRINGE_MAX_M := 0.9
## Floats per laid object: a MultiMesh transform (12) and its custom data (4) — the object's place in the
## chunk again, which the fade in needs and a shader cannot read back from the transform.
const ROW := 16


## HEALPix level whose cells are closest to [param cell_m] metres on a body of [param radius] metres.
static func scatter_nside(radius: float, cell_m: float) -> int:
	var side_at_1 := radius * sqrt(PI / 3.0)  # side of an nside-1 pixel
	var want := side_at_1 / maxf(cell_m, 0.01)
	var n := 1
	while n < MAX_NSIDE and float(n) * 1.41421356 < want:
		n <<= 1
	return n


## 32-bit integer mix (lowbias32). Products stay under 2^63: no overflow anywhere.
static func mix32(x: int) -> int:
	x &= _M32
	x = ((x ^ (x >> 16)) * 0x7feb352d) & _M32
	x = ((x ^ (x >> 15)) * 0x2c1b3c6d) & _M32
	return (x ^ (x >> 16)) & _M32


## Hash of a cell of a layer: depends on nothing but these integers.
static func cell_hash(layer_seed: int, face: int, ix: int, iy: int) -> int:
	var h := mix32(layer_seed ^ 0x9e3779b9)
	h = mix32(h ^ face)
	h = mix32(h ^ (ix & _M32))
	h = mix32(h ^ ((ix >> 32) & _M32))
	h = mix32(h ^ (iy & _M32))
	return mix32(h ^ ((iy >> 32) & _M32))


## The [param k]-th uniform number in [0, 1) drawn from a cell hash.
static func unit(h: int, k: int) -> float:
	return float(mix32(h + k * 0x632be5ab)) / 4294967296.0


## The object of one cell, or {} when the cell is empty. Pure function: see the class comment.
## Returns {fx, fy} (cell position in face coordinates at the layer's level) and uniform numbers u_*.
static func cell_object(layer_seed: int, density: float, face: int, ix: int, iy: int) -> Dictionary:
	var h := cell_hash(layer_seed, face, ix, iy)
	if unit(h, 0) >= density:
		return {}
	return {
		"fx": float(ix) + unit(h, 1),
		"fy": float(iy) + unit(h, 2),
		"u_mesh": unit(h, 3),
		"u_yaw": unit(h, 4),
		"u_scale": unit(h, 5),
		"u_edge": unit(h, 6),
		"u_spill_turn": unit(h, 7),
		"u_spill_far": unit(h, 8),
		"u_keep": unit(h, 9),
	}


## How likely a layer laid in clumps keeps an object at face position ([param fx], [param fy]): 1 inside a
## clump, 0 on the open ground between them, a short ramp at the rim. A smooth noise over a grid of
## [param cells] × [param cells] object cells, read at the object's own place: like the objects themselves it
## depends on nothing but integers of the planet's grid, so every machine and every LOD sees the same clumps.
static func clump_weight(layer_seed: int, face: int, fx: float, fy: float, cells: int, share: float) -> float:
	var gx := fx / cells
	var gy := fy / cells
	var x0 := floori(gx)
	var y0 := floori(gy)
	var tx := smoothstep(0.0, 1.0, gx - x0)
	var ty := smoothstep(0.0, 1.0, gy - y0)
	var s := layer_seed ^ CLUMP_SALT
	var noise := lerpf(
			lerpf(unit(cell_hash(s, face, x0, y0), 0), unit(cell_hash(s, face, x0 + 1, y0), 0), tx),
			lerpf(unit(cell_hash(s, face, x0, y0 + 1), 0), unit(cell_hash(s, face, x0 + 1, y0 + 1), 0), tx), ty)
	# A blend of four uniform numbers gathers around 0.5: stretch it back so [param share] is about the
	# share of ground the clumps hold.
	noise = clampf((noise - 0.5) * 1.8 + 0.5, 0.0, 1.0)
	return smoothstep(1.0 - share - CLUMP_SOFT, 1.0 - share + CLUMP_SOFT, noise)


## The colour of variant [param id]'s rock as the ground wears it: towards the light tint of the rock
## catalogue, as most of the ground is (the dark one is its impurities, RockImpurity).
## [param default_rock]: the rock of the ground outside any zone (see NovaBody.rock_of).
static func rock_tint(body: NovaBody, id: int, default_rock := "") -> Color:
	var rock := body.rock_of(id, default_rock)
	var pair: Array = RockCatalogue.colors_of(rock) if rock != "" else []
	return (pair[0] as Color).lerp(pair[1], 0.15) if not pair.is_empty() else Color(0.6, 0.6, 0.6)


## A material's colour for [param tint] × [param gain]. The ground's tint reaches its shader as a vertex
## colour, read as it is (no sRGB decoding); a material's colour is decoded. Encoded first, both end up with
## the same numbers — without this the rocks came out darker and redder than the ground they stand on.
static func tint_colour(tint: Color, gain: float) -> Color:
	return Color(minf(tint.r * gain, 1.0), minf(tint.g * gain, 1.0), minf(tint.b * gain, 1.0)).linear_to_srgb()


## What a rock takes from the ground of variant [param id], for the two materials below: its colour (as
## the terrain shader: tint × gain × the material's albedo multiplier), its tile and its textures (null
## when the variant names none).
static func _ground_look(body: NovaBody, id: int, default_rock: String) -> Dictionary:
	# The ground's close-up tile: a rock is looked at from near. The large tile, 13 times the size of a 1 m
	# boulder, showed a blurred thirteenth of the texture on it.
	var fine := float(body.resolve(id, "ground/detail_tile_m"))
	return {
		"colour": tint_colour(rock_tint(body, id, default_rock),
				float(body.resolve(id, "ground/texture_gain")) * ROCK_ALBEDO_MULT),
		"tile_m": maxf(fine if fine > 0.0 else float(body.resolve(id, "ground/tile_m")), 0.1),
		"albedo": _texture_of(body, id, "ground/albedo_texture"),
		"normal": _texture_of(body, id, "ground/normal_texture"),
		"normal_strength": float(body.resolve(id, "ground/normal_strength")),
	}


## The texture variant [param id] names at [param key], null when it names none or the file is gone.
static func _texture_of(body: NovaBody, id: int, key: String) -> Texture2D:
	var path := str(body.resolve(id, key))
	return load(path) as Texture2D if path != "" and ResourceLoader.exists(path) else null


## [param mesh] dressed for variant [param id]: a copy whose textured surfaces (a scanned or sculpted rock)
## wear [method rock_material] — the ground's rock grain over the model's own textures, [param own_share]
## of its base colour kept — and whose bare surfaces wear [param ground] ([method ground_material]).
## [param sink]: the share of its height the model is sunk into the ground (lay_chunk), where its fringe starts.
static func dressed(mesh: Mesh, body: NovaBody, id: int, ground: Material, own_share: float = 1.0,
		default_rock := "", sink: float = 0.0) -> Mesh:
	var copy: Mesh = mesh.duplicate()
	for surface in copy.get_surface_count():
		var own := copy.surface_get_material(surface) as BaseMaterial3D
		if own != null and own.albedo_texture != null:
			var m := rock_material(own, body, id, own_share, default_rock)
			set_fringe(m, body, id, mesh.get_aabb(), sink, default_rock)
			copy.surface_set_material(surface, m)
		else:
			copy.surface_set_material(surface, ground)
	return copy


## The material of a textured rock on variant [param id]'s ground (nova_rock.gdshader): the textures of
## [param own], the model's material, under the ground's rock texture at its close-up tile.
static func rock_material(own: BaseMaterial3D, body: NovaBody, id: int, own_share: float,
		default_rock := "") -> ShaderMaterial:
	var look := _ground_look(body, id, default_rock)
	var m := ShaderMaterial.new()
	m.shader = ROCK_SHADER
	m.set_shader_parameter("own_albedo", own.albedo_texture)
	m.set_shader_parameter("own_normal", own.normal_texture)
	var orm := own.ao_texture if own.ao_texture != null else own.roughness_texture
	m.set_shader_parameter("own_orm", orm)
	m.set_shader_parameter("roughness_scale", 1.0 if orm != null else float(body.resolve(id, "ground/roughness")))
	m.set_shader_parameter("own_share", own_share)
	m.set_shader_parameter("tint", look.colour)
	m.set_shader_parameter("detail_tile_m", look.tile_m)
	m.set_shader_parameter("detail_albedo", look.albedo)
	m.set_shader_parameter("detail_normal", look.normal)
	m.set_shader_parameter("detail_normal_strength", look.normal_strength)
	return m


## Gives rock material [param m] (nova_rock.gdshader) its ground fringe: the foot of the rock in the look of
## variant [param id]'s ground (NovaBody.ground_look: its materials, tiles, gains, strength, contrast,
## occlusion), the band starting where the ground meets a model of bounds [param aabb] sunk by [param sink] of its
## height (lay_chunk), or at its lowest point when that is higher. The patches the rock stands in are read by the
## shader at the rock's place, as the ground reads them. Left off when the variant's ground has no texture.
static func set_fringe(m: ShaderMaterial, body: NovaBody, id: int, aabb: AABB, sink: float, default_rock := "") -> void:
	var look := body.ground_look(id)
	if look.is_empty():
		m.set_shader_parameter("fringe_on", false)
		return
	var layers: Array = look.layers
	var ground_y := maxf(aabb.position.y, sink * aabb.size.y)
	m.set_shader_parameter("fringe_on", true)
	m.set_shader_parameter("fringe_ground_y", ground_y)
	m.set_shader_parameter("fringe_top_y", aabb.end.y)
	m.set_shader_parameter("fringe_ratio", FRINGE_RATIO)
	m.set_shader_parameter("fringe_max_m", FRINGE_MAX_M)
	var scale := Vector3.ZERO
	var gain := Vector3.ONE
	var share := Vector3(1.0, 0.0, 0.0)
	var patch := Vector3.ZERO
	var offset := Vector3(0.0, 0.0, 1.0)
	var ao := Vector3.ONE
	for i in 3:
		var l: Dictionary = layers[i] if i < layers.size() else layers[0]
		var mean := NovaBody.texture_mean(l.tex, true)
		m.set_shader_parameter("ground_albedo_%d" % i, l.tex)
		m.set_shader_parameter("ground_mean_%d" % i, Vector3(mean.r, mean.g, mean.b))
		scale[i] = float(l.scale)
		gain[i] = float(l.gain)
		ao[i] = NovaBody.ao_factor(l)
		if i > 0 and i < layers.size():
			share[i] = float(l.share)
			patch[i] = float(l.patch_scale)
			offset[i] = float(l.offset)
	m.set_shader_parameter("ground_scale", scale)
	m.set_shader_parameter("ground_gain", gain)
	m.set_shader_parameter("ground_share", share)
	m.set_shader_parameter("ground_patch_scale", patch)
	m.set_shader_parameter("ground_offset_k", offset)
	m.set_shader_parameter("ground_ao", ao)
	m.set_shader_parameter("ground_fine_scale", float(look.fine_scale))
	m.set_shader_parameter("ground_fine_range", Vector2(float(look.fine_near), float(look.fine_far)))
	m.set_shader_parameter("ground_strength", float(look.strength))
	m.set_shader_parameter("ground_contrast", float(look.contrast))
	m.set_shader_parameter("ground_macro", Vector2(float(look.macro_strength), float(look.macro_scale)))
	# The vertex colour the ground wears there: the rock's tint, as the rocks themselves take it (rock_tint).
	var t := body.biome_tint(rock_tint(body, id, default_rock))
	m.set_shader_parameter("ground_tint", Vector3(t.r, t.g, t.b))


## The ground's look for a model without textures of its own, standing on variant [param id]: the ground's
## textures laid by position over the object (no UVs needed), its rock's colour, and the light the model's
## own shape lets in (vertex colour). So a rock is made of the ground it stands on, whatever the corundum.
static func ground_material(body: NovaBody, id: int, default_rock := "") -> StandardMaterial3D:
	var look := _ground_look(body, id, default_rock)
	var m := StandardMaterial3D.new()
	m.albedo_color = look.colour
	m.vertex_color_use_as_albedo = true
	m.roughness = float(body.resolve(id, "ground/roughness"))
	m.uv1_triplanar = true
	# A sharp choice between the three projections: blended wide, the one that sees a face edge-on smears
	# long streaks over it.
	m.uv1_triplanar_sharpness = ROCK_TRIPLANAR_SHARPNESS
	m.uv1_scale = Vector3.ONE / float(look.tile_m)
	m.albedo_texture = look.albedo
	if look.normal != null:
		m.normal_enabled = true
		m.normal_texture = look.normal
		m.normal_scale = look.normal_strength
	# Occlusion (red) and roughness (green) from the ground's own image, when it has one.
	var orh := _texture_of(body, id, "ground/orh_texture")
	if orh != null:
		m.ao_enabled = true
		m.ao_texture = orh
		m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		m.roughness_texture = orh
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	return m


## The cells of a layer at level [param sn] inside chunk ([param nside], [param ipix]): the r × r block
## of face coordinates starting at (x0, y0) on [param face]. {} when the layer is coarser than the chunk
## or would put more than 4^MAX_DEPTH cells on it.
static func chunk_cells(nside: int, ipix: int, sn: int) -> Dictionary:
	if sn < nside or sn > nside << MAX_DEPTH:
		return {}
	var fxy := HEALPix.pix2face_xy(nside, ipix)
	@warning_ignore("integer_division")
	var r := sn / nside
	return {"face": int(fxy.face), "x0": int(fxy.ix) * r, "y0": int(fxy.iy) * r, "r": r}


## The exact zone lookup for lay_chunk on [param data]'s body: {variant_at: dir → variant id (the first
## zone holding dir, as the ground's vertices use), candidates: the variants whose objects can stand on the
## chunk — those of its export tile, and of the tiles around it when a neighbour's objects can spill onto
## it (PlanetChunk.nova_tiles_within), clearance: the ground the scatter keeps clear of on this chunk (roads,
## buildings, villages: NovaClearance) — absent when the chunk meets none}.
## Thread-safe like the chunk builders (PlanetData's zone cache is locked).
static func zone_context(data: PlanetData, nside: int, ipix: int) -> Dictionary:
	var nova := data.nova
	if nova == null or data.export_nside <= 0:
		return {}
	var en := data.export_nside
	var tiles := {}  # export tile → its zones ready for lookups, for this chunk's objects (one worker)
	var variant_at := func(dir: Vector3) -> int:
		var tile := HEALPix.vec2pix_nest(en, dir)
		if not tiles.has(tile):
			tiles[tile] = PlanetChunk.nova_entries(nova, PlanetChunk.nova_zones_of(data, en, tile))
		return PlanetChunk.nova_variant_in(tiles[tile], dir)
	var candidates := {}
	if nside >= en:
		for tile in PlanetChunk.nova_tiles_within(data, nside, ipix, nova.max_transition_m()):
			var covered := false
			for z: Dictionary in PlanetChunk.nova_zones_of(data, en, tile):
				candidates[nova.variant_id_for_zone(z)] = true
				covered = covered or str(z.get("coverage", "")) == "full"
			if not covered:
				candidates[1] = true
	var out := {"variant_at": variant_at, "candidates": candidates}
	var clearance := NovaClearance.for_chunk(data, nside, ipix)
	if clearance != null:
		out["clearance"] = clearance
	return out


## Everything a worker needs to lay one layer: plain values and loaded meshes, read-only.
## [param body] gives the settings; meshes are loaded here (main thread). [param default_rock]: the rock of
## the ground outside any zone (see NovaBody.rock_of).
static func layer_descs(body: NovaBody, radius: float, default_rock := "") -> Array:
	var out: Array = []
	for v in body.variants:
		var id: int = v.id
		for s in NovaSchema.SCATTER_SLOTS:
			var slot := s + 1
			var of := func(field: String) -> Variant:
				return body.resolve(id, NovaSchema.scatter_key(slot, field))
			if not bool(of.call("enabled")):
				continue
			var view_limit := float(of.call("view_m"))
			var meshes: Array = []
			var heights := PackedFloat32Array()
			var reaches := PackedFloat32Array()  # how far each model reaches from its middle, along the ground
			var view := 0.0
			# Dressed in the ground's look: this variant's own copy of each model, so the same model stands
			# on two corundums in two colours.
			var look: Material = ground_material(body, id, default_rock) if bool(of.call("like_ground")) else null
			for p in of.call("meshes"):
				var m := load_mesh(str(p))
				if m == null:
					continue
				if look != null:
					m = dressed(m, body, id, look, float(of.call("own_texture")), default_rock, float(of.call("sink")))
				meshes.append(m)
				heights.append(maxf(m.get_aabb().size.y, 0.01))
				reaches.append(maxf(m.get_aabb().size.x, m.get_aabb().size.z) * 0.5)
				view = maxf(view, view_of(m, view_limit))
			if meshes.is_empty():
				continue
			var nside := scatter_nside(radius, float(of.call("cell_m")))
			var cell_side := HEALPix.pixel_side_length(nside, radius)
			out.append({
				"variant": id,
				"seed": mix32(int(of.call("seed")) * 131 + slot) ^ (str(v.key).hash() & _M32),
				"nside": nside,
				# Clumps, in object cells a side (1 = no clumps).
				"clump_cells": maxi(roundi(float(of.call("clump_m")) / cell_side), 1),
				"clump_share": float(of.call("clump_share")),
				"cell_side_m": cell_side,
				# How far the layer's farthest-seen model is drawn: beyond it the layer is not laid at all
				# (PlanetTerrain lays a chunk's layers by its distance to the camera).
				"view_m": view,
				# The layer's own limit on how far it is drawn, 0 when its objects' sizes decide.
				"view_limit": view_limit,
				# How far the layer's objects spill over their variant's frontier, as an angle from the
				# planet's centre: the width of the ground's own transition.
				"spill": float(body.resolve(id, "ground/transition_m")) / radius,
				"density": float(of.call("density")),
				"scale_min": float(of.call("scale_min")),
				"scale_max": float(of.call("scale_max")),
				"sink": float(of.call("sink")),
				"align": float(of.call("align")),
				"cos_slope": cos(deg_to_rad(float(of.call("max_slope_deg")))),
				"meshes": meshes,
				"heights": heights,
				"reaches": reaches,
			})
	return out


## How far [param mesh] is drawn: the layer's own [param limit] when it sets one, else by the model's size.
## The one rule for laying a layer, culling its nodes and fading its rocks in.
static func view_of(mesh: Mesh, limit: float) -> float:
	return limit if limit > 0.0 else mesh.get_aabb().get_longest_axis_size() * VIEW_PER_SIZE


## A Mesh from a .tres/.res/.mesh, or the merged meshes of a scene (.glb, .tscn). Null when unusable. In the
## game, read once per path (_meshes_read): the scene a model is taken from is freed here, so it leaves the
## resource cache, and every variant naming the model read it again — 12 variants, ~200 loads of the same
## twenty models as the player's planet arrived (2026-11-24). The editor reads it again, a model re-imported.
static func load_mesh(path: String) -> Mesh:
	if path == "" or not ResourceLoader.exists(path):
		return null
	if Engine.is_editor_hint():
		return _read_mesh(path)
	_meshes_mutex.lock()
	var known: Variant = _meshes_read.get(path)
	_meshes_mutex.unlock()
	if known != null:
		return (known as Array)[0]
	var mesh := _read_mesh(path)
	_meshes_mutex.lock()
	_meshes_read[path] = [mesh]
	_meshes_mutex.unlock()
	return mesh


static func _read_mesh(path: String) -> Mesh:
	var res := load(path)
	if res is Mesh:
		return res
	if res is PackedScene:
		# A model made of one mesh at the scene's origin (a GLB exported for the scatter) is taken as it is:
		# its normals, the tangents its normal map needs and its levels of detail. Rebuilding it surface by
		# surface (mesh_from_scene, for scenes of several meshes) regenerates the normals and drops the rest.
		var scene := (res as PackedScene).instantiate()
		var found := scene.find_children("*", "MeshInstance3D", true, false)
		var whole: Mesh = null
		if found.size() == 1:
			var only := found[0] as MeshInstance3D
			var at_origin := only.transform.is_equal_approx(Transform3D.IDENTITY)
			var parent := only.get_parent() as Node3D
			while at_origin and parent != null:
				at_origin = parent.transform.is_equal_approx(Transform3D.IDENTITY)
				parent = parent.get_parent() as Node3D
			if at_origin:
				whole = only.mesh
		scene.free()
		return whole if whole != null else PlanetVegetation.mesh_from_scene(res)
	return null


## Lays every layer on one chunk. Pure, thread-safe: returns {[mesh, block of the chunk, the layer's view
## limit]: PackedFloat32Array of MultiMesh rows (ROW floats each)}.
## [param grid]: the chunk-local surface positions of its (res+1)² grid, row-major (yi * (res+1) + xi).
## [param vid]: the variant id of each grid vertex. [param center]: chunk centre, planet-local.
## [param zones]: from zone_context — the variant at an exact direction and the variants the chunk's
## export tile can hold. Without it the grid answers, which depends on the LOD (tests only).
## [param cancel]: [false] the caller sets to true to stop the laying where it is (an empty answer then).
static func lay_chunk(descs: Array, nside: int, ipix: int, res: int, grid: PackedVector3Array,
		vid: PackedInt32Array, center: Vector3, zones: Dictionary = {}, cancel: Array = []) -> Dictionary:
	var out := {}
	if grid.size() != (res + 1) * (res + 1) or vid.size() != grid.size():
		return out
	var fxy := HEALPix.pix2face_xy(nside, ipix)
	var face: int = fxy.face
	var variant_at: Callable = zones.get("variant_at", Callable())
	var clearance: NovaClearance = zones.get("clearance")
	var present: Dictionary = zones.get("candidates", {})
	if present.is_empty():
		for i in vid.size():
			present[vid[i]] = true
	for d: Dictionary in descs:
		if not present.has(d.variant):
			continue
		var cells := chunk_cells(nside, ipix, d.nside)
		if cells.is_empty():
			continue
		var r: int = cells.r
		var x0: int = cells.x0
		var y0: int = cells.y0
		var blocks := clampi(ceili(r * float(d.cell_side_m) / maxf(float(d.view_m) * 0.5, BLOCK_M)), 1, MAX_BLOCKS)
		for cy in r:
			if not cancel.is_empty() and cancel[0]:
				return {}
			for cx in r:
				var o := cell_object(d.seed, d.density, face, x0 + cx, y0 + cy)
				if o.is_empty():
					continue
				if d.clump_cells > 1 and float(o.u_edge) >= clump_weight(d.seed, face, float(o.fx), float(o.fy),
						d.clump_cells, d.clump_share):
					continue  # on the open ground between two clumps
				# Grid coordinates of the object inside this chunk.
				var gx: float = (float(o.fx) / float(r) - float(fxy.ix)) * res
				var gy: float = (float(o.fy) / float(r) - float(fxy.iy)) * res
				var xi := clampi(int(gx), 0, res - 1)
				var yi := clampi(int(gy), 0, res - 1)
				var tx := gx - xi
				var ty := gy - yi
				var i00 := yi * (res + 1) + xi
				var i10 := i00 + 1
				var i01 := i00 + res + 1
				var i11 := i01 + 1
				# Where: the cell's direction, a pure function of the cell (never the grid, whose vertices
				# the crack rims slide sideways). How high: the ground the chunk shows, its radial
				# distance interpolated on the grid. Both in doubles; only the small local result is float32.
				var up := HEALPix._face_xy_to_vec(face, float(o.fx), float(o.fy), d.nside)
				var mi := mini(int(o.u_mesh * d.meshes.size()), d.meshes.size() - 1)
				var sc: float = lerpf(d.scale_min, d.scale_max, o.u_scale)
				# Nothing on a road, under a building or in a village, and fewer and fewer objects toward them.
				if clearance != null and float(o.u_keep) >= clearance.share_for(up, float(d.reaches[mi]) * sc, float(o.u_keep)):
					continue
				if variant_at.is_valid():
					# The zone at a point drawn within the layer's spill of the object: the same answer at
					# every LOD, and the share of objects kept is the share of their variant around them —
					# the layer thins out across the frontier as the ground's textures do, instead of
					# stopping on the line.
					if int(variant_at.call(_spilled(up, o, d.spill))) != d.variant:
						continue
				else:
					# Soft variant edge: the share of the cell's corners in this variant.
					var w := (1.0 - tx) * (1.0 - ty) * float(vid[i00] == d.variant) \
							+ tx * (1.0 - ty) * float(vid[i10] == d.variant) \
							+ (1.0 - tx) * ty * float(vid[i01] == d.variant) \
							+ tx * ty * float(vid[i11] == d.variant)
					if w <= 0.0 or o.u_edge >= w:
						continue
				# On the triangle the mesh draws there (a cell is two flat triangles split along its
				# i10 - i01 diagonal), not a smooth blend of the four corners: over a rolling ground the two
				# differ by the cell's twist — 0.6 m on a 25 m cell of the red corundum's relief, more on
				# the coarser levels — and the rocks stood in the air or in the ground.
				var r00 := _radial(center, grid[i00])
				var r10 := _radial(center, grid[i10])
				var r01 := _radial(center, grid[i01])
				var r11 := _radial(center, grid[i11])
				var rad: float = r00 + tx * (r10 - r00) + ty * (r01 - r00) if tx + ty <= 1.0 \
						else r11 + (1.0 - tx) * (r01 - r11) + (1.0 - ty) * (r10 - r11)
				var p := Vector3(float(up.x) * rad - float(center.x), float(up.y) * rad - float(center.y),
						float(up.z) * rad - float(center.z))
				var n := (grid[i10] - grid[i00] + grid[i11] - grid[i01]).cross(
						grid[i01] - grid[i00] + grid[i11] - grid[i10]).normalized()
				if n.dot(up) < 0.0:
					n = -n
				if n.dot(up) < d.cos_slope:
					continue
				var axis := up.slerp(n, d.align).normalized()
				var mesh: Mesh = d.meshes[mi]
				var basis := _basis_on(axis, o.u_yaw * TAU).scaled(Vector3.ONE * sc)
				var origin: Vector3 = p - axis * (float(d.sink) * float(d.heights[mi]) * sc)
				@warning_ignore("integer_division")
				var key := [mesh, cx * blocks / r + (cy * blocks / r) * blocks, float(d.view_limit)]
				var rows: PackedFloat32Array = out.get(key, PackedFloat32Array())
				rows.append_array([basis.x.x, basis.y.x, basis.z.x, origin.x,
						basis.x.y, basis.y.y, basis.z.y, origin.y,
						basis.x.z, basis.y.z, basis.z.z, origin.z,
						origin.x, origin.y, origin.z, 0.0])
				out[key] = rows
	return out


## The direction object [param o] of a cell at [param up] asks its variant at: a point of the disc of
## [param spill] (an angle) around it, drawn evenly from the cell's hash.
static func _spilled(up: Vector3, o: Dictionary, spill: float) -> Vector3:
	if spill <= 0.0:
		return up
	var t1 := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	var turn := float(o.u_spill_turn) * TAU
	return (up + (t1 * cos(turn) + up.cross(t1) * sin(turn)) * (spill * sqrt(float(o.u_spill_far)))).normalized()


## Distance from the planet centre of a chunk-local vertex, in doubles (a float32 sum would be 0.5 m off).
static func _radial(center: Vector3, v: Vector3) -> float:
	var x := float(center.x) + float(v.x)
	var y := float(center.y) + float(v.y)
	var z := float(center.z) + float(v.z)
	return sqrt(x * x + y * y + z * z)


## An orthonormal basis whose Y is [param up], turned by [param yaw] around it.
static func _basis_on(up: Vector3, yaw: float) -> Basis:
	var ref := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := ref.cross(up).normalized()
	var z := x.cross(up).normalized()
	return Basis(x, up, z) * Basis(Vector3.UP, yaw)


## The MultiMesh node of one entry of lay_chunk's result (one model on one block of the chunk), to add under
## the chunk's MeshInstance3D. [param center]: the chunk's centre in the planet's frame, for the rocks' fade in.
static func build_node(key: Array, rows: PackedFloat32Array, layers: int, center := Vector3.ZERO) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = key[0]
	mm.instance_count = rows.size() / ROW
	mm.buffer = rows
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.layers = layers
	# Drawn while it is worth it, measured from the block's middle.
	var view := view_of(key[0], key[2])
	mmi.visibility_range_end = view + mm.get_aabb().size.length() * 0.5
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var parts := fade_parts(center)
	mmi.set_instance_shader_parameter("fade_cell", parts[0])
	mmi.set_instance_shader_parameter("fade_rest", parts[1])
	mmi.set_instance_shader_parameter("fade_end_m", view)
	return mmi


## True when the block of an entry of lay_chunk's result is worth a node for a camera at [param cam] (the
## chunk's frame): always for a layer with no limit of its own (large rocks, seen from afar), else within
## the layer's limit × [param keep] of the block.
static func block_near(key: Array, rows: PackedFloat32Array, cam: Vector3, keep: float) -> bool:
	var limit := float(key[2])
	return limit <= 0.0 or cam.distance_to(block_at(rows)) < limit * keep + BLOCK_M


## [param at] (planet frame) as [whole cells of FADE_CELL_M, the rest]: see FADE_CELL_M.
static func fade_parts(at: Vector3) -> Array[Vector3]:
	var cell := (at / FADE_CELL_M).floor() * FADE_CELL_M
	return [cell, at - cell]


## Where an entry of lay_chunk's result stands, in the chunk's frame: its first object (a block is
## BLOCK_M wide, so any of its objects places it to that).
static func block_at(rows: PackedFloat32Array) -> Vector3:
	return Vector3(rows[3], rows[7], rows[11]) if rows.size() >= ROW else Vector3.ZERO
