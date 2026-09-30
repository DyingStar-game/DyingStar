class_name StarMapCanyons
extends StarMapTileLines
## The canyons of ONE body, drawn as lines from the heights where its ground cannot hold them.
##
## The canyons of a corundum world are not in its tiles: the game carves them as it builds a chunk, from
## a network it computes. Near the ground the chart does the same and they are real relief
## ([method StarMapRelief.detail_nside]). Higher up a canyon is a few pixels wide, under the pitch of any
## mesh the chart can afford — and it is still the thing you are looking for: where the plateau is cut,
## which way round a chasm the road goes. So from up there the network is drawn the way the roads are,
## as lines laid on the ground.
##
## Traced from the network itself, not from a height: the blocks between the canyons are the cells of a
## Voronoi diagram, so a canyon runs wherever two neighbouring points of the ground stand on different
## blocks. Asking which block a point is on needs no vertex every hundred metres — a point every
## kilometre finds every crossing of a network four kilometres across — which is what makes it
## affordable from a height where the ground itself is sampled every few kilometres.

## What a canyon is drawn in: the shadow it is from above.
const COLOUR: Color = Color(0.10, 0.08, 0.07)
## How far the canyons float over the ground: two thirds of what the roads do, so a road crossing a
## canyon is drawn OVER it, as the bridge it crosses on is. At the same height the two fought for the
## same pixels and the canyon, drawn last, won.
const UNDER_THE_ROADS: float = LIFT * 2.0 / 3.0
## Drawn before anything else that blends, for the same reason.
const RENDER_PRIORITY: int = -1
## How many points across one block of the network the tracing looks at. Four finds every canyon
## between two blocks; fewer steps over the narrow end of a block and leaves gaps.
const SAMPLES_PER_BLOCK: float = 4.0
## Bounds on the points along one side of a tile. The upper one is what a tile costs at most — each
## point is a Voronoi lookup — and decides, with the one above, the coarsest tile that is traced at all.
const GRID_MIN: int = 4
const GRID_MAX: int = 64
## How many pixels a block must span for the network to be drawn at all, and from how many it is drawn
## in full. Under the first the lines are closer together than they are wide and the plateau turns into
## a grey wash; between the two they fade in.
const BLOCK_PIXELS_MIN: float = 6.0
const BLOCK_PIXELS_FULL: float = 14.0

## Set by [method _available], once per body: the planet the network is read from, or null.
var _data: PlanetData = null
var _looked: bool = false


func _ready() -> void:
	super()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# The strips are seen from above whichever way their corners were wound.
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.render_priority = RENDER_PRIORITY


## Draw the network over [param tiles] — the ground's own tiles, and only those the ground draws FLAT:
## a tile fine enough to carry the canyons as relief needs no line over them.
##
## [param metres_per_pixel] is how much ground a pixel covers under the camera, which is what decides
## whether a network of this size can be read at all; see [method strength].
func show_over(tiles: Dictionary, metres_per_pixel: float) -> void:
	var alpha: float = 0.0
	if _available():
		alpha = strength(_data.crack_spacing_m, metres_per_pixel)
	visible = alpha > 0.0
	if not visible:
		return  # nothing laid while nothing shows: coming back down pays for the view it arrives at
	_material.albedo_color = Color(1.0, 1.0, 1.0, alpha)
	var traced: Dictionary = {}
	for id: int in tiles:
		if traces(_data, StarMapGround.id_nside(id)):
			traced[id] = true
	refresh(traced)


## How strongly the network is drawn, 0 to 1, for blocks [param spacing_m] across seen at
## [param metres_per_pixel].
static func strength(spacing_m: float, metres_per_pixel: float) -> float:
	if spacing_m <= 0.0 or metres_per_pixel <= 0.0:
		return 0.0
	return smoothstep(BLOCK_PIXELS_MIN, BLOCK_PIXELS_FULL, spacing_m / metres_per_pixel)


## Is a tile of this level traced? Not one so fine that the ground carves the canyons itself, and not
## one so wide that [constant GRID_MAX] points a side would step over them.
static func traces(data: PlanetData, nside: int) -> bool:
	if StarMapRelief.tile_pitch(data.radius, nside) < data.crack_width_m * 0.5:
		return false
	return _grid_for(data, nside) <= GRID_MAX


## Points along one side of a tile of this level: [constant SAMPLES_PER_BLOCK] to a block.
static func _grid_for(data: PlanetData, nside: int) -> int:
	var side_m: float = HEALPix.pixel_side_length(nside, 1.0) * data.radius
	return maxi(GRID_MIN, ceili(side_m * SAMPLES_PER_BLOCK / data.crack_spacing_m))


