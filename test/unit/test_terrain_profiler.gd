extends GutTest
## GUT suite pour [TerrainProfiler] — le rig de mesure de la phase 0 de
## docs/PLANET_CHUNK_STREAMING.md.
##
## Ce qui est couvert, et pourquoi :
##   1. [method TerrainProfiler.commit_mesh] agrège bien les phases, et ignore un Dictionary vide
##      (une tâche annulée ou un rig éteint ne doit pas compter comme un mesh).
##   2. [method TerrainProfiler.tile_census_line] regroupe les clés par niveau de pyramide. C'est le
##      chiffre que la phase 0 doit produire ; s'il est faux, tout le dimensionnement du streaming
##      l'est aussi.
##   3. Les lignes de log se construisent correctement. Un parse check ne les attrape PAS : une
##      arité erronée dans un `%` est une erreur d'exécution, et ce rig n'est allumé que sur les
##      machines où l'on chasse un problème — c'est-à-dire jamais dans les conditions où on
##      voudrait découvrir qu'il plante. On teste les String rendues, pas report_now() : un `print`
##      traverse le pont OpenTelemetry C#, et une erreur moteur fait échouer le test GUT.
##   4. La barrière d'intervalle : le point du rig est de remplacer un print par chunk par une ligne
##      toutes les 10 s, donc « n'imprime pas deux fois de suite » est une propriété, pas un détail.
##
## Run with:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_terrain_profiler.gd -gexit
## (-gtest veut un chemin res:// COMPLET ; un simple nom de fichier est silencieusement ignoré et
##  GUT exécute alors tout le répertoire.)

var _saved_prof_on: bool = false


func before_each() -> void:
	_saved_prof_on = PropNet.prof_on
	TerrainProfiler.reset()


func after_each() -> void:
	TerrainProfiler.reset()
	PropNet.prof_on = _saved_prof_on


# ===================================================================
# 1. commit_mesh
# ===================================================================

func test_commit_mesh_accumulates_every_phase() -> void:
	TerrainProfiler.commit_mesh({
		"total": 1000, "prepare": 100, "verts": 400, "index": 50,
		"normals": 150, "skirt": 80, "overlay": 70, "surface": 150,
	})
	assert_eq(PropNet.prof_chunk_calls, 1, "un mesh compté")
	assert_eq(PropNet.prof_chunk_total_usec, 1000, "total")
	assert_eq(PropNet.prof_chunk_prepare_usec, 100, "prepare")
	assert_eq(PropNet.prof_chunk_verts_usec, 400, "verts")
	assert_eq(PropNet.prof_chunk_index_usec, 50, "index")
	assert_eq(PropNet.prof_chunk_normals_usec, 150, "normals")
	assert_eq(PropNet.prof_chunk_skirt_usec, 80, "skirt")
	assert_eq(PropNet.prof_chunk_overlay_usec, 70, "overlay")
	assert_eq(PropNet.prof_chunk_surface_usec, 150, "surface")


func test_commit_mesh_sums_across_calls() -> void:
	TerrainProfiler.commit_mesh({"total": 1000, "verts": 400})
	TerrainProfiler.commit_mesh({"total": 3000, "verts": 600})
	assert_eq(PropNet.prof_chunk_calls, 2)
	assert_eq(PropNet.prof_chunk_total_usec, 4000)
	assert_eq(PropNet.prof_chunk_verts_usec, 1000)


func test_commit_mesh_ignores_empty_dict() -> void:
	# Le rig éteint laisse le Dictionary vide : ces tâches ne doivent pas gonfler le
	# compteur de meshes, sinon la moyenne par mesh est fausse.
	TerrainProfiler.commit_mesh({})
	assert_eq(PropNet.prof_chunk_calls, 0, "un prof vide ne compte pas un mesh")


func test_commit_mesh_tolerates_partial_dict() -> void:
	# generate_mesh peut sortir par une branche qui n'a pas franchi toutes les bornes.
	TerrainProfiler.commit_mesh({"total": 500})
	assert_eq(PropNet.prof_chunk_calls, 1)
	assert_eq(PropNet.prof_chunk_verts_usec, 0, "phase absente = 0, pas une erreur")


# ===================================================================
# 2. Recensement des tuiles
# ===================================================================

func test_tile_census_groups_by_nside() -> void:
	PlanetData.prof_tiles_seen["hp_n64_p13120"] = 3
	PlanetData.prof_tiles_seen["hp_n64_p13121"] = 1
	PlanetData.prof_tiles_seen["hp_n8192_p214259553"] = 1
	PlanetData.prof_tiles_seen["hp_n1_p0"] = 7
	PlanetData.prof_tile_requests = 12
	PlanetData.prof_tile_disk_reads = 4

	var line := TerrainProfiler.tile_census_line()
	assert_string_contains(line, "tuiles distinctes=4")
	assert_string_contains(line, "12 demandes")
	assert_string_contains(line, "4 lectures disque")
	assert_string_contains(line, "n1:1")
	assert_string_contains(line, "n64:2")
	assert_string_contains(line, "n8192:1")


