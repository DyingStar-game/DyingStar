class_name TerrainProfiler
extends RefCounted
## Profilage de la génération de terrain — phase 0 de [code]docs/PLANET_CHUNK_STREAMING.md[/code].
##
## L'étude conclut qu'il faut streamer les TUILES d'élévation plutôt que les meshes, sur des
## chiffres de volume. Mais l'autre problème posé au départ — « le calcul des chunks » — n'avait
## jamais été mesuré : le seul chrono existant ([method PlanetTerrain._assemble_visual_chunk])
## était commenté, et le seul actif (le [code]print[/code] serveur de [code]_create_chunk[/code])
## sortait une ligne PAR CHUNK, ce qui coûte des millisecondes via le pont OpenTelemetry et fausse
## la mesure qu'il prétend faire.
##
## Ce rig répond à deux questions, et à rien d'autre :
##
## 1. [b]Où part le temps de génération d'un chunk ?[/b] Si la lecture de tuile y est marginale, le
##    streaming ne touchera jamais au coût CPU et il faut chercher ailleurs. C'est la ligne
##    [code]tuiles: N% du temps mesh[/code] qui tranche, et elle seule.
## 2. [b]Combien de tuiles distinctes une vraie session touche-t-elle, à quels niveaux ?[/b] La
##    section 3 du doc l'estime par simulation de [code]_traverse[/code] (273 tuiles / 1,07 MiB) et
##    par reconstitution depuis le cache de meshes ; ici c'est mesuré. Ce chiffre dimensionne le
##    cache client, le prefetch et l'egress.
##
## S'arme comme les autres compteurs manuels du projet ([code]PropNet.prof_on[/code]) : [code]--perf[/code],
## [code]DS_PERF=1[/code], ou [code][debug] perf[/code] dans l'ini. Éteint, le coût est d'un test
## booléen par section instrumentée.
##
## [b]Modèle de threads.[/b] [method PlanetChunk.generate_mesh] tourne sur [WorkerThreadPool] et
## n'écrit jamais dans un compteur partagé : il remplit un [Dictionary] local à l'appel, que le
## thread principal reverse ici via [method commit_mesh] une fois la tâche terminée. Le recensement
## de tuiles, lui, est écrit depuis les workers et porte son propre mutex dans [PlanetData].

## Intervalle du récapitulatif agrégé. Une ligne toutes les 10 s, jamais une par chunk.
const REPORT_INTERVAL_MS := 10000

## Statique : les 18 planètes partagent les compteurs, une seule doit imprimer.
static var _next_report_ms: int = 0
## Bornes de la fenêtre précédente, pour exprimer les demandes de tuiles en débit INSTANTANÉ.
##
## Première tentative : un cumul divisé par le temps écoulé depuis le premier rapport. Faux, et
## visiblement faux — le relevé imprimait 3 327 000 dem/s puis 665, 333, 222, 166… une décroissance
## en 1/t. Les compteurs commencent à s'accumuler dès l'armement du rig, bien avant le premier
## rapport, donc le numérateur était déjà à 6654 quand le dénominateur valait ~0. Un débit fenêtré
## (delta demandes / delta temps) n'a pas ce défaut, et répond en plus à la vraie question : est-ce
## un pic de chargement ou un régime permanent ?
static var _prev_report_ms: int = 0
static var _prev_requests: int = 0


