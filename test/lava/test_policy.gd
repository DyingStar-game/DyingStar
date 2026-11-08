extends Node

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var simulated := not "--authored-lava" in OS.get_cmdline_user_args()
	var data: PlanetData = SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn").planet_data.duplicate(true)
	data.apply_chunk_manifest(); data.ensure_queries_loaded()
	var key := data.grade_bake_key()
	var ok := data.has_lava() == (not simulated)
	ok = ok and data.get_whole_lava().is_empty() == simulated
	ok = ok and key.contains("simulated_lava_4") == simulated
	var volcano: VolcanoRelief.Volcano
	for ip in 12:
		var candidates := data.get_chunk_volcanoes(1, ip)
		if not candidates.is_empty():
			volcano = candidates[0]
			break
	if volcano == null:
		push_error("No shipped volcano for policy regression"); get_tree().quit(1); return
	volcano.lake = true; volcano.activity = "dormant"
	var features := VolcanoFeatures.build(data, volcano)
	ok = ok and features.has_node("LavaLake") == (not simulated)
	features.free()
	print("LAVA_POLICY mode=", "simulated" if simulated else "normal", " pass=", ok)
	get_tree().quit(0 if ok else 1)