func test_tile_census_orders_levels_ascending() -> void:
	# La ligne se lit du niveau grossier au niveau fin, comme la pyramide.
	PlanetData.prof_tiles_seen["hp_n8192_p1"] = 1
	PlanetData.prof_tiles_seen["hp_n16_p1"] = 1
	PlanetData.prof_tiles_seen["hp_n256_p1"] = 1
	var line := TerrainProfiler.tile_census_line()
	assert_lt(line.find("n16:"), line.find("n256:"), "n16 avant n256")
	assert_lt(line.find("n256:"), line.find("n8192:"), "n256 avant n8192")


func test_tile_census_reports_who_asked() -> void:
	# Sans cette ventilation, "6654 demandes sans un seul chunk construit" reste un
	# mystère : c'est elle qui dit que ce sont les échantillonneurs de hauteur, pas la
	# génération de terrain.
	PlanetData.prof_sampler_calls["dir_query"] = 3223
	PlanetData.prof_sampler_calls["boundary"] = 4
	PlanetData.prof_tile_requests = 6654
	var line := TerrainProfiler.tile_census_line()
	assert_string_contains(line, "dir_query=3223")
	assert_string_contains(line, "boundary=4")


func test_tile_census_reports_tiles_per_sampler_call() -> void:
	# 6654 demandes pour 3327 appels = 2,0 tuiles par échantillon : chacun touche sa
	# tuile PLUS une voisine (chemin bilinéaire de bord). Multiplicateur qui compte
	# directement dans le dimensionnement d'un cache réseau.
	PlanetData.prof_sampler_calls["dir_query"] = 3327
	PlanetData.prof_tile_requests = 6654
	assert_string_contains(TerrainProfiler.tile_census_line(), "2.0 tuiles/appel")


func test_tile_census_rate_is_windowed_not_cumulative() -> void:
	# Régression : le débit affichait 3 327 000 dem/s puis 665, 333, 222… (décroissance
	# en 1/t), parce qu'un cumul était divisé par un temps qui grandit. Le premier
	# rapport n'a pas de fenêtre précédente, donc il n'annonce aucun débit — plutôt qu'un
	# chiffre faux.
	PlanetData.prof_tile_requests = 6654
	assert_eq(TerrainProfiler.tile_census_line().find("dem/s"), -1,
			"premier rapport : pas de fenêtre, donc pas de débit annoncé")
	# Le deuxième rapport en a une, et ne compte QUE les demandes de l'intervalle.
	# La fenêtre est posée explicitement : s'appuyer sur l'horloge rendait le test
	# flaky — les deux appels tombaient dans la même milliseconde lors d'un run complet,
	# la fenêtre valait 0 et aucun débit n'était annoncé.
	TerrainProfiler._prev_report_ms = Time.get_ticks_msec() - 1000
	TerrainProfiler._prev_requests = 6654
	PlanetData.prof_tile_requests = 6754
	# 100 demandes sur ~1 s : le débit porte sur l'intervalle, pas sur les 6754 cumulées.
	assert_string_contains(TerrainProfiler.tile_census_line(), "100 dem/s")


func test_tile_census_empty_is_safe() -> void:
	var line := TerrainProfiler.tile_census_line()
	assert_string_contains(line, "tuiles distinctes=0")


# ===================================================================
# 3. Les lignes de log se construisent (sans les imprimer)
# ===================================================================
#
# On vérifie les String rendues, jamais report_now() : un `print` traverse le pont
# OpenTelemetry C#, qui peut lever, et GUT compte une erreur moteur comme un échec —
# le test mesurerait alors la santé du pont, pas celle du rig.

func test_phase_line_is_safe_with_zero_counters() -> void:
	# maxi(..., 1) doit tenir : sans compteurs, la moyenne par mesh divise par zéro.
	var line := TerrainProfiler.phase_line()
	assert_string_contains(line, "meshes=0")
	assert_string_contains(line, "mean=0.00ms")


func test_phase_line_reports_percentages_of_total() -> void:
	TerrainProfiler.commit_mesh({
		"total": 1000, "prepare": 100, "verts": 500, "index": 20,
		"normals": 120, "skirt": 60, "overlay": 50, "surface": 150,
	})
	var line := TerrainProfiler.phase_line()
	assert_string_contains(line, "meshes=1")
	assert_string_contains(line, "mean=1.00ms")
	assert_string_contains(line, "prepare=10%")
	assert_string_contains(line, "verts=50%")
	assert_string_contains(line, "surface=15%")


func test_cost_line_ignores_tile_reads_outside_mesh_generation() -> void:
	# Régression du premier relevé client : la ligne affichait "tuiles=144.4% du temps
	# mesh". Le numérateur était le compteur GLOBAL — qui inclut les 488 chunks servis
	# par le cache disque, les requêtes de gameplay et les spawners — pendant que le
	# dénominateur ne couvrait que les 3 meshes réellement générés. Seul le temps de
	# tuile mesuré DANS generate_mesh est comparable au temps mesh.
	TerrainProfiler.commit_mesh({"total": 10000, "tile": 2000})
	PlanetData.prof_tile_usec = 999_999  # bruit hors génération
	var line := TerrainProfiler.cost_line()
	assert_string_contains(line, "tuiles=20.0% du temps mesh")