## Reverse dans les compteurs partagés le [Dictionary] de phases rempli par une tâche worker.
## À n'appeler que depuis le thread principal, après complétion de la tâche — c'est ce qui rend
## [code]PropNet.prof_chunk_*[/code] sûr sans verrou.
static func commit_mesh(prof: Dictionary) -> void:
	if prof.is_empty():
		return
	PropNet.prof_chunk_calls += 1
	PropNet.prof_chunk_total_usec += int(prof.get("total", 0))
	PropNet.prof_chunk_prepare_usec += int(prof.get("prepare", 0))
	PropNet.prof_chunk_verts_usec += int(prof.get("verts", 0))
	PropNet.prof_chunk_index_usec += int(prof.get("index", 0))
	PropNet.prof_chunk_normals_usec += int(prof.get("normals", 0))
	PropNet.prof_chunk_skirt_usec += int(prof.get("skirt", 0))
	PropNet.prof_chunk_overlay_usec += int(prof.get("overlay", 0))
	PropNet.prof_chunk_surface_usec += int(prof.get("surface", 0))
	PropNet.prof_chunk_tile_usec += int(prof.get("tile", 0))
	PropNet.prof_norm_sample_usec += int(prof.get("normals_sample", 0))
	PropNet.prof_norm_crack_usec += int(prof.get("normals_crack", 0))


## Imprime le récapitulatif si l'intervalle est écoulé. No-op quand le rig est éteint.
## Ne remet PAS les compteurs à zéro : ce sont des totaux de session, pour que la dernière ligne
## du log soit le bilan complet.
static func maybe_report(backlog: int = 0, tasks: int = 0) -> void:
	if not PropNet.prof_on:
		return
	# Instantané du pipeline, pris à chaque appel : c'est l'état à l'instant du rapport
	# qui intéresse, pas un cumul.
	PropNet.prof_backlog = backlog
	PropNet.prof_tasks = tasks
	var now := Time.get_ticks_msec()
	if now < _next_report_ms:
		return
	_next_report_ms = now + REPORT_INTERVAL_MS
	if PropNet.prof_chunk_calls == 0 and PlanetData.prof_tile_requests == 0:
		return
	report_now()


## Le récapitulatif lui-même, sans la barrière d'intervalle.
##
## Il ne fait qu'imprimer : chaque ligne est construite par une fonction pure ci-dessous. C'est
## délibéré — les lignes sont ainsi vérifiables sans imprimer, ce qui compte ici pour deux raisons.
## D'abord une arité erronée dans un [code]%[/code] est une erreur d'EXÉCUTION qu'aucun parse check
## n'attrape, et ce rig n'est allumé que sur les machines où l'on chasse déjà un problème.
## Ensuite [code]print[/code] traverse CustomLogger -> Obs -> le pont OpenTelemetry C#, qui peut
## lever (assembly manquante) : un test qui imprime mesure la santé du pont, pas celle du rig.
static func report_now() -> void:
	print("[TerrainProf] %s" % phase_line())
	print("[TerrainProf] %s" % cost_line())
	if PropNet.prof_gate_pass + PropNet.prof_gate_defer > 0:
		print("[TerrainProf] garde: %d acceptés, %d différés (dont %d présence inconnue) "
				% [PropNet.prof_gate_pass, PropNet.prof_gate_defer, PropNet.prof_gate_unknown]
				+ "| backlog=%d tâches=%d" % [PropNet.prof_backlog, PropNet.prof_tasks])
	print("[TerrainProf] %s" % normals_line())
	print("[TerrainProf] %s" % tile_census_line())


## Découpage par phase, en pourcentage du temps mesh. Les phases suivent les sections
## [code]# --- ... ---[/code] de [method PlanetChunk.generate_mesh].
static func phase_line() -> String:
	var n := maxi(PropNet.prof_chunk_calls, 1)
	var tot := maxi(PropNet.prof_chunk_total_usec, 1)
	# Un client tiède sert la quasi-totalité de ses chunks depuis le cache disque : le premier
	# relevé montre 3 meshes générés pour 488 assemblés. Sans ce ratio, "mean=28.99ms" se lit
	# comme le coût d'un chunk alors que 99,4 % des chunks ne le paient jamais.
	var cache_tag := ""
	if PropNet.prof_asm_calls > 0:
		cache_tag = " (%d assemblés, %.1f%% depuis le cache)" % [
			PropNet.prof_asm_calls,
			100.0 * float(maxi(PropNet.prof_asm_calls - PropNet.prof_chunk_calls, 0))
					/ float(PropNet.prof_asm_calls)]
	return ("meshes=%d%s mean=%.2fms | prepare=%.0f%% verts=%.0f%% index=%.0f%% "
			+ "normals=%.0f%% skirt=%.0f%% overlay=%.0f%% surface=%.0f%%") % [
		PropNet.prof_chunk_calls, cache_tag, float(tot) / float(n) / 1000.0,
		_pc(tot, PropNet.prof_chunk_prepare_usec), _pc(tot, PropNet.prof_chunk_verts_usec),
		_pc(tot, PropNet.prof_chunk_index_usec), _pc(tot, PropNet.prof_chunk_normals_usec),
		_pc(tot, PropNet.prof_chunk_skirt_usec), _pc(tot, PropNet.prof_chunk_overlay_usec),
		_pc(tot, PropNet.prof_chunk_surface_usec)]


