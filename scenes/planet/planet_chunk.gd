@tool
class_name PlanetChunk
## Static helpers for generating terrain-chunk meshes & collision shapes.
##
## Each chunk covers a rectangular patch on one cube-sphere face.
## Vertices are displaced along the sphere normal by the heightmap value.
## Biome colours are baked into vertex colours so the base material uses
## [code]vertex_color_use_as_albedo = true[/code].

## Biome terrain constants are now in self-contained modules:
##   Linear: MaritimeRiverRiverTerrain, RockyLandformCanyonTerrain, IcyIceCrevasseTerrain,
##           ArideDesertDryRiverBedTerrain, RockyLandformPressureCanyonTerrain, VolcanicGeothermalLavaRiverTerrain
##   Point:  CaveTerrain, SpatialCraterTerrain, VolcanicGeothermalFumaroleTerrain, VolcanicGeothermalIceGeyserTerrain,
##           VolcanicGeothermalMineralThermalSourceTerrain
##   Overlay: RoadTerrain (biome-adaptive road textures)


## LOD-seam stitch mask: which edges of the chunk face a neighbour ONE quadtree
## level coarser (PlanetTerrain sets it from the balanced leaf set; see
## [method edge_stitch_applies] and [method _stitch_edge_heights]).
const STITCH_LEFT   := 1  # xi == 0   (HEALPix "W" neighbour)
const STITCH_RIGHT  := 2  # xi == res ("E")
const STITCH_BOTTOM := 4  # yi == 0   ("S")
const STITCH_TOP    := 8  # yi == res ("N")
## Rows blended from the parent level towards the chunk's own level behind a
## stitched edge, when the two read DIFFERENT pyramid tiles: row 0 is fully the
## parent's, row STITCH_BLEND_ROWS the chunk's own. Spreads the level-to-level
## data step over that many cells instead of one.
const STITCH_BLEND_ROWS := 3
## An edge is stitched only if bending the chunk onto the parent's border
## costs at most this slope over the rows it is spread on: past it the
## coarse neighbour's chord is nowhere near the terrain (tarsis_3 has 600 m
## cliffs inside one 200 m texel: the parent chord sits 300-800 m off the
## surface there) and the stitch would raise a sloped block along the
## border. Such an edge keeps its own heights and its skirt hides the seam
## as before — a vertical curtain where the terrain is a cliff anyway.
## 5 %: a 35 m level-to-level mismatch on a dune (what the stitch is for)
## spreads over 3 rows of 400 m at n1024 well under it; a 160 m one — the
## mesa's edge seen from 15 km — does not, and stays a curtain.
const STITCH_MAX_SLOPE := 0.05

# One-shot guard for the corundum-default-biome debug print (temporary).
static var _corundum_logged := false

# The Globals SCRIPT, not the autoload: this file is @tool and builds chunks in the
# editor too, where a non-tool autoload is only a placeholder instance (calling a
# method on it errors out). Constants and static funcs read fine off the script.
const GlobalsDefs := preload("res://scenes/globals/globals.gd")


