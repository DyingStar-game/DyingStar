class_name StarMapRoads
extends StarMapTileLines
## The roads and railways of ONE body, drawn over its ground.
##
## Read straight from the terrain's own modifier pack rather than from anything the chart keeps: these
## are the very lines the game carves its road beds along, so a road on this map is where a road is.
## The pack stores, per HEALPix tile and per level, the piece of each feature that crosses it — so
## asking for the tiles the ground is drawing returns exactly the roads in view, already clipped, with
## nothing to cull and nothing counted twice.
##
## Lines rather than ribbons. A road is 6 m wide and a trail narrower; at any height where the whole
## network reads, a true-to-width ribbon is thinner than a pixel, and one widened until it shows is no
## longer telling you the width. A line says "there is a road here", which is what a map is for.
##
## The life of those lines — which tiles, laid when, kept how long — is [StarMapTileLines]'s.

## Where a body's modifier pack lives, beside its height tiles.
const PACK_PATH: String = "%s/%s_chunks/terrainmodifier.pack"

## What each kind of way is drawn in. Bright enough to hold against sunlit ground, and distinct from
## one another rather than merely from the terrain: the point of showing a railway is that it is not a
## road.
const COLOURS: Dictionary = {
	"highway": Color(1.0, 0.94, 0.78),
	"road": Color(0.98, 0.80, 0.55),
	"trail": Color(0.80, 0.66, 0.50),
	"railway": Color(0.72, 0.86, 1.0),
}
const UNKNOWN_COLOUR: Color = Color(0.85, 0.85, 0.85)
## The kind of way drawn with sleepers across it.
const RAILWAY: String = "railway"
## The length the map's signs are sized on, in pixels: a sleeper, the sides of a tunnel. On the ground
## it is that many pixels' worth of metres at the view's scale, taken to the nearest power of two so
## the ways are laid again once per doubling of the scale and not at every notch of the wheel — the
## signs are therefore this size to within a third either way.
##
## In pixels because that is what a sign is read in. It was a step of the ground's mesh, on the
## reckoning that a step is about five pixels; it is anything from three to twenty, and the tunnels
## came out five times too wide.
const SIGN_PIXELS: float = 4.0
## A sleeper every so many signs' lengths, and half its own length in the same.
const SLEEPER_EVERY: float = 3.0
const SLEEPER_HALF: float = 0.75
## A tunnel or a bridge: a line either side of the way for as long as it lasts, this far out from it,
## splayed at each end by a stroke this long — the way a map draws both — each stroke this thick.
const SPAN_SIDE: float = 0.8
const SPAN_WING: float = 1.2
const SPAN_THICK: float = 0.5
## Two of them closer together than this are drawn as ONE, from the first mouth to the last: a line
## through a massif is a tunnel, a cutting, a tunnel, and as many signs end to end is a saw blade.
## They come apart as the view comes down, since the distance is in signs' lengths.
const SPAN_JOIN: float = 6.0
## One shorter than this, once joined, is not marked: its sign would be wider than it is long, and a
## railway crossing a canyon every four km would be signs from end to end. They too come in as the
## view comes down.
const SPAN_MIN: float = 1.5
## Under the ground: dark, on a darker bed between its two lines. Over the void: light, and nothing
## under it — the void is what is there.
const TUNNEL_COLOUR: Color = Color(0.04, 0.04, 0.04)
const TUNNEL_BED: Color = Color(0.13, 0.12, 0.12)
const BRIDGE_COLOUR: Color = Color(0.95, 0.95, 0.92)
## How far under the lines the bed lies, as a fraction of the body's radius: at the same height the
## way drawn down its middle would fight it for the same pixels.
const BED_SINK: float = LIFT / 6.0

var _pack: ModifierPack = null
## The step the map's signs — sleepers, tunnels, bridges — are sized on, for the whole view: see
## [method show_over]. Zero until a view says, and each tile then uses its own.
var _sign_step: float = 0.0
## Where each line runs in a tunnel and where over a bridge, {"tunnels", "bridges"}, each feature id →
## Array of Vector2(from, to) in metres along the line; and what that was read from, as counts: a
## loaded planet goes on profiling its lines in the background, and those born since are wanted too.
var _spans: Dictionary = {}
var _spans_from: Vector2i = Vector2i(-1, -1)
## The same, as they are DRAWN at the current size of sign — joined where close, the short ones left
## out — and the size that was worked out for.
var _drawn_spans: Dictionary = {}
var _drawn_spans_for: float = -1.0


