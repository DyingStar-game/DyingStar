## Dump a .recipe.bin file's elevation grid to CSV for QGIS inspection.
##
## Usage (run from project root):
##   $GODOT --headless --script tools/dump_recipe_to_csv.gd -- <path/to/hp_n64_pN.recipe.bin> [out.csv]
##
## Outputs a CSV with columns: lon,lat,elevation  (EPSG:4326)
## Load in QGIS: Layer > Add Layer > Add Delimited Text Layer, geometry X=lon Y=lat, CRS EPSG:4326.
##
## What the script prints:
##   - base_elevation  : fallback height when no contours are nearby
##   - grid_inner_n    : NxN grid of baked elevation samples from global TIF (if any)
##   - contour_vertices: raw QGIS contour points baked into the recipe (if any)
##
## If base_elevation ≈ -550m and grid is flat → the recipe has NO QGIS contour data
## for that area, meaning you need to draw contours in QGIS and re-export.
@tool
extends SceneTree

const HEALPix = preload("res://scenes/planet/healpix.gd")

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 1:
		printerr("Usage: godot --headless --script tools/dump_recipe_to_csv.gd -- <recipe.bin> [out.csv]")
		quit(1)
		return

	var bin_path: String = args[0]
	var csv_path: String = args[1] if args.size() >= 2 \
		else bin_path.replace(".recipe.bin", "_grid.csv")

	# ── Load binary recipe ──
	var fa := FileAccess.open(bin_path, FileAccess.READ)
	if fa == null:
		printerr("Cannot open: %s" % bin_path)
		quit(1)
		return
	var recipe = fa.get_var(true)
	fa.close()

	if typeof(recipe) != TYPE_DICTIONARY:
		printerr("Recipe is not a Dictionary (type=%d)" % typeof(recipe))
		quit(1)
		return

	var key: String  = recipe.get("key", "?")
	var nside: int   = recipe.get("nside", 0)
	var ipix: int    = recipe.get("ipix", -1)
	var version: int = recipe.get("version", 0)
	print("Recipe  key=%s  nside=%d  ipix=%d  version=%d" % [key, nside, ipix, version])

	var elev_section = recipe.get("elevation", {})
	var base_elev: float = float(elev_section.get("base_elevation", 0.0))
	var grid_data         = elev_section.get("grid_elevations", null)
	var grid_n: int       = int(elev_section.get("grid_inner_n", 0))
	var contour_verts     = elev_section.get("contour_vertices", null)

	var has_grid := grid_data != null and grid_n >= 2
	var has_contours := contour_verts != null \
		and typeof(contour_verts) == TYPE_ARRAY \
		and (contour_verts as Array).size() > 0

	print("  base_elevation=%.2f" % base_elev)
	if has_grid:
		print("  grid_inner_n=%d  (baked NxN from global TIF)" % grid_n)
	if has_contours:
		print("  contour_vertices=%d  (QGIS contour points)" % (contour_verts as Array).size())
	if not has_grid and not has_contours:
		print("  ⚠ No grid and no contours — terrain will be FLAT at base_elevation=%.2f" % base_elev)

	# ── Decode HEALPix geometry ──
	var npface := nside * nside
	var face: int   = ipix / npface
	var local: int  = ipix % npface
	var xy: Vector2i = HEALPix.nest2xy(local)
	var ix: int = xy.x
	var iy: int = xy.y

	# ── Write CSV ──
	var out := FileAccess.open(csv_path, FileAccess.WRITE)
	if out == null:
		printerr("Cannot write: %s" % csv_path)
		quit(1)
		return
	out.store_line("lon,lat,elevation")
	var written := 0

	if has_grid:
		# grid_elevations: flat Array, row-major, (grid_n + 2*margin)² cells.
		var arr := grid_data as Array
		var total_n := int(round(sqrt(float(arr.size()))))
		var margin := (total_n - grid_n) / 2
		print("  grid array size=%d → total_n=%d margin=%d" % [arr.size(), total_n, margin])

		for row in total_n:
			for col in total_n:
				# Sub-pixel coords at cell centre (in units of 1/grid_n of the chunk edge)
				var fx := float(ix * grid_n + col - margin) + 0.5
				var fy := float(iy * grid_n + row - margin) + 0.5
				var dir: Vector3 = HEALPix._face_xy_to_vec(face, fx, fy, nside * grid_n)
				var lat := rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))
				var lon := rad_to_deg(atan2(dir.z, dir.x))
				out.store_line("%.6f,%.6f,%.4f" % [lon, lat, float(arr[row * total_n + col])])
				written += 1

	elif has_contours:
		for v in (contour_verts as Array):
			if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 3:
				out.store_line("%.6f,%.6f,%.4f" % [float(v[0]), float(v[1]), float(v[2])])
				written += 1

	else:
		# Flat fallback: emit single centre point so the chunk is visible in QGIS
		var dir: Vector3 = HEALPix._face_xy_to_vec(
			face, float(ix) + 0.5, float(iy) + 0.5, nside)
		var lat := rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))
		var lon := rad_to_deg(atan2(dir.z, dir.x))
		out.store_line("%.6f,%.6f,%.4f" % [lon, lat, base_elev])
		written = 1

	out.close()
	print("✓ Wrote %d points → %s" % [written, ProjectSettings.globalize_path(csv_path)])

	# ── If grid exists but contours also exist, dump contours to a second file ──
	if has_grid and has_contours:
		var cv_path := csv_path.get_basename() + "_contours.csv"
		var cv := FileAccess.open(cv_path, FileAccess.WRITE)
		if cv:
			cv.store_line("lon,lat,elevation")
			for v in (contour_verts as Array):
				if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 3:
					cv.store_line("%.6f,%.6f,%.4f" % [float(v[0]), float(v[1]), float(v[2])])
			cv.close()
			print("✓ Contour pts → %s" % ProjectSettings.globalize_path(cv_path))

	quit(0)