## LA ligne qui décide de la phase 3 : la part du temps mesh passée à lire des tuiles est exactement
## ce qu'un passage en streaming déplacerait sur le réseau. Le reste du coût ne bougerait pas.
## Porte aussi les postes hors génération : assemblage, collision serveur, cache disque.
##
## Quand AUCUN mesh n'a été généré, la part relative n'a pas de sens et le premier run serveur l'a
## montré en imprimant [code]tuiles=3323000.0%[/code] (un total nul ramené à 1 µs par le garde
## anti-division). Ce cas est normal et fréquent — un serveur ne génère jamais de mesh, il ne fait
## que de la collision, et sans joueur résident il ne construit rien du tout — donc la ligne bascule
## sur des valeurs absolues plutôt que d'afficher un pourcentage faux.
static func cost_line() -> String:
	var head := ""
	if PropNet.prof_chunk_calls > 0:
		var n := PropNet.prof_chunk_calls
		var tot := maxi(PropNet.prof_chunk_total_usec, 1)
		# prof_chunk_tile_usec, PAS le compteur global : seul le temps de tuile mesuré
		# DANS generate_mesh est comparable au temps mesh (cf. le 144 % du premier relevé).
		head = "tuiles=%.1f%% du temps mesh (%.2fms/mesh)" % [
			_pc(tot, PropNet.prof_chunk_tile_usec),
			float(PropNet.prof_chunk_tile_usec) / float(n) / 1000.0]
	else:
		head = "tuiles=%.1fms cumulées, %.1fµs/demande (aucun mesh généré)" % [
			float(PlanetData.prof_tile_usec) / 1000.0,
			float(PlanetData.prof_tile_usec) / float(maxi(PlanetData.prof_tile_requests, 1))]
	return head + (" | asm=%d×%.2fms col=%d×%.2fms | cache save=%d×%.2fms load=%d×%.2fms" % [
		PropNet.prof_asm_calls,
		float(PropNet.prof_asm_usec) / float(maxi(PropNet.prof_asm_calls, 1)) / 1000.0,
		PropNet.prof_col_calls,
		float(PropNet.prof_col_usec) / float(maxi(PropNet.prof_col_calls, 1)) / 1000.0,
		PropNet.prof_cache_save_calls,
		float(PropNet.prof_cache_save_usec) / float(maxi(PropNet.prof_cache_save_calls, 1)) / 1000.0,
		PropNet.prof_cache_load_calls,
		float(PropNet.prof_cache_load_usec) / float(maxi(PropNet.prof_cache_load_calls, 1)) / 1000.0])