func _ready() -> void:
	super()
	# The signs' strips are seen from above whichever way their corners were wound.
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED


## The pack for this body, opened once. A body with no pack is an ordinary answer — most of them have
## none — and it is remembered as such so the disk is not searched again every quarter second.
func _available() -> bool:
	if _pack != null:
		return _pack.is_open()
	if body_key == "":
		return false
	_pack = ModifierPack.new()
	if not _pack.open(PACK_PATH % [StarMapRelief.EXPORT_ROOT, body_key]):
		return false
	return true


## On a worker when the body's PlanetData is there to sample, on this thread otherwise, where the
## chart's own reading is cheap. Laying a way means sampling the game's height field at every surveyed
## point — 80 to 150 µs a point, over a thousand points for a view around the mining villages — so on
## the main thread a new view cost 110 to 200 ms in one frame. While the worker runs, the pack is its
## alone.
func _laying() -> Array:
	var data: PlanetData = StarMapTiles.for_body(body_key).data
	var pack: ModifierPack = _pack
	var signs: Dictionary = {"step": _sign_step, "spans": _spans_to_draw(data)}
	if data == null or data.radius <= 0.0:
		var key: String = body_key
		return [func(id: int) -> Array:
			return _lay_tile(pack, StarMapGround.id_nside(id), StarMapGround.id_ipix(id),
					func(dir: Vector3) -> Vector3:
						return dir * (StarMapRelief.MESH_RADIUS
								* (StarMapRelief.surface_factor(key, dir) + LIFT)), signs), false]
	return [func(id: int) -> Array:
		# The ground THAT TILE draws, which costs nothing until a way asks where it stands.
		var tile := StarMapDrawnTile.new(data, StarMapGround.id_nside(id), StarMapGround.id_ipix(id))
		return _lay_tile(pack, tile.nside, tile.ipix, func(dir: Vector3) -> Vector3:
			return tile.place(dir, LIFT), signs), true]


func _release() -> void:
	if _pack != null:
		_pack.close()
		_pack = null
	_spans = {}
	_spans_from = Vector2i(-1, -1)
	_drawn_spans = {}
	_drawn_spans_for = -1.0


## Draw the ways crossing [param tiles], with the map's signs — a railway's sleepers, the sides of a
## tunnel or a bridge — sized for a view in which a pixel covers [param metres_per_pixel] of a body
## [param radius_m] across.
##
## ONE size for the whole view, which is why it is not each tile's own: a view mixes levels, fine under
## the camera and coarser ring by ring, and sleepers sized tile by tile doubled in length and spacing at
## every ring. When the size changes, everything laid is laid again.
func show_over(tiles: Dictionary, metres_per_pixel: float, radius_m: float) -> void:
	var step: float = sign_length(metres_per_pixel, radius_m)
	if not is_equal_approx(step, _sign_step):
		_sign_step = step
		lay_again()
	refresh(tiles)


## The length of a sign ([constant SIGN_PIXELS]) on a body [param radius_m] across seen at
## [param metres_per_pixel], as an angle at its centre. Zero when either is unknown.
static func sign_length(metres_per_pixel: float, radius_m: float) -> float:
	if metres_per_pixel <= 0.0 or radius_m <= 0.0:
		return 0.0
	return pow(2.0, roundf(log(metres_per_pixel * SIGN_PIXELS) / log(2.0))) / radius_m


## One step of the mesh of a tile at [param nside], as an angle at the body's centre: the longest a
## piece of a way is drawn on that tile.
static func mesh_step(nside: int) -> float:
	return HEALPix.pixel_angular_size(nside) / float(StarMapGround.GRID_RES) if nside > 0 else 0.0