## Generate a visual [ArrayMesh] for one terrain chunk.
## [param data] — planet configuration (heightmap, radius, etc.)
## [param face] — cube face index 0–5
## [param u_min] / [param u_max] — horizontal bounds on the face (−1 … 1)
## [param v_min] / [param v_max] — vertical bounds on the face (−1 … 1)
## [param resolution] — number of quads per edge (vertex count = res + 1)
static func generate_mesh(
		data: PlanetData,
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		resolution: int,
		chunk_center: Vector3 = Vector3.ZERO,
		hp_nside: int = 0,
		hp_ipix: int = -1,
		prof: Dictionary = {},
		stitch: int = 0) -> ArrayMesh:

	# Découpage du coût de génération, phase 0 de docs/PLANET_CHUNK_STREAMING.md.
	# Cette fonction tourne sur WorkerThreadPool : on n'écrit QUE dans `prof`, qui
	# appartient à l'appelant et n'est vu que par ce thread. Le reversement dans les
	# compteurs partagés (PropNet.prof_chunk_*) se fait sur le thread principal, dans
	# PlanetTerrain._poll_mesh_tasks. Rig éteint => un test booléen par section.
	var _pf: bool = PropNet.prof_on
	var _t_phase: int = Time.get_ticks_usec() if _pf else 0
	var _t_start: int = _t_phase
	# Coût de lecture de tuile propre À CE MESH : le compteur global compte aussi les
	# lectures faites hors génération (chunks servis par le cache disque, requêtes de
	# gameplay, spawners), ce qui donnait une part de 144 % du temps mesh.
	var _t_tile0: int = PlanetData.prof_thread_tile_usec() if _pf else 0

	var res := resolution
	var vert_count := (res + 1) * (res + 1)
	# Même garde que le constructeur de collision : un mesh bâti sur un ancêtre supposé
	# ne doit pas être persisté, sans quoi il survit à l'arrivée de la vraie tuile.
	data.climb_reset()
	var vertices := PackedVector3Array()
	var normals  := PackedVector3Array()
	var uvs      := PackedVector2Array()
	var uv2s     := PackedVector2Array()  # .x = detail layer index, .y = detail tiling scale
	var colors   := PackedColorArray()
	var indices  := PackedInt32Array()
	# CUSTOM0: inverse skirt offset (3 floats per vertex).  Zero for terrain
	# vertices; non-zero for skirt vertices so the shader can recover the
	# surface position for triplanar UV:  surface_pos = VERTEX + CUSTOM0.
	var skirt_offsets := PackedFloat32Array()

	vertices.resize(vert_count)
	normals.resize(vert_count)
	uvs.resize(vert_count)
	uv2s.resize(vert_count)
	colors.resize(vert_count)
	skirt_offsets.resize(vert_count * 3)  # initialized to 0.0 for surface verts

	var hp_mode := hp_nside > 0
	var u_step := (u_max - u_min) / float(res) if not hp_mode else 0.0
	var v_step := (v_max - v_min) / float(res) if not hp_mode else 0.0

	# HEALPix direction grid (replaces cube-sphere u/v iteration).
	var grid_dirs: Array[PackedVector3Array] = []
	# Export-level ipix for height sampling.  Using the deterministic
	# parent-chain avoids vec2pix_nest rounding at the polar/equatorial
	# cap boundary where it may return a pixel on the wrong face.
	# When the chunk is COARSER than export_nside (low-LOD chunks like
	# hp_n1/2/4/8 vs export_nside=64), it spans many export tiles, so
	# there is no single export ipix; leave it -1 and let
	# sample_height_for_direction resolve per-vertex via vec2pix_nest.
	# Pyramid level this chunk samples heights from (its own nside, clamped to the
	# baked range; == export_nside for legacy single-level exports).
	var _sample_nside := data.sample_nside_for(hp_nside)
	var _export_ipix: int = -1
	if hp_mode:
		grid_dirs = HEALPix.get_pixel_grid(hp_nside, hp_ipix, res)
		if hp_nside >= data.export_nside:
			# Finer than the finest tile → walk UP to the finest (nside_max) tile.
			_export_ipix = hp_ipix
			var _ns := hp_nside
			while _ns > data.export_nside:
				_export_ipix >>= 2
				_ns /= 2
		elif hp_nside == _sample_nside:
			# Pyramid: this chunk's own coarse level is baked → one tile per chunk.
			_export_ipix = hp_ipix
		# else: coarser than the coarsest baked level (or legacy flat export) →
		# leave -1 so each vertex resolves its tile via vec2pix at _sample_nside.
	# Cadre d'échantillonnage du chunk : face, position dans la face, voisines et tableau de
	# floats, résolus au premier accès et mémorisés PAR TUILE. Un chunk en touche neuf au
	# plus — la sienne et celles que ses sommets de bord atteignent — contre 5 445
	# échantillons, dont chacun refaisait le travail, get_neighbors_nest() en tête.
	#
	# Le cadre remplace les trois précalculs qu'on passait à la main, et pas seulement pour
	# la vitesse : eux décrivaient la tuile DEMANDÉE, alors qu'un sommet de bord bascule sur
	# la tuile voisine et qu'un pack creux fait remonter à un ancêtre. Le cadre est indexé
	# par tuile, donc il donne toujours ceux de la tuile réellement lue.
	#
	# Mesuré sur un chunk de tarsis_3 dont les sommets tombent dans la marge de mélange de
	# 4 texels : 550 → 185 ms de génération, dont les sommets de bord 120 → 45 µs. Hauteurs
	# identiques au bit près (test/perf/bench_height_sampling.gd,
	# test/unit/test_chunk_sampling_precompute.gd).
	var _frame: PlanetData.TileFrame = data.make_tile_frame() if hp_mode else null

	# ── Float32 precision fix ──────────────────────────────────────
	# Vertex positions are stored as float32 in PackedVector3Array.
	# To minimise seams between adjacent chunks we force chunk_center
	# through a float32 round-trip so that the GPU-side mi.position
	# (camera-relative f32) is consistent.
	#
	# We compute  local = world_f64 - cc_f32  in float64 (GDScript
	# native precision in Double-Precision builds), then snap the
	# *result* to float32 for the mesh buffer.  This preserves height
	# precision to ~60 µm (ULP at ±500 m local range) instead of the
	# ~0.12–0.25 m terracing caused by snapping the world position to
	# float32 before subtracting.
	# Skirt geometry hides any sub-mm boundary seams this introduces.
	var _cc_f32 := PackedFloat32Array([chunk_center.x, chunk_center.y, chunk_center.z])
	var cc_f32 := Vector3(_cc_f32[0], _cc_f32[1], _cc_f32[2])
	# Reusable buffer for snapping local-space offsets to float32.
	var _wp_f32 := PackedFloat32Array([0.0, 0.0, 0.0])

	# Pre-fetch recipe biome data for this chunk (replaces BiomeQuery).
	var _rbd := _get_recipe_biome_data(data, hp_nside, hp_ipix)
	var _pz_zones: Array = _rbd[0]   # populate_zones
	var _lf_arr: Array = _rbd[1]     # linear_features
	var _rf_arr: Array = _rbd[2]     # radial_features
	var _cr_arr: Array = _rbd[3]     # sub-pixel craters
	var _road_arr: Array = _rbd[4]   # road pieces, already clipped to this chunk

	# Cuttings of profiled lines (railways, graded roads): the per-vertex rule
	# of GradeBed.apply, armed only on the finest grid (see
	# GradeBed.carve_enabled) and only when such a line
	# with a profile runs through this chunk or one of its eight neighbours.
	# `_rw_band` remembers which vertices it moved, so the normal pass below
	# carves its gradient probes the same way (sharp walls) and nowhere else.
	var _rw_ctx: Dictionary = {}
	var _rw_band := PackedByteArray()
	# Final coarse heights in double, for the refinement patch (the f32
	# _chunk_heights below is for the skirt sizing only).
	var _rw_h := PackedFloat64Array()
	# On the coarser LODs the cutting is not carved (the grid cannot hold it),
	# but the terrain is still shaved down to the bed top around the line so
	# it never pierces the bed — `_rw_shave` (visual only, see GradeBed).
	var _rw_shave: Dictionary = {}
	if hp_mode and res > 0 and data.has_profiled_lines():
		var _rw_pitch := HEALPix.pixel_side_length(hp_nside, data.radius) / float(res)
		_rw_ctx = GradeBed.make_ctx(data, hp_nside, hp_ipix, _rw_pitch)
		if not _rw_ctx.is_empty():
			_rw_band.resize((res + 1) * (res + 1))
			_rw_h.resize((res + 1) * (res + 1))
		else:
			_rw_shave = GradeBed.make_coarse_ctx(data, hp_nside, hp_ipix, _rw_pitch)
			if not _rw_shave.is_empty():
				_rw_band.resize((res + 1) * (res + 1))

	# Quick check: does this chunk potentially overlap any liquid/shallow zone?
	# Derived from recipe data — no GeoJSON needed.
	var has_liquid_overlap := false
	var has_shallow_water_overlap := false
	var has_river_overlap := false
	var _river_zones: Array[Dictionary] = []  # linear features matching river
	var has_linear_overlap := false
	var has_point_overlap := false
	var has_crater_overlap := not _cr_arr.is_empty()
	var has_volcanic_active_overlap := false
	var has_lunar_ground_overlap := false
	var has_lava_river_overlap := false
	var has_meadow_overlap := false
	var has_forest_ground_overlap := false
	var has_cliff_overlap := false
	var has_dry_river_bed_overlap := false
	var _dry_river_bed_zones: Array[Dictionary] = []  # linear features matching dry riverbed
	# Biomes whose BiomeDefinition carries a (non-liquid) terrain_material_override
	# — an outcrop's hex-tiled rock, say: their quads leave the base surface for
	# one surface per material. Index 0 = none; k = _surface_mats[k - 1].
	var has_surface_override_overlap := false
	var _surface_mats: Array = []
	var _surface_mat_index: Dictionary = {}   # material path → k
	# Biomes with a relief noise (BiomeDefinition.relief_*): k = _relief_bds[k - 1].
	var has_relief_overlap := false
	var _relief_bds: Array = []
	var _relief_index: Dictionary = {}        # biome_type → k

	# Road overlay. Normally the tile from terrainmodifier.pack already holds
	# this chunk's own disjoint stretch, so the test is just "is it empty".
	# The BiomeQuery/roads_geojson path below is the transition fallback for
	# planets that have not been re-exported yet (and for use_modifier_pack=off).
	var has_road_overlap := not _road_arr.is_empty()
	var rq = null
	if not has_road_overlap and data.get_modifier_pack() == null:
		rq = data.get_road_query()  # may be null

	# HEALPix lon/lat bounding box (reused for road overlay).
	var _cbb: Array[Vector2] = []
	if hp_mode:
		_cbb = _healpix_lonlat_bbox(hp_nside, hp_ipix)
		var _cbb_mn: Vector2 = _cbb[0]
		var _cbb_mx: Vector2 = _cbb[1]
		if rq and rq.is_loaded():
			for _rz in rq.get_zones_for_region(_cbb_mn, _cbb_mx):
				if BiomeQuery._aabb_overlap(_cbb_mn, _cbb_mx, _rz.bbox_min, _rz.bbox_max):
					has_road_overlap = true
					break
	else:
		if rq and rq.is_loaded():
			has_road_overlap = rq.chunk_overlaps_any_zone(
				face, u_min, u_max, v_min, v_max)

	# ── Recipe-based overlap detection ─────────────────────────────
	# Populate zones (polygon/point biomes).
	for _pz in _pz_zones:
		var _bt: String = _pz.get("biome_type", "")
		var _bd = data.get_biome_by_type(_bt)
		if _bd == null:
			continue
		if _bd.is_liquid and data.has_ocean:
			has_liquid_overlap = true
		if _bd.get("has_shallow_water"):
			has_shallow_water_overlap = true
		if CaveTerrain.is_cave_biome(_bd) \
				or VolcanicGeothermalFumaroleTerrain.is_fumarole_biome(_bd) \
				or VolcanicGeothermalIceGeyserTerrain.matches_zone(_bd) \
				or VolcanicGeothermalMineralThermalSourceTerrain.matches_zone(_bd) \
				or VolcanicGeothermalActiveVolcanoTerrain.is_active_volcano_biome(_bd):
			has_point_overlap = true
		if VolcanicGeothermalActiveVolcanoTerrain.is_active_volcano_biome(_bd):
			has_volcanic_active_overlap = true
		if SpatialLunarGroundTerrain.matches_zone(_bd):
			has_lunar_ground_overlap = true
		if MeadowSteppeMeadowTerrain.matches_zone(_bd):
			has_meadow_overlap = true
		if ForestTemperateForestTerrain.matches_zone(_bd):
			has_forest_ground_overlap = true
		if RockyLandformCliffTerrain.matches_zone(_bd):
			has_cliff_overlap = true
		if SpatialCraterTerrain.is_crater_biome(_bd):
			has_crater_overlap = true
		if _bd.terrain_material_override and not _bd.is_liquid:
			has_surface_override_overlap = true
			var _om_path: String = _bd.terrain_material_override.resource_path
			if not _surface_mat_index.has(_om_path):
				_surface_mats.append(_bd.terrain_material_override)
				_surface_mat_index[_om_path] = _surface_mats.size()
		if _bd.has_relief():
			has_relief_overlap = true
			if not _relief_index.has(_bd.biome_type):
				_relief_bds.append(_bd)
				_relief_index[_bd.biome_type] = _relief_bds.size()

	# Linear features (rivers, canyons, crevasses, lava rivers, etc.).
	for _lf in _lf_arr:
		var _lt: String = _lf.get("type", "")
		var _lcl: Array = _lf.get("centerline", [])
		if _lcl.size() < 2:
			continue
		if _lt == "maritime_river-river":
			has_river_overlap = true
			_river_zones.append(_lf)
		elif _lt == "volcanic_geothermal-lava_river":
			has_lava_river_overlap = true
		elif _lt == "aride_desert-dry_river_bed":
			has_linear_overlap = true
			has_dry_river_bed_overlap = true
			_dry_river_bed_zones.append(_lf)
		elif _lt == "rocky_landform-canyon" or _lt == "icy-ice_crevasse" \
				or _lt == "rocky_landform-pressure_canyon":
			has_linear_overlap = true

	# Radial features.
	for _rf in _rf_arr:
		var _rt: String = _rf.get("type", "")
		if _rt == "volcanic_geothermal-active_volcano":
			has_volcanic_active_overlap = true
			has_point_overlap = true

	# Pre-prepare river zones (linear features have same keys as prepare_zone expects).
	if has_river_overlap:
		for _rz in _river_zones:
			var _rcl: Array = _rz.get("centerline", [])
			if _rcl.size() >= 2:
				MaritimeRiverRiverTerrain.prepare_zone(_rz, data.radius)
	if has_dry_river_bed_overlap:
		for _drbz in _dry_river_bed_zones:
			var _drbcl: Array = _drbz.get("centerline", [])
			if _drbcl.size() >= 2:
				ArideDesertDryRiverBedTerrain.prepare_zone(_drbz, data.radius)

	# Per-vertex: liquid flag + original terrain height (before depression).
	var is_liquid_vertex: PackedByteArray = PackedByteArray()
	var original_height: PackedFloat32Array = PackedFloat32Array()
	if has_liquid_overlap:
		is_liquid_vertex.resize(vert_count)
		original_height.resize(vert_count)

	# Per-vertex: shallow water flag (swamp, bog, marsh).
	var is_shallow_water_vertex: PackedByteArray = PackedByteArray()
	if has_shallow_water_overlap:
		is_shallow_water_vertex.resize(vert_count)

	# Per-vertex: volcanic_active flag for lava overlay.
	var is_volcanic_active_vertex: PackedByteArray = PackedByteArray()
	if has_volcanic_active_overlap:
		is_volcanic_active_vertex.resize(vert_count)

	# Per-vertex: lunar_ground flag for lunar ground material overlay.
	var is_lunar_ground_vertex: PackedByteArray = PackedByteArray()
	if has_lunar_ground_overlap:
		is_lunar_ground_vertex.resize(vert_count)

	# Per-vertex: meadow flag for grass ground material overlay.
	var is_meadow_vertex: PackedByteArray = PackedByteArray()
	if has_meadow_overlap:
		is_meadow_vertex.resize(vert_count)

	# Per-vertex: forest_ground flag for leaf-litter material overlay.
	var is_forest_ground_vertex: PackedByteArray = PackedByteArray()
	if has_forest_ground_overlap:
		is_forest_ground_vertex.resize(vert_count)

	# Per-vertex: surface-override material index (0 = none).
	var surface_override_vertex: PackedInt32Array = PackedInt32Array()
	if has_surface_override_overlap:
		surface_override_vertex.resize(vert_count)

	# Per-vertex: relief biome index (0 = none) and its road weight, so the
	# normal probes re-evaluate the same relief at their own directions.
	var relief_vertex: PackedInt32Array = PackedInt32Array()
	var relief_road_w: PackedFloat32Array = PackedFloat32Array()
	if has_relief_overlap:
		relief_vertex.resize(vert_count)
		relief_road_w.resize(vert_count)

	# Per-vertex: cliff flag for cliff face material overlay.
	var is_cliff_vertex: PackedByteArray = PackedByteArray()
	if has_cliff_overlap:
		is_cliff_vertex.resize(vert_count)

	# Per-vertex: lava_river flag + original height before depression.
	# The lava surface sits at the original terrain height (like water),
	# so we need to remember the pre-depression height per vertex.
	# Flow-aligned UVs are pre-computed so the texture follows the river.
	var is_lava_river_vertex: PackedByteArray = PackedByteArray()
	var lava_river_original_height: PackedFloat32Array = PackedFloat32Array()
	var lava_river_flow_uv: PackedVector2Array = PackedVector2Array()
	if has_lava_river_overlap:
		is_lava_river_vertex.resize(vert_count)
		lava_river_original_height.resize(vert_count)
		lava_river_flow_uv.resize(vert_count)

	# Per-vertex: dry_river_bed flag + flow-aligned UVs for pebble texture overlay.
	# The pebble material sits on the carved riverbed floor (post-depression).
	var is_dry_river_bed_vertex: PackedByteArray = PackedByteArray()
	var dry_river_bed_flow_uv: PackedVector2Array = PackedVector2Array()
	if has_dry_river_bed_overlap:
		is_dry_river_bed_vertex.resize(vert_count)
		dry_river_bed_flow_uv.resize(vert_count)

	# Per-vertex: river flag + original terrain height before V-depression.
	var is_river_vertex: PackedByteArray = PackedByteArray()
	var river_original_height: PackedFloat32Array = PackedFloat32Array()
	var river_cross_t: PackedFloat32Array = PackedFloat32Array()  # 0=center, 1=edge
	var river_along_t: PackedFloat32Array = PackedFloat32Array()  # 0=start, 1=end of river
	var river_zone_for_flow: Dictionary = {}
	if has_river_overlap:
		is_river_vertex.resize(vert_count)
		river_original_height.resize(vert_count)
		river_cross_t.resize(vert_count)
		river_along_t.resize(vert_count)

	# How far the terrain is pushed below the water surface (metres).
	const LIQUID_DEPTH := 10.0
	# How far above the original terrain the water surface sits.
	const WATER_OFFSET := 2.0

	# Ensure the detail texture array is built so the shader has it.
	data.get_detail_texture_array()

	# ── Corundum default biome ─────────────────────────────────────
	# When enabled, a vertex that no populate zone assigns a KNOWN biome is
	# coloured / detailed as aride_desert-corundum_plateau and carved with the
	# crack network; a vertex inside a biome's zone is that biome's, uncarved
	# (PlanetData.corundum_applies_to_zone — the collision applies the same).
	var _corundum_bd: BiomeDefinition = null
	# Mesh vertex spacing (m) for this chunk — the LOD gate of every feature
	# that must exist in the mesh and the collision alike (the crack carve is
	# skipped past half its width, the biome relief past half its wavelength).
	var _crack_vtx_spacing := 0.0
	if hp_mode and res > 0:
		_crack_vtx_spacing = HEALPix.pixel_side_length(hp_nside, 1.0) \
				* data.radius / float(res)
	if data.corundum_default_biome:
		_corundum_bd = data.get_biome_by_type(
				ArideDesertCorundumPlateauTerrain.BIOME_TYPE)
		if not _corundum_logged:
			_corundum_logged = true
			print("[PlanetChunk] corundum default biome ACTIVE on planet=%s  bd=%s  spacing=%.0f width=%.0f depth=%.0f" % [
				data.planet_name, str(_corundum_bd != null),
				data.crack_spacing_m, data.crack_width_m, data.crack_depth_m])

	# Roads flatten the relief: the chunk's pieces plus its neighbours'.
	var _relief_roads: Array = []
	var _relief_mpd := data.radius * PI / 180.0
	if has_relief_overlap and hp_mode:
		_relief_roads = BiomeRelief.gather_roads(data, hp_nside, hp_ipix)

	# ── Recipe crater data ─────────────────────────────────────────
	# Craters from recipes are too small to resolve in the recipe heightmap
	# (sub-pixel at 128px / ~60km chunks).  Fetch cached recipe crater data
	# and apply displacement per-vertex instead.
	var recipe_craters: Array = []
	if not data.craters_baked:
		if hp_mode:
			var _crater_ipix := hp_ipix
			var _cur_nside := hp_nside
			while _cur_nside > data.export_nside:
				_crater_ipix = HEALPix.parent_pixel(_crater_ipix)
				_cur_nside /= 2
			while _cur_nside < data.export_nside:
				_crater_ipix = _crater_ipix * 4
				_cur_nside *= 2
			recipe_craters = data.get_chunk_craters(_crater_ipix)
		else:
			var _cpe := int(pow(2, data.chunk_export_depth))
			var _u_mid := (u_min + u_max) * 0.5
			var _v_mid := (v_min + v_max) * 0.5
			var _eu := clampi(int((_u_mid + 1.0) * 0.5 * _cpe), 0, _cpe - 1)
			var _ev := clampi(int((_v_mid + 1.0) * 0.5 * _cpe), 0, _cpe - 1)
			recipe_craters = []  # Legacy cube-sphere: craters only stored via HEALPix export

	# ── Pre-query compact craters for this chunk ───────────────────
	# Recipe craters are already cached; no BiomeQuery needed.
	var _chunk_compact_craters: Array = []
	if has_crater_overlap and not data.craters_baked:
		_chunk_compact_craters = _cr_arr

	# Record per-vertex height so the edge skirt can be sized from the steepest
	# single cell (the actual LOD-seam mismatch), not the whole-chunk relief.
	# Whole-chunk relief × exaggeration produced kilometre-deep skirt walls →
	# massive overdraw. The seam between a chunk and a 2× coarser neighbour is
	# only ~a couple of cells of slope, so a small multiple of the max cell step
	# covers it cheaply.
	var _chunk_heights := PackedFloat32Array()
	_chunk_heights.resize((res + 1) * (res + 1))
	# Distance au bord de crack la plus proche, par sommet — INF quand aucune crack n'est
	# dessinée ici. Le Voronoï 3D qui la produit est la partie chère de crack_offset ; en la
	# gardant, le calcul des normales sait sans rien réévaluer que ses quatre points de
	# gradient sont hors crack, donc que leurs offsets sont nuls.
	var _crack_edge := PackedFloat32Array()
	_crack_edge.resize((res + 1) * (res + 1))

	# ── LOD-seam stitch ──────────────────────────────────────────────
	# Edges facing a one-level-coarser neighbour take the PARENT grid's heights
	# (see _stitch_edge_heights), so the two meshes share their border exactly
	# instead of leaving a gap for the skirt to hide.
	var _st_edge: Dictionary = {}   # vertex index → base height forced by the stitch
	var _st_blend: Dictionary = {}  # vertex index → Vector2(weight, parent-level height)
	if stitch != 0 and hp_mode and edge_stitch_applies(data, hp_nside):
		# The border reads the PARENT level: only with its tiles here. A
		# missing one would climb to the coarse floor levels and put the
		# border hundreds of metres off on a cliff — then an unstitched
		# border (a small seam under the skirt) is the lesser evil, and the
		# mesh is marked provisional so it is not cached under this mask.
		if TileResidency.tiles_available(data,
				TileResidency.stitch_parent_tile_set(data, hp_nside, hp_ipix)):
			_stitch_edge_heights(data, hp_nside, hp_ipix, res, grid_dirs, stitch,
					_frame, _st_edge, _st_blend)
		else:
			data.climb_mark()

	if _pf:
		var _now := Time.get_ticks_usec()
		prof["prepare"] = _now - _t_phase
		_t_phase = _now
	# --- vertices -----------------------------------------------------------
	for yi in res + 1:
		for xi in res + 1:
			var idx := yi * (res + 1) + xi
			var dir: Vector3
			var height: float
			if hp_mode:
				dir = grid_dirs[yi][xi]
				# Boundary vertices may be shared with a chunk that has a different
				# _export_ipix (at HEALPix face or export-tile seams).
				# sample_height_boundary picks the same canonical export tile for
				# any given direction, so both sides of the seam are consistent.
				if _st_edge.has(idx):
					height = _st_edge[idx]
				elif xi == 0 or xi == res or yi == 0 or yi == res:
					height = data.sample_height_boundary(dir, _export_ipix,
							-1, Vector2i(-1, -1), null, _sample_nside, _frame)
				else:
					height = data.sample_height_for_direction(dir, _export_ipix,
							-1, Vector2i(-1, -1), null, _sample_nside, _frame)
					if _st_blend.has(idx):
						var _sb: Vector2 = _st_blend[idx]
						height = lerpf(height, _sb.y, _sb.x)
			else:
				# Snap boundary vertices to exact u_min/u_max/v_min/v_max so
				# shared edges between adjacent chunks sample identical heights.
				var u: float
				if xi == 0:
					u = u_min
				elif xi == res:
					u = u_max
				else:
					u = u_min + xi * u_step
				var v: float
				if yi == 0:
					v = v_min
				elif yi == res:
					v = v_max
				else:
					v = v_min + yi * v_step
				dir = PlanetData.cube_to_sphere(face, u, v)
				height = data.sample_height_for_chunk(
						face, u, v, u_min, u_max, v_min, v_max)

			# ── Single biome query per vertex (from populate zones) ──────
			# Reused for liquid detection, colour, AND detail texture.
			var bd: BiomeDefinition = null
			var zone_color_hex: String = ""
			var first_zone: Dictionary = {}
			if not _pz_zones.is_empty():
				var _vz := _query_zones_at_direction(dir, _pz_zones)
				if not _vz.is_empty():
					first_zone = _vz[0]
					bd = data.get_biome_by_type(first_zone.get("biome_type", ""))
					zone_color_hex = first_zone.get("color_hex", "")
			# The corundum default yields to a zone that names a known biome —
			# and only to that (a first_zone with no biome is a rock_type /
			# colour-only zone, which sits ON the corundum, not instead of it).
			# Geometry hangs on this flag alone, never on _corundum_bd: the
			# collision shape carves by the same rule and has no colour to bake.
			var _cor_here: bool = data.corundum_applies_to_zone(first_zone)

			# River depression — V-shaped cross-section with progressive width.
			# The recipe heightmap resolution (~122m/pixel at nside=64) is too
			# coarse to carve rivers that are typically 1–50m wide.  Carving is
			# therefore performed at runtime per-vertex.
			#
			# River zone lookup bypasses point-in-polygon (query_at_direction)
			# because the buffered polygon may be narrower than the vertex grid
			# spacing at coarse LODs — no grid vertex falls inside the polygon.
			# Instead, we compute get_cross_section_t directly from the cached
			# river zones found during the AABB pre-pass.
			if has_river_overlap:
				var lonlat := BiomeQuery._dir_to_lonlat(dir)
				var best_t: float = 1.0
				var best_along: float = 0.0
				var best_rzone: Dictionary = {}
				for _rz in _river_zones:
					var _rcl: PackedVector2Array = _rz.get("centerline", PackedVector2Array())
					if _rcl.size() < 2:
						continue
					var cs := BiomeQuery.get_cross_section_t(_rz, lonlat)
					var t: float = cs.t
					if t < best_t:
						best_t = t
						best_along = cs.along_t
						best_rzone = _rz
				if best_t < 1.0 and not best_rzone.is_empty():
					is_river_vertex[idx] = 1
					river_cross_t[idx] = best_t
					river_along_t[idx] = best_along
					# Progressive depth: interpolate width, then depth = width × 0.1.
					var ws: float = best_rzone.get("width_start_m", 0.0)
					var we: float = best_rzone.get("width_end_m", 0.0)
					var width_here: float
					if ws > 0.0 or we > 0.0:
						width_here = lerpf(ws, we, best_along)
					else:
						width_here = best_rzone.get("width", 10.0)
					var zdepth: float = width_here * MaritimeRiverRiverTerrain.DEPTH_RATIO
					if zdepth < 0.5:
						zdepth = 0.5
					# Store bank height, then carve the V-shaped depression
					# at runtime (recipe heightmap is too coarse for this).
					river_original_height[idx] = height
					height -= zdepth * (1.0 - best_t * best_t)
					if river_zone_for_flow.is_empty():
						river_zone_for_flow = best_rzone
				elif has_liquid_overlap and bd and bd.is_liquid:
					# Not inside a river — check for other liquid zones.
					is_liquid_vertex[idx] = 1
					original_height[idx] = height
					height -= LIQUID_DEPTH
			# Regular liquid depression (ocean, lake…) — only when no river overlap.
			elif has_liquid_overlap and bd and bd.is_liquid:
				is_liquid_vertex[idx] = 1
				original_height[idx] = height
				height -= LIQUID_DEPTH

			# Shallow water (swamp, bog) — no terrain depression.
			if has_shallow_water_overlap and bd and bd.has_shallow_water:
				is_shallow_water_vertex[idx] = 1

			# Volcanic active — flag for lava overlay surface.
			# Active volcanos are radial features, not populate zones.
			if has_volcanic_active_overlap:
				var _va_lonlat := BiomeQuery._dir_to_lonlat(dir)
				var _va_m_per_deg := data.radius * PI / 180.0
				for _va_rf in _rf_arr:
					if _va_rf.get("type", "") != "volcanic_geothermal-active_volcano":
						continue
					var _va_dx: float = (_va_lonlat.x - _va_rf.get("lon", 0.0)) * cos(deg_to_rad(_va_lonlat.y)) * _va_m_per_deg
					var _va_dy: float = (_va_lonlat.y - _va_rf.get("lat", 0.0)) * _va_m_per_deg
					var _va_dist: float = sqrt(_va_dx * _va_dx + _va_dy * _va_dy)
					if _va_dist < _va_rf.get("radius_m", 0.0):
						is_volcanic_active_vertex[idx] = 1
						break

			# Lunar ground — flag for lunar ground material overlay surface.
			if has_lunar_ground_overlap and bd \
					and SpatialLunarGroundTerrain.matches_zone(bd):
				is_lunar_ground_vertex[idx] = 1

			# Surface override — the biome's own material replaces the base
			# shader on this vertex's quads (outcrop rock, tinted by COLOR).
			if has_surface_override_overlap and bd \
					and bd.terrain_material_override and not bd.is_liquid:
				surface_override_vertex[idx] = int(_surface_mat_index.get(
						bd.terrain_material_override.resource_path, 0))

			# Meadow — flag for grass ground material overlay surface.
			if has_meadow_overlap and bd \
					and MeadowSteppeMeadowTerrain.matches_zone(bd):
				is_meadow_vertex[idx] = 1

			# Forest ground — flag for leaf-litter material overlay surface.
			if has_forest_ground_overlap and bd \
					and ForestTemperateForestTerrain.matches_zone(bd):
				is_forest_ground_vertex[idx] = 1

			# Cliff — flag for cliff face material overlay surface.
			if has_cliff_overlap and bd \
					and RockyLandformCliffTerrain.matches_zone(bd):
				is_cliff_vertex[idx] = 1

			# Dry riverbed — flag for pebble texture overlay, with flow-aligned UVs.
			# The pebble surface follows the carved floor (post-depression vertices).
			if has_dry_river_bed_overlap:
				var _drb_lonlat := BiomeQuery._dir_to_lonlat(dir)
				var _drb_best_t: float = 1.0
				var _drb_best_zone: Dictionary = {}
				for _drbz in _dry_river_bed_zones:
					var _drb_cl: PackedVector2Array = _drbz.get("centerline", PackedVector2Array())
					if _drb_cl.size() < 2:
						continue
					var _drb_cs := BiomeQuery.get_cross_section_t(_drbz, _drb_lonlat)
					if _drb_cs.t < _drb_best_t:
						_drb_best_t = _drb_cs.t
						_drb_best_zone = _drbz
				if _drb_best_t < 1.0 and not _drb_best_zone.is_empty():
					is_dry_river_bed_vertex[idx] = 1
					var _drb_m_per_deg := data.radius * PI / 180.0
					var _drb_flow := BiomeQuery.get_flow_aligned_coords(
						_drb_best_zone, _drb_lonlat, _drb_m_per_deg)
					dry_river_bed_flow_uv[idx] = _drb_flow

			# No per-vertex road pass here: roads don't depress the terrain, and
			# the overlay is an independent strip extruded from the centerline
			# further down. The vegetation spawners run their own road query to
			# suppress grass and trees, so flagging grid vertices was a
			# query_at_direction() + get_cross_section_t() per vertex whose
			# result nothing ever read.

			# Lava river — iterate recipe linear features for lava_river type.
			# The cross-section test (t < 1.0) determines which vertices
			# are actually inside the channel; only those get the lava
			# overlay flag AND the depression.
			if has_lava_river_overlap:
				for _lr_z in _lf_arr:
					if _lr_z.get("type", "") != "volcanic_geothermal-lava_river":
						continue
					var _lr_cl: PackedVector2Array = _lr_z.get("centerline", PackedVector2Array())
					if _lr_cl.size() < 2:
						continue
					VolcanicGeothermalLavaRiverTerrain.prepare_zone(_lr_z, data.radius)
					var _lr_lonlat := BiomeQuery._dir_to_lonlat(dir)
					var _lr_cs := BiomeQuery.get_cross_section_t(_lr_z, _lr_lonlat)
					var _lr_t: float = _lr_cs.t
					if _lr_t < 1.0:
						# Inside the actual channel — flag for overlay.
						is_lava_river_vertex[idx] = 1
						lava_river_original_height[idx] = height
						# Flow-aligned UV: U = along flow, V = across.
						var _lr_m_per_deg := data.radius * PI / 180.0
						var _lr_flow := BiomeQuery.get_flow_aligned_coords(
							_lr_z, _lr_lonlat, _lr_m_per_deg)
						lava_river_flow_uv[idx] = _lr_flow
						# Apply linear depression (U-profile).
						var _lr_depth: float = _lr_z.get("depth_override", 0.0)
						if _lr_depth <= 0.0:
							_lr_depth = VolcanicGeothermalLavaRiverTerrain.DEFAULT_DEPTH_M
						var _lr_t2 := _lr_t * _lr_t
						height -= _lr_depth * (1.0 - _lr_t2 * _lr_t2)
					break

			# Linear depression — steep-walled U-profile (1 − t⁴).
			# Iterates recipe linear features directly for canyon/crevasse types.
			if has_linear_overlap:
				var _lin_lonlat := BiomeQuery._dir_to_lonlat(dir)
				for _lin_z in _lf_arr:
					var _lin_type: String = _lin_z.get("type", "")
					# Lava river and water river handled by their own sections.
					if _lin_type == "volcanic_geothermal-lava_river" \
							or _lin_type == "maritime_river-river":
						continue
					var _lin_cl: PackedVector2Array = _lin_z.get("centerline", PackedVector2Array())
					if _lin_cl.size() < 2:
						continue
					var _lin_depth_m: float = RockyLandformCanyonTerrain.DEFAULT_DEPTH_M
					match _lin_type:
						"rocky_landform-canyon":
							RockyLandformCanyonTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = RockyLandformCanyonTerrain.DEFAULT_DEPTH_M
						"icy-ice_crevasse":
							IcyIceCrevasseTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = IcyIceCrevasseTerrain.DEFAULT_DEPTH_M
						"aride_desert-dry_river_bed":
							ArideDesertDryRiverBedTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = ArideDesertDryRiverBedTerrain.DEFAULT_DEPTH_M
						"rocky_landform-pressure_canyon":
							RockyLandformPressureCanyonTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = RockyLandformPressureCanyonTerrain.DEFAULT_DEPTH_M
						_:
							RockyLandformCanyonTerrain.prepare_zone(_lin_z, data.radius)
					var _lin_cs := BiomeQuery.get_cross_section_t(_lin_z, _lin_lonlat)
					var _lin_t: float = _lin_cs.t
					if _lin_t < 1.0:
						var cdepth: float = _lin_z.get("depth_override", 0.0)
						if cdepth <= 0.0:
							cdepth = _lin_depth_m
						var t2 := _lin_t * _lin_t
						height -= cdepth * (1.0 - t2 * t2)
						break

			# Point depression — radial funnel around polygon centroid.
			# Cave uses vertex-collapse hole; others use smooth bowl.
			# Active volcano depression is baked in recipe heightmap (radial feature).
			if has_point_overlap and bd:
				var _pt_radius: float = 0.0
				var _pt_depth: float = 0.0
				var _pt_hole_radius: float = 0.0
				var _pt_has_hole := false
				if CaveTerrain.is_cave_biome(bd):
					_pt_radius = CaveTerrain.ENTRANCE_RADIUS_M
					_pt_depth = CaveTerrain.ENTRANCE_DEPTH_M
					_pt_hole_radius = CaveTerrain.HOLE_RADIUS_M
					_pt_has_hole = true
				elif VolcanicGeothermalFumaroleTerrain.matches_zone(bd):
					_pt_radius = VolcanicGeothermalFumaroleTerrain.DEPRESSION_RADIUS_M
					_pt_depth = VolcanicGeothermalFumaroleTerrain.DEPRESSION_DEPTH_M
				elif VolcanicGeothermalIceGeyserTerrain.matches_zone(bd):
					_pt_radius = VolcanicGeothermalIceGeyserTerrain.DEPRESSION_RADIUS_M
					_pt_depth = VolcanicGeothermalIceGeyserTerrain.DEPRESSION_DEPTH_M
				elif VolcanicGeothermalMineralThermalSourceTerrain.matches_zone(bd):
					_pt_radius = VolcanicGeothermalMineralThermalSourceTerrain.DEPRESSION_RADIUS_M
					_pt_depth = VolcanicGeothermalMineralThermalSourceTerrain.DEPRESSION_DEPTH_M
				if _pt_radius > 0.0:
					# Determine centroid from populate zone structure.
					var centroid := Vector2.ZERO
					var _pz_cov: String = first_zone.get("coverage", "")
					var _has_centroid := false
					if _pz_cov == "point":
						centroid = Vector2(first_zone.get("lon", 0.0), first_zone.get("lat", 0.0))
						_has_centroid = true
					else:
						var _pz_verts: Array = first_zone.get("vertices", [])
						if _pz_verts.size() >= 3:
							for _pv in _pz_verts:
								centroid += Vector2(_pv[0], _pv[1])
							centroid /= float(_pz_verts.size())
							_has_centroid = true
					if _has_centroid:
						var lonlat := BiomeQuery._dir_to_lonlat(dir)
						var m_per_deg := data.radius * PI / 180.0
						var dist_m := (lonlat - centroid).length() * m_per_deg
						if dist_m < _pt_radius:
							if _pt_has_hole and dist_m < _pt_hole_radius:
								# Cave-style vertex collapse — creates a real hole.
								var hole_centre_dir := CaveTerrain.lonlat_to_dir(centroid)
								var hole_pos := hole_centre_dir * (data.radius + height - _pt_depth)
								vertices[idx] = _world_to_local(hole_pos, cc_f32, _wp_f32)
								normals[idx]  = dir
								uvs[idx]      = PlanetData.direction_to_uv(dir)
								continue
							else:
								# Smooth taper depression.
								var _t_outer: float
								if _pt_has_hole:
									_t_outer = (dist_m - _pt_hole_radius) / (_pt_radius - _pt_hole_radius)
								else:
									_t_outer = dist_m / _pt_radius
								height -= _pt_depth * (1.0 - _t_outer * _t_outer)

			# ── Recipe crater displacement ─────────────────────────
			# Sub-pixel craters from recipe JSON, applied per-vertex
			# because the recipe heightmap is too coarse to resolve them.
			if not recipe_craters.is_empty():
				height += SpatialCraterTerrain.apply_craters(
					dir, recipe_craters, data.radius)

			# ── Cliff displacement ─────────────────────────────────
			# Vertices inside the cliff polygon are pushed down to form
			# a steep drop at the polygon boundary.
			if has_cliff_overlap and bd and RockyLandformCliffTerrain.matches_zone(bd):
				var _cl_poly := _zone_outline(first_zone)
				if _cl_poly.size() >= 3:
					var _cl_lonlat := BiomeQuery._dir_to_lonlat(dir)
					var _cl_m_per_deg := data.radius * PI / 180.0
					var _cl_dist_deg := BiomeQuery._dist_to_polygon_edge(_cl_lonlat, _cl_poly)
					var _cl_dist_m := _cl_dist_deg * _cl_m_per_deg
					var _cl_drop: float = first_zone.get("depth", 0.0)
					if _cl_drop <= 0.0:
						_cl_drop = RockyLandformCliffTerrain.DROP_M
					height -= RockyLandformCliffTerrain.height_offset(_cl_dist_m, _cl_drop)

			# ── Biome relief ───────────────────────────────────────
			# Pure function of dir + the biome's constants, flattened near
			# roads; the collision builder applies the very same call.
			if has_relief_overlap and bd and bd.has_relief():
				var _rl_w := BiomeRelief.road_weight(HEALPix.vec2lonlat(dir),
						_relief_roads, _relief_mpd, _crack_vtx_spacing)
				if _rl_w > 0.0:
					height += _rl_w * BiomeRelief.offset(dir, data.radius, bd, _crack_vtx_spacing)
					relief_vertex[idx] = int(_relief_index.get(bd.biome_type, 0))
					relief_road_w[idx] = _rl_w

			# ── Corundum crack network ─────────────────────────────
			# Pure function of dir + PlanetData params → identical on the
			# server collision path (see generate_collision_shape), which
			# gates it on the very same zone rule (corundum_applies_to_zone):
			# a crack stops at the edge of another biome's zone, in both.
			# Offset (≤ 0) is reused below to stain the crack interiors; the
			# INF edge distance of an uncarved vertex also tells the normal
			# pass below that its probes have nothing to carve.
			var _crack_off := 0.0
			var _crack_d := INF
			if _cor_here:
				_crack_d = ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(
					dir, data.radius, data.crack_spacing_m,
					data.crack_width_m, _crack_vtx_spacing)
				_crack_off = ArideDesertCorundumPlateauTerrain.crack_offset_from_edge(
					_crack_d, data.crack_width_m, data.crack_depth_m)
				height += _crack_off
			_crack_edge[idx] = _crack_d

			# ── Profiled-line cutting ──────────────────────────────
			# Same rule, same pieces, same profile as the collision builder.
			if not _rw_ctx.is_empty():
				var _rw_carved := GradeBed.apply(height, HEALPix.vec2lonlat(dir), _rw_ctx)
				if _rw_carved != height:
					height = _rw_carved
					_rw_band[idx] = 1
				_rw_h[idx] = height
			elif not _rw_shave.is_empty():
				var _rw_shaved := GradeBed.apply(height, HEALPix.vec2lonlat(dir), _rw_shave)
				if _rw_shaved != height:
					height = _rw_shaved
					_rw_band[idx] = 1

			_chunk_heights[idx] = height
			vertices[idx] = _world_to_local(dir * (data.radius + height), cc_f32, _wp_f32)
			normals[idx]  = dir  # placeholder — overwritten below
			uvs[idx]      = PlanetData.direction_to_uv(dir)

			# ── Biome colour ────────────────────────────────────────
			# Use the single biome query result directly.  The GPU's
			# hardware vertex-colour interpolation across triangles smooths
			# boundaries at ~6 m spacing, making expensive multi-sample
			# jittering unnecessary.
			var base_col := Color(0.45, 0.35, 0.25)  # fallback
			if _cor_here and _corundum_bd:
				# Milky-white ↔ iron-yellow mottling ("iron impurities"),
				# then darken/stain the interiors of the cracks.
				base_col = ArideDesertCorundumPlateauTerrain.iron_tint(
					dir, data.radius, _corundum_bd.color)
				base_col = ArideDesertCorundumPlateauTerrain.crack_stain(
					base_col, _crack_off, data.crack_depth_m)
			elif first_zone.has("rock_type") \
					and RockCatalogue.has(str(first_zone["rock_type"])):
				# The zone's rock: every shade between its light and dark
				# tints, from a deterministic mottling (same on every client).
				var _rock_fallback: Color = bd.color if bd \
						else (Color(zone_color_hex) if not zone_color_hex.is_empty() else base_col)
				base_col = RockCatalogue.tint(dir, data.radius,
						str(first_zone["rock_type"]), _rock_fallback)
			elif bd:
				base_col = bd.color
			elif not zone_color_hex.is_empty():
				base_col = Color(zone_color_hex)
			else:
				base_col = data.sample_biome_at(dir)
			colors[idx] = base_col

			# Detail texture info → UV2.
			var _detail_bd: BiomeDefinition = _corundum_bd if (_cor_here and _corundum_bd) else bd
			var detail_layer := data.get_detail_layer(_detail_bd)
			var detail_scale := data.get_detail_scale_for_layer(detail_layer)
			uv2s[idx] = Vector2(float(detail_layer), detail_scale)

	if _pf:
		var _now := Time.get_ticks_usec()
		prof["verts"] = _now - _t_phase
		_t_phase = _now
	# --- indices (two triangles per quad) -----------------------------------
	indices.resize(res * res * 6)
	var ii := 0
	for yi in res:
		for xi in res:
			var i := yi * (res + 1) + xi
			indices[ii]     = i
			indices[ii + 1] = i + res + 1
			indices[ii + 2] = i + 1
			indices[ii + 3] = i + 1
			indices[ii + 4] = i + res + 1
			indices[ii + 5] = i + res + 2
			ii += 6

	# --- triangle winding correction ----------------------------------------
	# HEALPix base faces (and cube-sphere faces) have inconsistent (xi, yi)
	# grid orientations relative to the outward sphere normal.  For some
	# faces the iteration produces CCW triangles when viewed from outside
	# (correct for CULL_BACK), for others CW (treated as back-faces and
	# culled — the chunk renders invisible while skirts remain visible).
	# Detect the actual winding using the first triangle's geometric normal
	# vs an outward reference direction; if reversed, swap the second and
	# third index of every triangle.
	if indices.size() >= 3 and vertices.size() > indices[2]:
		var v0: Vector3 = vertices[indices[0]]
		var v1: Vector3 = vertices[indices[1]]
		var v2: Vector3 = vertices[indices[2]]
		var tri_n := (v1 - v0).cross(v2 - v0)
		var outward_ref: Vector3
		if hp_mode:
			outward_ref = grid_dirs[0][0]
		else:
			outward_ref = PlanetData.cube_to_sphere(face, u_min, v_min)
		if tri_n.dot(outward_ref) < 0.0:
			var swapped := PackedInt32Array()
			swapped.resize(indices.size())
			var jj := 0
			while jj < indices.size():
				swapped[jj]     = indices[jj]
				swapped[jj + 1] = indices[jj + 2]
				swapped[jj + 2] = indices[jj + 1]
				jj += 3
			indices = swapped

	if _pf:
		var _now := Time.get_ticks_usec()
		prof["index"] = _now - _t_phase
		_t_phase = _now
	# --- smooth normals from analytical heightmap gradient -------------------
	# Previously we used _recalculate_normals (face-accumulated) for interior
	# vertices and analytical gradient only for boundary vertices.  The two
	# methods produced slightly different normals, causing a visible dark band
	# at the edge-to-interior transition.
	# Fix: compute analytical normals for ALL vertices.  The heightmap gradient
	# is the "true" normal and is consistent across chunk boundaries, so every
	# vertex uses the same method — no transition artifact.
	if hp_mode:
		var _eps_frac := 0.25 / float(res)
		# Invariants de boucle : pixel_side_length ne dépend que de hp_nside, et l'était
		# recalculé à chaque sommet.
		var _eps_rad := HEALPix.pixel_side_length(hp_nside, 1.0) * _eps_frac
		# Un sommet dont le bord de crack le plus proche est au-delà de cette distance a
		# ses quatre points de gradient hors crack : la distance à un bord est
		# 1-lipschitzienne et ils ne sont qu'à _eps_rad de lui. Leurs offsets valent donc
		# zéro, et les quatre Voronoï sont inutiles. Marge de 2× sur le décalage plutôt
		# que 1× : elle ne coûte presque rien en taux de saut et clôt toute discussion sur
		# la lipschitziennité de l'approximation de Voronoï employée.
		var _crack_skip_m: float = data.crack_width_m * 0.5 + 2.0 * _eps_rad * data.radius
		# Sous-découpage de la phase "normals", qui pèse 74 % de la génération d'un chunk
		# (mesuré à froid : 623 ms/chunk). Trois postes candidats, et le correctif n'est pas
		# le même selon lequel domine :
		#   _t_sm : les 4 échantillons de hauteur par sommet
		#   _t_ck : les 4 crack_offset par sommet — chacun évalue un Voronoï 3D
		#           (deux passes 3×3×3, ~160 sin()), et seule tarsis_3 les active
		#   le reste : repère tangent, normalisations, produit vectoriel
		var _t_sm := 0
		var _t_ck := 0
		var _t_sub := 0
		for yi in res + 1:
			for xi in res + 1:
				var idx := yi * (res + 1) + xi
				var dir_c: Vector3 = grid_dirs[yi][xi]
				# Build tangent frame on sphere at this vertex.
				var up := dir_c
				var arbitrary := Vector3.UP if absf(up.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
				var tan_u := up.cross(arbitrary).normalized()
				var tan_v := up.cross(tan_u).normalized()
				var dir_l := (dir_c - tan_u * _eps_rad).normalized()
				var dir_r := (dir_c + tan_u * _eps_rad).normalized()
				var dir_b := (dir_c - tan_v * _eps_rad).normalized()
				var dir_t := (dir_c + tan_v * _eps_rad).normalized()
				# Edge vertices: use sample_height_boundary so both sides of
				# a chunk seam resolve to the same canonical export tile →
				# identical normals.  Interior vertices can use the fast path.
				var h_l: float
				var h_r: float
				var h_b: float
				var h_t: float
				if _pf:
					_t_sub = Time.get_ticks_usec()
				if xi == 0 or xi == res or yi == 0 or yi == res:
					h_l = data.sample_height_boundary(dir_l, _export_ipix, -1, Vector2i(-1, -1), null, _sample_nside, _frame)
					h_r = data.sample_height_boundary(dir_r, _export_ipix, -1, Vector2i(-1, -1), null, _sample_nside, _frame)
					h_b = data.sample_height_boundary(dir_b, _export_ipix, -1, Vector2i(-1, -1), null, _sample_nside, _frame)
					h_t = data.sample_height_boundary(dir_t, _export_ipix, -1, Vector2i(-1, -1), null, _sample_nside, _frame)
				else:
					h_l = data.sample_height_for_direction(dir_l, _export_ipix, -1, Vector2i(-1, -1), null, _sample_nside, _frame)
					h_r = data.sample_height_for_direction(dir_r, _export_ipix, -1, Vector2i(-1, -1), null, _sample_nside, _frame)
					h_b = data.sample_height_for_direction(dir_b, _export_ipix, -1, Vector2i(-1, -1), null, _sample_nside, _frame)
					h_t = data.sample_height_for_direction(dir_t, _export_ipix, -1, Vector2i(-1, -1), null, _sample_nside, _frame)
				if _pf:
					var _now := Time.get_ticks_usec()
					_t_sm += _now - _t_sub
					_t_sub = _now
				# Carve the crack network into the gradient samples too, so the
				# near-vertical crack walls get correct (sharp) shading normals.
				# Sauté quand le sommet est assez loin d'un bord pour que les quatre
				# offsets soient nuls par construction : le résultat est identique, sans
				# les quatre Voronoï. Mesuré à 39 % du temps des normales, soit 29 % de la
				# génération d'un chunk sur tarsis_3.
				if data.corundum_default_biome \
						and _crack_edge[idx] < _crack_skip_m:
					h_l += ArideDesertCorundumPlateauTerrain.crack_offset(
						dir_l, data.radius, data.crack_spacing_m, data.crack_width_m, data.crack_depth_m, _crack_vtx_spacing)
					h_r += ArideDesertCorundumPlateauTerrain.crack_offset(
						dir_r, data.radius, data.crack_spacing_m, data.crack_width_m, data.crack_depth_m, _crack_vtx_spacing)
					h_b += ArideDesertCorundumPlateauTerrain.crack_offset(
						dir_b, data.radius, data.crack_spacing_m, data.crack_width_m, data.crack_depth_m, _crack_vtx_spacing)
					h_t += ArideDesertCorundumPlateauTerrain.crack_offset(
						dir_t, data.radius, data.crack_spacing_m, data.crack_width_m, data.crack_depth_m, _crack_vtx_spacing)
				# Biome relief on the probes: the vertex's own road weight is
				# reused (a quarter-cell away it is the same to the eye), the
				# noise is evaluated at each probe's exact direction.
				if has_relief_overlap and relief_vertex[idx] > 0:
					var _rl_bd: BiomeDefinition = _relief_bds[relief_vertex[idx] - 1]
					var _rl_wv: float = relief_road_w[idx]
					h_l += _rl_wv * BiomeRelief.offset(dir_l, data.radius, _rl_bd, _crack_vtx_spacing)
					h_r += _rl_wv * BiomeRelief.offset(dir_r, data.radius, _rl_bd, _crack_vtx_spacing)
					h_b += _rl_wv * BiomeRelief.offset(dir_b, data.radius, _rl_bd, _crack_vtx_spacing)
					h_t += _rl_wv * BiomeRelief.offset(dir_t, data.radius, _rl_bd, _crack_vtx_spacing)
				var _rw_probe_ctx: Dictionary = _rw_ctx if not _rw_ctx.is_empty() else _rw_shave
				if not _rw_probe_ctx.is_empty() and _rw_band[idx] == 1:
					h_l = GradeBed.apply(h_l, HEALPix.vec2lonlat(dir_l), _rw_probe_ctx)
					h_r = GradeBed.apply(h_r, HEALPix.vec2lonlat(dir_r), _rw_probe_ctx)
					h_b = GradeBed.apply(h_b, HEALPix.vec2lonlat(dir_b), _rw_probe_ctx)
					h_t = GradeBed.apply(h_t, HEALPix.vec2lonlat(dir_t), _rw_probe_ctx)
				if _pf:
					_t_ck += Time.get_ticks_usec() - _t_sub
				var world_l := dir_l * (data.radius + h_l)
				var world_r := dir_r * (data.radius + h_r)
				var world_b := dir_b * (data.radius + h_b)
				var world_t := dir_t * (data.radius + h_t)
				var tangent_u := world_r - world_l
				var tangent_v := world_t - world_b
				var n := tangent_u.cross(tangent_v)
				# HEALPix face winding varies between base pixels — flip if the
				# computed normal points inward (away from the surface).
				if n.dot(dir_c) < 0.0:
					n = -n
				if n.length_squared() > 0.0:
					normals[idx] = n.normalized()
				else:
					normals[idx] = dir_c
		if _pf:
			prof["normals_sample"] = _t_sm
			prof["normals_crack"] = _t_ck
	else:
		# Cube-sphere path: analytical normals for all vertices too.
		var _eps_u := u_step * 0.25
		var _eps_v := v_step * 0.25
		for yi in res + 1:
			for xi in res + 1:
				var idx := yi * (res + 1) + xi
				var u: float
				if xi == 0:
					u = u_min
				elif xi == res:
					u = u_max
				else:
					u = u_min + xi * u_step
				var v: float
				if yi == 0:
					v = v_min
				elif yi == res:
					v = v_max
				else:
					v = v_min + yi * v_step
				var u_l := maxf(u - _eps_u, -1.0)
				var u_r := minf(u + _eps_u, 1.0)
				var v_b := maxf(v - _eps_v, -1.0)
				var v_t := minf(v + _eps_v, 1.0)
				var h_l: float = data.sample_height_for_chunk(face, u_l, v, u_min, u_max, v_min, v_max)
				var h_r: float = data.sample_height_for_chunk(face, u_r, v, u_min, u_max, v_min, v_max)
				var h_b: float = data.sample_height_for_chunk(face, u, v_b, u_min, u_max, v_min, v_max)
				var h_t: float = data.sample_height_for_chunk(face, u, v_t, u_min, u_max, v_min, v_max)
				var dir_l: Vector3 = PlanetData.cube_to_sphere(face, u_l, v) * (data.radius + h_l)
				var dir_r: Vector3 = PlanetData.cube_to_sphere(face, u_r, v) * (data.radius + h_r)
				var dir_b: Vector3 = PlanetData.cube_to_sphere(face, u, v_b) * (data.radius + h_b)
				var dir_t: Vector3 = PlanetData.cube_to_sphere(face, u, v_t) * (data.radius + h_t)
				var tangent_u: Vector3 = dir_r - dir_l
				var tangent_v: Vector3 = dir_t - dir_b
				var n: Vector3 = tangent_u.cross(tangent_v)
				# Cube face winding varies — flip if the normal points inward.
				var _outward: Vector3 = PlanetData.cube_to_sphere(face, u, v)
				if n.dot(_outward) < 0.0:
					n = -n
				if n.length_squared() > 0.0:
					normals[idx] = n.normalized()
				else:
					normals[idx] = _outward

	if _pf:
		var _now := Time.get_ticks_usec()
		prof["normals"] = _now - _t_phase
		_t_phase = _now
	# --- skirt geometry to hide chunk boundary seams -------------------------
	# Duplicate every edge vertex, nudge outward from the chunk interior
	# (so the skirt overlaps slightly with the neighbour's terrain), then
	# drop toward the planet centre.  The outward nudge ensures micro-gaps
	# between adjacent chunks are always covered by overlapping skirts.
	# Skirt depth = a small multiple of the steepest single-cell height step, which
	# is what actually has to be bridged where this chunk meets a coarser-LOD
	# neighbour. Sizing from whole-chunk relief (× exaggeration) produced
	# kilometre-deep walls and crushing overdraw; the seam mismatch is only a
	# couple of cells of slope, so max_step × 6 (+ margin) covers it cheaply.
	# Build switch (Globals.ENABLED_DEV_TOOLS): OFF bakes the bare grid, seams exposed.
	if GlobalsDefs.is_dev_tool_enabled(&"build_chunk_skirts"):
		var _max_step := 0.0
		var _stride := res + 1
		for _yi in res + 1:
			for _xi in res + 1:
				var _i := _yi * _stride + _xi
				var _hc := _chunk_heights[_i]
				if _xi > 0:
					_max_step = maxf(_max_step, absf(_hc - _chunk_heights[_i - 1]))
				if _yi > 0:
					_max_step = maxf(_max_step, absf(_hc - _chunk_heights[_i - _stride]))
		var skirt_drop := maxf(_max_step * 6.0 + 25.0, 40.0)  # metres below surface
		# Corundum cracks create ~crack_depth single-cell steps, which would inflate
		# skirt_drop into kilometre-tall walls (overdraw + dark vertical faces at LOD
		# seams).  A LOD-seam mismatch never exceeds the crack depth, so cap it there.
		if _corundum_bd:
			skirt_drop = minf(skirt_drop, data.crack_depth_m * 1.5 + 40.0)
		var skirt_nudge := 0.1  # metres along surface, outward from chunk interior
		var edge_indices_list: Array[int] = []
		# Bottom edge (yi == 0, all xi)
		for xi in res + 1:
			edge_indices_list.append(0 * (res + 1) + xi)
		# Top edge (yi == res, all xi)
		for xi in res + 1:
			edge_indices_list.append(res * (res + 1) + xi)
		# Left edge (xi == 0, yi 1..res-1) — corners already included above
		for yi in range(1, res):
			edge_indices_list.append(yi * (res + 1) + 0)
		# Right edge (xi == res, yi 1..res-1)
		for yi in range(1, res):
			edge_indices_list.append(yi * (res + 1) + res)

		# Map: original vertex index → skirt (dropped) vertex index
		var skirt_map: Dictionary = {}
		for ei in edge_indices_list:
			if skirt_map.has(ei):
				continue
			var world_pos := vertices[ei] + cc_f32
			var dir_s := world_pos.normalized()
			# Compute outward nudge: push the skirt base slightly beyond the
			# chunk edge so it tucks under the neighbour's terrain surface.
			var _sk_xi: int = ei % (res + 1)
			@warning_ignore("integer_division")
			var _sk_yi: int = ei / (res + 1)
			var nudge := Vector3.ZERO
			if _sk_yi == 0:  # bottom edge → nudge toward yi = -1
				nudge += vertices[ei] - vertices[1 * (res + 1) + _sk_xi]
			if _sk_yi == res:  # top edge → nudge toward yi = res+1
				nudge += vertices[ei] - vertices[(res - 1) * (res + 1) + _sk_xi]
			if _sk_xi == 0:  # left edge → nudge toward xi = -1
				nudge += vertices[ei] - vertices[_sk_yi * (res + 1) + 1]
			if _sk_xi == res:  # right edge → nudge toward xi = res+1
				nudge += vertices[ei] - vertices[_sk_yi * (res + 1) + (res - 1)]
			# Project onto tangent plane and scale to SKIRT_NUDGE metres.
			if nudge.length_squared() > 0.0:
				nudge = nudge - dir_s * nudge.dot(dir_s)
				if nudge.length_squared() > 0.0:
					nudge = nudge.normalized() * skirt_nudge
			var dropped := _world_to_local(world_pos + nudge - dir_s * skirt_drop, cc_f32, _wp_f32)
			var surface_local := vertices[ei]
			var surface_offset := surface_local - dropped
			var skirt_idx := vertices.size()
			# Store the DROPPED position directly as VERTEX so the geometry is
			# correct even without shader support for CUSTOM0.  CUSTOM0 holds
			# the inverse offset (dropped → surface) so the shader can recover
			# the surface position for triplanar UV continuity:
			#   surface_pos = VERTEX + CUSTOM0
			vertices.append(dropped)
			normals.append(normals[ei])
			uvs.append(uvs[ei])
			uv2s.append(uv2s[ei])
			# Debug: paint skirt curtains bright magenta so they can be told apart
			# from real terrain / crack interiors in-game.
			colors.append(Color.MAGENTA if data.debug_color_skirts else colors[ei])
			skirt_offsets.append(surface_offset.x)
			skirt_offsets.append(surface_offset.y)
			skirt_offsets.append(surface_offset.z)
			skirt_map[ei] = skirt_idx

		# Connect skirt triangles along each continuous edge strip.
		# For each consecutive pair of edge vertices (a, b), form a quad
		# with their dropped counterparts (sa, sb) → 2 triangles.
		# Bottom edge (left to right)
		for xi in res:
			var a := 0 * (res + 1) + xi
			var b := 0 * (res + 1) + xi + 1
			var sa: int = skirt_map[a]
			var sb: int = skirt_map[b]
			indices.append(a);  indices.append(sa); indices.append(b)
			indices.append(b);  indices.append(sa); indices.append(sb)
		# Top edge (left to right)
		for xi in res:
			var a := res * (res + 1) + xi
			var b := res * (res + 1) + xi + 1
			var sa: int = skirt_map[a]
			var sb: int = skirt_map[b]
			indices.append(a);  indices.append(b);  indices.append(sa)
			indices.append(b);  indices.append(sb); indices.append(sa)
		# Left edge (bottom to top)
		for yi in res:
			var a := yi * (res + 1) + 0
			var b := (yi + 1) * (res + 1) + 0
			var sa: int = skirt_map[a]
			var sb: int = skirt_map[b]
			indices.append(a);  indices.append(b);  indices.append(sa)
			indices.append(b);  indices.append(sb); indices.append(sa)
		# Right edge (bottom to top)
		for yi in res:
			var a := yi * (res + 1) + res
			var b := (yi + 1) * (res + 1) + res
			var sa: int = skirt_map[a]
			var sb: int = skirt_map[b]
			indices.append(a);  indices.append(sa); indices.append(b)
			indices.append(b);  indices.append(sa); indices.append(sb)

	if _pf:
		var _now := Time.get_ticks_usec()
		prof["skirt"] = _now - _t_phase
		_t_phase = _now
	# --- collect volcanic_active quad indices for lava surface ---------------
	# Volcanic quads are excluded from the base terrain surface and drawn on a
	# separate surface with their own ORMMaterial3D.  No z-fighting because
	# the quads don't overlap.
	var lava_indices := PackedInt32Array()
	if has_volcanic_active_overlap:
		for qi in range(0, res * res * 6, 6):
			var i00 := indices[qi]
			var i01 := indices[qi + 1]
			var i10 := indices[qi + 2]
			var i11 := indices[qi + 5]
			if is_volcanic_active_vertex[i00] == 1 \
					or is_volcanic_active_vertex[i10] == 1 \
					or is_volcanic_active_vertex[i01] == 1 \
					or is_volcanic_active_vertex[i11] == 1:
				for oi in range(qi, qi + 6):
					lava_indices.append(indices[oi])

	# --- collect lunar_ground quad indices for material overlay ---
	var lunar_ground_indices := PackedInt32Array()
	if has_lunar_ground_overlap:
		for qi in range(0, res * res * 6, 6):
			var i00 := indices[qi]
			var i01 := indices[qi + 1]
			var i10 := indices[qi + 2]
			var i11 := indices[qi + 5]
			if is_lunar_ground_vertex[i00] == 1 \
					or is_lunar_ground_vertex[i10] == 1 \
					or is_lunar_ground_vertex[i01] == 1 \
					or is_lunar_ground_vertex[i11] == 1:
				for oi in range(qi, qi + 6):
					lunar_ground_indices.append(indices[oi])

	# --- collect meadow quad indices for grass ground overlay ---
	var meadow_indices := PackedInt32Array()
	if has_meadow_overlap:
		for qi in range(0, res * res * 6, 6):
			var i00 := indices[qi]
			var i01 := indices[qi + 1]
			var i10 := indices[qi + 2]
			var i11 := indices[qi + 5]
			if is_meadow_vertex[i00] == 1 \
					or is_meadow_vertex[i10] == 1 \
					or is_meadow_vertex[i01] == 1 \
					or is_meadow_vertex[i11] == 1:
				for oi in range(qi, qi + 6):
					meadow_indices.append(indices[oi])

	# --- collect forest_ground quad indices for leaf-litter overlay ---
	var forest_ground_indices := PackedInt32Array()
	if has_forest_ground_overlap:
		for qi in range(0, res * res * 6, 6):
			var i00 := indices[qi]
			var i01 := indices[qi + 1]
			var i10 := indices[qi + 2]
			var i11 := indices[qi + 5]
			if is_forest_ground_vertex[i00] == 1 \
					or is_forest_ground_vertex[i10] == 1 \
					or is_forest_ground_vertex[i01] == 1 \
					or is_forest_ground_vertex[i11] == 1:
				for oi in range(qi, qi + 6):
					forest_ground_indices.append(indices[oi])

	# --- collect surface-override quad indices, one list per material -------
	# Any flagged vertex claims the quad (like the other overlays); the
	# material is the first flagged vertex's, so a quad never straddles two.
	var surface_override_indices: Array = []   # k-1 → PackedInt32Array
	if has_surface_override_overlap:
		for _k in _surface_mats.size():
			surface_override_indices.append(PackedInt32Array())
		for qi in range(0, res * res * 6, 6):
			var _k := 0
			for oi in [qi, qi + 2, qi + 1, qi + 5]:
				_k = surface_override_vertex[indices[oi]]
				if _k > 0:
					break
			if _k > 0:
				var _lst: PackedInt32Array = surface_override_indices[_k - 1]
				for oi in range(qi, qi + 6):
					_lst.append(indices[oi])
				surface_override_indices[_k - 1] = _lst

	# --- collect cliff face indices for steep triangles only ---------------
	# Only triangles within the cliff biome whose face normal is steep
	# (dot with planet-up < SLOPE_THRESHOLD) get the cliff ORMMaterial3D.
	var cliff_indices := PackedInt32Array()
	if has_cliff_overlap:
		for qi in range(0, res * res * 6, 6):
			var i00 := indices[qi]
			var i01 := indices[qi + 1]
			var i10 := indices[qi + 2]
			var i11 := indices[qi + 5]
			# At least one vertex must belong to the cliff biome.
			if is_cliff_vertex[i00] == 0 \
					and is_cliff_vertex[i10] == 0 \
					and is_cliff_vertex[i01] == 0 \
					and is_cliff_vertex[i11] == 0:
				continue
			# Check the two triangles' face normals for steepness.
			# Use absf() because cross-product winding may flip across
			# cube faces, producing an inward-facing normal.
			for ti in 2:
				var oi := qi + ti * 3
				var a := vertices[indices[oi]] + chunk_center
				var b := vertices[indices[oi + 1]] + chunk_center
				var c := vertices[indices[oi + 2]] + chunk_center
				var face_normal := (b - a).cross(c - a).normalized()
				var planet_up := ((a + b + c) / 3.0).normalized()
				if absf(face_normal.dot(planet_up)) < RockyLandformCliffTerrain.SLOPE_THRESHOLD:
					for k in 3:
						cliff_indices.append(indices[oi + k])

	# (lava_river quad collection removed — the lava surface is now built
	#  as a separate vertex mesh like the river water overlay, see below.)

	# --- exclude overlay quads from base terrain surface --------------------
	# When an overlay (lava, lunar, meadow, forest, cliff) covers a quad, the
	# two different shader programs (ShaderMaterial base vs ORMMaterial3D
	# overlay) produce subtly different fragment depths for the same vertex
	# positions, causing z-fighting sparkle.  Removing covered quads from the
	# base surface eliminates the overlap entirely.
	var _grid_quad_count := res * res
	var _quad_has_overlay := PackedByteArray()
	_quad_has_overlay.resize(_grid_quad_count)
	# Mark quads that appear in any overlay.
	for qi in range(0, _grid_quad_count * 6, 6):
		var qi_idx := qi / 6
		var i00 := indices[qi]
		var i10 := indices[qi + 2]
		var i01 := indices[qi + 1]
		var i11 := indices[qi + 5]
		if (has_volcanic_active_overlap \
					and (is_volcanic_active_vertex[i00] == 1 \
					or is_volcanic_active_vertex[i10] == 1 \
					or is_volcanic_active_vertex[i01] == 1 \
					or is_volcanic_active_vertex[i11] == 1)) \
				or (has_lunar_ground_overlap \
					and (is_lunar_ground_vertex[i00] == 1 \
					or is_lunar_ground_vertex[i10] == 1 \
					or is_lunar_ground_vertex[i01] == 1 \
					or is_lunar_ground_vertex[i11] == 1)) \
				or (has_meadow_overlap \
					and (is_meadow_vertex[i00] == 1 \
					or is_meadow_vertex[i10] == 1 \
					or is_meadow_vertex[i01] == 1 \
					or is_meadow_vertex[i11] == 1)) \
				or (has_forest_ground_overlap \
					and (is_forest_ground_vertex[i00] == 1 \
					or is_forest_ground_vertex[i10] == 1 \
					or is_forest_ground_vertex[i01] == 1 \
					or is_forest_ground_vertex[i11] == 1)) \
				or (has_cliff_overlap \
					and (is_cliff_vertex[i00] == 1 \
					or is_cliff_vertex[i10] == 1 \
					or is_cliff_vertex[i01] == 1 \
					or is_cliff_vertex[i11] == 1)) \
				or (has_surface_override_overlap \
					and (surface_override_vertex[i00] > 0 \
					or surface_override_vertex[i10] > 0 \
					or surface_override_vertex[i01] > 0 \
					or surface_override_vertex[i11] > 0)):
			_quad_has_overlay[qi_idx] = 1
	# Profile refinement patch: the cells a cutting or a tunnel mouth runs
	# through are re-meshed finer (GradeRefine); their coarse quads leave the
	# base surface and the patch's triangles join it below.
	var _rw_ref: Dictionary = {}
	if not _rw_ctx.is_empty():
		var _rw_ref_sampler := func(d: Vector3) -> float:
			return data.sample_height_for_direction(d, _export_ipix, -1,
					Vector2i(-1, -1), null, _sample_nside, _frame)
		# Overlay quads stay coarse (lava, meadow… are drawn by their own
		# surface on the coarse grid) — EXCEPT the surface-override quads: an
		# outcrop's rock is a full replacement of the base surface, so its
		# cells must be refined like any other, and their patch triangles are
		# routed to the override surface below.
		var _rw_skip := _quad_has_overlay
		if has_surface_override_overlap:
			_rw_skip = _quad_has_overlay.duplicate()
			for qi_idx in _grid_quad_count:
				if _rw_skip[qi_idx] == 0:
					continue
				var qi := qi_idx * 6
				if surface_override_vertex[indices[qi]] > 0 \
						or surface_override_vertex[indices[qi + 2]] > 0 \
						or surface_override_vertex[indices[qi + 1]] > 0 \
						or surface_override_vertex[indices[qi + 5]] > 0:
					_rw_skip[qi_idx] = 0
		_rw_ref = GradeRefine.build(data, hp_nside, hp_ipix, res, grid_dirs, _rw_h,
				_rw_band, _rw_ctx, _rw_skip, _rw_ref_sampler, true)
	var _rw_ref_quads: PackedByteArray = _rw_ref.get("quads", PackedByteArray())
	# A refined override quad is drawn by its patch triangles, not by the
	# coarse quad: drop those from the override lists.
	if not _rw_ref_quads.is_empty() and not surface_override_indices.is_empty():
		for _k in surface_override_indices.size():
			var _src: PackedInt32Array = surface_override_indices[_k]
			var _kept := PackedInt32Array()
			for oi in range(0, _src.size(), 6):
				# The quad id is recovered from its first index (row-major grid).
				var _v0 := _src[oi]
				@warning_ignore("integer_division")
				var _qi_idx := (_v0 / (res + 1)) * res + (_v0 % (res + 1))
				if _qi_idx < _grid_quad_count and _rw_ref_quads[_qi_idx] == 1:
					continue
				for j in 6:
					_kept.append(_src[oi + j])
			surface_override_indices[_k] = _kept
	# Build filtered base indices: non-overlay grid quads + all skirt tris.
	var base_indices := PackedInt32Array()
	for qi_idx in _grid_quad_count:
		if _quad_has_overlay[qi_idx] == 0 \
				and (_rw_ref_quads.is_empty() or _rw_ref_quads[qi_idx] == 0):
			var qi := qi_idx * 6
			for oi in range(qi, qi + 6):
				base_indices.append(indices[oi])
	# Append skirt triangles (everything after grid quads in indices).
	var _skirt_start := _grid_quad_count * 6
	for si in range(_skirt_start, indices.size()):
		base_indices.append(indices[si])
	# Append the refinement patch: its sub-vertices go at the end of every
	# per-vertex array (colour bilinear from the cell's corners, detail layer
	# from the nearest corner, no skirt offset), its triangles re-indexed.
	if not _rw_ref.is_empty():
		var _rf_pos: Array = _rw_ref["pos"]
		var _rf_dirs: PackedVector3Array = _rw_ref["dirs"]
		var _rf_norms: PackedVector3Array = _rw_ref["normals"]
		var _rf_quad: PackedInt32Array = _rw_ref["quad_of"]
		var _rf_frac: PackedVector2Array = _rw_ref["frac"]
		var _rf_base := vertices.size()
		var _rf_ncoarse := (res + 1) * (res + 1)
		for _ri in _rf_pos.size():
			var _qi: int = _rf_quad[_ri]
			@warning_ignore("integer_division")
			var _c00: int = (_qi / res) * (res + 1) + (_qi % res)
			var _c10 := _c00 + 1
			var _c01 := _c00 + res + 1
			var _c11 := _c01 + 1
			var _f: Vector2 = _rf_frac[_ri]
			var _near: int = _c00
			if _f.x >= 0.5:
				_near = _c11 if _f.y >= 0.5 else _c10
			elif _f.y >= 0.5:
				_near = _c01
			vertices.append(_world_to_local(_rf_pos[_ri], cc_f32, _wp_f32))
			normals.append(_rf_norms[_ri])
			uvs.append(PlanetData.direction_to_uv(_rf_dirs[_ri]))
			uv2s.append(uv2s[_near])
			colors.append(colors[_c00].lerp(colors[_c10], _f.x).lerp(
					colors[_c01].lerp(colors[_c11], _f.x), _f.y))
			skirt_offsets.append(0.0)
			skirt_offsets.append(0.0)
			skirt_offsets.append(0.0)
		var _rf_tris: PackedInt32Array = _rw_ref["tris"]
		var _patch_base := PackedInt32Array()
		var _patch_over: Array = []          # k-1 → PackedInt32Array
		for _k in surface_override_indices.size():
			_patch_over.append(PackedInt32Array())
		for _t0 in range(0, _rf_tris.size(), 3):
			# The cell of this sub-triangle: any of its sub-vertices tells
			# (a refined cell has no triangle made of three coarse corners).
			var _cell := -1
			for j in 3:
				var _ti := _rf_tris[_t0 + j]
				if _ti >= _rf_ncoarse:
					_cell = _rf_quad[_ti - _rf_ncoarse]
					break
			var _dst_k := -1
			if _cell >= 0 and has_surface_override_overlap:
				var _cq := _cell * 6
				for oi in [_cq, _cq + 2, _cq + 1, _cq + 5]:
					var _kk := surface_override_vertex[indices[oi]]
					if _kk > 0:
						_dst_k = _kk - 1
						break
			for j in 3:
				var _ti := _rf_tris[_t0 + j]
				var _vi := _ti if _ti < _rf_ncoarse else _rf_base + (_ti - _rf_ncoarse)
				if _dst_k >= 0:
					var _lst: PackedInt32Array = _patch_over[_dst_k]
					_lst.append(_vi)
					_patch_over[_dst_k] = _lst
				else:
					_patch_base.append(_vi)
		base_indices.append_array(_patch_base)
		for _k in _patch_over.size():
			var _merged: PackedInt32Array = surface_override_indices[_k]
			_merged.append_array(_patch_over[_k])
			surface_override_indices[_k] = _merged

	# --- compute tangents ---------------------------------------------------
	# Required for normal-mapped terrain materials. We compute tangents
	# inline (rather than via SurfaceTool) to preserve UV2 / COLOR /
	# CUSTOM0(skirt_offsets) which SurfaceTool's tangent path would
	# complicate. Standard per-triangle accumulation, then ortho-normalize
	# against the vertex normal and pack as Vector4(t.xyz, sign).
	var tangents := _compute_tangents(vertices, normals, uvs, base_indices)

	if _pf:
		var _now := Time.get_ticks_usec()
		prof["overlay"] = _now - _t_phase
		_t_phase = _now
	# --- build mesh ---------------------------------------------------------
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]  = vertices
	arrays[Mesh.ARRAY_NORMAL]  = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV]  = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR]   = colors
	arrays[Mesh.ARRAY_INDEX]   = base_indices
	arrays[Mesh.ARRAY_CUSTOM0] = skirt_offsets

	var mesh := ArrayMesh.new()
	var _c0_fmt := Mesh.ARRAY_CUSTOM_RGB_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	# A chunk whose every quad belongs to an overlay surface (an outcrop zone
	# covering it whole) and that bakes without skirts has NO base triangle:
	# an empty index array is refused by the renderer (five errors per
	# chunk), and the material would then land on the first overlay surface.
	if not base_indices.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, _c0_fmt)
		# Apply terrain material — use the one from PlanetData if provided,
		# otherwise fall back to a default vertex-colour material.
		if data.terrain_material:
			mesh.surface_set_material(0, data.terrain_material)
		else:
			var mat := StandardMaterial3D.new()
			mat.vertex_color_use_as_albedo = true
			mat.cull_mode = BaseMaterial3D.CULL_BACK
			mesh.surface_set_material(0, mat)

	# --- volcanic_active: lava material on top of the terrain ---------------
	# Overlay quads are excluded from the base terrain surface (see above),
	# so these surfaces REPLACE the base terrain for their quads rather than
	# overdrawing.  No z-fighting is possible because there is no overlapping
	# geometry.  cull_disabled matches the base terrain shader.

	if lava_indices.size() > 0:
		var lava_mat: Material = data.get_lava_material()
		if lava_mat:
			lava_mat = lava_mat.duplicate() as Material
			if lava_mat is BaseMaterial3D:
				(lava_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
			var lv_arrays: Array = []
			lv_arrays.resize(Mesh.ARRAY_MAX)
			lv_arrays[Mesh.ARRAY_VERTEX]  = vertices
			lv_arrays[Mesh.ARRAY_NORMAL]  = normals
			lv_arrays[Mesh.ARRAY_TEX_UV]  = uvs
			lv_arrays[Mesh.ARRAY_TEX_UV2] = uv2s
			lv_arrays[Mesh.ARRAY_COLOR]   = colors
			lv_arrays[Mesh.ARRAY_INDEX]   = lava_indices
			var lv_surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lv_arrays)
			mesh.surface_set_material(lv_surface_idx, lava_mat)

	# --- surface override: the biome's own material, tinted by COLOR ---------
	# One surface per material; same vertex arrays as the base (the shader
	# reads COLOR for the rock tint and shares the instance uniforms) plus
	# CUSTOM0 so planet_surface.gdshader keeps its triplanar position.
	for _k in surface_override_indices.size():
		var _so_idx: PackedInt32Array = surface_override_indices[_k]
		if _so_idx.is_empty():
			continue
		var _so_arrays: Array = []
		_so_arrays.resize(Mesh.ARRAY_MAX)
		_so_arrays[Mesh.ARRAY_VERTEX]  = vertices
		_so_arrays[Mesh.ARRAY_NORMAL]  = normals
		_so_arrays[Mesh.ARRAY_TEX_UV]  = uvs
		_so_arrays[Mesh.ARRAY_TEX_UV2] = uv2s
		_so_arrays[Mesh.ARRAY_COLOR]   = colors
		_so_arrays[Mesh.ARRAY_CUSTOM0] = skirt_offsets
		_so_arrays[Mesh.ARRAY_INDEX]   = _so_idx
		var _so_surface := mesh.get_surface_count()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _so_arrays,
				[], {}, _c0_fmt)
		mesh.surface_set_material(_so_surface, _surface_mats[_k])

	# --- lunar ground: ORMMaterial3D overlay on lunar ground terrain ----------
	# Build local tiling UVs from world-space position so the texture repeats
	# at a natural scale.  No vertex colours — the material's own albedo,
	# ORM and normal textures provide all visual detail.
	if lunar_ground_indices.size() > 0:
		var reg_mat: Material = data.get_lunar_ground_material()
		if reg_mat:
			reg_mat = reg_mat.duplicate() as Material
			if reg_mat is BaseMaterial3D:
				(reg_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
				# Disable deep parallax — each chunk has independent normals so
				# POM ray-marching produces different offsets at chunk seams.
				(reg_mat as BaseMaterial3D).heightmap_enabled = false
			# Build tiling UVs from vertex world position.
			# Subtract a chunk-level integer-tile offset so UV values stay
			# near zero — prevents float32 precision loss on the GPU.
			const LUNAR_GROUND_TILE_M := 8.0  # texture repeats every 8 metres
			var _rg_cd := chunk_center.normalized()
			var _rg_clon := atan2(_rg_cd.z, _rg_cd.x)
			var _rg_clat := asin(clampf(_rg_cd.y, -1.0, 1.0))
			var _rg_u_off := floorf(_rg_clon * data.radius / LUNAR_GROUND_TILE_M)
			var _rg_v_off := floorf(_rg_clat * data.radius / LUNAR_GROUND_TILE_M)
			var rg_uvs := PackedVector2Array()
			rg_uvs.resize(vertices.size())
			for vi in vertices.size():
				# vertices are chunk-local; add chunk_center for world pos.
				var world_pos := vertices[vi] + chunk_center
				var d := world_pos.normalized()
				# Project onto tangent plane using lon/lat.
				var lon := atan2(d.z, d.x)
				var lat := asin(clampf(d.y, -1.0, 1.0))
				# Arc-length in metres along surface.
				var x_m := lon * data.radius
				var y_m := lat * data.radius
				rg_uvs[vi] = Vector2(x_m / LUNAR_GROUND_TILE_M - _rg_u_off, y_m / LUNAR_GROUND_TILE_M - _rg_v_off)
			var rg_arrays: Array = []
			rg_arrays.resize(Mesh.ARRAY_MAX)
			rg_arrays[Mesh.ARRAY_VERTEX]  = vertices
			rg_arrays[Mesh.ARRAY_NORMAL]  = normals
			rg_arrays[Mesh.ARRAY_TEX_UV]  = rg_uvs
			rg_arrays[Mesh.ARRAY_INDEX]   = lunar_ground_indices
			var rg_surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rg_arrays)
			mesh.surface_set_material(rg_surface_idx, reg_mat)

	# --- meadow: grass ground texture overlay on meadow terrain -------
	# Same pattern as lunar ground — an additional mesh surface with tiled UVs
	# and the grass_ground ORMMaterial3D drawn on top of the base terrain,
	# giving a grassy ground beneath the 3D grass blade MultiMesh.
	if meadow_indices.size() > 0:
		var gl_mat: Material = data.get_meadow_material()
		if gl_mat:
			gl_mat = gl_mat.duplicate() as Material
			if gl_mat is BaseMaterial3D:
				(gl_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
				# Disable deep parallax — each chunk has independent normals so
				# POM ray-marching produces different offsets at chunk seams.
				(gl_mat as BaseMaterial3D).heightmap_enabled = false
			const GRASS_TILE_M := 4.0  # grass texture repeats every 4 metres
			var _gl_cd := chunk_center.normalized()
			var _gl_clon := atan2(_gl_cd.z, _gl_cd.x)
			var _gl_clat := asin(clampf(_gl_cd.y, -1.0, 1.0))
			var _gl_u_off := floorf(_gl_clon * data.radius / GRASS_TILE_M)
			var _gl_v_off := floorf(_gl_clat * data.radius / GRASS_TILE_M)
			var gl_uvs := PackedVector2Array()
			gl_uvs.resize(vertices.size())
			for vi in vertices.size():
				var world_pos := vertices[vi] + chunk_center
				var d := world_pos.normalized()
				var lon := atan2(d.z, d.x)
				var lat := asin(clampf(d.y, -1.0, 1.0))
				var x_m := lon * data.radius
				var y_m := lat * data.radius
				gl_uvs[vi] = Vector2(x_m / GRASS_TILE_M - _gl_u_off, y_m / GRASS_TILE_M - _gl_v_off)
			var gl_arrays: Array = []
			gl_arrays.resize(Mesh.ARRAY_MAX)
			gl_arrays[Mesh.ARRAY_VERTEX]  = vertices
			gl_arrays[Mesh.ARRAY_NORMAL]  = normals
			gl_arrays[Mesh.ARRAY_TEX_UV]  = gl_uvs
			gl_arrays[Mesh.ARRAY_INDEX]   = meadow_indices
			var gl_surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, gl_arrays)
			mesh.surface_set_material(gl_surface_idx, gl_mat)

	# --- forest_ground: leaf-litter texture overlay on temperate forest ------
	# Same pattern as the meadow grass overlay — tiled lon/lat UVs on a shared
	# vertex buffer, drawn as an extra surface replacing the base terrain.
	if forest_ground_indices.size() > 0:
		var fg_mat: Material = data.get_forest_ground_material()
		if fg_mat:
			fg_mat = fg_mat.duplicate() as Material
			if fg_mat is BaseMaterial3D:
				(fg_mat as BaseMaterial3D).heightmap_enabled = false
				(fg_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
			var _fg_tile_m: float = ForestTemperateForestTerrain.TILE_M
			var _fg_cd := chunk_center.normalized()
			var _fg_clon := atan2(_fg_cd.z, _fg_cd.x)
			var _fg_clat := asin(clampf(_fg_cd.y, -1.0, 1.0))
			var _fg_u_off := floorf(_fg_clon * data.radius / _fg_tile_m)
			var _fg_v_off := floorf(_fg_clat * data.radius / _fg_tile_m)
			var fg_uvs := PackedVector2Array()
			fg_uvs.resize(vertices.size())
			for vi in vertices.size():
				var world_pos := vertices[vi] + chunk_center
				var d := world_pos.normalized()
				var lon := atan2(d.z, d.x)
				var lat := asin(clampf(d.y, -1.0, 1.0))
				var x_m := lon * data.radius
				var y_m := lat * data.radius
				fg_uvs[vi] = Vector2(x_m / _fg_tile_m - _fg_u_off, y_m / _fg_tile_m - _fg_v_off)
			var fg_arrays: Array = []
			fg_arrays.resize(Mesh.ARRAY_MAX)
			fg_arrays[Mesh.ARRAY_VERTEX]  = vertices
			fg_arrays[Mesh.ARRAY_NORMAL]  = normals
			fg_arrays[Mesh.ARRAY_TEX_UV]  = fg_uvs
			fg_arrays[Mesh.ARRAY_INDEX]   = forest_ground_indices
			var fg_surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fg_arrays)
			mesh.surface_set_material(fg_surface_idx, fg_mat)

	# --- cliff: ORMMaterial3D overlay on steep cliff faces -------------------
	# Only triangles within the cliff biome whose face normal is nearly
	# vertical get this overlay.  Tiled UVs use the same lon/lat projection
	# as lunar ground / meadow.
	if cliff_indices.size() > 0:
		var cl_mat: Material = data.get_cliff_material()
		if cl_mat:
			cl_mat = cl_mat.duplicate() as Material
			if cl_mat is BaseMaterial3D:
				(cl_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
				# Disable heightmap/parallax — deep parallax displaces pixels
				# independently per chunk, creating visible seams at boundaries.
				(cl_mat as BaseMaterial3D).heightmap_enabled = false
			var _cl_tile_m := RockyLandformCliffTerrain.TILE_M
			var _cl_cd := chunk_center.normalized()
			var _cl_clon := atan2(_cl_cd.z, _cl_cd.x)
			var _cl_clat := asin(clampf(_cl_cd.y, -1.0, 1.0))
			var _cl_u_off := floorf(_cl_clon * data.radius / _cl_tile_m)
			var _cl_v_off := floorf(_cl_clat * data.radius / _cl_tile_m)
			var cl_uvs := PackedVector2Array()
			cl_uvs.resize(vertices.size())
			for vi in vertices.size():
				var world_pos := vertices[vi] + chunk_center
				var d := world_pos.normalized()
				var lon := atan2(d.z, d.x)
				var lat := asin(clampf(d.y, -1.0, 1.0))
				var x_m := lon * data.radius
				var y_m := lat * data.radius
				cl_uvs[vi] = Vector2(x_m / _cl_tile_m - _cl_u_off, y_m / _cl_tile_m - _cl_v_off)
			var cl_arrays: Array = []
			cl_arrays.resize(Mesh.ARRAY_MAX)
			cl_arrays[Mesh.ARRAY_VERTEX]  = vertices
			cl_arrays[Mesh.ARRAY_NORMAL]  = normals
			cl_arrays[Mesh.ARRAY_TEX_UV]  = cl_uvs
			cl_arrays[Mesh.ARRAY_INDEX]   = cliff_indices
			var cl_surface_idx := mesh.get_surface_count()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cl_arrays)
			mesh.surface_set_material(cl_surface_idx, cl_mat)

	# --- road: biome-adaptive texture overlay on terrain --------------------
	# Roads are independent strip meshes extruded from centerline data,
	# not derived from terrain grid quads.  This gives pixel-accurate width
	# regardless of terrain mesh resolution.
	#
	# UVs are flow-aligned (U = along road, V = across road) so the
	# texture follows the road direction.
	#
	# Material selection: highways/roads → fixed asphalt; paths/trails →
	# biome-adaptive (e.g. path_grass in meadow, path_dirt in forest).
	if has_road_overlap:
		var _rd_m_per_deg := data.radius * PI / 180.0
		var _rd_cbb: Array[Vector2]
		if hp_mode:
			_rd_cbb = _cbb  # Reuse HEALPix bbox computed earlier.
		else:
			_rd_cbb = BiomeQuery._chunk_lonlat_bbox(
				face, u_min, u_max, v_min, v_max)
		var _rd_cbb_min: Vector2 = _rd_cbb[0]
		var _rd_cbb_max: Vector2 = _rd_cbb[1]
		# Group slab geometry by material path — see _road_group().
		var road_groups: Dictionary = {}

		# Pack path: _road_arr holds this chunk's own pieces, already clipped.
		# Legacy path: whole global centerlines from BiomeQuery, which is why the
		# ribbon used to be built N times over and float above the terrain.
		var _rd_sources: Array = _road_arr
		if _rd_sources.is_empty() and rq:
			_rd_sources = []
			for _z in rq.get_zones_for_region(_rd_cbb_min, _rd_cbb_max):
				if RoadTerrain.is_road_zone(_z) and BiomeQuery._aabb_overlap(
						_rd_cbb_min, _rd_cbb_max, _z.bbox_min, _z.bbox_max):
					RoadTerrain.prepare_zone(_z, data.radius)
					_rd_sources.append(_z)

		# Profiled lines — railways and graded roads — leave the ribbon path:
		# their bed is built at the profile's altitude by GradeBed below. One
		# WITHOUT a profile (tiles not available at warm-up) stays here and
		# gets the terrain-hugging slab on its material — the degraded mode.
		var _rw_zones: Array = []

		# The slab's height sampler — the one the collision builder uses too,
		# so the slab the client draws is the slab the server collides with.
		var _rd_height_at := func(d: Vector3) -> float:
			if hp_mode:
				return data.sample_height_for_direction(d, _export_ipix,
						-1, Vector2i(-1, -1), null, _sample_nside, _frame)
			var _fuv := PlanetData.sphere_to_cube(d)
			return data.sample_height_for_chunk(
				_fuv["face"], _fuv["u"], _fuv["v"], u_min, u_max, v_min, v_max)
		var _max_seg_deg := _ribbon_pitch_deg(_rd_cbb, res)

		for _rd_zone in _rd_sources:
			var _rd_rt := RoadTerrain.get_road_type(_rd_zone)
			if GradeSettings.is_profiled(_rd_zone):
				var _rw_prof: Dictionary = data.get_grade_profile(
					int(_rd_zone.get("feature_id", -1)))
				if not _rw_prof.is_empty():
					_rw_zones.append([_rd_zone, _rw_prof])
					continue
			# Half-width in metres, then degrees. The pack pre-computes both
			# (width_m is the total width, halved once by the decoder); the
			# legacy path gets them from RoadTerrain.prepare_zone(). This is
			# where `half_width_deg` used to be ambiguous: BiomeQuery filled it
			# with width/2 in METRES and prepare_zone() overwrote it in degrees.
			var _rd_hw_m: float = float(_rd_zone.get(
				"half_width_m", RoadTerrain.get_half_width_m(_rd_zone)))
			var _rd_tile_m: float = RoadTerrain.get_tile_size(_rd_rt)
			var _rd_cl_full: PackedVector2Array = _rd_zone.get(
				"centerline", PackedVector2Array())
			if _rd_cl_full.size() < 2:
				continue
			# Distance from the road's TRUE start for each stored point. The
			# pack carries it so the asphalt UVs stay continuous where one
			# chunk's piece meets the next; without it every chunk would restart
			# at 0 and the texture would jump at every boundary.
			var _rd_cum_full: PackedFloat64Array = _rd_zone.get(
				"_cum_lengths", PackedFloat64Array())

			var _rd_surf := _road_surface_for(data, _rd_cl_full, _rd_rt,
					_pz_zones, _corundum_bd)
			var grp := _road_group(road_groups, _rd_surf["mat_path"], _rd_tile_m,
					_rd_surf["uv_mode"], _rd_surf["tinted"])

			# Take the ribbon out from under the bridges. Only the pack path can
			# be cut: the exclusion intervals are stated in absolute along-road
			# distances, which the legacy BiomeQuery path does not carry — and
			# which has no bridges either, since detection needs whole roads
			# from the pack.
			#
			# The result is a LIST of pieces, each of which gets its own strip
			# base and its own index run below. Dropping the vertices instead
			# would not open a hole: the strip builder joins consecutive pairs,
			# so it would stretch one quad straight over the gorge.
			var _rd_pieces: Array = [[_rd_cl_full, _rd_cum_full]]
			if _rd_cum_full.size() == _rd_cl_full.size() \
					and data.corundum_default_biome:
				var _rd_excl: Array = data.get_bridge_exclusions_for_feature(
					int(_rd_zone.get("feature_id", -1)))
				if not _rd_excl.is_empty():
					_rd_pieces = RoadCut.split(
						_rd_cl_full, _rd_cum_full, _rd_excl)

			# One slab per carriageway: a highway's two strips leave the median
			# gap open (the ground shows through), any other road is one strip.
			var _rd_layout := RoadTerrain.lane_layout(
					_rd_rt, RoadTerrain.lanes_of(_rd_zone), _rd_hw_m)
			for _rd_piece in _rd_pieces:
				for _rd_strip in _rd_layout["strips"]:
					_road_group_append_slab(road_groups, grp, _rd_surf, _rd_tile_m,
							RoadRibbon.emit_strip(
									_rd_piece[0], _rd_piece[1], _rd_strip, _rd_m_per_deg,
									data.radius, _max_seg_deg, _rd_height_at, cc_f32,
									true, true, _rd_surf["uv_mode"], _rd_tile_m,
									_rd_surf["tint"]))

		# --- profiled bed: level top on the profile, skirts to the ground -----
		# Railways (ballast) and graded roads (asphalt, or melted corundum on
		# the plateau) share this builder; each zone goes to the road_groups
		# entry of its own bed material, so the UV recentring and the surface
		# emission below serve them unchanged. A highway bed's median strip
		# goes to the structure group instead of being left open.
		# The stations are spaced on the chunk's own vertex pitch, the same
		# rule the collision builder applies, so the two beds are one geometry.
		if not _rw_zones.is_empty() and hp_mode:
			var _rw_step_m := HEALPix.pixel_side_length(hp_nside, data.radius) \
					/ float(res) * 0.5
			var _rw_sampler := func(d: Vector3) -> float:
				return data.sample_height_for_direction(d, _export_ipix, -1,
						Vector2i(-1, -1), null, _sample_nside, _frame)
			var _rw_smat := GradeSettings.STRUCTURE_MATERIAL_PATH
			var _rw_stile := RoadTerrain.get_tile_size("railway")
			for _rw_pair in _rw_zones:
				var _rw_zone: Dictionary = _rw_pair[0]
				var _rw_prof: Dictionary = _rw_pair[1]
				var _rw_fid := int(_rw_zone.get("feature_id", -1))
				var _rw_rt := RoadTerrain.get_road_type(_rw_zone)
				var _rw_cl: PackedVector2Array = _rw_zone.get("centerline", PackedVector2Array())
				var _rw_cum: PackedFloat64Array = _rw_zone.get("_cum_lengths", PackedFloat64Array())
				# The bed material: ballast / asphalt from the profile, or the
				# corundum surface when this highway crosses the plateau.
				var _rw_surf := _road_surface_for(data, _rw_cl, _rw_rt,
						_pz_zones, _corundum_bd)
				var _rw_mat: String = _rw_surf["mat_path"] if _rw_surf["tinted"] \
						else GradeSettings.bed_material_of(_rw_zone)
				var _rw_grp := _road_group(road_groups, _rw_mat,
						RoadTerrain.get_tile_size(_rw_rt), _rw_surf["uv_mode"],
						_rw_surf["tinted"])
				var _rw_bed := GradeBed.build_piece(_rw_cl, _rw_cum,
					_rw_prof, data.get_grade_exclusions_for_feature(_rw_fid),
					_rd_m_per_deg, data.radius, _rw_sampler, _rw_step_m, cc_f32,
					true, true, _rw_surf["uv_mode"], _rw_surf["tint"])
				_road_group_append_slab(road_groups, _rw_grp, _rw_surf,
						RoadTerrain.get_tile_size(_rw_rt), _rw_bed)
				var _rw_median: Dictionary = _rw_bed["median"]
				if not (_rw_median["verts"] as PackedVector3Array).is_empty():
					_road_group_append(_road_group(road_groups, _rw_smat, _rw_stile,
							RoadRibbon.UvMode.FLOW, false), _rw_median)
				# Tunnels (tube + headwalls) only where the grid is fine enough to
				# be carved — the same gate as the cuttings, so a coarse LOD shows
				# the mountain whole rather than a tube buried in it.
				if not _rw_ctx.is_empty():
					_road_group_append(_road_group(road_groups, _rw_smat, _rw_stile,
							RoadRibbon.UvMode.FLOW, false),
							GradeTunnel.build_piece(_rw_cl, _rw_cum, _rw_prof,
									data.radius, cc_f32, true, true))

		# Offset flow-aligned UVs per group so values stay near zero
		# (prevents GPU float32 precision artifacts on large planets). Both
		# UV modes survive a whole-tile shift.
		for _grp_key in road_groups:
			var _off_uvs: PackedVector2Array = road_groups[_grp_key]["uvs"]
			if _off_uvs.size() == 0:
				continue
			var _min_u := _off_uvs[0].x
			var _min_v := _off_uvs[0].y
			for _ui in range(1, _off_uvs.size()):
				if _off_uvs[_ui].x < _min_u: _min_u = _off_uvs[_ui].x
				if _off_uvs[_ui].y < _min_v: _min_v = _off_uvs[_ui].y
			var _uv_off := Vector2(floorf(_min_u), floorf(_min_v))
			for _ui in _off_uvs.size():
				_off_uvs[_ui] -= _uv_off
			road_groups[_grp_key]["uvs"] = _off_uvs

		# Emit one surface per material group using SurfaceTool for
		# tangent generation (needed by normal-mapped road materials).
		for mat_path in road_groups:
			var grp: Dictionary = road_groups[mat_path]
			var rv: PackedVector3Array = grp["verts"]
			var rn: PackedVector3Array = grp["norms"]
			var ru: PackedVector2Array = grp["uvs"]
			var rc: PackedColorArray = grp["colors"]
			var ri: PackedInt32Array = grp["indices"]
			var _tinted: bool = grp["tinted"]
			if rv.size() == 0:
				continue
			# Load the road material. This runs on a WorkerThreadPool task, so
			# the cache lookup + ResourceLoader.load + insert must be
			# serialised — an unsynchronised Dictionary write from several mesh
			# tasks at once is a live heap-corruption risk.
			var rd_mat: Material = data.get_road_material_cached(mat_path)
			if rd_mat == null:
				# Loud on purpose: a missing .tres silently dropped every road
				# surface for a long time (the old res://assets/materials/planet/
				# paths in RoadTerrain no longer existed).
				push_warning("[PlanetChunk] Road material not found: '%s' — "
					% mat_path + "road surface skipped.")
				continue
			rd_mat = rd_mat.duplicate() as Material
			if rd_mat is BaseMaterial3D:
				var bm := rd_mat as BaseMaterial3D
				bm.render_priority = 2
				# Disable deep parallax — auto-generated tangents are
				# sufficient for normal mapping but parallax on a flat
				# overlay adds cost without visual benefit. The engraved
				# corundum surface is the exception: its 5 cm grooves ARE
				# the parallax.
				bm.heightmap_enabled = bm.heightmap_enabled \
						and RoadTerrain.keeps_parallax(mat_path)
				# Render both faces to avoid winding-order issues.
				bm.cull_mode = BaseMaterial3D.CULL_DISABLED
			# Build surface via SurfaceTool so tangents are generated
			# (required for correct normal mapping on road materials).
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			for _vi in rv.size():
				st.set_normal(rn[_vi])
				st.set_uv(ru[_vi])
				if _tinted:
					st.set_color(rc[_vi])
				st.add_vertex(rv[_vi])
			for _idx in ri:
				st.add_index(_idx)
			st.generate_tangents()
			var rd_si := mesh.get_surface_count()
			st.commit(mesh)
			mesh.surface_set_material(rd_si, rd_mat)
			# Told to the assembler (meta "road_surfaces"): the road slabs and
			# beds go on their own node, hidden while a finer chunk covers
			# part of this one — see PlanetTerrain._split_road_surfaces.
			var _rd_list: PackedInt32Array = mesh.get_meta("road_surfaces", PackedInt32Array())
			_rd_list.append(rd_si)
			mesh.set_meta("road_surfaces", _rd_list)

	# --- lava_river: hot lava surface sitting ON TOP of the depression ------
	# Like the river water overlay, the lava surface is built as a separate
	# mesh with its own vertices placed at the original (pre-depression)
	# terrain height.  This makes the lava fill the channel like a liquid,
	# sitting at the landscape level instead of following the carved floor.
	#
	# UVs are FLOW-ALIGNED: U runs along the centerline direction and
	# V runs perpendicular to it.  The texture's horizontal axis (U) is
	# more continuous, matching the natural flow of the lava texture.
	if has_lava_river_overlap:
		var lr_mat: Material = data.get_lava_river_material()
		if lr_mat:
			lr_mat = lr_mat.duplicate() as Material
			lr_mat.render_priority = 1
			if lr_mat is BaseMaterial3D:
				(lr_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED

			var lr_verts := PackedVector3Array()
			var lr_norms := PackedVector3Array()
			var lr_uvs := PackedVector2Array()
			var lr_indices := PackedInt32Array()
			var lr_remap: Dictionary = {}

			# Tile size for flow-aligned UVs — from the terrain module.
			var _lr_tile_m: float = VolcanicGeothermalLavaRiverTerrain.TILE_M

			for yi in res:
				for xi in res:
					var i00 := yi * (res + 1) + xi
					var i10 := i00 + 1
					var i01 := i00 + (res + 1)
					var i11 := i01 + 1
					# Include quad if ANY corner is a lava_river vertex.
					if is_lava_river_vertex[i00] == 0 \
							and is_lava_river_vertex[i10] == 0 \
							and is_lava_river_vertex[i01] == 0 \
							and is_lava_river_vertex[i11] == 0:
						continue
					for orig_idx in [i00, i10, i01, i11]:
						if not lr_remap.has(orig_idx):
							var new_idx: int = lr_verts.size()
							lr_remap[orig_idx] = new_idx
							var planet_pos := vertices[orig_idx] + chunk_center
							var ldir := planet_pos.normalized()
							# Use the original (pre-depression) height for lava
							# vertices, terrain height for boundary vertices.
							var h: float
							if is_lava_river_vertex[orig_idx] == 1:
								h = lava_river_original_height[orig_idx]
							else:
								h = planet_pos.length() - data.radius
							lr_verts.append(_world_to_local(ldir * (data.radius + h - VolcanicGeothermalLavaRiverTerrain.SURFACE_OFFSET), cc_f32, _wp_f32))
							lr_norms.append(ldir)
							# Flow-aligned UVs: U = along flow, V = across.
							# Pre-computed during vertex flagging in metres;
							# boundary verts (flag==0) get lon/lat fallback.
							var fuv: Vector2
							if is_lava_river_vertex[orig_idx] == 1:
								fuv = lava_river_flow_uv[orig_idx]
							else:
								# Boundary vertex: approximate with lon/lat.
								var lon := atan2(ldir.z, ldir.x)
								var lat := asin(clampf(ldir.y, -1.0, 1.0))
								fuv = Vector2(lon * data.radius, lat * data.radius)
							lr_uvs.append(fuv / _lr_tile_m)
					# Two triangles for this quad.
					lr_indices.append(lr_remap[i00])
					lr_indices.append(lr_remap[i01])
					lr_indices.append(lr_remap[i10])
					lr_indices.append(lr_remap[i10])
					lr_indices.append(lr_remap[i01])
					lr_indices.append(lr_remap[i11])

			if lr_verts.size() > 0:
				var lr_arrays: Array = []
				lr_arrays.resize(Mesh.ARRAY_MAX)
				lr_arrays[Mesh.ARRAY_VERTEX]  = lr_verts
				lr_arrays[Mesh.ARRAY_NORMAL]  = lr_norms
				lr_arrays[Mesh.ARRAY_TEX_UV]  = lr_uvs
				lr_arrays[Mesh.ARRAY_INDEX]   = lr_indices
				var lr_surface_idx := mesh.get_surface_count()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lr_arrays)
				mesh.surface_set_material(lr_surface_idx, lr_mat)

	# --- dry_river_bed: pebble texture overlay on the carved riverbed floor ---
	# The pebble material sits directly ON the depressed terrain surface
	# (unlike lava river which sits at the pre-depression height).
	# UVs are FLOW-ALIGNED — U along the centerline, V across — so the
	# riverbed pebble texture follows the natural channel direction.
	if has_dry_river_bed_overlap:
		var drb_mat: Material = data.get_riverbed_material()
		if drb_mat:
			drb_mat = drb_mat.duplicate() as Material
			drb_mat.render_priority = 1
			if drb_mat is BaseMaterial3D:
				(drb_mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
				# Disable heightmap deep parallax per-chunk — seams at chunk
				# boundaries from independent POM ray-marching.
				(drb_mat as BaseMaterial3D).heightmap_enabled = false

			var drb_verts := PackedVector3Array()
			var drb_norms := PackedVector3Array()
			var drb_uvs := PackedVector2Array()
			var drb_indices := PackedInt32Array()
			var drb_remap: Dictionary = {}
			var _drb_tile_m: float = ArideDesertDryRiverBedTerrain.TILE_M

			for yi in res:
				for xi in res:
					var i00 := yi * (res + 1) + xi
					var i10 := i00 + 1
					var i01 := i00 + (res + 1)
					var i11 := i01 + 1
					# Include quad if ANY corner is a dry riverbed vertex.
					if is_dry_river_bed_vertex[i00] == 0 \
							and is_dry_river_bed_vertex[i10] == 0 \
							and is_dry_river_bed_vertex[i01] == 0 \
							and is_dry_river_bed_vertex[i11] == 0:
						continue
					for orig_idx in [i00, i10, i01, i11]:
						if not drb_remap.has(orig_idx):
							var new_idx: int = drb_verts.size()
							drb_remap[orig_idx] = new_idx
							drb_verts.append(vertices[orig_idx])
							drb_norms.append(normals[orig_idx])
							var fuv: Vector2
							if is_dry_river_bed_vertex[orig_idx] == 1:
								fuv = dry_river_bed_flow_uv[orig_idx]
							else:
								# Boundary vertex — approximate with lon/lat projection.
								var _planet_pos := vertices[orig_idx] + chunk_center
								var _d := _planet_pos.normalized()
								var _lon := atan2(_d.z, _d.x)
								var _lat := asin(clampf(_d.y, -1.0, 1.0))
								fuv = Vector2(_lon * data.radius, _lat * data.radius)
							drb_uvs.append(fuv / _drb_tile_m)
					# Two triangles for this quad.
					drb_indices.append(drb_remap[i00])
					drb_indices.append(drb_remap[i01])
					drb_indices.append(drb_remap[i10])
					drb_indices.append(drb_remap[i10])
					drb_indices.append(drb_remap[i01])
					drb_indices.append(drb_remap[i11])

			if drb_verts.size() > 0:
				var drb_arrays: Array = []
				drb_arrays.resize(Mesh.ARRAY_MAX)
				drb_arrays[Mesh.ARRAY_VERTEX]  = drb_verts
				drb_arrays[Mesh.ARRAY_NORMAL]  = drb_norms
				drb_arrays[Mesh.ARRAY_TEX_UV]  = drb_uvs
				drb_arrays[Mesh.ARRAY_INDEX]   = drb_indices
				var drb_surface_idx := mesh.get_surface_count()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, drb_arrays)
				mesh.surface_set_material(drb_surface_idx, drb_mat)

	# --- per-chunk water overlay --------------------------------------------
	# If this chunk overlaps a liquid zone, build a mesh surface whose
	# vertices sit at the original terrain height + WATER_OFFSET.  This makes
	# the water follow the landscape contour regardless of heightmap values.
	if has_liquid_overlap:
		var liquid_mat: Material = data.get_liquid_material()
		if liquid_mat:
			# Duplicate so we can set per-planet shader parameters.
			liquid_mat = liquid_mat.duplicate() as Material

			# Collect quads that have at least one liquid vertex.
			var w_verts := PackedVector3Array()
			var w_normals := PackedVector3Array()
			var w_uvs := PackedVector2Array()
			var w_indices := PackedInt32Array()
			# Map from original vertex index → water vertex index.
			var remap: Dictionary = {}

			for yi in res:
				for xi in res:
					var i00 := yi * (res + 1) + xi
					var i10 := i00 + 1
					var i01 := i00 + (res + 1)
					var i11 := i01 + 1
					# Include the quad if ANY corner is liquid.
					if is_liquid_vertex[i00] == 0 and is_liquid_vertex[i10] == 0 \
							and is_liquid_vertex[i01] == 0 and is_liquid_vertex[i11] == 0:
						continue
					# Ensure all 4 corners are in the water vertex list.
					for orig_idx in [i00, i10, i01, i11]:
						if not remap.has(orig_idx):
							var new_idx: int = w_verts.size()
							remap[orig_idx] = new_idx
							var planet_pos := vertices[orig_idx] + chunk_center
							var dir := planet_pos.normalized()
							# Place water at original terrain height + small
							# offset so it sits right at the landscape level.
							var h: float
							if is_liquid_vertex[orig_idx] == 1:
								h = original_height[orig_idx]
							elif orig_idx < original_height.size():
								h = original_height[orig_idx]
							else:
								h = 0.0
							# Non-liquid corners of boundary quads: use the
							# terrain height from the vertex directly.
							if is_liquid_vertex[orig_idx] == 0:
								h = planet_pos.length() - data.radius
							w_verts.append(_world_to_local(dir * (data.radius + h + WATER_OFFSET), cc_f32, _wp_f32))
							w_normals.append(dir)
							w_uvs.append(uvs[orig_idx])
					# Two triangles for this quad.
					w_indices.append(remap[i00])
					w_indices.append(remap[i01])
					w_indices.append(remap[i10])
					w_indices.append(remap[i10])
					w_indices.append(remap[i01])
					w_indices.append(remap[i11])

			if w_verts.size() > 0:
				# Set shader params using average water radius for wave calc.
				var avg_water_r: float = 0.0
				for wv in w_verts:
					avg_water_r += (wv + chunk_center).length()
				avg_water_r /= float(w_verts.size())
				if liquid_mat is ShaderMaterial:
					var sm := liquid_mat as ShaderMaterial
					sm.set_shader_parameter("planet_radius", avg_water_r)
					sm.set_shader_parameter("water_level_offset", 0.0)

				var w_arrays: Array = []
				w_arrays.resize(Mesh.ARRAY_MAX)
				w_arrays[Mesh.ARRAY_VERTEX] = w_verts
				w_arrays[Mesh.ARRAY_NORMAL] = w_normals
				w_arrays[Mesh.ARRAY_TEX_UV] = w_uvs
				w_arrays[Mesh.ARRAY_INDEX]  = w_indices
				var liquid_surface_idx := mesh.get_surface_count()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, w_arrays)
				mesh.surface_set_material(liquid_surface_idx, liquid_mat)

	# --- shallow water overlay (swamp, bog, marsh) --------------------------
	# Thin translucent water sheet at terrain level — no depression.
	# Placed as the next available surface after terrain (+ liquid if present).
	const SHALLOW_WATER_OFFSET := 0.3  # metres above terrain
	if has_shallow_water_overlap:
		var sw_mat: Material = data.get_shallow_water_material()
		if sw_mat:
			sw_mat = sw_mat.duplicate() as Material

			var sw_verts := PackedVector3Array()
			var sw_normals := PackedVector3Array()
			var sw_uvs := PackedVector2Array()
			var sw_colors := PackedColorArray()  # .r = edge_fade (0=edge, 1=interior)
			var sw_indices := PackedInt32Array()
			var sw_remap: Dictionary = {}
			# Fade band in metres — over this distance alpha ramps from 0 to full.
			var sw_fade_m := 20.0
			var sw_m_per_deg := data.radius * PI / 180.0

			for yi in res:
				for xi in res:
					var i00 := yi * (res + 1) + xi
					var i10 := i00 + 1
					var i01 := i00 + (res + 1)
					var i11 := i01 + 1
					# Include quad if ANY corner is shallow_water.
					if is_shallow_water_vertex[i00] == 0 \
							and is_shallow_water_vertex[i10] == 0 \
							and is_shallow_water_vertex[i01] == 0 \
							and is_shallow_water_vertex[i11] == 0:
						continue
					for orig_idx in [i00, i10, i01, i11]:
						if not sw_remap.has(orig_idx):
							var new_idx: int = sw_verts.size()
							sw_remap[orig_idx] = new_idx
							var planet_pos := vertices[orig_idx] + chunk_center
							var sdir := planet_pos.normalized()
							var h: float = planet_pos.length() - data.radius
							sw_verts.append(_world_to_local(sdir * (data.radius + h + SHALLOW_WATER_OFFSET), cc_f32, _wp_f32))
							sw_normals.append(sdir)
							sw_uvs.append(uvs[orig_idx])
							# Edge fade: distance to polygon boundary → 0..1 ramp.
							var edge_f := 1.0
							if is_shallow_water_vertex[orig_idx] == 1 and not _pz_zones.is_empty():
								var sw_lonlat := BiomeQuery._dir_to_lonlat(sdir)
								var sw_zones := _query_zones_at_direction(sdir, _pz_zones)
								for sw_z in sw_zones:
									var sw_bd := data.get_biome_by_type(sw_z.get("biome_type", ""))
									if sw_bd and sw_bd.has_shallow_water:
										var _sw_verts: Array = sw_z.get("vertices", [])
										if _sw_verts.size() >= 3:
											var _sw_poly := PackedVector2Array()
											for _sv in _sw_verts:
												_sw_poly.append(Vector2(_sv[0], _sv[1]))
											var d_deg := BiomeQuery._dist_to_polygon_edge(sw_lonlat, _sw_poly)
											var d_m := d_deg * sw_m_per_deg
											edge_f = clampf(d_m / sw_fade_m, 0.0, 1.0)
										elif sw_z.get("coverage", "") == "full":
											edge_f = 1.0
										break
							else:
								edge_f = 0.0  # non-shallow boundary vertex
							sw_colors.append(Color(edge_f, 0.0, 0.0, 1.0))
					sw_indices.append(sw_remap[i00])
					sw_indices.append(sw_remap[i01])
					sw_indices.append(sw_remap[i10])
					sw_indices.append(sw_remap[i10])
					sw_indices.append(sw_remap[i01])
					sw_indices.append(sw_remap[i11])

			if sw_verts.size() > 0:
				var avg_sw_r: float = 0.0
				for sv in sw_verts:
					avg_sw_r += (sv + chunk_center).length()
				avg_sw_r /= float(sw_verts.size())
				if sw_mat is ShaderMaterial:
					var sm := sw_mat as ShaderMaterial
					sm.set_shader_parameter("planet_radius", avg_sw_r)
					sm.set_shader_parameter("water_level_offset", 0.0)

				var sw_arrays: Array = []
				sw_arrays.resize(Mesh.ARRAY_MAX)
				sw_arrays[Mesh.ARRAY_VERTEX] = sw_verts
				sw_arrays[Mesh.ARRAY_NORMAL] = sw_normals
				sw_arrays[Mesh.ARRAY_TEX_UV] = sw_uvs
				sw_arrays[Mesh.ARRAY_COLOR]  = sw_colors
				sw_arrays[Mesh.ARRAY_INDEX]  = sw_indices
				var sw_surface_idx := mesh.get_surface_count()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sw_arrays)
				mesh.surface_set_material(sw_surface_idx, sw_mat)

	# --- river water overlay ------------------------------------------------
	# Flowing water surface for river biomes.  Built as a ribbon mesh that
	# follows the centerline geometry, giving smooth edges independent of
	# the terrain grid resolution.  Each cross-section has N_ACROSS+1
	# vertices with cross_t evenly spaced from 0 (center) to 1 (edge).
	# The ribbon is clipped to the chunk lon/lat bounding box to avoid
	# double-rendering across adjacent chunks.
	if has_river_overlap:
		var rw_mat: Material = data.get_river_material()
		if rw_mat:
			rw_mat = rw_mat.duplicate() as Material

			var rw_verts := PackedVector3Array()
			var rw_normals := PackedVector3Array()
			var rw_uvs := PackedVector2Array()
			var rw_colors := PackedColorArray()  # .r = cross_t, .g = along_t
			var rw_indices := PackedInt32Array()

			# Number of vertex pairs across the half-width (center to edge).
			# Full cross-section has 2*N_HALF+1 vertices (mirrored).
			const N_HALF := 4
			const N_ACROSS := 2 * N_HALF  # divisions across full width

			# Chunk bounding box in lon/lat for clipping (already computed).
			var _rw_bb_min: Vector2 = _cbb[0] if _cbb.size() >= 2 else Vector2(-180, -90)
			var _rw_bb_max: Vector2 = _cbb[1] if _cbb.size() >= 2 else Vector2(180, 90)

			var m_per_deg := data.radius * PI / 180.0

			for _rz in _river_zones:
				var cl: PackedVector2Array = _rz.get("centerline", PackedVector2Array())
				if cl.size() < 2:
					continue
				var cum: PackedFloat64Array = _rz.get("_cum_lengths", PackedFloat64Array())
				var total_len: float = _rz.get("_total_length", 0.0)
				if total_len <= 0.0:
					continue

				# Progressive width in metres.
				var ws_m: float = _rz.get("width_start_m", 0.0)
				var we_m: float = _rz.get("width_end_m", 0.0)
				if ws_m <= 0.0 and we_m <= 0.0:
					var w: float = _rz.get("width", 10.0)
					ws_m = w
					we_m = w
				var max_hw_m: float = maxf(ws_m, we_m) * 0.5

				# Along-river step: ~1/4 of average width, clamped to [2m, 30m].
				var avg_w := (ws_m + we_m) * 0.5
				var step_m: float = clampf(avg_w * 0.25, 2.0, 30.0)

				# Resample the centerline at uniform spacing + original vertices.
				# Each sample: Vector3(lon, lat, along_m).
				var samples: Array[Vector3] = []
				samples.append(Vector3(cl[0].x, cl[0].y, 0.0))
				var accum_m := 0.0
				var next_stop := step_m
				for si in cl.size() - 1:
					var a := cl[si]
					var b := cl[si + 1]
					var seg_len: float = cum[si + 1] - cum[si] if si + 1 < cum.size() else 0.0
					if seg_len <= 0.0:
						continue
					# Emit intermediate samples within this segment.
					while next_stop < cum[si + 1]:
						var frac := (next_stop - cum[si]) / seg_len
						var pt := a.lerp(b, frac)
						samples.append(Vector3(pt.x, pt.y, next_stop))
						next_stop += step_m
					# Always emit the segment endpoint.
					accum_m = cum[si + 1]
					# Avoid duplicate if very close to last sample.
					if samples.size() == 0 or (Vector2(samples[samples.size() - 1].x, samples[samples.size() - 1].y) - b).length() * m_per_deg > 0.5:
						samples.append(Vector3(b.x, b.y, accum_m))

				if samples.size() < 2:
					continue

				# Margin in degrees for chunk clipping (half-width + one step).
				var margin_deg := (max_hw_m + step_m) / m_per_deg

				# Build ribbon cross-sections.  Each row has (N_ACROSS + 1) verts.
				var row_size := N_ACROSS + 1  # verts per cross-section
				# prev_row_start tracks the vertex index of the previous
				# in-bounds row so we only connect consecutive rows with
				# triangles (a clipped-out sample creates a gap).
				var prev_row_start: int = -1

				for si in samples.size():
					var sp := samples[si]
					var s_lon: float = sp.x
					var s_lat: float = sp.y
					var s_along_m: float = sp.z

					# Clip: skip centerline points outside chunk bounds (with margin).
					if s_lon < _rw_bb_min.x - margin_deg or s_lon > _rw_bb_max.x + margin_deg:
						prev_row_start = -1
						continue
					if s_lat < _rw_bb_min.y - margin_deg or s_lat > _rw_bb_max.y + margin_deg:
						prev_row_start = -1
						continue

					# along_t: 0 at start, 1 at end.
					var along_t: float = clampf(s_along_m / total_len, 0.0, 1.0)
					# Half-width at this position (metres).
					var hw_m: float = lerpf(ws_m, we_m, along_t) * 0.5
					var hw_deg: float = hw_m / m_per_deg

					# Tangent direction (lon/lat space) for perpendicular computation.
					var tangent: Vector2
					if si == 0:
						tangent = Vector2(samples[1].x - sp.x, samples[1].y - sp.y)
					elif si == samples.size() - 1:
						var prev_sp := samples[si - 1]
						tangent = Vector2(sp.x - prev_sp.x, sp.y - prev_sp.y)
					else:
						var prev_sp := samples[si - 1]
						var next_sp := samples[si + 1]
						tangent = Vector2(next_sp.x - prev_sp.x, next_sp.y - prev_sp.y)
					if tangent.length_squared() < 1e-20:
						tangent = Vector2(1, 0)
					tangent = tangent.normalized()
					# Perpendicular (rotate 90° clockwise in lon/lat).
					var perp := Vector2(-tangent.y, tangent.x)

					var this_row_start: int = rw_verts.size()

					# Generate cross-section vertices: from left edge → center → right edge.
					for ci in row_size:
						# cross_frac: -1 (left edge) → 0 (center) → +1 (right edge)
						var cross_frac: float = -1.0 + 2.0 * float(ci) / float(N_ACROSS)
						var cross_t_val: float = absf(cross_frac)  # 0=center, 1=edge
						# Position offset in lon/lat.
						var offset := perp * (cross_frac * hw_deg)
						var v_lon: float = s_lon + offset.x
						var v_lat: float = s_lat + offset.y

						var rdir := HEALPix.lonlat2vec(v_lon, v_lat)
						var h: float = data.sample_height_for_direction(rdir)
						rw_verts.append(_world_to_local(
								rdir * (data.radius + h + MaritimeRiverRiverTerrain.WATER_OFFSET),
								cc_f32, _wp_f32))
						rw_normals.append(rdir)
						rw_uvs.append(PlanetData.direction_to_uv(rdir))
						rw_colors.append(Color(cross_t_val, along_t, 0.0, 1.0))

					# Connect to previous row if it was in-bounds (no gap).
					if prev_row_start >= 0:
						var r0 := prev_row_start
						var r1 := this_row_start
						for ci in N_ACROSS:
							rw_indices.append(r0 + ci)
							rw_indices.append(r1 + ci)
							rw_indices.append(r0 + ci + 1)
							rw_indices.append(r0 + ci + 1)
							rw_indices.append(r1 + ci)
							rw_indices.append(r1 + ci + 1)
					prev_row_start = this_row_start

			if rw_verts.size() > 0:
				var avg_rw_r: float = 0.0
				for rv in rw_verts:
					avg_rw_r += (rv + chunk_center).length()
				avg_rw_r /= float(rw_verts.size())

				if rw_mat is ShaderMaterial:
					var sm := rw_mat as ShaderMaterial
					sm.set_shader_parameter("planet_radius", avg_rw_r)
					sm.set_shader_parameter("water_level_offset", 0.0)
					# Set flow direction from the first river zone found.
					if not river_zone_for_flow.is_empty():
						var center_dir := chunk_center.normalized()
						if center_dir.length_squared() < 0.5:
							center_dir = Vector3.UP
						var center_lonlat := BiomeQuery._dir_to_lonlat(center_dir)
						var flow_vec := BiomeQuery.get_flow_vector(
								river_zone_for_flow, center_lonlat)
						sm.set_shader_parameter("flow_dir", flow_vec)

				var rw_arrays: Array = []
				rw_arrays.resize(Mesh.ARRAY_MAX)
				rw_arrays[Mesh.ARRAY_VERTEX] = rw_verts
				rw_arrays[Mesh.ARRAY_NORMAL] = rw_normals
				rw_arrays[Mesh.ARRAY_TEX_UV] = rw_uvs
				rw_arrays[Mesh.ARRAY_COLOR]  = rw_colors
				rw_arrays[Mesh.ARRAY_INDEX]  = rw_indices
				var rw_surface_idx := mesh.get_surface_count()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rw_arrays)
				mesh.surface_set_material(rw_surface_idx, rw_mat)

	if _pf:
		var _now := Time.get_ticks_usec()
		prof["surface"] = _now - _t_phase
		prof["total"] = _now - _t_start
		prof["tile"] = PlanetData.prof_thread_tile_usec() - _t_tile0

	# Zéro = tous les sommets ont lu leur propre tuile ; le mesh est persistable.
	mesh.set_meta("provisional_climbs", data.climb_count())
	return mesh