func _available() -> bool:
	if not _looked:
		_looked = true
		var data: PlanetData = StarMapTiles.for_body(body_key).data if body_key != "" else null
		if data != null and data.corundum_default_biome and data.radius > 0.0 \
				and data.crack_spacing_m > 0.0 and data.crack_width_m > 0.0:
			_data = data
	return _data != null


func _laying() -> Array:
	var data: PlanetData = _data
	# Built on first use, and this is the main thread: the worker must find it made.
	data.crack_noise()
	return [func(id: int) -> Array:
		return trace_tile(data, StarMapGround.id_nside(id), StarMapGround.id_ipix(id)), true]


func _release() -> void:
	_data = null
	_looked = false


# ---------------------------------------------------------------------------

## The canyons crossing one tile, as line segments laid on the ground that tile draws. Static and
## handed everything, because it runs on a worker.
##
## A grid of points over the tile, each asked which block it stands on. Along every side of every
## square of that grid whose two ends stand on different blocks, a canyon crosses, at the point halfway
## between the two blocks' feature points. A square crossed twice holds one stretch of canyon; one
## crossed three or four times holds a fork, drawn from its middle.
##
## Only where the game carves: a stretch whose middle the sampler leaves whole — a town's sphere, a
## massif, ground that is not corundum — is not drawn. Asked of the sampler's own carve, so the chart
## has no rule of its own to fall out of step with.
static func trace_tile(data: PlanetData, nside: int, ipix: int) -> Array:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	var grid_res: int = _grid_for(data, nside)
	var noise: CrackNoise = data.crack_noise()
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(nside, ipix, grid_res)
	var stride: int = grid_res + 1
	var read_at := PackedVector3Array()
	var blocks := PackedVector3Array()
	for vy: int in range(stride):
		for vx: int in range(stride):
			var cell: Array[Vector3] = ArideDesertCorundumPlateauTerrain.crack_cell(
					grid[vy][vx], data.radius, data.crack_spacing_m, noise)
			read_at.append(cell[0])
			blocks.append(cell[1])
	# Where a canyon crosses each side of the grid, or ZERO. Sides going right, then sides going down.
	var right := PackedVector3Array()
	var down := PackedVector3Array()
	right.resize(stride * stride)
	down.resize(stride * stride)
	for vy: int in range(stride):
		for vx: int in range(stride):
			var here: int = vy * stride + vx
			if vx < grid_res:
				right[here] = _crossing(grid[vy][vx], grid[vy][vx + 1], read_at, blocks, here, here + 1)
			if vy < grid_res:
				down[here] = _crossing(grid[vy][vx], grid[vy + 1][vx], read_at, blocks, here, here + stride)

	var corners := PackedVector3Array()
	var corner_colours := PackedColorArray()
	var half_width: float = data.crack_width_m * 0.5 / data.radius
	var frame: PlanetData.TileFrame = null
	var pitch: float = StarMapRelief.tile_pitch(data.radius, nside)
	for vy: int in range(grid_res):
		for vx: int in range(grid_res):
			var here: int = vy * stride + vx
			var met: Array[Vector3] = []
			for side: Vector3 in [right[here], down[here + 1], right[here + stride], down[here]]:
				if side != Vector3.ZERO:
					met.append(side)
			if met.size() < 2:
				continue
			if frame == null:
				frame = data.make_tile_frame()
				data.prepare_mountain_frame(frame, nside, ipix)
				CrackCarve.prepare_frame(data, frame, nside, ipix)
			var ends: Array[Vector3] = met
			if met.size() > 2:
				var fork: Vector3 = _fork(grid, read_at, blocks, vx, vy, stride)
				if fork == Vector3.ZERO:
					for at: Vector3 in met:
						fork += at
					fork = fork.normalized()
				ends = []
				for at: Vector3 in met:
					ends.append(at)
					ends.append(fork)
			for n: int in range(0, ends.size(), 2):
				# Where the ground keeps the canyon, asked of the game's own rule — and of that rule
				# only. Whether a canyon runs here is already known; testing the carve itself at the
				# middle of a stretch dropped the ones that cut a corner near a fork, and the network
				# came out in pieces that did not meet.
				if CrackCarve.depth_factor(data, (ends[n] + ends[n + 1]).normalized(), frame) < 0.5:
					continue
				var from: Vector3 = on_drawn_ground(data, frame, nside, pitch, ends[n], UNDER_THE_ROADS)
				var to: Vector3 = on_drawn_ground(data, frame, nside, pitch, ends[n + 1], UNDER_THE_ROADS)
				points.append(from)
				points.append(to)
				colours.append(COLOUR)
				colours.append(COLOUR)
				_add_ribbon(corners, from, to, half_width)
	corner_colours.resize(corners.size())
	corner_colours.fill(COLOUR)
	return [points, colours, corners, corner_colours]


