extends Node
## Reproduit la condition d'un pod qui vient de redémarrer : cache de tuiles VIDE au
## moment où warm_bridge_plans() tourne. Puis fait arriver les tuiles et vérifie que le
## rattrapage planifie bien les ponts.

static var OUT: FileAccess = null

func say(t: String) -> void:
	if OUT == null:
		OUT = FileAccess.open("user://bridge_out.txt", FileAccess.WRITE)
	OUT.store_line(t)
	OUT.flush()


func _make_data(cache_root: String):
	var PD = load("res://scenes/planet/planet_data.gd")
	var data = PD.new()
	data.planet_name = "tarsis_3"
	data.chunk_export_depth = 10
	data.chunk_resolution = 32
	data.max_quadtree_depth = 13
	data.corundum_default_biome = true
	data.crack_spacing_m = 4000.0
	data.crack_width_m = 250.0
	data.crack_depth_m = 180.0
	data.chunk_heightmaps_dir = "assets/qgis/export/tarsis_3_chunks"
	data.chunk_heightmap_res = 32
	data.roads_geojson = "assets/qgis/export/tarsis_3_roads_buffered.json"
	var rts := RemoteTileSource.new()
	rts.planet = "tarsis_3"
	rts.version = "ee59ef5f423a73da"
	rts.tile_res = 32
	rts.nside_min = 1
	rts.nside_max = 1024
	rts.request_timeout_ms = 300
	# Transport injecté qui échoue toujours : ce banc n'a pas de service de tuiles, et le
	# transport HTTP par défaut irait attendre une socket. C'est le point d'injection prévu.
	rts.fetcher = func(_url: String) -> Array: return [0, PackedByteArray()]
	rts.cache_root = cache_root
	data.remote_source = rts
	data.apply_chunk_manifest()
	return data


func _ready() -> void:
	# 1) Pod fraîchement démarré : le cache de tuiles n'existe pas.
	var cold := "user://bridge_probe_cold/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cold))
	var data = _make_data(cold)
	say("étape: data construite")
	var t0 := Time.get_ticks_msec()
	var n_spans: int = data.get_bridge_spans().size()
	say("étape: get_bridge_spans -> %d en %d ms" % [n_spans, Time.get_ticks_msec() - t0])
	t0 = Time.get_ticks_msec()
	data.warm_bridge_plans()
	say("étape: warm_bridge_plans en %d ms" % [Time.get_ticks_msec() - t0])
	say("FROID   travées=%d  plans=%d  incomplet=%s" % [
		n_spans, data._bridge_plans.size(), str(data.bridge_plans_incomplete())])

	# 2) Les tuiles arrivent (on rebranche le vrai cache, comme le ferait le streaming).
	data.remote_source.cache_root = "user://tile_cache/"
	var born: PackedStringArray = data.retry_starved_bridge_plans()
	say("RATTRAPÉ nouveaux=%d  plans=%d  incomplet=%s" % [
		born.size(), data._bridge_plans.size(), str(data.bridge_plans_incomplete())])

	# 3) Référence : un client au cache déjà chaud, même code.
	var warm = _make_data("user://tile_cache/")
	warm.warm_bridge_plans()
	say("CHAUD   plans=%d  incomplet=%s" % [
		warm._bridge_plans.size(), str(warm.bridge_plans_incomplete())])
	say("FIN")
	get_tree().quit()