## Generate a [ConcavePolygonShape3D] for server-side collision.
## Uses the same cube-sphere + heightmap projection at a (usually lower)
## resolution to keep collision cheap.
static func generate_collision_shape(
		data: PlanetData,
		face: int,
		u_min: float, u_max: float,
		v_min: float, v_max: float,
		resolution: int,
		hp_nside: int = 0,
		hp_ipix: int = -1) -> ConcavePolygonShape3D:

	var hp_mode := hp_nside > 0
	var res := resolution
	var u_step := (u_max - u_min) / float(res) if not hp_mode else 0.0
	var v_step := (v_max - v_min) / float(res) if not hp_mode else 0.0
	# Combien de sommets vont lire un ancêtre faute d'avoir leur tuile ? La réponse
	# voyage avec la forme (méta "provisional_climbs") et décide si elle a le droit
	# d'aller dans le cache disque. Voir PlanetData.climb_mark().
	data.climb_reset()

	var grid_dirs: Array[PackedVector3Array] = []
	var _export_ipix: int = -1
	# Collision-grid vertex spacing (m) — feeds the crack LOD fade.  The server
	# collision grid is ~397 m/vertex, far coarser than a ~500 m crack, so the
	# fade zeroes the carve here (and skips the expensive Voronoi), which is what
	# keeps the server framerate up.  Cracks are carved only where the grid is
	# fine enough to actually represent them.
	var _col_crack_spacing := 0.0
	# Height tile is separate from _export_ipix: _export_ipix stays at export_nside
	# for recipe lookups (craters/zones/features), while heights read the pyramid
	# level matching this chunk's own nside so collision matches the rendered mesh.
	var _height_nside := data.sample_nside_for(hp_nside)
	var _height_ipix: int = -1
	if hp_mode:
		grid_dirs = HEALPix.get_pixel_grid(hp_nside, hp_ipix, res)
		if res > 0:
			_col_crack_spacing = HEALPix.pixel_side_length(hp_nside, 1.0) \
					* data.radius / float(res)
		if hp_nside >= data.export_nside:
			_export_ipix = hp_ipix
			var _ns := hp_nside
			while _ns > data.export_nside:
				_export_ipix >>= 2
				_ns /= 2
			_height_ipix = _export_ipix
		elif hp_nside == _height_nside:
			# Pyramid coarse chunk: one baked tile at the chunk's own level.
			_height_ipix = hp_ipix
		# else: coarser than coarsest baked level (or legacy flat) → leave -1
		# so each vertex resolves via vec2pix at _height_nside (matches builder 1).

	# ── Fetch recipe data for collision overlap detection ─────────
	var _col_pz_zones: Array = []
	var _col_lf_arr: Array = []
	var _col_rf_arr: Array = []
	var _col_cr_arr: Array = []
	# Profiled beds ride their own profile, not the terrain, so unlike the road
	# ribbon they DO get collision — built into this very shape (same origin,
	# same lifetime) from the chunk's own clipped pieces.
	var _col_rw: Array = []
	# Terrain-hugging roads are slabs with their own collision too (RoadRibbon):
	# every road piece of the chunk that is NOT built on a profile — a
	# profiled line whose profile is missing falls back here like the mesh.
	var _col_rd: Array = []
	if hp_mode:
		var _col_eipix := _export_ipix
		_col_pz_zones = data.get_chunk_populate_zones(_col_eipix)
		_col_lf_arr = data.get_chunk_linear_features(_col_eipix)
		_col_rf_arr = data.get_chunk_radial_features(_col_eipix)
		_col_cr_arr = data.get_chunk_craters(_col_eipix)
		for _rd_r in data.get_roads_for_chunk(hp_nside, hp_ipix):
			if not RoadTerrain.is_road_zone(_rd_r):
				continue
			if GradeSettings.is_profiled(_rd_r):
				var _rw_p: Dictionary = data.get_grade_profile(int(_rd_r.get("feature_id", -1)))
				if not _rw_p.is_empty():
					_col_rw.append([_rd_r, _rw_p])
					continue
			_col_rd.append(_rd_r)
	# Profiled-line cuttings, on the same finest-grid gate as the visual mesh.
	var _col_rw_ctx: Dictionary = {}
	var _col_rw_band := PackedByteArray()
	var _col_rw_h := PackedFloat64Array()
	if hp_mode and data.has_profiled_lines():
		_col_rw_ctx = GradeBed.make_ctx(data, hp_nside, hp_ipix, _col_crack_spacing)
		if not _col_rw_ctx.is_empty():
			_col_rw_band.resize((res + 1) * (res + 1))
			_col_rw_h.resize((res + 1) * (res + 1))

	var has_liquid_overlap := false
	var has_linear_overlap := false
	var has_point_overlap := false
	var has_crater_overlap := false
	var has_lava_river_overlap := false
	var has_cliff_overlap := false
	var has_river_overlap := false
	var _col_river_zones: Array[Dictionary] = []
	# Biome relief (same gate, same roads, same call as generate_mesh).
	var has_relief_overlap := false

	# Populate zones (polygon/point biomes).
	for _pz in _col_pz_zones:
		var _bt: String = _pz.get("biome_type", "")
		var _bd = data.get_biome_by_type(_bt)
		if _bd == null:
			continue
		if _bd.has_relief():
			has_relief_overlap = true
		if _bd.is_liquid and data.has_ocean:
			has_liquid_overlap = true
		if CaveTerrain.is_cave_biome(_bd) \
				or VolcanicGeothermalFumaroleTerrain.is_fumarole_biome(_bd) \
				or VolcanicGeothermalIceGeyserTerrain.matches_zone(_bd) \
				or VolcanicGeothermalMineralThermalSourceTerrain.matches_zone(_bd):
			has_point_overlap = true
		if SpatialCraterTerrain.is_crater_biome(_bd):
			has_crater_overlap = true
		if RockyLandformCliffTerrain.matches_zone(_bd):
			has_cliff_overlap = true
	var _col_relief_roads: Array = []
	var _col_relief_mpd := data.radius * PI / 180.0
	if has_relief_overlap and hp_mode:
		_col_relief_roads = BiomeRelief.gather_roads(data, hp_nside, hp_ipix)

	# Linear features.
	for _lf in _col_lf_arr:
		var _lt: String = _lf.get("type", "")
		var _lcl: Array = _lf.get("centerline", [])
		if _lcl.size() < 2:
			continue
		if _lt == "maritime_river-river":
			has_river_overlap = true
			_col_river_zones.append(_lf)
		elif _lt == "volcanic_geothermal-lava_river":
			has_lava_river_overlap = true
		elif _lt == "rocky_landform-canyon" or _lt == "icy-ice_crevasse" \
				or _lt == "aride_desert-dry_river_bed" \
				or _lt == "rocky_landform-pressure_canyon":
			has_linear_overlap = true

	# Radial features.
	for _rf in _col_rf_arr:
		var _rt: String = _rf.get("type", "")
		if _rt == "volcanic_geothermal-active_volcano":
			has_point_overlap = true

	# Craters.
	if not _col_cr_arr.is_empty():
		has_crater_overlap = true

	# Pre-prepare river zones.
	if has_river_overlap:
		for _rz in _col_river_zones:
			var _rcl: Array = _rz.get("centerline", [])
			if _rcl.size() >= 2:
				MaritimeRiverRiverTerrain.prepare_zone(_rz, data.radius)

	# ── Recipe crater data (collision) ─────────────────────────────
	var _col_recipe_craters: Array = _col_cr_arr

	# ── Pre-query compact craters from recipe ──────────────────────
	var _col_compact_craters: Array = _col_cr_arr

	# Build vertex grid
	var grid: Array[Vector3] = []
	grid.resize((res + 1) * (res + 1))

	# Même cadre que le constructeur visuel (voir generate_mesh). Il remplace les trois
	# précalculs passés à la main : ceux-ci décrivaient la tuile DEMANDÉE, et restaient en
	# place quand un pack creux faisait remonter l'échantillonnage à un ancêtre — la
	# collision lisait alors le terrain à côté du rendu. Le cadre est indexé par tuile,
	# donc il ne peut pas se désynchroniser.
	var _frame: PlanetData.TileFrame = data.make_tile_frame() if hp_mode else null

	for yi in res + 1:
		for xi in res + 1:
			var dir: Vector3
			var height: float
			if hp_mode:
				dir = grid_dirs[yi][xi]
				if xi == 0 or xi == res or yi == 0 or yi == res:
					height = data.sample_height_boundary(dir, _height_ipix,
							-1, Vector2i(-1, -1), null, _height_nside, _frame)
				else:
					height = data.sample_height_for_direction(dir, _height_ipix,
							-1, Vector2i(-1, -1), null, _height_nside, _frame)
			else:
				var u: float
				if xi == 0:
					u = u_min
				elif xi == res:
					u = u_max
				else:
					u = u_min + xi * u_step
				var v: float
				if yi == 0:
					v = v_min
				elif yi == res:
					v = v_max
				else:
					v = v_min + yi * v_step
				dir = PlanetData.cube_to_sphere(face, u, v)
				height = data.sample_height_for_chunk(
						face, u, v, u_min, u_max, v_min, v_max)
			# Depress liquid biome zones below the water surface.
			# Rivers are carved at runtime (recipe too coarse), then
			# non-river liquids get a flat depression.
			if has_river_overlap:
				var lonlat := BiomeQuery._dir_to_lonlat(dir)
				var best_t: float = 1.0
				var best_along: float = 0.0
				var best_rzone: Dictionary = {}
				for _rz in _col_river_zones:
					var _rcl: PackedVector2Array = _rz.get("centerline", PackedVector2Array())
					if _rcl.size() < 2:
						continue
					var cs := BiomeQuery.get_cross_section_t(_rz, lonlat)
					var t: float = cs.t
					if t < best_t:
						best_t = t
						best_along = cs.along_t
						best_rzone = _rz
				if best_t < 1.0 and not best_rzone.is_empty():
					var ws: float = best_rzone.get("width_start_m", 0.0)
					var we: float = best_rzone.get("width_end_m", 0.0)
					var width_here: float
					if ws > 0.0 or we > 0.0:
						width_here = lerpf(ws, we, best_along)
					else:
						width_here = best_rzone.get("width", 10.0)
					var zdepth: float = width_here * MaritimeRiverRiverTerrain.DEPTH_RATIO
					if zdepth < 0.5:
						zdepth = 0.5
					height -= zdepth * (1.0 - best_t * best_t)
				elif has_liquid_overlap:
					# Not inside a river — check populate zones for liquid.
					var _lq_zones := _query_zones_at_direction(dir, _col_pz_zones)
					for _lq_z in _lq_zones:
						var _lq_bd := data.get_biome_by_type(_lq_z.get("biome_type", ""))
						if _lq_bd and _lq_bd.is_liquid:
							height -= 10.0
							break
			elif has_liquid_overlap:
				var _lq_zones := _query_zones_at_direction(dir, _col_pz_zones)
				for _lq_z in _lq_zones:
					var _lq_bd := data.get_biome_by_type(_lq_z.get("biome_type", ""))
					if _lq_bd and _lq_bd.is_liquid:
						height -= 10.0
						break
			# Linear depression — iterate recipe linear features.
			if has_linear_overlap:
				var _lin_lonlat := BiomeQuery._dir_to_lonlat(dir)
				for _lin_z in _col_lf_arr:
					var _lin_type: String = _lin_z.get("type", "")
					if _lin_type == "volcanic_geothermal-lava_river" \
							or _lin_type == "maritime_river-river":
						continue
					var _lin_cl: PackedVector2Array = _lin_z.get("centerline", PackedVector2Array())
					if _lin_cl.size() < 2:
						continue
					var _lin_depth_m: float = RockyLandformCanyonTerrain.DEFAULT_DEPTH_M
					match _lin_type:
						"rocky_landform-canyon":
							RockyLandformCanyonTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = RockyLandformCanyonTerrain.DEFAULT_DEPTH_M
						"icy-ice_crevasse":
							IcyIceCrevasseTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = IcyIceCrevasseTerrain.DEFAULT_DEPTH_M
						"aride_desert-dry_river_bed":
							ArideDesertDryRiverBedTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = ArideDesertDryRiverBedTerrain.DEFAULT_DEPTH_M
						"rocky_landform-pressure_canyon":
							RockyLandformPressureCanyonTerrain.prepare_zone(_lin_z, data.radius)
							_lin_depth_m = RockyLandformPressureCanyonTerrain.DEFAULT_DEPTH_M
						_:
							RockyLandformCanyonTerrain.prepare_zone(_lin_z, data.radius)
					var _lin_cs := BiomeQuery.get_cross_section_t(_lin_z, _lin_lonlat)
					var ct: float = _lin_cs.t
					if ct < 1.0:
						var cdepth: float = _lin_z.get("depth_override", 0.0)
						if cdepth <= 0.0:
							cdepth = _lin_depth_m
						var ct2 := ct * ct
						height -= cdepth * (1.0 - ct2 * ct2)
						break
			# Lava river depression — iterate recipe linear features.
			if has_lava_river_overlap:
				for _lr_z in _col_lf_arr:
					if _lr_z.get("type", "") != "volcanic_geothermal-lava_river":
						continue
					var _lr_cl: PackedVector2Array = _lr_z.get("centerline", PackedVector2Array())
					if _lr_cl.size() < 2:
						continue
					VolcanicGeothermalLavaRiverTerrain.prepare_zone(_lr_z, data.radius)
					var lr_ll := BiomeQuery._dir_to_lonlat(dir)
					var _lr_cs2 := BiomeQuery.get_cross_section_t(_lr_z, lr_ll)
					var lr_ct: float = _lr_cs2.t
					if lr_ct < 1.0:
						var lr_dp: float = _lr_z.get("depth_override", 0.0)
						if lr_dp <= 0.0:
							lr_dp = VolcanicGeothermalLavaRiverTerrain.DEFAULT_DEPTH_M
						var lr_t2 := lr_ct * lr_ct
						height -= lr_dp * (1.0 - lr_t2 * lr_t2)
					break
			# Point depression — query populate zones for point biomes.
			var _is_hole_vertex := false
			if has_point_overlap:
				var _pt_zones := _query_zones_at_direction(dir, _col_pz_zones)
				for pz in _pt_zones:
					var pbd := data.get_biome_by_type(pz.get("biome_type", ""))
					if pbd == null:
						continue
					var _pt_radius: float = 0.0
					var _pt_depth: float = 0.0
					var _pt_hole_radius: float = 0.0
					var _pt_has_hole := false
					if CaveTerrain.is_cave_biome(pbd):
						_pt_radius = CaveTerrain.ENTRANCE_RADIUS_M
						_pt_depth = CaveTerrain.ENTRANCE_DEPTH_M
						_pt_hole_radius = CaveTerrain.HOLE_RADIUS_M
						_pt_has_hole = true
					elif VolcanicGeothermalFumaroleTerrain.matches_zone(pbd):
						_pt_radius = VolcanicGeothermalFumaroleTerrain.DEPRESSION_RADIUS_M
						_pt_depth = VolcanicGeothermalFumaroleTerrain.DEPRESSION_DEPTH_M
					elif VolcanicGeothermalIceGeyserTerrain.matches_zone(pbd):
						_pt_radius = VolcanicGeothermalIceGeyserTerrain.DEPRESSION_RADIUS_M
						_pt_depth = VolcanicGeothermalIceGeyserTerrain.DEPRESSION_DEPTH_M
					elif VolcanicGeothermalMineralThermalSourceTerrain.matches_zone(pbd):
						_pt_radius = VolcanicGeothermalMineralThermalSourceTerrain.DEPRESSION_RADIUS_M
						_pt_depth = VolcanicGeothermalMineralThermalSourceTerrain.DEPRESSION_DEPTH_M
					if _pt_radius > 0.0:
						var ccentroid := Vector2.ZERO
						var _pz_cov: String = pz.get("coverage", "")
						var _has_cen := false
						if _pz_cov == "point":
							ccentroid = Vector2(pz.get("lon", 0.0), pz.get("lat", 0.0))
							_has_cen = true
						else:
							var _pzverts: Array = pz.get("vertices", [])
							if _pzverts.size() >= 3:
								for _pvt in _pzverts:
									ccentroid += Vector2(_pvt[0], _pvt[1])
								ccentroid /= float(_pzverts.size())
								_has_cen = true
						if _has_cen:
							var clonlat := BiomeQuery._dir_to_lonlat(dir)
							var cm_per_deg := data.radius * PI / 180.0
							var cdist_m := (clonlat - ccentroid).length() * cm_per_deg
							if cdist_m < _pt_radius:
								if _pt_has_hole and cdist_m < _pt_hole_radius:
									var hole_dir := CaveTerrain.lonlat_to_dir(ccentroid)
									grid[yi * (res + 1) + xi] = hole_dir * (data.radius + height - _pt_depth)
									_is_hole_vertex = true
									break
								else:
									var tc: float
									if _pt_has_hole:
										tc = (cdist_m - _pt_hole_radius) / (_pt_radius - _pt_hole_radius)
									else:
										tc = cdist_m / _pt_radius
									height -= _pt_depth * (1.0 - tc * tc)
					break
			# ── Recipe crater displacement (collision) ─────────────
			if not _col_recipe_craters.is_empty():
				height += SpatialCraterTerrain.apply_craters(
					dir, _col_recipe_craters, data.radius)

			# ── Cliff displacement (collision) ─────────────────────
			if has_cliff_overlap:
				var _cl_zones := _query_zones_at_direction(dir, _col_pz_zones)
				for _clz in _cl_zones:
					var _clbd := data.get_biome_by_type(_clz.get("biome_type", ""))
					if _clbd and RockyLandformCliffTerrain.matches_zone(_clbd):
						var _cl_poly := _zone_outline(_clz)
						if _cl_poly.size() >= 3:
							var _cl_ll := BiomeQuery._dir_to_lonlat(dir)
							var _cl_mpd := data.radius * PI / 180.0
							var _cl_dist := BiomeQuery._dist_to_polygon_edge(_cl_ll, _cl_poly) * _cl_mpd
							var _cl_drop: float = _clz.get("depth", 0.0)
							if _cl_drop <= 0.0:
								_cl_drop = RockyLandformCliffTerrain.DROP_M
							height -= RockyLandformCliffTerrain.height_offset(_cl_dist, _cl_drop)
						break

			# ── Biome relief (collision) ───────────────────────────
			# The mesh takes the FIRST zone containing the vertex and its biome;
			# same rule here, same pure offset, same road flattening.
			if has_relief_overlap:
				var _rl_zones := _query_zones_at_direction(dir, _col_pz_zones)
				if not _rl_zones.is_empty():
					var _rl_bd := data.get_biome_by_type(_rl_zones[0].get("biome_type", ""))
					if _rl_bd and _rl_bd.has_relief():
						var _rl_w := BiomeRelief.road_weight(HEALPix.vec2lonlat(dir),
								_col_relief_roads, _col_relief_mpd, _col_crack_spacing)
						if _rl_w > 0.0:
							height += _rl_w * BiomeRelief.offset(dir, data.radius, _rl_bd, _col_crack_spacing)

			# ── Corundum crack network (collision) ─────────────────
			# Same pure crack_offset() and params as the visual mesh, with the
			# same LOD fade keyed on this grid's spacing — so where the collision
			# grid is fine enough it matches the client, and where it's too coarse
			# it fades to flat (and skips the Voronoi → server stays fast).
			# Same zone rule too: the mesh carves only where the FIRST zone
			# containing the vertex names no known biome (corundum by default).
			var _cor_here := data.corundum_default_biome
			if _cor_here and not _col_pz_zones.is_empty():
				var _cor_zones := _query_zones_at_direction(dir, _col_pz_zones)
				_cor_here = data.corundum_applies_to_zone(
						_cor_zones[0] if not _cor_zones.is_empty() else {})
			if _cor_here:
				height += ArideDesertCorundumPlateauTerrain.crack_offset(
					dir, data.radius, data.crack_spacing_m,
					data.crack_width_m, data.crack_depth_m, _col_crack_spacing)

			# ── Profiled-line cutting (collision) ──────────────────
			if not _col_rw_ctx.is_empty():
				var _rw_carved := GradeBed.apply(height, HEALPix.vec2lonlat(dir), _col_rw_ctx)
				if _rw_carved != height:
					height = _rw_carved
					_col_rw_band[yi * (res + 1) + xi] = 1
				_col_rw_h[yi * (res + 1) + xi] = height

			# ── Write final vertex position ────────────────────────
			if not _is_hole_vertex:
				grid[yi * (res + 1) + xi] = dir * (data.radius + height)

	# Build triangle face array (3 vertices per triangle, packed sequentially).
	# Rebase vertices onto a chunk-local origin BEFORE packing into the
	# float32 PackedVector3Array.  At absolute planet scale (~6,000,000 m)
	# float32 has ~0.5 m ULP, which quantises the collision triangles and
	# displaces them from the client visual mesh — the mesh is likewise built
	# relative to this same snapped origin.  grid[] holds double-precision
	# Vector3s, so the subtraction is exact and only the small local offset is
	# stored as float32.  The caller offsets the CollisionShape3D by col_origin
	# in double precision (see PlanetTerrain._chunk_collision_origin).
	var col_origin := snap_to_f32(HEALPix.pix2vec_nest(hp_nside, hp_ipix) * data.radius) \
			if hp_mode else Vector3.ZERO
	var faces := PackedVector3Array()
	faces.resize(res * res * 6)
	var fi := 0
	for yi in res:
		for xi in res:
			var i := yi * (res + 1) + xi
			faces[fi]     = grid[i]           - col_origin
			faces[fi + 1] = grid[i + res + 1] - col_origin
			faces[fi + 2] = grid[i + 1]       - col_origin
			faces[fi + 3] = grid[i + 1]       - col_origin
			faces[fi + 4] = grid[i + res + 1] - col_origin
			faces[fi + 5] = grid[i + res + 2] - col_origin
			fi += 6

	# ── Profiled lines: refinement patch, bed, tunnels (collision) ───
	# Wound with the grid's own sign, so the one-shot flip in
	# PlanetTerrain._make_chunk_collision_body (navmesh CW-front) treats bed
	# and ground alike. Stations on the collision grid's pitch, like the mesh.
	if not _col_rw.is_empty() or not _col_rw_ctx.is_empty() or not _col_rd.is_empty():
		var _rw_outward := true
		if faces.size() >= 3:
			var _rw_n := (faces[1] - faces[0]).cross(faces[2] - faces[0])
			_rw_outward = _rw_n.dot(HEALPix.pix2vec_nest(hp_nside, hp_ipix)) > 0.0
		var _rw_step_m := HEALPix.pixel_side_length(hp_nside, data.radius) \
				/ float(res) * 0.5
		var _rw_mpd := data.radius * PI / 180.0
		var _rw_sampler := func(d: Vector3) -> float:
			return data.sample_height_for_direction(d, _height_ipix, -1,
					Vector2i(-1, -1), null, _height_nside, _frame)
		# The same patch the mesh builder gets (same grid, same inputs): the
		# refined cells' coarse faces are dropped and the patch's appended.
		if not _col_rw_ctx.is_empty():
			var _rw_ref := GradeRefine.build(data, hp_nside, hp_ipix, res, grid_dirs,
					_col_rw_h, _col_rw_band, _col_rw_ctx, PackedByteArray(),
					_rw_sampler, _rw_outward)
			if not _rw_ref.is_empty():
				var _rq: PackedByteArray = _rw_ref["quads"]
				var _kept := PackedVector3Array()
				for _qi in res * res:
					if _rq[_qi] == 0:
						for _e in 6:
							_kept.append(faces[_qi * 6 + _e])
				faces = _kept
				var _rf_pos: Array = _rw_ref["pos"]
				var _rf_n := (res + 1) * (res + 1)
				for _ti in (_rw_ref["tris"] as PackedInt32Array):
					if _ti < _rf_n:
						faces.append(grid[_ti] - col_origin)
					else:
						faces.append((_rf_pos[_ti - _rf_n] as Vector3) - col_origin)
		for _rw_pair in _col_rw:
			var _rw_zone: Dictionary = _rw_pair[0]
			var _rw_cl: PackedVector2Array = _rw_zone.get("centerline", PackedVector2Array())
			var _rw_cum: PackedFloat64Array = _rw_zone.get("_cum_lengths", PackedFloat64Array())
			var _rw_bed := GradeBed.build_piece(_rw_cl, _rw_cum, _rw_pair[1],
				data.get_grade_exclusions_for_feature(int(_rw_zone.get("feature_id", -1))),
				_rw_mpd, data.radius, _rw_sampler, _rw_step_m, col_origin,
				false, _rw_outward)
			faces.append_array(_rw_bed["faces"])
			if not _col_rw_ctx.is_empty():
				var _rw_tun := GradeTunnel.build_piece(_rw_cl, _rw_cum, _rw_pair[1],
					data.radius, col_origin, false, _rw_outward)
				faces.append_array(_rw_tun["faces"])
		# Road slabs: the same strips, stations and sampler as the mesh's
		# RoadRibbon.emit_strip calls, minus the visual arrays.
		if not _col_rd.is_empty():
			var _rd_pitch := _ribbon_pitch_deg(_healpix_lonlat_bbox(hp_nside, hp_ipix), res)
			for _rd_zone in _col_rd:
				var _rd_cl: PackedVector2Array = _rd_zone.get("centerline", PackedVector2Array())
				var _rd_cum: PackedFloat64Array = _rd_zone.get("_cum_lengths", PackedFloat64Array())
				var _rd_hw_m: float = float(_rd_zone.get(
					"half_width_m", RoadTerrain.get_half_width_m(_rd_zone)))
				var _rd_pieces: Array = [[_rd_cl, _rd_cum]]
				if _rd_cum.size() == _rd_cl.size() and data.corundum_default_biome:
					var _rd_excl: Array = data.get_bridge_exclusions_for_feature(
						int(_rd_zone.get("feature_id", -1)))
					if not _rd_excl.is_empty():
						_rd_pieces = RoadCut.split(_rd_cl, _rd_cum, _rd_excl)
				var _rd_layout := RoadTerrain.lane_layout(
						RoadTerrain.get_road_type(_rd_zone),
						RoadTerrain.lanes_of(_rd_zone), _rd_hw_m)
				for _rd_piece in _rd_pieces:
					for _rd_strip in _rd_layout["strips"]:
						faces.append_array(RoadRibbon.emit_strip(
								_rd_piece[0], _rd_piece[1], _rd_strip, _rw_mpd,
								data.radius, _rd_pitch, _rw_sampler, col_origin,
								false, _rw_outward)["faces"])

	var shape := ConcavePolygonShape3D.new()
	# Zéro = tous les sommets ont lu leur propre tuile ; la forme est persistable.
	shape.set_meta("provisional_climbs", data.climb_count())
	# Collide from BOTH sides. Unlike the visual mesh, the collision faces get
	# no winding correction, so their one-sided front can end up facing inward
	# (toward the planet centre) — leaving bodies to fall straight through the
	# surface from above. Double-sided collision makes the terrain solid
	# regardless of triangle winding.
	shape.backface_collision = true
	shape.set_faces(faces)
	return shape


