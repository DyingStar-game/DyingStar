class_name BuildingWalkways
extends RefCounted

## The walkways and stairs of a spawn building of more than one storey. Before each upper storey of each
## façade runs a walkway (a deck and its railing) to its doors, and goes on past the end of the building
## as a landing; from it a half-landing stair climbs along the free side of the last container -- two
## half flights a storey on two lanes side by side, back towards the façade, each flight right above the
## one of the storey below: no head meets the flight above.
##
## Built from the building's rows / cols / floors when its apartments are made (SpawnBuilding), on the
## server (its decks are walked on) as on the clients. The decks and railings are boxes made here; a half
## flight is a scene (stair_half_flight.tscn), to be replaced by a model one day.
##
## Frame of a façade: +x out of the doors, z along the façade from 0 to its length, y up from the ground.

const STAIR_SCENE := preload("res://scenes/_universe/structures/buildings/walkways/stair_half_flight.tscn")
const DECK_MATERIAL := preload("res://assets/_universe/_shared/materials/mat_metal_diamondplate2k/mat_metal_diamondplate2k.tres")
## The node they are built under, in the building.
const NODE_NAME := &"Walkways"

## Width (m) of a walkway, out from the doors: a door swings 1.275 m open over it.
const WALKWAY_W := 1.5
## Width (m) of one lane of the stair (a half flight is that wide).
const LANE_W := 1.2
## Depth (m) of the half landing at the back of the flights, along the container's side.
const LANDING_D := 1.2
## Rise and run (m) of a half flight (stair_half_flight.tscn): half a storey.
const HALF_RISE := 1.3
const HALF_RUN := 1.7
## Height (m) of a container's floor over its base: the decks are level with it.
const FLOOR_Y := 0.12
## Thickness (m) of a deck.
const DECK_T := 0.08
## Height (m) of a railing, and the spacing of its posts.
const RAIL_H := 1.0
const POST_STEP := 1.3
## Side (m) of a rail's bar and of a post.
const RAIL_BAR := 0.04
## What the posts of a half flight are named, under it (Post1, Post2...).
const FLIGHT_POST_PREFIX := "Post"
## What the walls at the sides of a half flight are named, under it (SideWall1, SideWall2).
const FLIGHT_WALL_PREFIX := "SideWall"
## What the one mesh of a façade's railings, posts and columns is named, under it.
const RAILINGS_NAME := &"Railings"
## Thickness (m) of the wall a railing is for the bodies.
const RAIL_WALL_T := 0.05
## Side (m) of a column the decks stand on, and the most (m) between two along a walkway.
const COLUMN_W := 0.12
const COLUMN_STEP := 5.2
## How far (m) the stairs stand past the end of a façade: two lanes, along the last container's side.
const STAIR_ZONE := 2.0 * LANE_W
## How far (m) the walkways stand out of the façade.
const STAIR_OUT := WALKWAY_W

static var _rail_material: StandardMaterial3D
static var _plate_material: StandardMaterial3D
## The box meshes made so far, by size and material: three hundred posts are one mesh.
static var _meshes: Dictionary = {}
## The two side walls of a half flight (flight_side_walls), made once: every flight shares them.
static var _side_walls: Array[ConvexPolygonShape3D] = []


## Build them under [param building] (a SpawnBuilding): nothing for one storey, nor twice.
static func build(building: Node3D, rows: int, cols: int, floors: int, x_spacing: float, z_spacing: float,
		y_spacing: float) -> void:
	if floors < 2 or building.has_node(NodePath(NODE_NAME)):
		return
	var root := Node3D.new()
	root.name = NODE_NAME
	root.add_to_group(TerrainBlend.NO_FRINGE_GROUP)  # a fringe dresses the ground, not 300 rails
	var length: float = cols * z_spacing
	for row in rows:
		# The façade is the body its decks are walked on, their meshes under it: there the footsteps read
		# what it is made of (SurfaceProbe).
		var facade := StaticBody3D.new()
		facade.name = "Facade%d" % row
		facade.collision_mask = 0
		facade.transform = facade_transform(row, cols, x_spacing, z_spacing)
		root.add_child(facade)
		_build_facade(facade, length, floors, y_spacing)
	building.add_child(root)


