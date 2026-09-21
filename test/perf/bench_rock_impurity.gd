## Banc de mesure de la teinte des roches (RockImpurity) par sommet.
##
## Pourquoi : la couleur d'un sommet de roche passe désormais par
## RockImpurity.tint (mottle + strates + règle de la roche + poussière) et par
## PlanetData.mountain_core (un appel C# par sommet). Ce banc isole les deux
## pour les comparer à l'ancien coût (RockCatalogue.tint = le mottle seul) et
## au budget d'un chunk (33² sommets, ~5 échantillons de hauteur chacun).
##
## Un test GUT et non un `--script` : RockImpurity dépend de PlanetData, donc
## des autoloads, qu'un script nu ne charge pas (le fichier ne compile pas et
## ses initialiseurs statiques ne tournent pas — le Mutex est null).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/perf/bench_rock_impurity.gd -gexit
extends GutTest

const RADIUS := 3467000.0
const N := 20000


func test_bench() -> void:
	RockCatalogue.reload()
	var dirs := PackedVector3Array()
	for i in N:
		dirs.append(Vector3(sin(i * 0.37), cos(i * 0.53), sin(i * 0.11 + 1.0)).normalized())
	var sink := 0.0
	var t0 := Time.get_ticks_usec()
	for i in N:
		sink += SurfaceNoise.mottle(dirs[i], RADIUS, RockCatalogue.BLOTCH_M, RockCatalogue.STREAK_M)
	var t_mottle := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for i in N:
		sink += RockImpurity.strata(dirs[i], RADIUS, 120.0)
	var t_strata := Time.get_ticks_usec() - t0
	for slug in ["corundum_milky", "corundum_red", "corundum_blue"]:
		t0 = Time.get_ticks_usec()
		for i in N:
			var c := RockImpurity.tint(slug, dirs[i], RADIUS, 120.0, 0.6, 20.0, 0.1)
			sink += c.r
		var t_tint := Time.get_ticks_usec() - t0
		print("%-16s tint %.2f µs/sommet" % [slug, float(t_tint) / N])
	print("mottle seul (ancien RockCatalogue.tint) %.2f µs/sommet ; strates %.2f µs/sommet" % [
			float(t_mottle) / N, float(t_strata) / N])
	# mountain_core : un massif + une crête, appel C# par sommet.
	var pd := PlanetData.new()
	pd.planet_name = "bench"
	pd.radius = RADIUS
	pd.export_nside = 64
	var c := Vector2(12.0, 20.0)
	var mpd := RADIUS * PI / 180.0
	var dl := 20000.0 / mpd
	var poly := PackedVector2Array([c + Vector2(-dl, -dl), c + Vector2(dl, -dl), c + Vector2(dl, dl), c + Vector2(-dl, dl)])
	pd.set_mountain_overrides(
			[{"coverage": "partial", "polygon": poly, "amplitude_m": 800.0, "wavelength_m": 8000.0, "octaves": 7, "feather_m": 3000.0}],
			[{"coverage": "partial", "polygon": PackedVector2Array([c + Vector2(-dl * 0.5, 0.0), c + Vector2(dl * 0.5, 0.0)]), "height_m": 400.0, "width_m": 1500.0}])
	var inside := PackedVector3Array()
	for i in N:
		var ll := c + Vector2(fmod(i * 0.013, 2.0 * dl) - dl, fmod(i * 0.017, 2.0 * dl) - dl)
		inside.append(HEALPix.lonlat2vec(ll.x, ll.y))
	t0 = Time.get_ticks_usec()
	for i in N:
		sink += pd.mountain_core(inside[i])
	var t_core := Time.get_ticks_usec() - t0
	print("mountain_core (C#, dans le massif) %.2f µs/sommet   [sink %f]" % [float(t_core) / N, sink])
	assert_true(sink > 0.0)
