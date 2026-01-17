class_name ChunkRecipeGenerator
## Generates a heightmap Image from a chunk recipe JSON at runtime.
##
## Deterministic: same recipe + same resolution → identical Image on
## server and client, guaranteeing consistent collision.
##
## The generated Image uses FORMAT_RF (32-bit float red channel) so that
## the existing bilinear sampling in PlanetData works unchanged.

const DEFAULT_RESOLUTION := 512

## Minimum number of pixels across a crater's diameter for it to be
## meaningfully resolved in the heightmap.  Craters below this threshold
## are returned as "sub-pixel" for per-vertex displacement instead.
const MIN_CRATER_PIXELS := 4


## Generate a heightmap Image from a recipe dictionary.
## [param recipe] The parsed recipe JSON (Dictionary).
## [param resolution] Pixels per edge for the output Image.
## [param planet_radius] Planet radius in metres (for degree→metre conversion).
## [param elev_min] Minimum elevation in metres (for normalization).
## [param elev_range] Elevation range in metres (elev_max - elev_min).
## Returns [Image, Array_of_subpixel_craters].  Large craters are baked
## into the Image; small (sub-pixel) ones are returned for per-vertex
## displacement in PlanetChunk.
static func generate_heightmap(
		recipe: Dictionary,
		resolution: int,
		planet_radius: float,
		elev_min: float,
		elev_range: float) -> Array:

	var img := Image.create(resolution, resolution, false, Image.FORMAT_RF)
	var m_per_deg := planet_radius * PI / 180.0

	# ── HEALPix pixel coordinates ──
	# Recipes carry nside + ipix; we derive pixel face & (ix, iy) from those
	# so every direction computation matches the actual chunk location.
	var hp_nside: int = recipe.get("nside", 64)
	var hp_ipix: int = recipe.get("ipix", 0)
	var hp_npface := hp_nside * hp_nside
	var hp_face := hp_ipix / hp_npface
	var hp_local := hp_ipix % hp_npface
	var hp_xy := HEALPix.nest2xy(hp_local)
	var hp_ix: int = hp_xy.x
	var hp_iy: int = hp_xy.y
	var sub_nside := hp_nside * resolution

	# ── Parse recipe sections ──
	var elev_cfg: Dictionary = recipe.get("elevation", {})
	var contour_verts: Array = elev_cfg.get("contour_vertices", [])
	var base_elev: float = elev_cfg.get("base_elevation", 0.0)
	var idw_power: int = elev_cfg.get("idw_power", 2)
	var idw_k: int = elev_cfg.get("idw_k", 8)

	# ── Parse regular grid elevation data ──
	# Version >= 5: pixel-space grid (grid_inner_n).
	# Version  4:   lon/lat-space grid (grid_cols, grid_rows, grid_lon/lat_*).
	var grid_elev_data: Array = elev_cfg.get("grid_elevations", [])
	var grid_inner_n: int = elev_cfg.get("grid_inner_n", 0)
	var grid_total: int = grid_inner_n + 2  # inner + 1-cell margin each side
	var has_grid := grid_inner_n >= 2 \
		and grid_elev_data.size() == grid_total
	# v4 backward compat: lon/lat-space grid
	var grid_v4_cols: int = elev_cfg.get("grid_cols", 0)
	var grid_v4_rows: int = elev_cfg.get("grid_rows", 0)
	var grid_v4_lon_min: float = elev_cfg.get("grid_lon_min", 0.0)
	var grid_v4_lon_max: float = elev_cfg.get("grid_lon_max", 0.0)
	var grid_v4_lat_min: float = elev_cfg.get("grid_lat_min", 0.0)
	var grid_v4_lat_max: float = elev_cfg.get("grid_lat_max", 0.0)
	var has_grid_v4 := not has_grid \
		and grid_v4_cols >= 2 and grid_v4_rows >= 2 \
		and grid_elev_data.size() == grid_v4_rows

	# Pre-pack grid into a flat array for fast bilinear lookups
	var grid_flat := PackedFloat64Array()
	if has_grid:
		grid_flat.resize(grid_total * grid_total)
		for gy in grid_total:
			var row_data: Array = grid_elev_data[gy]
			for gx in grid_total:
				grid_flat[gy * grid_total + gx] = row_data[gx]
	elif has_grid_v4:
		grid_flat.resize(grid_v4_rows * grid_v4_cols)
		for gy in grid_v4_rows:
			var row_data: Array = grid_elev_data[gy]
			for gx in grid_v4_cols:
				grid_flat[gy * grid_v4_cols + gx] = row_data[gx]

	var _recipe_version: int = recipe.get("version", 0)
	if not has_grid and not has_grid_v4:
		push_warning("ChunkRecipeGenerator: recipe v%d key=%s — NO grid data, using IDW fallback (will cause terracing)" % [
			_recipe_version, recipe.get("key", "?")])
	elif has_grid_v4:
		# Only print once (first recipe loaded)
		if Engine.get_process_frames() < 10:
			print("[ChunkRecipeGenerator] Using v4 lon/lat grid (re-export for v5 pixel-space grid)")

	var _raw_craters: Array = recipe.get("craters", [])
	# Deduplicate craters — some export pipelines emit each crater twice.
	var craters_arr: Array = []
	var _seen_craters := {}
	for _cr in _raw_craters:
		var _ck := "%.6f_%.6f_%.1f" % [float(_cr["lon"]), float(_cr["lat"]), float(_cr["radius_m"])]
		if not _seen_craters.has(_ck):
			_seen_craters[_ck] = true
			craters_arr.append(_cr)
	var linear_arr: Array = recipe.get("linear_features", [])
	var radial_arr: Array = recipe.get("radial_features", [])
	var noise_cfg: Dictionary = recipe.get("noise", {})

	# ── Split craters: large → bake into heightmap, small → per-vertex ──
	# Approximate ground size of this chunk to compute metres/pixel.
	var center_dir := HEALPix.pix2vec_nest(hp_nside, hp_ipix)
	var corner_dir := HEALPix._face_xy_to_vec(
		hp_face, float(hp_ix), float(hp_iy), hp_nside)
	var chunk_ground_m := center_dir.angle_to(corner_dir) * 2.0 * planet_radius
	var m_per_pixel := chunk_ground_m / float(resolution)
	var min_baked_radius := m_per_pixel * MIN_CRATER_PIXELS * 0.5

	var baked_craters: Array = []
	var subpixel_craters: Array = []
	for cr in craters_arr:
		if float(cr["radius_m"]) >= min_baked_radius:
			baked_craters.append(cr)
		else:
			subpixel_craters.append(cr)

	# ── Pre-compute baked crater data for angular-distance evaluation ──
	var _baked_cr_data := SpatialCraterTerrain.prepare_baked_craters(
		baked_craters, planet_radius)

	# ── Pre-build contour data as PackedFloat64Arrays for speed ──
	var n_contours := contour_verts.size()
	var c_lon := PackedFloat64Array()
	var c_lat := PackedFloat64Array()
	var c_elev := PackedFloat64Array()
	c_lon.resize(n_contours)
	c_lat.resize(n_contours)
	c_elev.resize(n_contours)
	for i in n_contours:
		var v: Array = contour_verts[i]
		c_lon[i] = v[0]
		c_lat[i] = v[1]
		c_elev[i] = v[2]

	# ── Build spatial grid for fast IDW lookups ──
	var contour_grid := {}
	var grid_nx := 1
	var grid_ny := 1
	var grid_lon_min := 0.0
	var grid_lat_min := 0.0
	var grid_cell_w := 1.0
	var grid_cell_h := 1.0
	if n_contours >= 3:
		var gd := _build_contour_grid(c_lon, c_lat, n_contours)
		contour_grid = gd[0]
		grid_nx = gd[1]
		grid_ny = gd[2]
		grid_lon_min = gd[3]
		grid_lat_min = gd[4]
		grid_cell_w = gd[5]
		grid_cell_h = gd[6]

	# ── Pre-build noise generator ──
	var noise: FastNoiseLite = null
	var noise_octaves: Array = noise_cfg.get("octaves", [])
	if not noise_octaves.is_empty():
		noise = FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
		noise.seed = noise_cfg.get("seed", 0)

	# ── Safe normalization range ──
	if elev_range <= 0.0:
		elev_range = 1.0

	# ── Main pixel loop ──
	for py in resolution:
		for px in resolution:
			# Map image pixel to HEALPix sub-pixel direction
			var sub_ix := hp_ix * resolution + px
			var sub_iy := hp_iy * resolution + py
			var dir := HEALPix._face_xy_to_vec(
				hp_face, float(sub_ix) + 0.5, float(sub_iy) + 0.5, sub_nside)
			var lonlat := _dir_to_lonlat(dir)

			# ── Step 1: Base elevation from grid bilinear ──
			var height: float
			if has_grid:
				# v5+: pixel-space grid (uniform in HEALPix pixel coords)
				var gx := float(px) * float(grid_inner_n) / float(resolution) + 0.5
				var gy := float(py) * float(grid_inner_n) / float(resolution) + 0.5
				height = _grid_bilinear_px(gx, gy, grid_flat, grid_total)
			elif has_grid_v4:
				# v4: lon/lat-space grid (backward compat)
				height = _grid_bilinear(
						lonlat.x, lonlat.y, grid_flat,
						grid_v4_cols, grid_v4_rows,
						grid_v4_lon_min, grid_v4_lon_max,
						grid_v4_lat_min, grid_v4_lat_max)
			elif n_contours >= 3:
				var cands := _grid_candidates(
						lonlat.x, lonlat.y, contour_grid,
						grid_nx, grid_ny, grid_lon_min, grid_lat_min,
						grid_cell_w, grid_cell_h, idw_k * 3)
				if cands.size() > 0:
					height = _idw_interpolate(lonlat, c_lon, c_lat,
							c_elev, cands, idw_k, idw_power)
				else:
					height = base_elev
			else:
				height = base_elev

			# ── Step 2: Crater offsets (large craters only) ──
			# Uses 3D angular distance for perfect circular crater borders.
			# Additive: smaller craters dig into larger ones.
			height += SpatialCraterTerrain.apply_baked_craters(
				dir, _baked_cr_data, planet_radius)

			# ── Step 3: Linear feature offsets ──
			for feat in linear_arr:
				var cs := _cross_section_t(lonlat, feat, m_per_deg)
				var t: float = cs["t"]
				if t < 1.0:
					var along_t: float = cs["along_t"]
					var ws: float = feat.get("width_start_m", 100.0)
					var we: float = feat.get("width_end_m", 100.0)
					var width_here: float = lerpf(ws, we, along_t)
					# Depth: override from recipe, or derived 1:10 from width.
					var depth_m: float
					if feat.has("depth_override"):
						depth_m = feat["depth_override"]
					else:
						depth_m = width_here * 0.1
					var profile: String = feat.get("profile", "v_shape")
					if profile == "u_shape":
						var t2 := t * t
						height -= depth_m * (1.0 - t2 * t2)
					elif profile == "raised_linear":
						var height_m: float = feat.get("height_m", 10.0)
						height += height_m * (1.0 - t * t)
					else:  # v_shape
						height -= depth_m * (1.0 - t * t)

			# ── Step 4: Radial feature offsets ──
			for feat in radial_arr:
				var f_pos := Vector2(feat["lon"], feat["lat"])
				var delta := lonlat - f_pos
				var cos_lat := cos(deg_to_rad((lonlat.y + f_pos.y) * 0.5))
				var dist_m := sqrt((delta.x * cos_lat * m_per_deg) ** 2 \
					+ (delta.y * m_per_deg) ** 2)
				var r: float = feat["radius_m"]
				if dist_m < r:
					var t := dist_m / r
					var depth_m: float = feat["depth_m"]
					var profile: String = feat.get("profile", "bowl")
					if profile == "volcanic":
						# Bowl + rim uplift (similar to crater but simpler)
						var t2 := t * t
						height -= depth_m * (1.0 - t2 * t2)
					elif profile == "volcanic_raised":
						# Dome that raises terrain (e.g. lava dome)
						var height_m: float = feat.get("height_m", 50.0)
						height += height_m * (1.0 - t * t)
					else:
						# Simple bowl
						height -= depth_m * (1.0 - t * t)

			# ── Step 5: Procedural noise ──
			if noise != null:
				var noise_val := 0.0
				for octave in noise_octaves:
					var freq: float = octave["frequency"]
					var amp: float = octave["amplitude"]
					noise.frequency = freq
					noise_val += noise.get_noise_2d(lonlat.x, lonlat.y) * amp
				height += noise_val

			# ── Normalize and store ──
			# FORMAT_RF stores full float32, so do NOT clamp to [0, 1].
			# Craters and other features can push height below elev_min;
			# clamping would flatten them.
			var normalized := (height - elev_min) / elev_range
			img.set_pixel(px, py, Color(normalized, 0.0, 0.0, 1.0))

	return [img, subpixel_craters]


