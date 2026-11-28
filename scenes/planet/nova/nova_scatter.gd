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
## Settings > Debug > scatter rock collisions: the rocks that collide, drawn as their shapes (client only).
const COLLISION_DEBUG := preload("res://scenes/planet/nova/nova_scatter_collision_debug.gd")
## load_mesh's meshes by path, in the game ([mesh or null]); guarded: the scatter's layers are read on a worker.
static var _meshes_read: Dictionary = {}
static var _meshes_mutex := Mutex.new()
## solid_shapes' answers by model file (or mesh id), guarded like _meshes_read: the server lays on workers.
static var _shapes_made: Dictionary = {}
static var _shapes_mutex := Mutex.new()
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
const FRINGE_MAX_M := 0.4
## Floats per laid object: a MultiMesh transform (12) and its custom data (4) — the object's place in the
## chunk again, which the fade in needs and a shader cannot read back from the transform — and, last, the
## object's layer slot (1, 2…), positive when the object collides ([method is_solid]), negative when not.
const ROW := 16
## A dressed model's meta: the ground colour its material was tinted for (NovaBody.biome_tint of its variant's
## catalogue rock, rock_tint). Each block of rocks is tinted again for the ground it stands on (_tint_block).
const BASE_TINT_META := &"nova_base_tint"
## How far a block's tint may stray from its material's, per channel (ground_ratio).
const GROUND_RATIO_RANGE := Vector2(0.2, 4.0)
## Which laid objects collide (the server lays them as boxes, NovaRockCollision): those at least
## SOLID_MIN_SIZE_M long (largest side) AND standing at least SOLID_MIN_PROUD_M above the ground — a 4 m wide
## gravel patch 6 cm thick is long, and nothing anyone bumps into.
const SOLID_MIN_SIZE_M := 1.0
const SOLID_MIN_PROUD_M := 0.5
## Which laid objects cast a shadow: those standing at least this high above the ground at their layer's
## largest scale (proud_height). Every block of a model is one more draw in each shadow pass; gravel, pebbles
## and flat rubble cast a shadow no one sees, and with them a drive drew 4 200 draws a frame instead of
## 2 500 (16 fps instead of 30, 2026-11-28).
const SHADOW_MIN_PROUD_M := 0.3


## How far a model of bounds [param aabb], scaled by [param scale] and sunk by [param sink] of its height
## (lay_chunk), stands above the ground: from the ground line to its top, along its own up.
static func proud_height(aabb: AABB, scale: float, sink: float) -> float:
	return (aabb.end.y - sink * maxf(aabb.size.y, 0.01)) * scale


## True when an object of bounds [param aabb] at [param scale], sunk by [param sink], collides.
static func is_solid(aabb: AABB, scale: float, sink: float) -> bool:
	return aabb.get_longest_axis_size() * scale >= SOLID_MIN_SIZE_M \
			and proud_height(aabb, scale, sink) >= SOLID_MIN_PROUD_M


## The smallest scale at which a model of bounds [param aabb] sunk by [param sink] collides (both sides of
## [method is_solid] grow with the scale), INF when none does.
static func solid_scale(aabb: AABB, sink: float) -> float:
	var longest := aabb.get_longest_axis_size()
	var proud := proud_height(aabb, 1.0, sink)
	if longest <= 0.0 or proud <= 0.0:
		return INF
	return maxf(SOLID_MIN_SIZE_M / longest, SOLID_MIN_PROUD_M / proud)


## True when some object of layer [param d] (an entry of layer_descs) can collide.
static func layer_can_collide(d: Dictionary) -> bool:
	for s: float in d.get("solid_scales", PackedFloat32Array()):
		if s <= float(d.scale_max):
			return true
	return false


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


## The Graphics option a scatter layer's view distance follows (DrawRange): its blocks are drawn, and laid
## (PlanetTerrain), that much farther or nearer.
const VIEW_OPTION := "terrain_distance"
## Every block of a layer (masks of lay_chunk, cell_survivors): at most MAX_BLOCKS² = 64 bits.
const ALL_BLOCKS := -1
## Doubles per cell in cell_survivors' answer: [cx, cy, fx, fy, u_mesh, u_yaw, u_scale, u_edge, u_spill_turn,
## u_spill_far, u_keep].
const CELL_ROW := 11
## False: lay_chunk asks the GDScript twin even when the C# one is there (tests compare the two).
static var native_cells := true
static var _cells_native: Object = null
static var _cells_native_tried := false
static var _cells_native_mutex := Mutex.new()