## Décomposition de la phase "normals" — le poste dominant de la génération.
## Le correctif n'est pas le même selon que le temps part dans l'échantillonnage de
## hauteur (4 lookups par sommet) ou dans crack_offset (4 Voronoï 3D par sommet, actifs
## sur la seule tarsis_3). Le reliquat est le repère tangent et le produit vectoriel.
static func normals_line() -> String:
	var norm := PropNet.prof_chunk_normals_usec
	if norm <= 0:
		return "normals: aucun relevé"
	var sm := PropNet.prof_norm_sample_usec
	var ck := PropNet.prof_norm_crack_usec
	var n := maxi(PropNet.prof_chunk_calls, 1)
	return ("normals=%.1fms/mesh | échantillons %.0f%% (%.1fms) crack %.0f%% (%.1fms) "
			+ "reste %.0f%% (%.1fms)") % [
		float(norm) / float(n) / 1000.0,
		_pc(norm, sm), float(sm) / float(n) / 1000.0,
		_pc(norm, ck), float(ck) / float(n) / 1000.0,
		_pc(norm, norm - sm - ck), float(norm - sm - ck) / float(n) / 1000.0]


## Recensement des tuiles distinctes, par niveau de pyramide. C'est le chiffre que la phase 0
## doit produire : il dimensionne le cache client, le prefetch et l'egress.
static func tile_census_line() -> String:
	var per_level: Dictionary = {}
	var distinct := 0
	var reqs := 0
	var disk := 0
	PlanetData.prof_tile_mutex.lock()
	# Les clés ont la forme "hp_n<nside>_p<ipix>" : la tranche entre l'index 4 et "_p" est le nside.
	for k: String in PlanetData.prof_tiles_seen:
		var cut := k.find("_p")
		if cut < 4:
			continue
		var ns_txt := k.substr(4, cut - 4)
		per_level[ns_txt] = int(per_level.get(ns_txt, 0)) + 1
	distinct = PlanetData.prof_tiles_seen.size()
	reqs = PlanetData.prof_tile_requests
	disk = PlanetData.prof_tile_disk_reads
	# Qui demande ces tuiles. Sans cette ventilation, "6654 demandes sans un seul chunk
	# construit" reste un mystère au lieu d'être une piste.
	var per_caller: Dictionary = PlanetData.prof_sampler_calls.duplicate()
	PlanetData.prof_tile_mutex.unlock()

	var callers := ""
	for entry: String in per_caller:
		callers += " %s=%d" % [entry, int(per_caller[entry])]

	var levels: Array = []
	for ns_txt: String in per_level:
		levels.append([int(ns_txt), int(per_level[ns_txt])])
	levels.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0])
	var lv := ""
	for e: Array in levels:
		lv += " n%d:%d" % [e[0], e[1]]
	var rate := ""
	var now := Time.get_ticks_msec()
	var window_ms := now - _prev_report_ms
	if _prev_report_ms > 0 and window_ms > 0:
		rate = "%.0f dem/s, " % (float(reqs - _prev_requests) * 1000.0 / float(window_ms))
	_prev_report_ms = now
	_prev_requests = reqs

	# Tuiles lues par appel d'échantillonneur. Le premier relevé donne 2,0 : chaque
	# échantillon de hauteur touche sa tuile PLUS une voisine (le chemin bilinéaire va
	# chercher W/E/S/N sur les bords). C'est un multiplicateur qui compte directement
	# dans le dimensionnement d'un cache réseau.
	var sampler_total := 0
	for entry: String in per_caller:
		sampler_total += int(per_caller[entry])
	var ratio := ""
	if sampler_total > 0:
		ratio = " %.1f tuiles/appel" % (float(reqs) / float(sampler_total))

	return "tuiles distinctes=%d (%s%d demandes, %d lectures disque)%s%s |%s" % [
		distinct, rate, reqs, disk, callers, ratio, lv]


## Remet à zéro tout ce que ce rig accumule, des deux côtés (PropNet et PlanetData).
static func reset() -> void:
	PropNet.prof_reset()
	PlanetData.prof_tiles_reset()
	_next_report_ms = 0
	_prev_report_ms = 0
	_prev_requests = 0


## Part d'un total, en pourcent. Sert uniquement au formatage des lignes de log.
static func _pc(total_usec: int, usec: int) -> float:
	return 100.0 * float(usec) / float(maxi(total_usec, 1))