## What the warm-up draws (Warmup.RUNTIME_SURFACES) so the walkways' shaders are compiled before the first
## building: [mesh, [materials]] for each vertex format and material they are drawn with -- the railings' batch,
## the decks' and posts' boxes, and a half flight's meshes, its treads in the plate. No scene names these
## materials: the first building waited 212 ms for them in game (2026-11-28).
static func warm_surfaces() -> Array:
	var batch := BoxBatch.new()
	batch.add(Vector3.ONE, Vector3.ZERO)
	var out: Array = [[batch.commit(_rail_mat()), [_rail_mat()]], [_mesh(Vector3.ONE, null), [_plate(), _rail_mat()]]]
	var flight: Node = STAIR_SCENE.instantiate()
	for node in flight.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var tread: bool = str(mi.name).begins_with("Tread")
		out.append([mi.mesh, [_plate()] if tread else ([mi.material_override] if mi.material_override else [])])
	flight.free()
	return out


## The frame of the façade of row [param row]: the second row is turned to face the other way, its doors
## at x = 2 x_spacing.
static func facade_transform(row: int, cols: int, x_spacing: float, z_spacing: float) -> Transform3D:
	if row == 0:
		return Transform3D.IDENTITY
	return Transform3D(Basis(Vector3.UP, PI), Vector3(2.0 * x_spacing, 0.0, cols * z_spacing))


## The height of the deck of storey [param floor] (0: the ground the stairs start from).
static func level_y(floor_index: int, y_spacing: float) -> float:
	return floor_index * y_spacing + FLOOR_Y


## The railings, posts and columns of a façade are one mesh (RAILINGS_NAME), not a node each: they were 150
## of a building's 220 walkway nodes, each a draw, and each walked when it entered the building (its draw
## distance, StructureDrawRange) — 10 ms of the 13 its walkways took to build (2026-11-28). The decks stay
## nodes of their own: the footsteps read the plate's material from the smallest mesh under the foot.
static func _build_facade(facade: StaticBody3D, length: float, floors: int, y_spacing: float) -> void:
	var rails := BoxBatch.new()
	_add_facade(facade, rails, length, floors, y_spacing)
	var railings := MeshInstance3D.new()
	railings.name = RAILINGS_NAME
	railings.mesh = rails.commit(_rail_mat())
	facade.add_child(railings)


static func _add_facade(facade: StaticBody3D, rails: BoxBatch, length: float, floors: int,
		y_spacing: float) -> void:
	var outer: float = length + STAIR_ZONE  # the far edge of the lanes, past the end of the façade
	var back: float = -HALF_RUN  # where the flights meet the half landing, along the side
	for f in range(1, floors):
		var y: float = level_y(f, y_spacing)
		var half: float = level_y(f - 1, y_spacing) + HALF_RISE
		# The walkway, going on past the end as the landing the flights leave from and come back to.
		_deck(facade, Vector3(0.0, y, 0.0), Vector3(WALKWAY_W, y, outer))
		_rail(facade, rails, Vector3(WALKWAY_W, y, 0.0), Vector3(WALKWAY_W, y, outer))
		_rail(facade, rails, Vector3(0.0, y, 0.0), Vector3(WALKWAY_W, y, 0.0))
		_rail(facade, rails, Vector3(0.0, y, outer), Vector3(WALKWAY_W, y, outer))
		if f == floors - 1:
			_rail(facade, rails, Vector3(0.0, y, length), Vector3(0.0, y, length + LANE_W))  # no flight goes on up
		# The half landing at the back, against the container's side.
		_deck(facade, Vector3(back - LANDING_D, half, length), Vector3(back, half, outer))
		_rail(facade, rails, Vector3(back - LANDING_D, half, length), Vector3(back - LANDING_D, half, outer))
		_rail(facade, rails, Vector3(back - LANDING_D, half, outer), Vector3(back, half, outer))
		# Up from the storey below on the lane by the wall, away from the façade; then back towards it on
		# the outer lane, to this storey's landing.
		_flight(facade, Transform3D(Basis(Vector3.UP, -PI / 2.0), Vector3(0.0, level_y(f - 1, y_spacing), length)))
		_flight(facade, Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(back, half, outer)))
	# The columns the decks stand on, up from the ground: along the walkway's outer edge, at both ends and
	# every COLUMN_STEP at most, and at the half landing's back corners -- clear of the flights.
	var top: float = level_y(floors - 1, y_spacing) - DECK_T
	var half_top: float = level_y(floors - 2, y_spacing) + HALF_RISE - DECK_T
	var edge: float = COLUMN_W * 0.5
	for z in column_stations(outer, COLUMN_STEP):
		_column(facade, rails, Vector3(WALKWAY_W - edge, 0.0, z), top)
	_column(facade, rails, Vector3(back - LANDING_D + edge, 0.0, length + edge), half_top)
	_column(facade, rails, Vector3(back - LANDING_D + edge, 0.0, outer - edge), half_top)


