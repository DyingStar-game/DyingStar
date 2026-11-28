extends RefCounted
## SERVER: the colliders of Nova's scattered rocks — the ones big enough to bump into (NovaScatter.is_solid).
##
## The client draws the scatter and nothing else knows of it; a truck drove through a 40 m outcrop. The
## server lays the same rocks: NovaScatter.lay_chunk is a pure function of the cell hashes and of the
## chunk's grid, and the server's finest collision chunk is built on the very grid the client's finest mesh
## shows (PlanetChunk.generate_collision_shape keeps it as the shape's "nova_grid"). So each colliding rock
## the player sees gets its model's collision where it stands, scaled and turned as drawn: the shapes the
## model's scene carries, else its convex hull (NovaScatter.solid_shapes), one shared Shape3D per model.
## One StaticBody3D per chunk (world layer, mask 0 like every static: ADR 0013), built on a worker, added
## beside the chunk's own body and freed with it (PlanetTerrain's chunk features).
## Loaded by path (PlanetTerrain preloads it): no class_name.

const GlobalsDefs := preload("res://scenes/globals/globals.gd")


## The layers of [param body] that can hold a colliding rock (NovaScatter.layer_descs, models without their
## look), and the collision of each model that can collide made now (NovaScatter.solid_shapes: a hull is tens
## of milliseconds, not for the first chunk's laying to pay). Loads the models: call it on a worker.
static func layer_descs(body: NovaBody, radius: float, default_rock: String) -> Array:
	var descs := NovaScatter.layer_descs(body, radius, default_rock, true).filter(
			func(d: Dictionary) -> bool: return NovaScatter.layer_can_collide(d))
	for d: Dictionary in descs:
		var from: PackedFloat32Array = d.get("solid_scales", PackedFloat32Array())
		for m in mini(from.size(), (d.meshes as Array).size()):
			if from[m] <= float(d.scale_max):
				NovaScatter.solid_shapes(d.meshes[m])
	return descs


## The chunk-local grid the rocks of chunk ([param nside], [param ipix]) stand on: the one [param shape] keeps,
## or, for a shape read back from an older disk cache, the grid of a shape built again (worker only, the cost
## of a chunk's collision).
static func chunk_grid(data: PlanetData, nside: int, ipix: int, shape: ConcavePolygonShape3D) -> PackedVector3Array:
	if shape != null and shape.has_meta("nova_grid"):
		return shape.get_meta("nova_grid")
	var again := PlanetChunk.generate_collision_shape_healpix(data, nside, ipix, data.collision_col_res_for(nside))
	return again.get_meta("nova_grid", PackedVector3Array()) if again != null else PackedVector3Array()


## The colliding rocks of one chunk, as NovaScatter.solid_parts gives them (chunk-local), from its
## [param grid] ((res+1)² points). Pure but for the zones read from [param data]; thread-safe like the
## client's laying. [param cancel]: [false], set to true to stop (an empty answer then).
static func lay(descs: Array, data: PlanetData, body: NovaBody, nside: int, ipix: int, grid: PackedVector3Array,
		origin: Vector3, cancel: Array = []) -> Array:
	var res := roundi(sqrt(float(grid.size()))) - 1
	if res < 1 or descs.is_empty():
		return []
	var vid := PackedInt32Array()
	vid.resize(grid.size())  # the zones answer (zone_context); the grid's ids are only a fallback
	var zones := NovaScatter.zone_context(data, nside, ipix, body)
	return NovaScatter.solid_parts(NovaScatter.lay_chunk(descs, nside, ipix, res, grid, vid, origin, zones,
			cancel, true))


## A StaticBody3D at [param origin] holding [param parts] (lay's: [transform, shape, …]), or null when there
## are none. Not in the tree: safe on a worker. A part's transform carries its rock's scale: Jolt scales the
## shared shape (uniformly) instead of a shape being made for each rock.
static func make_body(parts: Array, key: String, origin: Vector3) -> StaticBody3D:
	if parts.is_empty():
		return null
	var body := StaticBody3D.new()
	body.name = key + "_rocks_col"
	body.position = origin
	body.collision_layer = 0
	body.set_collision_layer_value(GlobalsDefs.LAYER_WORLD, true)
	body.collision_mask = 0
	# Shape owners, not CollisionShape3D nodes: a chunk holds a couple of thousand rocks, and each node
	# entering the tree is main-thread time.
	for part: Array in parts:
		var owner_id := body.create_shape_owner(body)
		body.shape_owner_add_shape(owner_id, part[1])
		body.shape_owner_set_transform(owner_id, part[0])
	return body
