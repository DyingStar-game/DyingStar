extends Node3D

signal universe_data_retrieved

var is_ready: bool = false

func _ready() -> void:
	is_ready = true

func retrieve_universe_datas() -> void:
	var universe_datas: Dictionary = {}
	var datas_count: int = 0

	for child in get_children():
		if child is PlanetPlaceholder:
			if not universe_datas.has("planets"):
				universe_datas["planets"] = []
			var real_coordinates: Vector3 = child.global_position * 100.0
			var planet_datas: Dictionary = {"name": child.name, "coordinates": real_coordinates}
			universe_datas.planets.append(planet_datas)
			datas_count += 1

		if child is StationPlaceholder:
			if not universe_datas.has("stations"):
				universe_datas["stations"] = []
			var real_coordinates: Vector3 = child.global_position * 100.0
			var stations_datas: Dictionary = {"name": child.name, "coordinates": real_coordinates}
			universe_datas.stations.append(stations_datas)
			datas_count += 1

	if not universe_datas.has("datas_count"):
		universe_datas["datas_count"] = datas_count

	emit_signal("universe_data_retrieved", universe_datas)