## Generate a visual [ArrayMesh] for one HEALPix terrain chunk.
## Delegates to [method generate_mesh] with HEALPix mode enabled.
static func generate_mesh_healpix(
		data: PlanetData,
		nside: int,
		ipix: int,
		resolution: int,
		chunk_center: Vector3 = Vector3.ZERO,
		prof: Dictionary = {},
		stitch: int = 0) -> ArrayMesh:
	return generate_mesh(data, 0, 0.0, 0.0, 0.0, 0.0, resolution,
			chunk_center, nside, ipix, prof, stitch)


# ------------------------------------------------------------------
# LOD-seam stitch
# ------------------------------------------------------------------

## True when a chunk at [param hp_nside] must honour a stitch mask.
##
## Two adjacent chunks one quadtree level apart only share their border when
## the finer one's odd border vertices sit on the coarser one's chords. Both
## read the same tile whenever the PARENT is finer than export_nside, and
## that tile's bilinear knots (texel centres) then fall ON parent grid points,
## never strictly between two of them — so the finer chunk's own samples
## already lie on the chords, bit-exact, and no stitch is needed. From the
## parent == export_nside level down, either the knots sit at the parent's
## cell midpoints (the seam is off by the local slope change × half a cell)
## or the parent reads a coarser pyramid tile altogether (a whole other
## relief, tens of metres on a dune crest): those levels stitch.
static func edge_stitch_applies(data: PlanetData, hp_nside: int) -> bool:
	return hp_nside >= 2 and hp_nside <= 2 * data.export_nside


