@tool
class_name RoadCut
## Removes stretches of a road centerline, so the ribbon stops where a bridge
## takes over.
##
## The road ribbon samples the RAW heightmap, which has no crack in it, so it
## flies over every gorge at rim altitude. That was tolerable while nothing
## else was drawn there; now a deck and two ramps stand in the same place, and
## the tarmac would lie across them.
##
## ── Why the strip is SPLIT and not merely thinned ───────────────────────
## PlanetChunk builds the ribbon as one contiguous quad strip per road: it walks
## the vertex array from a saved base index and joins consecutive left/right
## pairs. Dropping vertices from the middle of that run does not open a hole —
## it joins the pair before the gap to the pair after it, stretching one quad
## straight over the gorge. Each surviving stretch has to become its OWN run,
## with its own base index, so no quad can be formed across the gap.
##
## ── Why the along-distances are carried through ─────────────────────────
## The ribbon's U coordinate is the absolute along-road distance over the
## texture tile size, which is what keeps the asphalt continuous from one chunk
## to the next. A cut piece keeps those absolute distances — and a vertex
## inserted exactly at a cut boundary carries that boundary's distance — so the
## texture on the far side of a bridge resumes exactly where the near side
## stopped, instead of restarting at zero.

## Pieces shorter than this are not worth a draw call.
const MIN_PIECE_M := 0.5


## Merge [param intervals] ([lo, hi] as Vector2) into sorted, non-overlapping
## ones. Two gorges close enough for their approach ramps to meet must become a
## single exclusion, or a sliver of ribbon survives between two decks.
static func merge_intervals(intervals: Array) -> Array:
	if intervals.size() <= 1:
		return intervals.duplicate()
	var sorted := intervals.duplicate()
	sorted.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var out: Array = [sorted[0]]
	for i in range(1, sorted.size()):
		var cur: Vector2 = sorted[i]
		var last: Vector2 = out[out.size() - 1]
		if cur.x <= last.y:
			out[out.size() - 1] = Vector2(last.x, maxf(last.y, cur.y))
		else:
			out.append(cur)
	return out


## Split a centerline into the pieces that survive [param exclusions].
##
## [param cum] holds the absolute along-road distance of each point.
## [param exclusions] must be merged and sorted (see [method merge_intervals]).
## Returns an Array of [cl_piece, cum_piece] pairs, in along-road order.
static func split(cl: PackedVector2Array, cum: PackedFloat64Array,
		exclusions: Array) -> Array:
	if cl.size() < 2 or cum.size() != cl.size():
		return []
	if exclusions.is_empty():
		return [[cl, cum]]

	# The kept stretches are the complement of the exclusions, clipped to the
	# road. Working forwards through both lists keeps this a single pass.
	var road_lo: float = cum[0]
	var road_hi: float = cum[cum.size() - 1]
	var keeps: Array = []
	var cursor := road_lo
	for e in exclusions:
		var lo: float = maxf(float((e as Vector2).x), road_lo)
		var hi: float = minf(float((e as Vector2).y), road_hi)
		if hi <= cursor:
			continue
		if lo > cursor:
			keeps.append(Vector2(cursor, minf(lo, road_hi)))
		cursor = maxf(cursor, hi)
		if cursor >= road_hi:
			break
	if cursor < road_hi:
		keeps.append(Vector2(cursor, road_hi))

	var out: Array = []
	for k in keeps:
		var piece := _clip(cl, cum, float((k as Vector2).x), float((k as Vector2).y))
		if not piece.is_empty():
			out.append(piece)
	return out


## The stretch of the centerline between two along-road distances, with the two
## boundary points INTERPOLATED so the piece ends exactly where it should and
## carries that exact distance — the property the flow-aligned UVs rely on.
static func _clip(cl: PackedVector2Array, cum: PackedFloat64Array,
		lo: float, hi: float) -> Array:
	if hi - lo < MIN_PIECE_M:
		return []
	var out_cl := PackedVector2Array()
	var out_cum := PackedFloat64Array()
	out_cl.append(RoadBridge.lonlat_at(cl, cum, lo))
	out_cum.append(lo)
	for i in cl.size():
		var d: float = cum[i]
		if d <= lo or d >= hi:
			continue
		out_cl.append(cl[i])
		out_cum.append(d)
	var last := RoadBridge.lonlat_at(cl, cum, hi)
	# Guard against a boundary landing on an existing vertex: a duplicated point
	# makes a zero-length segment, whose perpendicular is undefined.
	if out_cum[out_cum.size() - 1] < hi - 1e-6:
		out_cl.append(last)
		out_cum.append(hi)
	if out_cl.size() < 2:
		return []
	return [out_cl, out_cum]