## Where the columns stand along an edge [param length] long: both ends, and evenly between them no more
## than [param step] apart (each a column's half side in from the ends). Pure, for the tests.
static func column_stations(length: float, step: float) -> Array[float]:
	var first: float = COLUMN_W * 0.5
	var last: float = length - COLUMN_W * 0.5
	var spans: int = maxi(1, ceili((last - first) / step))
	var out: Array[float] = []
	for i in spans + 1:
		out.append(lerpf(first, last, float(i) / spans))
	return out


## A column from the ground at [param foot] up to [param top] (the underside of the deck it carries).
static func _column(facade: StaticBody3D, rails: BoxBatch, foot: Vector3, top: float) -> void:
	var size := Vector3(COLUMN_W, top, COLUMN_W)
	var centre: Vector3 = foot + Vector3.UP * top * 0.5
	rails.add(size, centre)
	_shape(facade, size, centre)


static func _flight(facade: Node3D, place: Transform3D) -> void:
	var flight: Node3D = STAIR_SCENE.instantiate()
	flight.transform = place
	for tread in flight.find_children("Tread*", "MeshInstance3D", false, false):
		(tread as MeshInstance3D).material_override = _plate()
	# The posts its two rails stand on: the scene only has the sloped bars, which hung in the air at
	# both ends wherever no deck railing happened to end there.
	var feet: Array[Vector3] = flight_post_feet()
	for i in feet.size():
		var post := MeshInstance3D.new()
		post.name = "%s%d" % [FLIGHT_POST_PREFIX, i + 1]
		post.mesh = _mesh(Vector3(RAIL_BAR, RAIL_H, RAIL_BAR), _rail_mat())
		post.position = feet[i] + Vector3.UP * RAIL_H * 0.5
		flight.add_child(post)
	# And a wall under each rail, for the bodies: the scene only has the ramp walked on, so one stepped
	# through the posts and off the side of a flight, where a deck's railing holds (_rail).
	if _side_walls.is_empty():
		for points: PackedVector3Array in flight_side_walls():
			var hull := ConvexPolygonShape3D.new()
			hull.points = points
			_side_walls.append(hull)
	for i in _side_walls.size():
		var wall := CollisionShape3D.new()
		wall.name = "%s%d" % [FLIGHT_WALL_PREFIX, i + 1]
		wall.shape = _side_walls[i]
		flight.add_child(wall)
	facade.add_child(flight)


## The walls at the sides of a half flight, in its frame, each as the corners of its hull: under each
## rail, RAIL_WALL_T thick, from the slope up to the rail (RAIL_H) along the whole run -- upright at both
## ends, so nothing stands out past the flight where one walks up to it. Both ends stay open. Pure, for
## the tests.
static func flight_side_walls() -> Array[PackedVector3Array]:
	var inset: float = RAIL_BAR * 0.5
	var out: Array[PackedVector3Array] = []
	for x: float in [inset, LANE_W - inset]:
		var corners := PackedVector3Array()
		for side: float in [-RAIL_WALL_T * 0.5, RAIL_WALL_T * 0.5]:
			corners.append(Vector3(x + side, 0.0, 0.0))
			corners.append(Vector3(x + side, RAIL_H, 0.0))
			corners.append(Vector3(x + side, HALF_RISE, HALF_RUN))
			corners.append(Vector3(x + side, HALF_RISE + RAIL_H, HALF_RUN))
		out.append(corners)
	return out


## The feet of the posts of a half flight, in its frame (x across the lane, y up, z along the run): on
## both sides, at both ends of the rail and no more than POST_STEP apart between them, each standing on
## the slope and RAIL_H tall (the rail runs RAIL_H over the slope). Pure, for the tests.
static func flight_post_feet() -> Array[Vector3]:
	var inset: float = RAIL_BAR * 0.5
	var spans: int = maxi(1, ceili(HALF_RUN / POST_STEP))
	var out: Array[Vector3] = []
	for x: float in [inset, LANE_W - inset]:
		for i in spans + 1:
			var z: float = lerpf(inset, HALF_RUN - inset, float(i) / spans)
			out.append(Vector3(x, z * HALF_RISE / HALF_RUN, z))
	return out