## Fill [param edge_out] (vertex index → base height) for every edge of the
## [param stitch] mask, and [param blend_out] (vertex index → Vector2(weight,
## parent-level height)) for the rows behind them.
##
## Stitched edge: even vertices along the edge ARE parent grid points — they
## take the parent level's own sample (sample_height_boundary at the parent's
## pyramid level, the very call the coarser neighbour makes for that point);
## odd vertices take the CHORD midpoint of their two even neighbours, i.e.
## exactly where the coarser mesh draws its straight edge. Corners are even
## on both of their edges, so a corner is parent-sampled whenever either
## edge is stitched — and its mate across the unstitched edge, which faces
## the same coarse neighbour diagonally, resolves it the same way.
##
## Blend rows exist only when the parent reads a different pyramid tile than
## the chunk: they ramp the interior from the parent's relief (row 0) to the
## chunk's own over STITCH_BLEND_ROWS cells. Same tile → the interior already
## agrees with the edge and the ramp is skipped.
static func _stitch_edge_heights(data: PlanetData, hp_nside: int, hp_ipix: int,
		res: int, grid_dirs: Array[PackedVector3Array], stitch: int,
		frame: PlanetData.TileFrame, edge_out: Dictionary, blend_out: Dictionary) -> void:
	if res < 2 or res % 2 != 0:
		return
	@warning_ignore("integer_division")
	var p_nside: int = hp_nside / 2
	var p_sample := data.sample_nside_for(p_nside)
	# Chain ipix at the parent's sample level — same resolution rule as the
	# chunk's own _export_ipix in generate_mesh, one level up.
	var p_chain: int = -1
	if p_nside >= data.export_nside:
		p_chain = hp_ipix >> 2
		var _ns := p_nside
		while _ns > data.export_nside:
			p_chain >>= 2
			_ns /= 2
	elif p_nside == p_sample:
		p_chain = hp_ipix >> 2
	var stride := res + 1
	var r := data.radius

	# Vertex indices of each stitched edge, in order along the edge.
	var edges: Array[PackedInt32Array] = []
	var edge_bit_list: Array[int] = []
	if stitch & STITCH_LEFT:
		var e := PackedInt32Array()
		for yi in stride:
			e.append(yi * stride)
		edges.append(e)
		edge_bit_list.append(STITCH_LEFT)
	if stitch & STITCH_RIGHT:
		var e := PackedInt32Array()
		for yi in stride:
			e.append(yi * stride + res)
		edges.append(e)
		edge_bit_list.append(STITCH_RIGHT)
	if stitch & STITCH_BOTTOM:
		var e := PackedInt32Array()
		for xi in stride:
			e.append(xi)
		edges.append(e)
		edge_bit_list.append(STITCH_BOTTOM)
	if stitch & STITCH_TOP:
		var e := PackedInt32Array()
		for xi in stride:
			e.append(res * stride + xi)
		edges.append(e)
		edge_bit_list.append(STITCH_TOP)

	var own_sample := data.sample_nside_for(hp_nside)
	var same_level := p_sample == own_sample
	var cell_m: float = (grid_dirs[0][0] as Vector3).angle_to(grid_dirs[0][1]) * r
	# Rows the bend is spread over: the blend band when the parent reads
	# another tile level, the single border cell when it reads the same one.
	var bend_rows: int = 1 if same_level or STITCH_BLEND_ROWS < 2 else STITCH_BLEND_ROWS
	var max_step: float = STITCH_MAX_SLOPE * float(bend_rows) * cell_m
	var kept := 0  # edges actually stitched, as STITCH_* bits
	var ei := 0
	for e in edges:
		var bit: int = edge_bit_list[ei]
		ei += 1
		var hs := PackedFloat64Array()
		hs.resize(stride)
		for k in range(0, stride, 2):
			var idx := e[k]
			if edge_out.has(idx):  # corner already resolved by the other edge
				hs[k] = edge_out[idx]
				continue
			@warning_ignore("integer_division")
			var d: Vector3 = grid_dirs[idx / stride][idx % stride]
			hs[k] = data.sample_height_boundary(d, p_chain, -1, Vector2i(-1, -1),
					null, p_sample, frame)
		for k in range(1, stride, 2):
			var ia := e[k - 1]
			var ib := e[k + 1]
			@warning_ignore("integer_division")
			var pa: Vector3 = grid_dirs[ia / stride][ia % stride] * (r + hs[k - 1])
			@warning_ignore("integer_division")
			var pb: Vector3 = grid_dirs[ib / stride][ib % stride] * (r + hs[k + 1])
			hs[k] = ((pa + pb) * 0.5).length() - r
		# How far the parent's border is from the chunk's own surface there.
		var worst := 0.0
		for k in stride:
			var idx := e[k]
			@warning_ignore("integer_division")
			var d: Vector3 = grid_dirs[idx / stride][idx % stride]
			var own := data.sample_height_boundary(d, -1, -1, Vector2i(-1, -1),
					null, own_sample, frame)
			worst = maxf(worst, absf(hs[k] - own))
		if worst > max_step:
			continue  # cliff under the seam: skirt, not stitch
		for k in stride:
			edge_out[e[k]] = hs[k]
		kept |= bit

	if same_level or STITCH_BLEND_ROWS < 2 or kept == 0:
		return
	# Ramp rows 1 .. STITCH_BLEND_ROWS-1 behind each stitched edge. A vertex in
	# the band of two stitched edges keeps the stronger (nearer-edge) weight.
	for yi in range(1, res):
		for xi in range(1, res):
			var d_min := STITCH_BLEND_ROWS
			if kept & STITCH_LEFT:
				d_min = mini(d_min, xi)
			if kept & STITCH_RIGHT:
				d_min = mini(d_min, res - xi)
			if kept & STITCH_BOTTOM:
				d_min = mini(d_min, yi)
			if kept & STITCH_TOP:
				d_min = mini(d_min, res - yi)
			if d_min >= STITCH_BLEND_ROWS:
				continue
			var w := float(STITCH_BLEND_ROWS - d_min) / float(STITCH_BLEND_ROWS)
			var hp := data.sample_height_for_direction(grid_dirs[yi][xi], p_chain,
					-1, Vector2i(-1, -1), null, p_sample, frame)
			blend_out[yi * stride + xi] = Vector2(w, hp)