## The cells (cx, cy) of the [param r] × [param r] block at face position ([param x0], [param y0]) that hold
## an object of the layer — cell_object, then clump_weight when [param clump_cells] > 1 — row by row,
## CELL_ROW doubles each, within the blocks of [param mask] ([param blocks] × [param blocks] of them, bit
## bx + by × blocks; ALL_BLOCKS: all). The reference of NovaCellsNative.CellsInBlocks, which returns the same numbers
## bit for bit.
static func cell_survivors(layer_seed: int, density: float, face: int, x0: int, y0: int, r: int,
		clump_cells: int, clump_share: float, blocks: int = 1, mask: int = ALL_BLOCKS) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for cy in r:
		@warning_ignore("integer_division")
		var row_block := (cy * blocks / r) * blocks
		for cx in r:
			@warning_ignore("integer_division")
			var bit := row_block + cx * blocks / r
			if (mask >> bit) & 1 == 0:
				continue
			var ix := x0 + cx
			var iy := y0 + cy
			var h := cell_hash(layer_seed, face, ix, iy)
			if unit(h, 0) >= density:
				continue
			var fx := float(ix) + unit(h, 1)
			var fy := float(iy) + unit(h, 2)
			var u_edge := unit(h, 6)
			if clump_cells > 1 and u_edge >= clump_weight(layer_seed, face, fx, fy, clump_cells, clump_share):
				continue
			out.append_array([cx, cy, fx, fy, unit(h, 3), unit(h, 4), unit(h, 5), u_edge, unit(h, 7), unit(h, 8),
					unit(h, 9)])
	return out