## Where three canyons meet inside one square of the grid, as a direction, or ZERO when the square
## does not hold exactly that.
##
## The place the three blocks' feature points are equally far from: two planes, each halfway between
## two of them, cut across the square. The square is small against a block, so the point the network is
## read at is taken to run evenly across it, which leaves two equations in two unknowns. Drawing the
## fork from the middle of the square instead put it up to half a step from where the canyons meet, and
## the three stretches reached it from the wrong angles.
static func _fork(grid: Array[PackedVector3Array], read_at: PackedVector3Array,
		blocks: PackedVector3Array, vx: int, vy: int, stride: int) -> Vector3:
	var here: int = vy * stride + vx
	var sites: Array[Vector3] = []
	for corner: int in [here, here + 1, here + stride, here + stride + 1]:
		if not sites.has(blocks[corner]):
			sites.append(blocks[corner])
	if sites.size() != 3:
		return Vector3.ZERO
	var origin: Vector3 = read_at[here]
	var along_x: Vector3 = read_at[here + 1] - origin
	var along_y: Vector3 = read_at[here + stride] - origin
	var first: Vector3 = sites[1] - sites[0]
	var second: Vector3 = sites[2] - sites[0]
	var a: float = along_x.dot(first)
	var b: float = along_y.dot(first)
	var c: float = along_x.dot(second)
	var d: float = along_y.dot(second)
	var det: float = a * d - b * c
	if absf(det) < 1.0e-12:
		return Vector3.ZERO
	var p: float = ((sites[0] + sites[1]) * 0.5 - origin).dot(first)
	var q: float = ((sites[0] + sites[2]) * 0.5 - origin).dot(second)
	var u: float = clampf((p * d - b * q) / det, 0.0, 1.0)
	var v: float = clampf((a * q - p * c) / det, 0.0, 1.0)
	return grid[vy][vx].lerp(grid[vy][vx + 1], u).lerp(
			grid[vy + 1][vx].lerp(grid[vy + 1][vx + 1], u), v).normalized()


## One stretch of canyon as a strip as wide as the canyon, two triangles. [param from] and [param to]
## are its ends ON the drawn ground; [param half_width] half its width as an angle at the body's
## centre. Each end runs half a width past its point, so two stretches meeting at an angle overlap
## instead of leaving a notch.
static func _add_ribbon(corners: PackedVector3Array, from: Vector3, to: Vector3,
		half_width: float) -> void:
	var up: Vector3 = (from + to).normalized()
	var along: Vector3 = (to - from)
	along = (along - up * along.dot(up)).normalized()
	if along == Vector3.ZERO:
		return
	var across: Vector3 = up.cross(along)
	var from_r: float = from.length()
	var to_r: float = to.length()
	var from_dir: Vector3 = from / from_r - along * half_width
	var to_dir: Vector3 = to / to_r + along * half_width
	var a: Vector3 = (from_dir - across * half_width).normalized() * from_r
	var b: Vector3 = (from_dir + across * half_width).normalized() * from_r
	var c: Vector3 = (to_dir + across * half_width).normalized() * to_r
	var d: Vector3 = (to_dir - across * half_width).normalized() * to_r
	corners.append_array(PackedVector3Array([a, b, c, a, c, d]))


## Where the canyon between two points of the grid crosses the line from one to the other, as a
## direction, or ZERO when both stand on the same block.
##
## The canyon runs along the plane halfway between the two blocks' feature points; the crossing is
## where the line between the two READ points meets it, which is one division. Exact while the two
## blocks are neighbours, and a good guess when a third was stepped over between them.
static func _crossing(from: Vector3, to: Vector3, read_at: PackedVector3Array,
		blocks: PackedVector3Array, a: int, b: int) -> Vector3:
	if blocks[a] == blocks[b]:
		return Vector3.ZERO
	var across: Vector3 = blocks[b] - blocks[a]
	var run: float = (read_at[b] - read_at[a]).dot(across)
	var share: float = 0.5
	if absf(run) > 1.0e-9:
		share = clampf(((blocks[a] + blocks[b]) * 0.5 - read_at[a]).dot(across) / run, 0.0, 1.0)
	return from.lerp(to, share).normalized()
