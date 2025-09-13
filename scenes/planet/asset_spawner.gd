@tool
extends Node3D


@export var planet_terrain: PlanetTerrain
@export var min_asset_cell = 3
@export var max_asset_cell = 10
@export var chunk_radius = 1
@export var cell_size = 300.0
@export var spawn_distance = 1200
@export var asset_scenes: Array[PackedScene]

@export var debugmesh: MeshInstance3D

var rnd := RandomNumberGenerator.new()

var planet: Planet

var player_chunks: Dictionary[int, Array]
var loaded_cells: Dictionary[Vector3i, Array]
var last_cell: Vector2i

var focus_positions_last = []

var current_seed = 123

func _ready() -> void:
	planet = owner

func get_local_focus_positions():
	var local_positions = []
	for pos: Vector3 in planet_terrain.focus_positions:
		local_positions.push_back(planet_terrain.to_local(pos))
	return local_positions

func _process(_delta: float) -> void:
	var positions = get_local_focus_positions()
	if not positions_changed(positions): return
	focus_positions_last = positions
	
	for i in planet_terrain.players_ids.size():
		var player_id = planet_terrain.players_ids[i]
		var pos: Vector3 = planet_terrain.focus_positions[i]
		if pos.distance_to(planet_terrain.global_position) < (spawn_distance + planet_terrain.radius):
			var local_pos = planet_terrain.to_local(pos)
			var cell := get_cell_from_position(local_pos, cell_size)
			
			var needed_cells = []
			for dx in range(-chunk_radius, chunk_radius + 1):
				for dy in range(-chunk_radius, chunk_radius + 1):
					for dz in range(-chunk_radius, chunk_radius + 1):
						needed_cells.push_back(cell + Vector3i(dx, dy, dz))
			
			player_chunks[player_id] = needed_cells
	
	update_world_chunks()

func update_world_chunks():
	var needed_chunks = {}
	for chunks in player_chunks.values():
		for cell in chunks:
			needed_chunks[cell] = true

	# Spawn new ones
	for cell in needed_chunks.keys():
		if not loaded_cells.has(cell):
			spawn_cell(cell)

	# Despawn if nobody needs it
	for cell in loaded_cells.keys():
		if not needed_chunks.has(cell):
			despawn_chunk(cell)


func despawn_chunk(cell):
	for asset in loaded_cells[cell]:
		asset.queue_free()
	
	loaded_cells.erase(cell)

func positions_changed(positions: Array) -> bool:
	if positions.size() != focus_positions_last.size():
		return true
	
	for i in positions.size():
		if positions[i] != focus_positions_last[i]:
			if floor(positions[i]) != focus_positions_last[i]:
				return true
	
	return false

func spawn_cell(cell: Vector3i):
	loaded_cells[cell] = generate_asset_in_cell(cell, rnd, cell_size)

func get_cell_from_position(pos: Vector3, cell_size_deg: float) -> Vector3i:
	var dir = pos.normalized()
	var scaled = pos / cell_size_deg
	return Vector3i(scaled)

func get_seed_from_cell(cell_coords: Vector3i) -> int:
	return int(cell_coords.x * 73856093 ^ cell_coords.y * 19349663 ^ cell_coords.z * 83492791)

func generate_asset_in_cell(cell: Vector3i, rng: RandomNumberGenerator, cell_size_value: float):
	var seed = get_seed_from_cell(cell)
	rng.seed = seed
	
	if debugmesh and debugmesh.visible:
		debugmesh.global_position = planet_terrain.to_global(planet_terrain.get_height(Vector3(cell + Vector3i.ONE).normalized()))
	
	var count = rng.randi_range(min_asset_cell, max_asset_cell) # Number of assets in this cell
	var nodes = []
	
	for i in count:
		
		var x = (cell.x + rng.randf() * 0.5) * cell_size_value
		var y = (cell.y + rng.randf() * 0.5) * cell_size_value
		var z = (cell.z + rng.randf() * 0.5) * cell_size_value

		var asset = spawn_asset_at(rng, Vector3(x, y, z))
		nodes.push_back(asset)
		
	return nodes

func spawn_asset_at(rng: RandomNumberGenerator, position: Vector3) -> Node3D:
	var dir = position.normalized()
	var pos = planet_terrain.get_height(dir)
	var asset = asset_scenes[rng.randi() % asset_scenes.size()].instantiate()
	add_child(asset, true)
	asset.global_position = planet_terrain.to_global(pos)
	
	asset.rotation = Vector3(
		rng.randf(),
		rng.randf(),
		rng.randf()
	)
	
	return asset