## cell_survivors, from the C# twin when it is there (NativeScript: a stale assembly falls back).
static func _survivors(layer_seed: int, density: float, face: int, x0: int, y0: int, r: int, clump_cells: int,
		clump_share: float, blocks: int = 1, mask: int = ALL_BLOCKS) -> PackedFloat64Array:
	if native_cells:
		_cells_native_mutex.lock()
		if not _cells_native_tried:
			_cells_native_tried = true
			var script := NativeScript.load_usable("res://scenes/planet/native/NovaCellsNative.cs", ["CellsInBlocks"])
			_cells_native = script.new() if script != null else null
		var native: Object = _cells_native
		_cells_native_mutex.unlock()
		if native != null:
			return native.CellsInBlocks(layer_seed, density, face, x0, y0, r, clump_cells, clump_share, blocks, mask)
	return cell_survivors(layer_seed, density, face, x0, y0, r, clump_cells, clump_share, blocks, mask)


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
## [param body]: the Nova body to read, when it is not [param data]'s dressed one (the server's, data.nova_relief).
static func zone_context(data: PlanetData, nside: int, ipix: int, body: NovaBody = null) -> Dictionary:
	var nova := body if body != null else data.nova
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
## the ground outside any zone (see NovaBody.rock_of). [param bare]: the models as they are, without the
## ground's look (the server, which only needs their bounds).
static func layer_descs(body: NovaBody, radius: float, default_rock := "", bare := false) -> Array:
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
			var solid_scales := PackedFloat32Array()  # from which scale each model collides (solid_scale)
			var shadows := PackedByteArray()  # whether each model casts a shadow (SHADOW_MIN_PROUD_M)
			var view := 0.0
			# Dressed in the ground's look: this variant's own copy of each model, so the same model stands
			# on two corundums in two colours.
			var look: Material = ground_material(body, id, default_rock) \
					if bool(of.call("like_ground")) and not bare else null
			for p in of.call("meshes"):
				var m := load_mesh(str(p))
				if m == null:
					continue
				if look != null:
					m = dressed(m, body, id, look, float(of.call("own_texture")), default_rock, float(of.call("sink")))
					m.set_meta(BASE_TINT_META, body.biome_tint(rock_tint(body, id, default_rock)))
				meshes.append(m)
				heights.append(maxf(m.get_aabb().size.y, 0.01))
				reaches.append(maxf(m.get_aabb().size.x, m.get_aabb().size.z) * 0.5)
				solid_scales.append(solid_scale(m.get_aabb(), float(of.call("sink"))))
				shadows.append(int(proud_height(m.get_aabb(), float(of.call("scale_max")), float(of.call("sink")))
						>= SHADOW_MIN_PROUD_M))
				if not Engine.is_editor_hint():
					m.set_meta("nova_path", str(p))  # its file, named by the collision debug view's legend
				view = maxf(view, view_of(m, view_limit))
			if meshes.is_empty():
				continue
			var nside := scatter_nside(radius, float(of.call("cell_m")))
			var cell_side := HEALPix.pixel_side_length(nside, radius)
			out.append({
				"variant": id,
				"slot": slot,
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
				"solid_scales": solid_scales,
				"shadows": shadows,
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
## limit, the layer's index in [param descs]]: PackedFloat32Array of MultiMesh rows (ROW floats each)}.
## [param grid]: the chunk-local surface positions of its (res+1)² grid, row-major (yi * (res+1) + xi).
## [param vid]: the variant id of each grid vertex. [param center]: chunk centre, planet-local.
## [param zones]: from zone_context — the variant at an exact direction and the variants the chunk's
## export tile can hold. Without it the grid answers, which depends on the LOD (tests only).
## [param cancel]: [false] the caller sets to true to stop the laying where it is (an empty answer then).
## [param solid_only]: only the objects that collide (the server's colliders), the same rows as the full laying.
## [param masks]: per layer, the blocks to lay (bit bx + by × blocks, layer_blocks): the client lays the blocks
## it draws, and more as the camera nears the others; 0 lays nothing of the layer. Empty: every block. A block
## comes out the same whether laid alone or with the whole chunk.
static func lay_chunk(descs: Array, nside: int, ipix: int, res: int, grid: PackedVector3Array,
		vid: PackedInt32Array, center: Vector3, zones: Dictionary = {}, cancel: Array = [],
		solid_only := false, masks := PackedInt64Array()) -> Dictionary:
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
	for layer in descs.size():
		var d: Dictionary = descs[layer]
		var mask: int = masks[layer] if layer < masks.size() else ALL_BLOCKS
		if mask == 0 or not present.has(d.variant):
			continue
		var cells := chunk_cells(nside, ipix, d.nside)
		if cells.is_empty():
			continue
		var r: int = cells.r
		var x0: int = cells.x0
		var y0: int = cells.y0
		var blocks := layer_blocks(d, nside, ipix)
		var slot := float(d.get("slot", 0))
		var solid_from: PackedFloat32Array = d.get("solid_scales", PackedFloat32Array())
		var model_count := (d.get("meshes", []) as Array).size()
		if solid_from.size() != model_count:
			solid_from.resize(model_count)
			solid_from.fill(INF)
		if not cancel.is_empty() and cancel[0]:
			return {}
		# The cells that hold an object at all (the layer's density, then its clumps: the open ground between
		# two clumps is empty), in C# when it is there — the hash of every cell was most of the laying.
		var cell_rows := _survivors(d.seed, d.density, face, x0, y0, r, int(d.clump_cells), float(d.clump_share),
				blocks, mask)
		var last_cy := -1
		for at in range(0, cell_rows.size(), CELL_ROW):
			var cx := int(cell_rows[at])
			var cy := int(cell_rows[at + 1])
			if cy != last_cy:
				last_cy = cy
				if not cancel.is_empty() and cancel[0]:
					return {}
			var fx := cell_rows[at + 2]
			var fy := cell_rows[at + 3]
			var u_mesh := cell_rows[at + 4]
			var u_scale := cell_rows[at + 6]
			var u_edge := cell_rows[at + 7]
			var u_keep := cell_rows[at + 10]
			# In a solid-only laying, the model and its scale: most cells end here, before the clearance
			# and the zones are asked.
			if solid_only and lerpf(d.scale_min, d.scale_max, u_scale) \
					< solid_from[mini(int(u_mesh * d.meshes.size()), d.meshes.size() - 1)]:
				continue
			# Grid coordinates of the object inside this chunk.
			var gx: float = (fx / float(r) - float(fxy.ix)) * res
			var gy: float = (fy / float(r) - float(fxy.iy)) * res
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
			var up := HEALPix._face_xy_to_vec(face, fx, fy, d.nside)
			var mi := mini(int(u_mesh * d.meshes.size()), d.meshes.size() - 1)
			var sc: float = lerpf(d.scale_min, d.scale_max, u_scale)
			# Too steep: the grid's slope there, first — a few vector operations, where the clearance and the
			# zone below are the dear part of an object (the same objects come out in any order of the tests).
			var n := (grid[i10] - grid[i00] + grid[i11] - grid[i01]).cross(
					grid[i01] - grid[i00] + grid[i11] - grid[i10]).normalized()
			if n.dot(up) < 0.0:
				n = -n
			if n.dot(up) < d.cos_slope:
				continue
			# Nothing on a road, under a building or in a village, and fewer and fewer objects toward them.
			if clearance != null and u_keep >= clearance.share_for(up, float(d.reaches[mi]) * sc, u_keep):
				continue
			if variant_at.is_valid():
				# The zone at a point drawn within the layer's spill of the object: the same answer at
				# every LOD, and the share of objects kept is the share of their variant around them —
				# the layer thins out across the frontier as the ground's textures do, instead of
				# stopping on the line.
				if int(variant_at.call(_spilled(up, cell_rows[at + 8], cell_rows[at + 9], d.spill))) != d.variant:
					continue
			else:
				# Soft variant edge: the share of the cell's corners in this variant.
				var w := (1.0 - tx) * (1.0 - ty) * float(vid[i00] == d.variant) \
						+ tx * (1.0 - ty) * float(vid[i10] == d.variant) \
						+ (1.0 - tx) * ty * float(vid[i01] == d.variant) \
						+ tx * ty * float(vid[i11] == d.variant)
				if w <= 0.0 or u_edge >= w:
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
			var axis := up.slerp(n, d.align).normalized()
			var mesh: Mesh = d.meshes[mi]
			var basis := _basis_on(axis, cell_rows[at + 5] * TAU).scaled(Vector3.ONE * sc)
			var origin: Vector3 = p - axis * (float(d.sink) * float(d.heights[mi]) * sc)
			@warning_ignore("integer_division")
			var key := [mesh, cx * blocks / r + (cy * blocks / r) * blocks, float(d.view_limit), layer]
			var rows: PackedFloat32Array = out.get(key, PackedFloat32Array())
			rows.append_array([basis.x.x, basis.y.x, basis.z.x, origin.x,
					basis.x.y, basis.y.y, basis.z.y, origin.y,
					basis.x.z, basis.y.z, basis.z.z, origin.z,
					origin.x, origin.y, origin.z, slot if sc >= solid_from[mi] else -slot])
			out[key] = rows
	return out


## The transform of the object at float [param at] of [param rows] (lay_chunk's), in the chunk's frame.
static func row_transform(rows: PackedFloat32Array, at: int) -> Transform3D:
	return Transform3D(Basis(Vector3(rows[at], rows[at + 4], rows[at + 8]), Vector3(rows[at + 1], rows[at + 5], rows[at + 9]),
			Vector3(rows[at + 2], rows[at + 6], rows[at + 10])), Vector3(rows[at + 3], rows[at + 7], rows[at + 11]))


## What a colliding object of [param mesh] collides with: [[shape, its transform in the model's frame], …].
## The shapes its scene carries when it has some — CollisionShape3D nodes, from the import's Physics (Advanced
## Import Settings: the mesh node, Physics > Generate) or from Blender objects named "-colonly" / "-convcolonly"
## — else one convex hull of the model, simplified (Mesh.create_convex_shape, at most 32 points). The box of
## the model's bounds it replaces was mostly air: a terrace fills a fifth of its box above the ground, a slab
## an eighth, and a truck ran into the empty corners (2026-11-28). Made once per model file (a hull is a
## convex decomposition, 20 to 150 ms) and shared by every rock of it; thread-safe. The bounds' box when the
## model has no geometry to hull.
static func solid_shapes(mesh: Mesh) -> Array:
	var path := str(mesh.get_meta("nova_path", ""))
	var id: Variant = path if path != "" else mesh.get_instance_id()
	_shapes_mutex.lock()
	var known: Variant = _shapes_made.get(id)
	_shapes_mutex.unlock()
	if known != null:
		return known
	var made := scene_shapes(path) if path != "" else []
	if made.is_empty():
		var hull := mesh.create_convex_shape(true, true) as ConvexPolygonShape3D
		if hull != null and hull.points.size() >= 4:
			made = [[hull, Transform3D.IDENTITY]]
		else:
			var box := BoxShape3D.new()
			box.size = mesh.get_aabb().size
			made = [[box, Transform3D(Basis.IDENTITY, mesh.get_aabb().get_center())]]
	_shapes_mutex.lock()
	if _shapes_made.has(id):
		made = _shapes_made[id]
	else:
		_shapes_made[id] = made
	_shapes_mutex.unlock()
	return made


## The collision shapes the scene at [param path] carries (CollisionShape3D nodes, enabled, with a shape), each
## with its transform from the scene's root — the frame its model is read in (load_mesh). [] for a mesh file
## or a scene without any.
static func scene_shapes(path: String) -> Array:
	if path == "" or not ResourceLoader.exists(path):
		return []
	var scene := load(path) as PackedScene
	if scene == null:
		return []
	var root := scene.instantiate()
	var out: Array = []
	for node in root.find_children("*", "CollisionShape3D", true, false):
		var cs := node as CollisionShape3D
		if cs.disabled or cs.shape == null:
			continue
		var xform := cs.transform
		var up := cs.get_parent() as Node3D
		while up != null and up != root:
			xform = up.transform * xform
			up = up.get_parent() as Node3D
		out.append([cs.shape, xform])
	root.free()
	return out


## The colliding objects of a lay_chunk result, in the chunk's frame: one entry a shape of each
## ([method solid_shapes]): [[transform (the object's, scaled like it, times the shape's), shape, slot of its
## layer, model], …].
static func solid_parts(laid: Dictionary) -> Array:
	var out: Array = []
	for key: Array in laid:
		var mesh: Mesh = key[0]
		var rows: PackedFloat32Array = laid[key]
		var shapes: Array = []
		for at in range(0, rows.size(), ROW):
			if rows[at + 15] <= 0.0:
				continue
			if shapes.is_empty():
				shapes = solid_shapes(mesh)
			var xform := row_transform(rows, at)
			for part: Array in shapes:
				out.append([xform * (part[1] as Transform3D), part[0], int(rows[at + 15]), mesh])
	return out


## The direction a cell's object at [param up] asks its variant at: a point of the disc of
## [param spill] (an angle) around it, drawn evenly from the cell's hash.
static func _spilled(up: Vector3, u_spill_turn: float, u_spill_far: float, spill: float) -> Vector3:
	if spill <= 0.0:
		return up
	var t1 := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	var turn := u_spill_turn * TAU
	return (up + (t1 * cos(turn) + up.cross(t1) * sin(turn)) * (spill * sqrt(u_spill_far))).normalized()


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
## Drawn as far as Graphics > Terrain distance says (DrawRange, VIEW_OPTION): [param mult] is its multiplier
## now, for the fade in, which set_view_mult moves when the option does.
static func build_node(key: Array, rows: PackedFloat32Array, layers: int, center := Vector3.ZERO,
		mult := 1.0, shadow := true) -> MultiMeshInstance3D:
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
	if Engine.is_editor_hint():
		mmi.visibility_range_end = view + mm.get_aabb().size.length() * 0.5
	else:
		DrawRange.track(mmi, VIEW_OPTION, 0.0, view + mm.get_aabb().size.length() * 0.5)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var parts := fade_parts(center)
	mmi.set_instance_shader_parameter("fade_cell", parts[0])
	mmi.set_instance_shader_parameter("fade_rest", parts[1])
	mmi.set_meta(&"nova_view", view)
	set_view_mult(mmi, mult)
	if not Engine.is_editor_hint():
		COLLISION_DEBUG.on_block(mmi, rows)
	if (key[0] as Mesh).has_meta(BASE_TINT_META):
		mmi.ready.connect(_tint_block.bind(mmi, center), CONNECT_ONE_SHOT)
	return mmi


## The rocks of block [param mmi] (a chunk centred at [param center], planet frame) in the colour of the ground
## they stand on: the ground's vertex colour there through the ground shader's start (NovaBody.biome_tint, as
## nova_ground_at colours the ground), over the colour their material was made for (its variant's catalogue
## rock). Made for the catalogue rock alone, the rocks stood beige on a dark green-grey corundum (2026-11-25).
static func _tint_block(mmi: MultiMeshInstance3D, center: Vector3) -> void:
	var planet := Planet.of(mmi)
	if planet == null or planet.planet_data == null or planet.planet_data.nova == null or center.is_zero_approx():
		return
	var vertex := planet.planet_data.ground_vertex_tint_at(center.normalized())
	if vertex == Color(0, 0, 0, 0):  # nothing sampled there (GroundLook.NO_SAMPLE)
		return
	var base: Color = mmi.multimesh.mesh.get_meta(BASE_TINT_META)
	mmi.set_instance_shader_parameter("ground_ratio", ground_ratio(planet.planet_data.nova.biome_tint(vertex), base))


## The tint that takes a material made for ground colour [param base] to ground colour [param here], per
## channel, within GROUND_RATIO_RANGE.
static func ground_ratio(here: Color, base: Color) -> Vector3:
	return Vector3(clampf(here.r / maxf(base.r, 1e-4), GROUND_RATIO_RANGE.x, GROUND_RATIO_RANGE.y),
			clampf(here.g / maxf(base.g, 1e-4), GROUND_RATIO_RANGE.x, GROUND_RATIO_RANGE.y),
			clampf(here.b / maxf(base.b, 1e-4), GROUND_RATIO_RANGE.x, GROUND_RATIO_RANGE.y))


## How many blocks a side layer [param d] cuts chunk ([param nside], [param ipix]) into (lay_chunk's keys and
## masks): about half its view distance each, at least BLOCK_M, at most MAX_BLOCKS a side.
static func layer_blocks(d: Dictionary, nside: int, ipix: int) -> int:
	var cells := chunk_cells(nside, ipix, int(d.nside))
	if cells.is_empty():
		return 1
	return clampi(ceili(int(cells.r) * float(d.cell_side_m) / maxf(float(d.view_m) * 0.5, BLOCK_M)), 1, MAX_BLOCKS)


## The box (chunk frame) of each of the [param blocks] × [param blocks] blocks of a chunk: its
## [param grid]'s vertices ((res+1)², row-major) over the block's span, index bx + by × blocks. What a block
## of objects can be measured by before it is laid: the objects stand on that ground.
static func block_boxes(grid: PackedVector3Array, res: int, blocks: int) -> Array[AABB]:
	var out: Array[AABB] = []
	for by in blocks:
		for bx in blocks:
			@warning_ignore("integer_division")
			var x_from := bx * res / blocks
			@warning_ignore("integer_division")
			var y_from := by * res / blocks
			var x_to := ceili(float((bx + 1) * res) / blocks)
			var y_to := ceili(float((by + 1) * res) / blocks)
			var box := AABB(grid[y_from * (res + 1) + x_from], Vector3.ZERO)
			for yi in range(y_from, y_to + 1):
				for xi in range(x_from, x_to + 1):
					box = box.expand(grid[yi * (res + 1) + xi])
			out.append(box)
	return out


## The middle of the block of [param mask] (bits of [param boxes], block_boxes) nearest [param cam] (chunk frame).
static func nearest_block(boxes: Array[AABB], mask: int, cam: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var best_d := INF
	for b in boxes.size():
		if (mask >> b) & 1 == 0:
			continue
		var box: AABB = boxes[b]
		var d := cam.distance_to(cam.clamp(box.position, box.end))
		if d < best_d:
			best_d = d
			best = box.get_center()
	return best


## The blocks among [param boxes] (block_boxes) with ground within [param reach] metres of [param cam] (chunk
## frame), as a mask (bit = index).
static func blocks_within(boxes: Array[AABB], cam: Vector3, reach: float) -> int:
	var mask := 0
	for b in boxes.size():
		var box: AABB = boxes[b]
		if cam.distance_to(cam.clamp(box.position, box.end)) <= reach:
			mask |= 1 << b
	return mask


## The fade in of block node [param mmi] (build_node) for the view distance option's multiplier [param mult]:
## the rocks grow in over the same distance their node is drawn to.
static func set_view_mult(mmi: GeometryInstance3D, mult: float) -> void:
	mmi.set_instance_shader_parameter("fade_end_m", float(mmi.get_meta(&"nova_view", 0.0)) * mult)


## [param at] (planet frame) as [whole cells of FADE_CELL_M, the rest]: see FADE_CELL_M.
static func fade_parts(at: Vector3) -> Array[Vector3]:
	var cell := (at / FADE_CELL_M).floor() * FADE_CELL_M
	return [cell, at - cell]

