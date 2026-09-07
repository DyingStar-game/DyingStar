extends GutTest
## Équivalence entre l'échantillonnage par get_pixel() et par indexation float.
##
## Le chemin chaud d'échantillonnage de hauteur lisait chaque texel via
## `img.get_pixel(x, y).r`, ce qui construit une Color (quatre floats) par texel. Le noyau
## bilinéaire en demande quatre, le calcul des normales quatre échantillons par sommet, et
## la bande de mélange de bord en ajoute encore : ~17 400 appels par chunk, pour 45 % du
## temps de génération passé dans l'échantillonnage (mesuré à cache froid sur tarsis_3).
##
## Les tuiles étant créées en FORMAT_RF depuis les octets bruts du pack, la donnée
## sous-jacente EST déjà du float32 : l'indexer directement rend la même valeur sans
## l'allocation. Tout le gain repose sur ce « la même valeur », donc il se teste.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_tile_sampling.gd -gexit

const RES := 16


func _tile() -> Array:
	## Une tuile FORMAT_RF pseudo-aléatoire, et ses floats. Valeurs dans [0,1] comme le
	## format normalisé de l'exporteur.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260908
	var bytes := PackedByteArray()
	bytes.resize(RES * RES * 4)
	for i in RES * RES:
		bytes.encode_float(i * 4, rng.randf())
	var img := Image.create_from_data(RES, RES, false, Image.FORMAT_RF, bytes)
	return [img, bytes.to_float32_array()]


func test_float_array_matches_get_pixel_texel_by_texel() -> void:
	var t := _tile()
	var img: Image = t[0]
	var floats: PackedFloat32Array = t[1]
	for y in RES:
		for x in RES:
			assert_eq(floats[y * RES + x], img.get_pixel(x, y).r,
					"texel (%d,%d) doit être identique" % [x, y])


func test_bilinear_twins_agree_exactly() -> void:
	# Les deux échantillonneurs doivent rendre le MÊME float, pas une approximation :
	# une divergence, même minime, déplacerait le terrain et la collision.
	var t := _tile()
	var img: Image = t[0]
	var floats: PackedFloat32Array = t[1]
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 300:
		var u := rng.randf()
		var v := rng.randf()
		assert_eq(PlanetData._sample_floats_bilinear(floats, RES, RES, u, v),
				PlanetData._sample_image_bilinear(img, u, v),
				"désaccord bilinéaire en (%f, %f)" % [u, v])


func test_bilinear_twins_agree_on_the_borders() -> void:
	# Les bords exercent les clamps : c'est là qu'une erreur d'indexation se voit.
	var t := _tile()
	var img: Image = t[0]
	var floats: PackedFloat32Array = t[1]
	for uv in [Vector2(0.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0), Vector2(1.0, 0.0),
			Vector2(0.5, 0.0), Vector2(0.0, 0.5), Vector2(1.0, 0.5), Vector2(0.5, 1.0)]:
		assert_eq(PlanetData._sample_floats_bilinear(floats, RES, RES, uv.x, uv.y),
				PlanetData._sample_image_bilinear(img, uv.x, uv.y),
				"désaccord au bord %s" % uv)


func test_decode_handles_formats_other_than_rf() -> void:
	# Bug attrapé par test_collision_shape : `get_data().to_float32_array()` échoue en
	# silence sur un format dont la taille n'est pas un multiple de 4 octets — Godot
	# rapporte « size % sizeof(float) » et rend un tableau vide, c'est-à-dire un terrain
	# plat. Le chemin recipe et les tuiles synthétiques des tests ne sont pas en RF.
	var img := Image.create(4, 4, false, Image.FORMAT_L8)
	for y in 4:
		for x in 4:
			img.set_pixel(x, y, Color(float(x + 4 * y) / 16.0, 0, 0))
	var floats := PlanetData._decode_tile_floats(img)
	assert_eq(floats.size(), 16, "un format non-RF doit quand même se décoder")
	for y in 4:
		for x in 4:
			assert_eq(floats[y * 4 + x], img.get_pixel(x, y).r,
					"texel (%d,%d) d'une image L8" % [x, y])


func test_tile_side_is_derived_from_the_array_not_assumed() -> void:
	# Bug attrapé par test_collision_shape : passer chunk_heightmap_res comme côté lisait
	# hors des bornes dès qu'une tuile stockée avait une autre taille (chemin recipe).
	var f := PackedFloat32Array()
	f.resize(25)
	assert_eq(PlanetData._tile_side(f), 5, "25 texels -> côté 5")
	f.resize(2500)
	assert_eq(PlanetData._tile_side(f), 50, "2500 texels -> côté 50")
	f.resize(0)
	assert_eq(PlanetData._tile_side(f), -1, "tuile vide -> refus")
	f.resize(30)
	assert_eq(PlanetData._tile_side(f), -1, "non carrée -> refus plutôt que lecture hors bornes")


func test_row_major_order_is_not_transposed() -> void:
	# Une tuile transposée passerait tous les tests symétriques ci-dessus si elle était
	# carrée et le motif symétrique. Ce motif ne l'est pas.
	var bytes := PackedByteArray()
	bytes.resize(RES * RES * 4)
	for y in RES:
		for x in RES:
			bytes.encode_float((y * RES + x) * 4, float(x) * 0.01 + float(y))
	var img := Image.create_from_data(RES, RES, false, Image.FORMAT_RF, bytes)
	var floats := bytes.to_float32_array()
	# (x=3, y=11) vaut 11.03 ; transposé il vaudrait 3.11.
	assert_almost_eq(floats[11 * RES + 3], 11.03, 0.0001, "indexation ligne-majeure")
	assert_almost_eq(img.get_pixel(3, 11).r, 11.03, 0.0001, "get_pixel prend (x, y)")