## Generate a [ConcavePolygonShape3D] for one HEALPix terrain chunk.
## Delegates to [method generate_collision_shape] with HEALPix mode enabled.
static func generate_collision_shape_healpix(
		data: PlanetData,
		nside: int,
		ipix: int,
		resolution: int) -> ConcavePolygonShape3D:
	return generate_collision_shape(data, 0, 0.0, 0.0, 0.0, 0.0, resolution,
			nside, ipix)


# ------------------------------------------------------------------
# Internal
# ------------------------------------------------------------------

## Convert a world position to chunk-local space.
## Subtracts cc_f32 in float64 to preserve height precision, then snaps
## the small local offset to float32 for the GPU vertex buffer.
## At ±500 m local range the float32 ULP is ~60 µm — far below any
## visible seam threshold (skirt geometry covers the rest).
static func _world_to_local(world_pos: Vector3, cc_f32: Vector3,
		buf: PackedFloat32Array) -> Vector3:
	var local := world_pos - cc_f32
	buf[0] = local.x; buf[1] = local.y; buf[2] = local.z
	return Vector3(buf[0], buf[1], buf[2])


## Lon/lat bounding box (degrees) of a HEALPix chunk: its corners, edge
## midpoints and centre. Shared by the mesh and the collision builders so
## the road slab's stations fall on the same pitch on both sides.
static func _healpix_lonlat_bbox(hp_nside: int, hp_ipix: int) -> Array[Vector2]:
	var corners: Array = HEALPix.get_pixel_corners(hp_nside, hp_ipix)
	var cdir := HEALPix.pix2vec_nest(hp_nside, hp_ipix)
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	var dirs: Array[Vector3] = []
	for ci in corners.size():
		dirs.append(corners[ci])
		dirs.append((corners[ci] + corners[(ci + 1) % corners.size()]).normalized())
	dirs.append(cdir)
	for d in dirs:
		var ll := HEALPix.vec2lonlat(d)
		mn.x = minf(mn.x, ll.x)
		mn.y = minf(mn.y, ll.y)
		mx.x = maxf(mx.x, ll.x)
		mx.y = maxf(mx.y, ll.y)
	return [mn, mx]