func test_phase_line_reports_the_disk_cache_hit_ratio() -> void:
	# Le fait dominant d'un client tiède : 3 meshes générés pour 488 chunks assemblés.
	# Sans ce ratio, "mean=28.99ms" se lit comme le coût d'un chunk alors que 99,4 %
	# des chunks ne le paient jamais.
	TerrainProfiler.commit_mesh({"total": 28990})
	PropNet.prof_asm_calls = 488
	var line := TerrainProfiler.phase_line()
	assert_string_contains(line, "meshes=1")
	assert_string_contains(line, "488 assemblés")
	assert_string_contains(line, "99.8% depuis le cache")


func test_normals_line_is_safe_without_data() -> void:
	assert_string_contains(TerrainProfiler.normals_line(), "aucun relevé")


func test_normals_line_splits_sampling_crack_and_the_rest() -> void:
	# La phase "normals" pèse 74 % de la génération ; savoir si ce temps part dans
	# l'échantillonnage de hauteur ou dans crack_offset décide du correctif, donc la
	# répartition doit être juste.
	TerrainProfiler.commit_mesh({"total": 10000, "normals": 8000})
	# Parts choisies pour tomber juste : un test ne doit pas dépendre du mode d'arrondi.
	PropNet.prof_norm_sample_usec = 800     # 10 %
	PropNet.prof_norm_crack_usec = 6400     # 80 %, le reliquat en vaut 10
	var line := TerrainProfiler.normals_line()
	assert_string_contains(line, "normals=8.0ms/mesh")
	assert_string_contains(line, "échantillons 10%")
	assert_string_contains(line, "crack 80%")
	assert_string_contains(line, "reste 10%")


func test_cost_line_is_safe_with_zero_counters() -> void:
	var line := TerrainProfiler.cost_line()
	assert_string_contains(line, "aucun mesh généré")
	assert_string_contains(line, "asm=0×0.00ms")


func test_cost_line_falls_back_to_absolute_without_meshes() -> void:
	# Régression du premier run serveur : la ligne affichait "tuiles=3323000.0% du temps
	# mesh" parce qu'un total nul était ramené à 1 µs par le garde anti-division. Un
	# serveur ne génère JAMAIS de mesh (il ne fait que de la collision), donc ce cas est
	# le régime normal côté serveur, pas un accident.
	PlanetData.prof_tile_usec = 33230
	PlanetData.prof_tile_requests = 6654
	var line := TerrainProfiler.cost_line()
	assert_eq(line.find("du temps mesh"), -1, "pas de part relative sans mesh de référence")
	assert_string_contains(line, "aucun mesh généré")
	assert_string_contains(line, "33.2ms cumulées")
	assert_string_contains(line, "5.0µs/demande")


func test_cost_line_reports_the_tile_share() -> void:
	# La ligne qui décide de la phase 3 : 900 µs de tuile sur 4200 µs de mesh = 21,4 %.
	TerrainProfiler.commit_mesh({"total": 4200, "verts": 2000, "tile": 900})
	PropNet.prof_asm_calls = 3
	PropNet.prof_asm_usec = 9000
	PropNet.prof_col_calls = 2
	PropNet.prof_col_usec = 8000
	PropNet.prof_cache_save_calls = 1
	PropNet.prof_cache_save_usec = 2500
	PropNet.prof_cache_load_calls = 5
	PropNet.prof_cache_load_usec = 1500
	var line := TerrainProfiler.cost_line()
	assert_string_contains(line, "tuiles=21.4%")
	assert_string_contains(line, "(0.90ms/mesh)")
	assert_string_contains(line, "asm=3×3.00ms")
	assert_string_contains(line, "col=2×4.00ms")
	assert_string_contains(line, "cache save=1×2.50ms")
	assert_string_contains(line, "load=5×0.30ms")


# ===================================================================
# 4. Barrière d'intervalle
# ===================================================================

func test_maybe_report_is_noop_when_rig_is_off() -> void:
	PropNet.prof_on = false
	TerrainProfiler.commit_mesh({"total": 1000})
	TerrainProfiler.maybe_report()
	assert_eq(TerrainProfiler._next_report_ms, 0,
			"rig éteint : la barrière ne doit même pas être armée")


func test_maybe_report_arms_then_holds_the_interval() -> void:
	PropNet.prof_on = true
	# Compteurs laissés à zéro EXPRÈS : maybe_report arme la barrière avant de constater
	# qu'il n'y a rien à dire, donc on teste la barrière sans déclencher le print (qui
	# traverse le pont OpenTelemetry et ferait échouer le test sur une erreur moteur).
	TerrainProfiler.maybe_report()
	var armed := TerrainProfiler._next_report_ms
	assert_gt(armed, 0, "premier appel : la barrière est armée")
	# Le point du rig : une ligne toutes les 10 s, pas une par chunk.
	TerrainProfiler.maybe_report()
	assert_eq(TerrainProfiler._next_report_ms, armed,
			"deuxième appel immédiat : pas de réarmement, donc pas de deuxième ligne")