## A deck whose top spans [param from] .. [param to] (their y: the top).
static func _deck(facade: StaticBody3D, from: Vector3, to: Vector3) -> void:
	var size := Vector3(absf(to.x - from.x), DECK_T, absf(to.z - from.z))
	var centre := Vector3((from.x + to.x) * 0.5, from.y - DECK_T * 0.5, (from.z + to.z) * 0.5)
	var instance := MeshInstance3D.new()
	instance.mesh = _mesh(size, _plate())
	instance.position = centre
	facade.add_child(instance)
	_shape(facade, size, centre)


## A railing along the deck edge [param from] .. [param to]: a top rail, a middle rail and posts (into
## [param rails]), and a wall of the same height for the bodies.
static func _rail(facade: StaticBody3D, rails: BoxBatch, from: Vector3, to: Vector3) -> void:
	var along: Vector3 = to - from
	var length: float = along.length()
	if length < 0.01:
		return
	var on_z: bool = absf(along.z) > absf(along.x)
	var bar := Vector3(0.04, 0.04, length) if on_z else Vector3(length, 0.04, 0.04)
	var mid: Vector3 = (from + to) * 0.5
	rails.add(bar, mid + Vector3.UP * RAIL_H)
	rails.add(bar, mid + Vector3.UP * RAIL_H * 0.5)
	var posts: int = maxi(1, ceili(length / POST_STEP))
	for i in posts + 1:
		rails.add(Vector3(0.04, RAIL_H, 0.04), from + along * (float(i) / posts) + Vector3.UP * RAIL_H * 0.5)
	var wall := Vector3(0.05, RAIL_H, length) if on_z else Vector3(length, RAIL_H, 0.05)
	_shape(facade, wall, mid + Vector3.UP * RAIL_H * 0.5)


## A box shape of [param facade], in its frame.
static func _shape(facade: StaticBody3D, size: Vector3, centre: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = centre
	facade.add_child(shape)


## The box mesh of [param size] in [param material], made once.
static func _mesh(size: Vector3, material: Material) -> BoxMesh:
	var key := [size.snapped(Vector3.ONE * 0.001), material]
	if not _meshes.has(key):
		var mesh := BoxMesh.new()
		mesh.size = size
		mesh.material = material
		_meshes[key] = mesh
	return _meshes[key]


## The deck plate, its texture laid at its true size (1 m, material.json) whatever the box: a box mesh
## stretches it over each face, 18 m of walkway or 24 cm of tread alike. Same id (the footsteps read it).
static func _plate() -> StandardMaterial3D:
	if _plate_material == null:
		_plate_material = DECK_MATERIAL.duplicate()
		_plate_material.uv1_triplanar = true
		_plate_material.uv1_scale = Vector3.ONE
	return _plate_material


static func _rail_mat() -> StandardMaterial3D:
	if _rail_material == null:
		_rail_material = StandardMaterial3D.new()
		_rail_material.resource_name = "mat_metal_railing"  # a metal family for the footsteps (SurfaceProbe)
		_rail_material.albedo_color = Color(0.82, 0.83, 0.85)
		_rail_material.metallic = 0.6
		_rail_material.roughness = 0.4
	return _rail_material


## Axis-aligned boxes gathered into one mesh, their vertices written here. SurfaceTool.append_from read each
## source box back from the GPU (Mesh.surface_get_arrays -> RenderingDevice.buffer_get_data, which stalls
## until every frame in flight is done): 24-275 ms a building in game, free headless (2026-11-28).
class BoxBatch:
	## Each face of a box: its normal and two axes across it, u x v = the normal.
	const FACES: Array[Array] = [
		[Vector3.RIGHT, Vector3.UP, Vector3.BACK], [Vector3.LEFT, Vector3.BACK, Vector3.UP],
		[Vector3.UP, Vector3.BACK, Vector3.RIGHT], [Vector3.DOWN, Vector3.RIGHT, Vector3.BACK],
		[Vector3.BACK, Vector3.RIGHT, Vector3.UP], [Vector3.FORWARD, Vector3.UP, Vector3.RIGHT],
	]

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	## A box of [param size] around [param centre].
	func add(size: Vector3, centre: Vector3) -> void:
		var half: Vector3 = size * 0.5
		for face: Array in FACES:
			var n: Vector3 = face[0]
			var du: Vector3 = (face[1] as Vector3) * half
			var dv: Vector3 = (face[2] as Vector3) * half
			var mid: Vector3 = centre + n * half
			var base: int = vertices.size()
			vertices.append_array([mid - du - dv, mid + du - dv, mid + du + dv, mid - du + dv])
			normals.append_array([n, n, n, n])
			# Clockwise seen from outside: Godot's front faces.
			indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2])

	## The boxes as one mesh in [param material].
	func commit(material: Material) -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, material)
		return mesh
