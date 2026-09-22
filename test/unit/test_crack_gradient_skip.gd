extends GutTest
## Sûreté du saut des Voronoï dans le calcul des normales (PlanetChunk.generate_mesh).
##
## Le calcul des normales évaluait crack_offset() QUATRE fois par sommet, pour carver le
## réseau de cracks dans les échantillons de gradient. Chaque appel lance un Voronoï 3D
## (deux passes 3×3×3, ~160 sin()). Mesuré sur tarsis_3 à cache froid : 39 % du temps des
## normales, soit 29 % de la génération d'un chunk.
##
## L'optimisation repose sur deux propriétés, et ce fichier les vérifie toutes les deux
## parce qu'une erreur sur l'une ou l'autre déformerait le terrain sans rien signaler :
##
##   1. Le découpage crack_offset() -> crack_edge_distance_m() + crack_offset_from_edge()
##      est arithmétiquement NEUTRE. Sinon toute la planète change de forme.
##   2. Un sommet dont le bord de crack le plus proche est au-delà de
##      demi-largeur + 2·eps a ses quatre points de gradient hors crack, donc quatre
##      offsets nuls. C'est ce qui autorise à ne pas les calculer. Si la propriété est
##      fausse, on efface des parois de crack dans l'ombrage.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_crack_gradient_skip.gd -gexit

# preload plutôt que le nom de classe global : un identifiant de classe n'est pas une
# expression constante, et `const CRACK := ArideDesertCorundumPlateauTerrain` ne compile pas.
const CRACK := preload(
	"res://scenes/planet/aride_desert_corundum_plateau/aride_desert_corundum_plateau_terrain.gd")

# Paramètres réels de tarsis_3 (scenes/systems/tarsis/tarsis_3.tscn).
const RADIUS := 6356000.0
const SPACING := 4000.0
const WIDTH := 250.0
const DEPTH := 180.0
## Grille la plus fine effectivement construite : nside 8192, chunk_resolution 32.
const NSIDE := 8192
const RES := 32


func _dirs(count: int, seed_value: int) -> Array[Vector3]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out: Array[Vector3] = []
	for i in count:
		# Directions uniformes sur la sphère : z uniforme, angle uniforme.
		var z := rng.randf_range(-1.0, 1.0)
		var phi := rng.randf_range(0.0, TAU)
		var r := sqrt(maxf(1.0 - z * z, 0.0))
		out.append(Vector3(r * cos(phi), z, r * sin(phi)))
	return out


func _eps_rad() -> float:
	return HEALPix.pixel_side_length(NSIDE, 1.0) * (0.25 / float(RES))


# ===================================================================
# 1. Le découpage ne change pas un bit
# ===================================================================

## Copie littérale du corps de crack_offset() AVANT le découpage. Comparer la fonction
## à sa propre implémentation ne prouverait rien : c'est contre cette référence figée que
## la neutralité arithmétique se vérifie.
func _reference_offset(dir: Vector3, radius: float, spacing_m: float,
		width_m: float, depth_m: float, vtx_spacing_m: float) -> float:
	if spacing_m <= 0.0 or width_m <= 0.0 or depth_m <= 0.0:
		return 0.0
	if vtx_spacing_m > 0.0 and vtx_spacing_m >= width_m * 0.5:
		return 0.0
	var p := dir * (radius / spacing_m)
	var edge_cells: float = CRACK._voronoi_edge_distance(p)
	var d_m := edge_cells * spacing_m
	var half := width_m * 0.5
	if d_m >= half:
		return 0.0
	var t := d_m / half
	var t2 := t * t
	return -depth_m * (1.0 - t2 * t2)


func test_split_reproduces_the_original_arithmetic_exactly() -> void:
	for dir in _dirs(400, 12345):
		assert_eq(CRACK.crack_offset(dir, RADIUS, SPACING, WIDTH, DEPTH, 0.0),
				_reference_offset(dir, RADIUS, SPACING, WIDTH, DEPTH, 0.0),
				"le découpage doit reproduire l'arithmétique d'origine bit pour bit")