## Return the populate zones array from a v7+ recipe.
## Each zone is a Dictionary with keys: biome_type, coverage, vertices (or lon/lat), etc.
static func get_populate_zones(recipe: Dictionary) -> Array:
	return recipe.get("populate_zones", [])


## IDW (Inverse Distance Weighting) interpolation from K nearest among candidates.
static func _idw_interpolate(
		lonlat: Vector2,
		c_lon: PackedFloat64Array, c_lat: PackedFloat64Array,
		c_elev: PackedFloat64Array,
		candidates: PackedInt32Array, k: int, power: int) -> float:

	var nc := candidates.size()
	var max_k := mini(k, nc)
	if max_k == 0:
		return 0.0

	# Use a small fixed-size array for top-K tracking
	var best_dist := PackedFloat64Array()
	var best_elev := PackedFloat64Array()
	best_dist.resize(max_k)
	best_elev.resize(max_k)
	for i in max_k:
		best_dist[i] = INF
		best_elev[i] = 0.0

	var worst_idx := 0
	var worst_dist := INF

	for ci in nc:
		var i: int = candidates[ci]
		var dx := lonlat.x - c_lon[i]
		# Wrap longitude difference across the ±180° dateline.
		if dx > 180.0:
			dx -= 360.0
		elif dx < -180.0:
			dx += 360.0
		var dy := lonlat.y - c_lat[i]
		var dist_sq := dx * dx + dy * dy
		if dist_sq < worst_dist:
			best_dist[worst_idx] = dist_sq
			best_elev[worst_idx] = c_elev[i]
			# Find new worst
			worst_dist = 0.0
			for j in max_k:
				if best_dist[j] > worst_dist:
					worst_dist = best_dist[j]
					worst_idx = j

	# Compute weighted average
	var weight_sum := 0.0
	var value_sum := 0.0
	for i in max_k:
		if best_dist[i] == INF:
			continue
		var dist := sqrt(best_dist[i])
		if dist < 1e-10:
			return best_elev[i]  # Exact match
		var w: float
		if power == 2:
			w = 1.0 / best_dist[i]  # 1/d^2 = 1/dist_sq
		else:
			w = 1.0 / (dist ** power)
		weight_sum += w
		value_sum += w * best_elev[i]

	if weight_sum > 0.0:
		return value_sum / weight_sum
	return 0.0


