extends Node
## What a volcano's nodes cost the chunk that owns its summit (PlanetTerrain._acquire_volcano_nodes ->
## VolcanoFeatures.build, inside asm:zones), headless, piece by piece, twice (cold, then warm).
##   <godot> --headless --path . res://test/perf/volcano_build_probe.tscn

const VOLCANO := "@-39.754773,25.066776"
const VOLCANO_SOUND := preload("res://scenes/audio/volcano/volcano_sound.gd")


func _ready() -> void:
	_run.call_deferred()


func _ms(t: int) -> float:
	return (Time.get_ticks_usec() - t) / 1000.0


func _run() -> void:
	var t := Time.get_ticks_usec()
	var data: PlanetData = SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn").planet_data.duplicate(true)
	data.apply_chunk_manifest()
	data.connect_tile_service()
	data.warm_mountains()
	print("[VolcProbe] planet data ready: %.1f ms" % _ms(t))
	var volcano: VolcanoRelief.Volcano = null
	for ip in 12:
		for v: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ip):
			if VolcanoFeatures.key_of(v) == VOLCANO:
				volcano = v
	for round_k in 2:
		t = Time.get_ticks_usec()
		data.ground_albedo_at(volcano.c)
		print("[VolcProbe] %d ground_albedo_at: %.1f ms" % [round_k, _ms(t)])
		t = Time.get_ticks_usec()
		var level := data.volcano_lake_level(volcano)
		print("[VolcProbe] %d volcano_lake_level: %.1f ms" % [round_k, _ms(t)])
		var centre := volcano.c * (data.radius + level)
		t = Time.get_ticks_usec()
		var plume := VolcanoPlume.create(data, volcano, centre)
		print("[VolcProbe] %d VolcanoPlume.create: %.1f ms" % [round_k, _ms(t)])
		t = Time.get_ticks_usec()
		var sound: Node3D = VOLCANO_SOUND.create(plume)
		print("[VolcProbe] %d sound create: %.1f ms" % [round_k, _ms(t)])
		var root := Node3D.new()
		root.add_child(plume)
		if sound != null:
			root.add_child(sound)
		t = Time.get_ticks_usec()
		add_child(root)
		print("[VolcProbe] %d enter the tree: %.1f ms (%d nodes)" % [round_k, _ms(t),
				root.find_children("*", "", true, false).size()])
		t = Time.get_ticks_usec()
		var whole := VolcanoFeatures.build(data, volcano)
		print("[VolcProbe] %d VolcanoFeatures.build whole: %.1f ms" % [round_k, _ms(t)])
		whole.free()
		await get_tree().physics_frame
		t = Time.get_ticks_usec()
		await get_tree().physics_frame
		print("[VolcProbe] %d next physics frame: %.1f ms" % [round_k, _ms(t)])
		root.queue_free()
		await get_tree().process_frame
	get_tree().quit()