## Station pitch of the road slab, in degrees along the centerline: half the
## chunk's vertex pitch. Chunk degree span (not cube-face UV span) so the
## subdivision matches the centerline's coordinate system.
static func _ribbon_pitch_deg(cbb: Array[Vector2], res: int) -> float:
	return maxf(cbb[1].x - cbb[0].x, cbb[1].y - cbb[0].y) / float(maxi(res, 1)) * 0.5


# ------------------------------------------------------------------
# Road surface groups (generate_mesh)
# ------------------------------------------------------------------

## The road_groups entry for [param mat_path], created on first use: one
## surface per material, with the UV mode and vertex-tint rule of that
## material. Every group carries `colors` (padded WHITE by
## [method _road_group_append]) so the emitter can index them blindly.
static func _road_group(groups: Dictionary, mat_path: String, tile_m: float,
		uv_mode: int, tinted: bool) -> Dictionary:
	if not groups.has(mat_path):
		groups[mat_path] = {
			"verts": PackedVector3Array(),
			"norms": PackedVector3Array(),
			"uvs": PackedVector2Array(),
			"colors": PackedColorArray(),
			"indices": PackedInt32Array(),
			"tile_m": tile_m,
			"uv_mode": uv_mode,
			"tinted": tinted,
		}
	return groups[mat_path]