## Build a uniform spatial grid over the contour data for fast neighbor lookups.
## Returns [grid: Dictionary, nx, ny, lon_min, lat_min, cell_w, cell_h].
static func _build_contour_grid(
		c_lon: PackedFloat64Array, c_lat: PackedFloat64Array,
		n: int) -> Array:
	var lon_min := INF
	var lon_max := -INF
	var lat_min := INF
	var lat_max := -INF
	for i in n:
		lon_min = minf(lon_min, c_lon[i])
		lon_max = maxf(lon_max, c_lon[i])
		lat_min = minf(lat_min, c_lat[i])
		lat_max = maxf(lat_max, c_lat[i])

	var lon_span := maxf(lon_max - lon_min, 1e-6)
	var lat_span := maxf(lat_max - lat_min, 1e-6)

	# Target ~20 points per cell → ~sqrt(n/20) cells per axis.
	var cells := maxi(int(sqrt(float(n) / 20.0)), 1)
	var nx := clampi(cells, 1, 500)
	var ny := clampi(cells, 1, 500)
	var cell_w := lon_span / float(nx)
	var cell_h := lat_span / float(ny)

	var grid := {}  # int -> Array[int]
	for i in n:
		var cx := clampi(int((c_lon[i] - lon_min) / cell_w), 0, nx - 1)
		var cy := clampi(int((c_lat[i] - lat_min) / cell_h), 0, ny - 1)
		var key := cy * nx + cx
		if not grid.has(key):
			grid[key] = []
		(grid[key] as Array).append(i)

	return [grid, nx, ny, lon_min, lat_min, cell_w, cell_h]