## Where the body's lines run in tunnels and over bridges, from what it KNOWS — built by a loaded
## planet, baked for one that is not: the TUNNEL and BRIDGE stretches of each line's profile (a bridge
## there is a viaduct), and the crossings of the canyons. Read again only when there is more of either
## than last time. Main thread.
func _known_spans(data: PlanetData) -> Dictionary:
	if data == null:
		return {}
	var profiles: Dictionary = data.known_grade_profiles()
	var crossings: Array = data.known_bridge_spans()
	var from := Vector2i(profiles.size(), crossings.size())
	if from == _spans_from:
		return _spans
	_spans_from = from
	var tunnels: Dictionary = {}
	var bridges: Dictionary = {}
	for fid: int in profiles:
		for seg: Dictionary in (profiles[fid] as Dictionary).get("segments", []):
			var span := Vector2(float(seg["lo"]), float(seg["hi"]))
			match int(seg["kind"]):
				GradeSettings.Kind.TUNNEL:
					_note_span(tunnels, fid, span)
				GradeSettings.Kind.BRIDGE:
					_note_span(bridges, fid, span)
	for crossing: Dictionary in crossings:
		# One too oblique for a bridge has none: the way goes down into the canyon there.
		if not bool(crossing.get("truncated", false)):
			_note_span(bridges, int(crossing.get("feature_id", -1)),
					Vector2(float(crossing["along_start"]), float(crossing["along_end"])))
	_spans = {"tunnels": tunnels, "bridges": bridges}
	return _spans


## [method _known_spans] as drawn at the current size of sign: see [method join_spans]. Worked out
## again only when the size or what is known has changed — thirteen thousand crossings on Tarsis III
## are not to be sorted for every batch of tiles. Main thread.
func _spans_to_draw(data: PlanetData) -> Dictionary:
	var was: Vector2i = _spans_from
	var known: Dictionary = _known_spans(data)
	if data == null or _sign_step <= 0.0:
		return known
	if was == _spans_from and is_equal_approx(_drawn_spans_for, _sign_step):
		return _drawn_spans
	_drawn_spans_for = _sign_step
	var sign_m: float = _sign_step * data.radius
	_drawn_spans = {}
	for sort: String in known:
		var lines: Dictionary = {}
		for fid: int in known[sort]:
			var drawn: Array[Vector2] = join_spans(known[sort][fid], sign_m * SPAN_JOIN, sign_m * SPAN_MIN)
			if not drawn.is_empty():
				lines[fid] = drawn
		_drawn_spans[sort] = lines
	return _drawn_spans


## [param spans] — Vector2(from, to) along one line, in metres, in any order — with every run of them
## less than [param join_m] apart made into one, and what is then shorter than [param shortest_m]
## left out. In order along the line.
static func join_spans(spans: Array, join_m: float, shortest_m: float) -> Array[Vector2]:
	var sorted: Array = spans.duplicate()
	sorted.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var joined: Array[Vector2] = []
	for span: Vector2 in sorted:
		if not joined.is_empty() and span.x - joined[joined.size() - 1].y < join_m:
			joined[joined.size() - 1].y = maxf(joined[joined.size() - 1].y, span.y)
		else:
			joined.append(span)
	var out: Array[Vector2] = []
	for span: Vector2 in joined:
		if span.y - span.x >= shortest_m:
			out.append(span)
	return out


static func _note_span(into: Dictionary, fid: int, span: Vector2) -> void:
	if not into.has(fid):
		into[fid] = []
	(into[fid] as Array).append(span)


# ---------------------------------------------------------------------------