## Append a builder's {verts, norms, uvs, indices[, colors]} to a group,
## rebasing the indices. PackedArrays are copy-on-write, so the arrays are
## written back to the dictionary explicitly.
static func _road_group_append(grp: Dictionary, part: Dictionary) -> void:
	var pv: PackedVector3Array = part["verts"]
	if pv.is_empty():
		return
	var verts: PackedVector3Array = grp["verts"]
	var norms: PackedVector3Array = grp["norms"]
	var uvs: PackedVector2Array = grp["uvs"]
	var colors: PackedColorArray = grp["colors"]
	var indices: PackedInt32Array = grp["indices"]
	var base := verts.size()
	verts.append_array(pv)
	norms.append_array(part["norms"])
	uvs.append_array(part["uvs"])
	var pc: PackedColorArray = part.get("colors", PackedColorArray())
	if pc.size() == pv.size():
		colors.append_array(pc)
	else:
		for _i in pv.size():
			colors.append(Color.WHITE)
	for _i in (part["indices"] as PackedInt32Array):
		indices.append(base + _i)
	grp["verts"] = verts
	grp["norms"] = norms
	grp["uvs"] = uvs
	grp["colors"] = colors
	grp["indices"] = indices


## Append a slab builder's part — {…, indices, side_indices} — to its top
## group [param grp], and its sides to the group of
## RoadTerrain.side_material_path(): the engraved corundum's flanks and
## skirts go to the plain melted corundum, any other material keeps its
## sides with its top (one append, indices merged).
static func _road_group_append_slab(groups: Dictionary, grp: Dictionary,
		surf: Dictionary, tile_m: float, part: Dictionary) -> void:
	var side_idx: PackedInt32Array = part.get("side_indices", PackedInt32Array())
	var mat_path: String = surf["mat_path"]
	var side_mat := RoadTerrain.side_material_path(mat_path)
	if side_mat == mat_path or side_idx.is_empty():
		if not side_idx.is_empty():
			var merged := part.duplicate()
			var idx: PackedInt32Array = (part["indices"] as PackedInt32Array).duplicate()
			idx.append_array(side_idx)
			merged["indices"] = idx
			_road_group_append(grp, merged)
		else:
			_road_group_append(grp, part)
		return
	_road_group_append(grp, part)
	var sides := part.duplicate()
	sides["indices"] = side_idx
	_road_group_append(_road_group(groups, side_mat, tile_m,
			RoadRibbon.UvMode.FLOW, surf["tinted"]), sides)


## Which surface a road piece gets: {mat_path, uv_mode, tint, tinted}.
##
## The MATERIAL is decided once per piece, from the first populate zone at
## its midpoint; the TINT is resolved per vertex from [param pz_zones], the
## chunk's populate zones — a coarse chunk's piece can run for kilometres
## and cross a rock outcrop that its midpoint is nowhere near. See
## [method road_surface_for_zone].
static func _road_surface_for(data: PlanetData, cl: PackedVector2Array,
		road_type: String, pz_zones: Array,
		corundum_bd: BiomeDefinition) -> Dictionary:
	var mid_ll := (cl[0] + cl[cl.size() - 1]) * 0.5
	var mid_dir := RoadBridge.lonlat_to_dir(mid_ll.x, mid_ll.y)
	var first_mid: Dictionary = {}
	if not pz_zones.is_empty():
		var mid_zones := _query_zones_at_direction(mid_dir, pz_zones)
		if not mid_zones.is_empty():
			first_mid = mid_zones[0]
	return road_surface_for_zone(data, road_type, first_mid, corundum_bd, pz_zones)


## The surface of a road piece whose ground is [param first_zone] (the first
## populate zone containing its midpoint, {} when none does): {mat_path,
## uv_mode, tint, tinted}.
##
## A highway on corundum ground — the planet's DEFAULT biome (typically NO
## zone contains the point), a corundum biome, or an outcrop zone whose rock
## is a corundum variety (RoadTerrain.is_corundum_ground) — gets the melted
## corundum surface: lane UVs and the GROUND'S OWN colour baked into the
## vertex colour ([method road_ground_tint]), so the road matches the ground
## around it. With [param pz_zones] the tint looks the zone up per vertex;
## without, every vertex takes [param first_zone]'s. Shared with
## BridgeSpawner (a deck is the same road).
static func road_surface_for_zone(data: PlanetData, road_type: String,
		first_zone: Dictionary, corundum_bd: BiomeDefinition = null,
		pz_zones: Array = []) -> Dictionary:
	var biome_type := ""
	var zone_bd: BiomeDefinition = null
	if not first_zone.is_empty():
		zone_bd = data.get_biome_by_type(String(first_zone.get("biome_type", "")))
		if zone_bd:
			biome_type = zone_bd.biome_type
	var rock_type := str(first_zone.get("rock_type", ""))
	var on_cor := road_type == "highway" and RoadTerrain.is_corundum_ground(
			biome_type, rock_type, data.corundum_applies_to_zone(first_zone))
	var mat_path := RoadTerrain.get_material_path(road_type, biome_type, on_cor)
	var out := {
		"mat_path": mat_path,
		"uv_mode": RoadRibbon.UvMode.FLOW,
		"tint": Callable(),
		"tinted": false,
	}
	if not RoadTerrain.is_corundum_surface(mat_path):
		return out
	var cor_bd: BiomeDefinition = corundum_bd if corundum_bd \
			else data.get_biome_by_type(RoadTerrain.CORUNDUM_BIOME_TYPE)
	out["uv_mode"] = RoadRibbon.UvMode.LANE
	out["tinted"] = true
	if pz_zones.is_empty():
		out["tint"] = func(d: Vector3) -> Color:
			return road_ground_tint(data, d, first_zone, cor_bd)
	else:
		out["tint"] = func(d: Vector3) -> Color:
			var here := _query_zones_at_direction(d, pz_zones)
			return road_ground_tint(data, d,
					here[0] if not here.is_empty() else {}, cor_bd)
	return out


## The ground's colour at [param d] under [param zone] (its first populate
## zone, {} for none) — the three cases of the terrain's biome colour pass,
## in its order: the corundum iron tint where corundum is the default, the
## zone's RockCatalogue tint where it names a rock, the biome colour else.
static func road_ground_tint(data: PlanetData, d: Vector3, zone: Dictionary,
		cor_bd: BiomeDefinition) -> Color:
	var zone_bd: BiomeDefinition = null
	if not zone.is_empty():
		zone_bd = data.get_biome_by_type(String(zone.get("biome_type", "")))
	var base: Color = zone_bd.color if zone_bd else (
			cor_bd.color if cor_bd else Color(0.823, 0.784, 0.69))
	if data.corundum_applies_to_zone(zone):
		return ArideDesertCorundumPlateauTerrain.iron_tint(d, data.radius, base)
	var rock_type := str(zone.get("rock_type", ""))
	if not rock_type.is_empty() and RockCatalogue.has(rock_type):
		return RockCatalogue.tint(d, data.radius, rock_type, base)
	return base


## Snap a Vector3 to float32 precision.
## Use this to ensure mi.position matches the cc_f32 used internally
## by generate_mesh, eliminating the float64↔float32 chunk-center
## mismatch that causes sub-metre vertex seams between adjacent chunks.
static func snap_to_f32(v: Vector3) -> Vector3:
	var buf := PackedFloat32Array([v.x, v.y, v.z])
	return Vector3(buf[0], buf[1], buf[2])


# ------------------------------------------------------------------
# Recipe-based biome helpers (replaces BiomeQuery for biome data)
# ------------------------------------------------------------------

## Resolve the export-level ipix for a given chunk nside/ipix.
## Returns -1 when the chunk is COARSER than the export level (a single
## chunk then spans many export tiles, so there is no canonical export
## ipix and callers should fall back to per-vertex vec2pix_nest).
static func _resolve_export_ipix(hp_nside: int, hp_ipix: int,
		export_nside: int) -> int:
	if hp_nside < export_nside:
		return -1
	var cur_nside := hp_nside
	var ipix := hp_ipix
	while cur_nside > export_nside:
		ipix = HEALPix.parent_pixel(ipix)
		cur_nside /= 2
	return ipix


## Get per-chunk modifier data: [populate_zones, linear_features,
## radial_features, craters, roads].  Falls back to empty arrays gracefully.
##
## The first four are read at export_nside via the ancestor ipix, exactly as
## before. Roads are read at THIS chunk's own level, so the record it gets is
## already clipped to this chunk — which is what stops a neighbouring chunk at a
## coarser LOD from extruding the same stretch of road at a different altitude.
static func _get_recipe_biome_data(data: PlanetData,
		hp_nside: int, hp_ipix: int) -> Array:
	if hp_nside <= 0:
		return [[], [], [], [], []]
	var eip := _resolve_export_ipix(hp_nside, hp_ipix, data.export_nside)
	var roads: Array = data.get_roads_for_chunk(hp_nside, hp_ipix)
	return [
		data.get_chunk_populate_zones(eip),
		data.get_chunk_linear_features(eip),
		data.get_chunk_radial_features(eip),
		data.get_chunk_craters(eip),
		roads,
	]


## Ray-casting point-in-polygon test (lon/lat space).
## [param vertices] is an Array of 2-element arrays [[lon,lat], ...].
static func _point_in_polygon_lonlat(lon: float, lat: float,
		vertices: Array) -> bool:
	var n := vertices.size()
	if n < 3:
		return false
	var inside := false
	var j := n - 1
	for i in n:
		var vi = vertices[i]
		var vj = vertices[j]
		var viy: float = vi[1]
		var vjy: float = vj[1]
		if ((viy > lat) != (vjy > lat)) and \
				(lon < (float(vj[0]) - float(vi[0])) * (lat - viy) / (vjy - viy) + float(vi[0])):
			inside = not inside
		j = i
	return inside


## Check if a direction vector lies inside a populate zone.
## Returns true for "full" coverage, false for "point" coverage (no polygon),
## runs point-in-polygon for "partial" coverage.
static func _dir_in_populate_zone(dir: Vector3, zone: Dictionary) -> bool:
	var coverage: String = zone.get("coverage", "")
	if coverage == "full":
		return true
	if coverage == "point":
		return false
	var vertices: Array = zone.get("vertices", [])
	if vertices.size() < 3:
		return false
	var lonlat := BiomeQuery._dir_to_lonlat(dir)
	return _point_in_polygon_lonlat(lonlat.x, lonlat.y, vertices)


## Outline of a populate zone as a PackedVector2Array of lon/lat points.
##
## Producers disagree on the key: recipe exports write `vertices` (an Array of
## [lon, lat] pairs, see tools/planettech/qgis/export/planet/recipe.py), while
## PlanetData.inject_biome_feature() writes `polygon` (a PackedVector2Array).
## Reading only one of them silently yields an empty outline for zones from the
## other producer — that is how the client mesh lost its cliff drop while the
## server collision kept it, diverging by up to DROP_M (50 m).
## Returns an empty array when the zone has no usable outline (< 3 points).
static func _zone_outline(zone: Dictionary) -> PackedVector2Array:
	var verts: Array = zone.get("vertices", [])
	if verts.size() >= 3:
		var poly := PackedVector2Array()
		poly.resize(verts.size())
		for i in verts.size():
			var v = verts[i]
			poly[i] = Vector2(float(v[0]), float(v[1]))
		return poly
	var packed: PackedVector2Array = zone.get("polygon", PackedVector2Array())
	if packed.size() >= 3:
		return packed
	return PackedVector2Array()


## Find all populate zones containing the given direction.
## Returns an array of zone Dictionaries (may be empty).
static func _query_zones_at_direction(dir: Vector3,
		populate_zones: Array) -> Array:
	var result: Array = []
	for z in populate_zones:
		if _dir_in_populate_zone(dir, z):
			result.append(z)
	return result


## Check if any populate zone has the given biome_type.
static func _zones_have_biome_type(zones: Array, btype: String) -> bool:
	for z in zones:
		if z.get("biome_type", "") == btype:
			return true
	return false


## Check if any populate zone has a biome matching the predicate (is_liquid, etc).
## Uses PlanetData.get_biome_by_type() for the lookup.
static func _zones_have_biome_property(data: PlanetData,
		zones: Array, prop: String) -> bool:
	for z in zones:
		var bd = data.get_biome_by_type(z.get("biome_type", ""))
		if bd and bd.get(prop):
			return true
	return false


## Check if any linear feature has the given biome type.
static func _linear_has_type(linear_features: Array, btype: String) -> bool:
	for lf in linear_features:
		if lf.get("type", "") == btype:
			return true
	return false


## Check if any radial feature has the given biome type.
static func _radial_has_type(radial_features: Array, btype: String) -> bool:
	for rf in radial_features:
		if rf.get("type", "") == btype:
			return true
	return false


## Compute per-vertex tangents from positions, normals, UVs and triangle indices.
## Returns a PackedFloat32Array suitable for Mesh.ARRAY_TANGENT
## (4 floats per vertex: tangent.xyz + bitangent sign).
## Uses the standard per-triangle accumulation method, then ortho-normalizes
## the tangent against the vertex normal (Gram-Schmidt) and computes the
## handedness sign so normal maps render correctly.
static func _compute_tangents(verts: PackedVector3Array,
		norms: PackedVector3Array,
		uv_arr: PackedVector2Array,
		idx: PackedInt32Array) -> PackedFloat32Array:
	var vcount := verts.size()
	var t_accum := PackedVector3Array()
	var b_accum := PackedVector3Array()
	t_accum.resize(vcount)
	b_accum.resize(vcount)
	var zero := Vector3.ZERO
	for vi in vcount:
		t_accum[vi] = zero
		b_accum[vi] = zero

	var tri_count := idx.size() / 3
	for ti in tri_count:
		var i0 := idx[ti * 3 + 0]
		var i1 := idx[ti * 3 + 1]
		var i2 := idx[ti * 3 + 2]
		var v0 := verts[i0]
		var v1 := verts[i1]
		var v2 := verts[i2]
		var w0 := uv_arr[i0]
		var w1 := uv_arr[i1]
		var w2 := uv_arr[i2]
		var e1 := v1 - v0
		var e2 := v2 - v0
		var x1 := w1.x - w0.x
		var y1 := w1.y - w0.y
		var x2 := w2.x - w0.x
		var y2 := w2.y - w0.y
		var det := x1 * y2 - x2 * y1
		if absf(det) < 1e-12:
			continue
		var r := 1.0 / det
		var t := (e1 * y2 - e2 * y1) * r
		var b := (e2 * x1 - e1 * x2) * r
		t_accum[i0] += t
		t_accum[i1] += t
		t_accum[i2] += t
		b_accum[i0] += b
		b_accum[i1] += b
		b_accum[i2] += b

	var out := PackedFloat32Array()
	out.resize(vcount * 4)
	for vi in vcount:
		var n := norms[vi]
		var t := t_accum[vi]
		# Gram-Schmidt ortho-normalize against the normal.
		t = t - n * n.dot(t)
		if t.length_squared() < 1e-12:
			# Degenerate (no UV variation hit this vertex). Pick an
			# arbitrary tangent perpendicular to the normal.
			var ax := Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.UP
			t = ax - n * n.dot(ax)
		t = t.normalized()
		var sign_w := 1.0
		if n.cross(t).dot(b_accum[vi]) < 0.0:
			sign_w = -1.0
		out[vi * 4 + 0] = t.x
		out[vi * 4 + 1] = t.y
		out[vi * 4 + 2] = t.z
		out[vi * 4 + 3] = sign_w
	return out