## Collect candidate contour-point indices from grid cells near (lon, lat).
## Expands search rings until at least [param min_count] candidates are found.
static func _grid_candidates(
		lon: float, lat: float,
		grid: Dictionary, nx: int, ny: int,
		lon_min: float, lat_min: float,
		cell_w: float, cell_h: float,
		min_count: int) -> PackedInt32Array:
	var cx := clampi(int((lon - lon_min) / cell_w), 0, nx - 1)
	var cy := clampi(int((lat - lat_min) / cell_h), 0, ny - 1)
	var result := PackedInt32Array()
	var max_ring := maxi(nx, ny)
	for ring in max_ring + 1:
		var x0 := maxi(cx - ring, 0)
		var x1 := mini(cx + ring, nx - 1)
		var y0 := maxi(cy - ring, 0)
		var y1 := mini(cy + ring, ny - 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				if ring == 0 or absi(x - cx) == ring or absi(y - cy) == ring:
					var key := y * nx + x
					if grid.has(key):
						for idx in grid[key]:
							result.append(idx)
		if result.size() >= min_count:
			break
	return result


## Compute cross-section parameter for a point relative to a linear feature.
## Returns a Dictionary { "t": float, "along_t": float } where:
##   t      = perpendicular distance / interpolated half-width  [0..1)
##   along_t = normalized position along the centerline  [0..1]
## If the point is outside the feature, returns { "t": 1.0, "along_t": 0.0 }.
static func _cross_section_t(
		lonlat: Vector2, feat: Dictionary, m_per_deg: float) -> Dictionary:
	var centerline: Array = feat.get("centerline", [])
	var half_width_max_deg: float = feat.get("half_width_max_deg", 0.001)
	if centerline.size() < 2 or half_width_max_deg <= 0.0:
		return { "t": 1.0, "along_t": 0.0 }

	var width_start_m: float = feat.get("width_start_m", 100.0)
	var width_end_m: float = feat.get("width_end_m", 100.0)
	var total_length_m: float = feat.get("total_length_m", 1.0)
	var cum_lengths: Array = feat.get("cum_lengths", [])
	if total_length_m <= 0.0:
		total_length_m = 1.0

	# Find nearest segment, perpendicular distance, and projection parameter.
	var min_dist := INF
	var best_along_m := 0.0
	for i in range(centerline.size() - 1):
		var a := Vector2(centerline[i][0], centerline[i][1])
		var b := Vector2(centerline[i + 1][0], centerline[i + 1][1])
		var ab := b - a
		var ap := lonlat - a
		var ab_sq := ab.dot(ab)
		var proj_t := 0.0
		if ab_sq > 1e-20:
			proj_t = clampf(ap.dot(ab) / ab_sq, 0.0, 1.0)
		var closest := a + ab * proj_t
		var d := (lonlat - closest).length()
		if d < min_dist:
			min_dist = d
			# Cumulative distance along centerline to the projection point.
			var seg_start_m: float = cum_lengths[i] if i < cum_lengths.size() else 0.0
			var seg_end_m: float = cum_lengths[i + 1] if (i + 1) < cum_lengths.size() else total_length_m
			best_along_m = seg_start_m + proj_t * (seg_end_m - seg_start_m)

	var along_t := clampf(best_along_m / total_length_m, 0.0, 1.0)

	# Interpolate half-width at this position along the centerline.
	var half_width_here_m := lerpf(width_start_m, width_end_m, along_t) * 0.5
	var half_width_here_deg := half_width_here_m / m_per_deg

	if half_width_here_deg <= 0.0 or min_dist >= half_width_here_deg:
		return { "t": 1.0, "along_t": along_t }

	return { "t": min_dist / half_width_here_deg, "along_t": along_t }


## Perpendicular distance from point P to line segment AB (in degree space).
static func _point_to_segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var ap := p - a
	var ab_sq := ab.dot(ab)
	if ab_sq < 1e-20:
		return ap.length()
	var t := clampf(ap.dot(ab) / ab_sq, 0.0, 1.0)
	var closest := a + ab * t
	return (p - closest).length()


## Convert unit direction vector to (longitude, latitude) in degrees.
static func _dir_to_lonlat(dir: Vector3) -> Vector2:
	var d := dir.normalized()
	var lon := rad_to_deg(atan2(d.z, d.x))
	var lat := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
	return Vector2(lon, lat)


## Bilinear interpolation from a regular elevation grid.
## The grid is stored as a flat PackedFloat64Array in row-major order
## (row 0 = lat_min, last row = lat_max).
static func _grid_bilinear(
		lon: float, lat: float,
		grid: PackedFloat64Array,
		cols: int, rows: int,
		lon_min: float, lon_max: float,
		lat_min: float, lat_max: float) -> float:
	var lon_span := lon_max - lon_min
	var lat_span := lat_max - lat_min
	if lon_span <= 0.0 or lat_span <= 0.0:
		return grid[0] if grid.size() > 0 else 0.0

	var gx := (lon - lon_min) / lon_span * float(cols - 1)
	var gy := (lat - lat_min) / lat_span * float(rows - 1)
	var x0 := clampi(int(gx), 0, cols - 2)
	var y0 := clampi(int(gy), 0, rows - 2)
	var fx := clampf(gx - float(x0), 0.0, 1.0)
	var fy := clampf(gy - float(y0), 0.0, 1.0)

	var v00 := grid[y0 * cols + x0]
	var v10 := grid[y0 * cols + x0 + 1]
	var v01 := grid[(y0 + 1) * cols + x0]
	var v11 := grid[(y0 + 1) * cols + x0 + 1]

	return v00 * (1.0 - fx) * (1.0 - fy) \
		+ v10 * fx * (1.0 - fy) \
		+ v01 * (1.0 - fx) * fy \
		+ v11 * fx * fy


## Bilinear interpolation from a pixel-space elevation grid.
## [param gx] Fractional grid x-coordinate (0.5 = first inner cell center).
## [param gy] Fractional grid y-coordinate.
## [param grid] Flat PackedFloat64Array, row-major, (total × total).
## [param total] Grid side length (inner_n + 2).
static func _grid_bilinear_px(
		gx: float, gy: float,
		grid: PackedFloat64Array,
		total: int) -> float:
	var x0 := clampi(int(gx), 0, total - 2)
	var y0 := clampi(int(gy), 0, total - 2)
	var fx := clampf(gx - float(x0), 0.0, 1.0)
	var fy := clampf(gy - float(y0), 0.0, 1.0)

	var v00 := grid[y0 * total + x0]
	var v10 := grid[y0 * total + x0 + 1]
	var v01 := grid[(y0 + 1) * total + x0]
	var v11 := grid[(y0 + 1) * total + x0 + 1]

	return v00 * (1.0 - fx) * (1.0 - fy) \
		+ v10 * fx * (1.0 - fy) \
		+ v01 * (1.0 - fx) * fy \
		+ v11 * fx * fy