## Every way crossing one tile, as line segments, each surveyed point put on the ground by
## [param place]. Static and handed everything, because it may run on a worker.
##
## [param signs] is what the map's signs need: "step", the length they are sized on (zero leaves it to
## the tile's own), and "spans", see [method _spans_to_draw].
##
## The pack stores lon/lat in DEGREES, which is what [method HEALPix.lonlat2vec] takes — the two agree,
## and it is worth saying so here because the neighbouring call in this file's own tests once did not.
static func _lay_tile(pack: ModifierPack, nside: int, ipix: int, place: Callable,
		signs: Dictionary = {}) -> Array:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	# The signs' strokes again, as strips: a line is a pixel wide whatever is done to it, and a dark
	# pixel beside a bright way on dark ground is not seen.
	var strips := PackedVector3Array()
	var strip_colours := PackedColorArray()
	if not pack.has_tile(nside, ipix):
		return [points, colours]
	var tile: Dictionary = pack.decode_tile(pack.read_tile(nside, ipix), 0.0, ModifierPack.MASK_ROAD)
	# One step of the tile's mesh, as an angle: no piece of a way is drawn longer than that.
	var step: float = mesh_step(nside)
	var sign_step: float = float(signs.get("step", 0.0))
	if sign_step <= 0.0:
		sign_step = step
	var spans: Dictionary = signs.get("spans", {})

	for entry: Variant in (tile["roads"] as Array):
		var road: Dictionary = entry
		var line: PackedVector2Array = road["centerline"]
		if line.size() < 2:
			continue
		var kind: String = str(road.get("road_type", ""))
		var tint: Color = COLOURS.get(kind, UNKNOWN_COLOUR)
		var way := PackedVector3Array()
		for at: Vector2 in line:
			way.append(HEALPix.lonlat2vec(at.x, at.y))
		for i: int in range(1, way.size()):
			add_line(points, colours, way[i - 1], way[i], step, place, tint)
		if kind == RAILWAY:
			add_sleepers(points, colours, way, sign_step, place, tint)
		var fid: int = int(road.get("feature_id", -1))
		var along: PackedFloat64Array = road.get("_cum_lengths", PackedFloat64Array())
		for sort: Array in [["tunnels", TUNNEL_COLOUR, true], ["bridges", BRIDGE_COLOUR, false]]:
			var here: Array = (spans.get(sort[0], {}) as Dictionary).get(fid, [])
			if here.is_empty():
				continue
			var before: int = points.size()
			var beds: int = strips.size()
			add_span_signs(points, colours, way, along, here, sign_step, step, place, sort[1],
					0.0, strips if sort[2] else null)
			for n: int in range(beds, strips.size()):
				strip_colours.append(TUNNEL_BED)
			beds = strips.size()
			for n: int in range(before, points.size(), 2):
				add_ribbon(strips, points[n], points[n + 1], sign_step * SPAN_THICK * 0.5)
			for n: int in range(beds, strips.size()):
				strip_colours.append(sort[1])
	return [points, colours, strips, strip_colours]


## The sleepers of a railway: short strokes across the line, which is how a map has always said
## "railway" and what tells it from a road when both are a pixel wide.
##
## [param way] is the piece of the railway one tile holds; [param step] the length they are sized on —
## [constant SLEEPER_EVERY] of it apart, [constant SLEEPER_HALF] of it to each side.
##
## Spread EVENLY over the piece, half a gap in from each end, rather than counted off from its start:
## a railway reaches the chart cut at every tile edge, and counting afresh in each tile left a gap of
## any length at each edge. Spread this way the two half gaps either side of an edge make a whole one.
## And every stroke is the same length, standing level at the height of the line: its two ends put on
## the ground one by one stood on different ground, and came out longer on a slope.
static func add_sleepers(points: PackedVector3Array, colours: PackedColorArray,
		way: PackedVector3Array, step: float, place: Callable, tint: Color) -> void:
	var length: float = 0.0
	for i: int in range(1, way.size()):
		length += way[i - 1].angle_to(way[i])
	var count: int = roundi(length / (step * SLEEPER_EVERY)) if step > 0.0 else 0
	if count <= 0:
		return
	var gap: float = length / float(count)
	var next_at: float = gap * 0.5
	var walked: float = 0.0
	for i: int in range(1, way.size()):
		var stretch: float = way[i - 1].angle_to(way[i])
		if stretch <= 0.0:
			continue
		var across: Vector3 = way[i - 1].cross(way[i]).normalized()
		while next_at <= walked + stretch:
			var on_line: Vector3 = way[i - 1].slerp(way[i], (next_at - walked) / stretch)
			var height: float = (place.call(on_line) as Vector3).length()
			points.append((on_line - across * (step * SLEEPER_HALF)).normalized() * height)
			points.append((on_line + across * (step * SLEEPER_HALF)).normalized() * height)
			colours.append(tint)
			colours.append(tint)
			next_at += gap
		walked += stretch