func test_split_reproduces_the_lod_skip() -> void:
	# vtx_spacing >= width/2 : la crack n'est pas dessinée, la distance est INF.
	var dir := Vector3(0.3, 0.5, 0.81).normalized()
	assert_eq(CRACK.crack_offset(dir, RADIUS, SPACING, WIDTH, DEPTH, WIDTH), 0.0)
	assert_eq(CRACK.crack_edge_distance_m(dir, RADIUS, SPACING, WIDTH, WIDTH), INF)


func test_degenerate_parameters_carve_nothing() -> void:
	var dir := Vector3(0.0, 1.0, 0.0)
	assert_eq(CRACK.crack_edge_distance_m(dir, RADIUS, 0.0, WIDTH), INF, "spacing nul")
	assert_eq(CRACK.crack_edge_distance_m(dir, RADIUS, SPACING, 0.0), INF, "largeur nulle")
	assert_eq(CRACK.crack_offset_from_edge(10.0, WIDTH, 0.0), 0.0, "profondeur nulle")


# ===================================================================
# 2. La propriété qui autorise le saut
# ===================================================================

func test_far_vertices_have_four_zero_gradient_offsets() -> void:
	# LA propriété. Pour chaque sommet jugé « loin », on reconstruit exactement les
	# quatre directions de gradient de generate_mesh et on vérifie que leurs offsets
	# sont nuls — c'est-à-dire que ne pas les calculer ne change rien.
	var eps_rad := _eps_rad()
	var skip_m: float = WIDTH * 0.5 + 2.0 * eps_rad * RADIUS
	var checked := 0
	for dir_c in _dirs(600, 99):
		var d := CRACK.crack_edge_distance_m(dir_c, RADIUS, SPACING, WIDTH, 0.0)
		if d < skip_m:
			continue    # sommet proche d'une crack : le code calcule, rien à prouver
		checked += 1
		var up := dir_c
		var arbitrary := Vector3.UP if absf(up.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var tan_u := up.cross(arbitrary).normalized()
		var tan_v := up.cross(tan_u).normalized()
		for offset in [
				(dir_c - tan_u * eps_rad).normalized(),
				(dir_c + tan_u * eps_rad).normalized(),
				(dir_c - tan_v * eps_rad).normalized(),
				(dir_c + tan_v * eps_rad).normalized()]:
			assert_eq(CRACK.crack_offset(offset, RADIUS, SPACING, WIDTH, DEPTH, 0.0), 0.0,
					"sommet à %.1f m du bord (seuil %.1f) : gradient non nul" % [d, skip_m])
	assert_gt(checked, 100, "l'échantillon doit contenir assez de sommets « loin »")


func test_the_margin_is_not_vacuous() -> void:
	# Le seuil doit laisser passer de vrais sommets des deux côtés, sinon le test
	# précédent ne prouverait rien et l'optimisation ne gagnerait rien.
	var skip_m: float = WIDTH * 0.5 + 2.0 * _eps_rad() * RADIUS
	var near := 0
	var far := 0
	for dir in _dirs(400, 4242):
		if CRACK.crack_edge_distance_m(dir, RADIUS, SPACING, WIDTH, 0.0) < skip_m:
			near += 1
		else:
			far += 1
	assert_gt(near, 0, "des sommets proches d'une crack doivent exister")
	assert_gt(far, near, "la majorité doit être « loin » — c'est là qu'est le gain")
	# Pas de gut.p() ici : tout print traverse le pont OpenTelemetry, et une erreur du
	# pont est comptée par GUT comme un échec de test. Le taux de saut est donc encodé
	# dans une assertion plutôt qu'imprimé.
	assert_gt(float(far) / float(near + far), 0.5,
			"le saut doit couvrir plus de la moitié des sommets pour valoir la peine")


# ===================================================================
# 3. Le rebord : les sommets glissent dessus
# ===================================================================

func test_rim_snap_puts_near_vertices_on_the_rim_and_leaves_the_others() -> void:
	var pitch := 13.5
	var half := WIDTH * 0.5
	var max_move := pitch * PlanetChunk.RIM_SNAP_PITCHES
	var snapped := 0
	var kept := 0
	var off_rim := 0   # moved onto a plane that stopped being the nearest edge (a cell corner)
	for dir in _dirs(3000, 4242):
		var d := CRACK.crack_edge_distance_m(dir, RADIUS, SPACING, WIDTH, 0.0)
		var r := CRACK.crack_rim_snap(dir, RADIUS, SPACING, WIDTH, pitch, max_move)
		var nd := Vector3(r.x, r.y, r.z)
		var moved_m := nd.distance_to(dir) * RADIUS
		assert_lte(moved_m, max_move + 1e-6, "never more than the allowed move")
		if nd == dir:
			kept += 1
			assert_eq(r.w, d, "unmoved: its own edge distance")
			if absf(d - half) < max_move * 0.5:
				# Reachable but not moved: only when the edge plane is too flat.
				pass
		else:
			snapped += 1
			assert_eq(r.w, half, "moved: declared on the rim")
			var true_d := CRACK.crack_edge_distance_m(nd, RADIUS, SPACING, WIDTH, 0.0)
			if absf(true_d - half) > 0.05:
				off_rim += 1
			assert_lt(absf(d - half), max_move + 1e-6, "was within reach")
	assert_gt(snapped, 5, "some vertices sat near a rim")
	assert_gt(kept, snapped, "most did not")
	assert_lte(off_rim, int(ceil(snapped * 0.05)),
			"%d of %d snapped vertices are not on the rim (cell corners only)" % [off_rim, snapped])


func test_rim_snap_leaves_no_gap_along_a_grid_line() -> void:
	# Walk straight lines of vertices at the pitch across many rims: wherever
	# a line crosses a rim, at least one of the two vertices around the
	# crossing must have been moved onto it — the notch-per-period bug.
	var pitch := 13.5
	var max_move := pitch * PlanetChunk.RIM_SNAP_PITCHES
	var half := WIDTH * 0.5
	var crossings := 0
	var gaps := 0
	for start in _dirs(120, 31337):
		var arbitrary := Vector3.UP if absf(start.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var step := start.cross(arbitrary).normalized() * (pitch / RADIUS)
		var prev_d := INF
		var prev_snapped := false
		var dir := start
		for i in 400:
			var r := CRACK.crack_rim_snap(dir, RADIUS, SPACING, WIDTH, pitch, max_move)
			var d := CRACK.crack_edge_distance_m(dir, RADIUS, SPACING, WIDTH, 0.0)
			var snapped_here := Vector3(r.x, r.y, r.z) != dir
			if not is_inf(prev_d) and (prev_d - half) * (d - half) < 0.0 \
					and absf(d - prev_d) < pitch * 1.5:
				crossings += 1
				if not prev_snapped and not snapped_here:
					gaps += 1
			prev_d = d
			prev_snapped = snapped_here
			dir = (dir + step).normalized()
	assert_gt(crossings, 30, "the lines crossed rims")
	assert_lte(gaps, int(ceil(crossings * 0.03)),
			"%d of %d rim crossings have neither vertex on the rim" % [gaps, crossings])
	# No move when the caller forbids it (a stitched edge), no crack at a coarse pitch.
	var any := _dirs(1, 7)[0]
	var b := CRACK.crack_rim_snap(any, RADIUS, SPACING, WIDTH, pitch, 0.0)
	assert_eq(Vector3(b.x, b.y, b.z), any)
	assert_eq(b.w, CRACK.crack_edge_distance_m(any, RADIUS, SPACING, WIDTH, 0.0))
	assert_eq(CRACK.crack_rim_snap(any, RADIUS, SPACING, WIDTH, WIDTH, max_move).w, INF)


func test_edge_normal_matches_the_distance_gradient() -> void:
	# Moving along the normal by the distance lands on the edge (distance 0) —
	# except where IQ's 3×3×3 second pass misses a Voronoi neighbour two
	# cells away: the field is discontinuous there (a known approximation the
	# crack pattern itself lives with), so a few points land off. Rare.
	var off := 0
	var n := 0
	for dir in _dirs(300, 99):
		var p := dir * (RADIUS / SPACING)
		var dn := CRACK._voronoi_edge_dn(p)
		assert_eq(dn.w, CRACK._voronoi_edge_distance(p), "same distance as before")
		var on_edge := p + Vector3(dn.x, dn.y, dn.z) * dn.w
		if absf(CRACK._voronoi_edge_distance(on_edge)) > 1e-6 * max(1.0, dn.w) + 1e-9:
			off += 1
		n += 1
	assert_lte(off, 6, "%d of %d normals do not point straight at the edge" % [off, n])