## The sign of a tunnel or of a bridge on one piece of a way: a line either side of it for as long as
## it lasts, splayed outward at each end — what a map has for both, told apart by [param colour].
##
## [param way] is the piece one tile holds and [param along] how far along the WHOLE line each of its
## points is, in metres; [param spans] where that line is in a tunnel (or on a bridge), as
## Vector2(from, to) in the same metres. One running on into the next tile is drawn up to the edge and
## has no end here; one shorter than [param shortest_m] is not drawn at all.
## [param step] sizes the sign; no stretch of it is drawn longer than [param max_piece].
##
## [param beds], when given, receives a strip the width of the sign along each one, just under it: the
## darker ground of a tunnel.
static func add_span_signs(points: PackedVector3Array, colours: PackedColorArray,
		way: PackedVector3Array, along: PackedFloat64Array, spans: Array, step: float,
		max_piece: float, place: Callable, colour: Color, shortest_m: float = 0.0,
		beds: Variant = null) -> void:
	if along.size() != way.size() or way.size() < 2:
		return
	var first: float = along[0]
	var last: float = along[along.size() - 1]
	for span: Vector2 in spans:
		var from: float = maxf(span.x, first)
		var to: float = minf(span.y, last)
		if to <= from or span.y - span.x < shortest_m:
			continue
		var inside: PackedVector3Array = stretch_of(way, along, from, to, max_piece)
		if inside.size() < 2:
			continue
		var heights := PackedFloat64Array()
		for at: Vector3 in inside:
			heights.append((place.call(at) as Vector3).length())
		if beds != null:
			for i: int in range(1, inside.size()):
				add_ribbon(beds, inside[i - 1] * (heights[i - 1] * (1.0 - BED_SINK)),
						inside[i] * (heights[i] * (1.0 - BED_SINK)), step * SPAN_SIDE)
		for side: float in [-1.0, 1.0]:
			var rail := PackedVector3Array()
			for i: int in range(inside.size()):
				var ahead: Vector3 = inside[mini(i + 1, inside.size() - 1)] - inside[maxi(i - 1, 0)]
				var across: Vector3 = inside[i].cross(ahead).normalized() * side
				rail.append((inside[i] + across * (step * SPAN_SIDE)).normalized() * heights[i])
			for i: int in range(1, rail.size()):
				_add_stroke(points, colours, rail[i - 1], rail[i], colour)
			# An end only where it really ends in this piece: the splay leans away from the span and
			# out from the way, half and half.
			if span.x >= first:
				_add_wing(points, colours, rail[0], rail[0] - rail[1], inside[0], step, colour)
			if span.y <= last:
				var end: int = rail.size() - 1
				_add_wing(points, colours, rail[end], rail[end] - rail[end - 1], inside[end], step, colour)


## The part of [param way] between [param from] and [param to] metres along its line, with both ends
## found between its points, and no two points further apart than [param max_piece] (an angle).
static func stretch_of(way: PackedVector3Array, along: PackedFloat64Array, from: float, to: float,
		max_piece: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i: int in range(1, way.size()):
		var a: float = along[i - 1]
		var b: float = along[i]
		if b <= a or b < from or a > to:
			continue
		var start: float = clampf((from - a) / (b - a), 0.0, 1.0)
		var stop: float = clampf((to - a) / (b - a), 0.0, 1.0)
		var first: Vector3 = way[i - 1].slerp(way[i], start)
		var last: Vector3 = way[i - 1].slerp(way[i], stop)
		var pieces: int = maxi(1, ceili(first.angle_to(last) / maxf(max_piece, 1.0e-9)))
		if out.is_empty():
			out.append(first)
		for n: int in range(1, pieces + 1):
			out.append(first.slerp(last, float(n) / float(pieces)))
	return out


static func _add_stroke(points: PackedVector3Array, colours: PackedColorArray, from: Vector3,
		to: Vector3, colour: Color) -> void:
	points.append(from)
	points.append(to)
	colours.append(colour)
	colours.append(colour)


## The splay at the end of a sign: from [param at], the end of one side line, leaning [param outward]
## (along the way, away from the span) and away from [param centre], the way itself.
static func _add_wing(points: PackedVector3Array, colours: PackedColorArray, at: Vector3,
		outward: Vector3, centre: Vector3, step: float, colour: Color) -> void:
	var up: Vector3 = at.normalized()
	var away: Vector3 = up - centre
	away = (away - up * away.dot(up)).normalized()
	var on: Vector3 = (outward - up * outward.dot(up)).normalized()
	var lean: Vector3 = (away + on).normalized()
	_add_stroke(points, colours, at, (up + lean * (step * SPAN_WING)).normalized() * at.length(), colour)
