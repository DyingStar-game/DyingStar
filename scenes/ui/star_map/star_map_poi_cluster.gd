class_name StarMapPoiCluster
extends RefCounted

## Which points of interest are too close together ON SCREEN to be drawn apart, and so are drawn as
## one marker carrying their number.
##
## The level design packs its sites: sixty-two villages of tarsis_3 line one corridor, and from any
## height worth the name their badges land on the same few pixels. The names already gave way to one
## another ([StarMapPoiLayer]); the badges did not, and a heap of badges is neither readable nor
## clickable.
##
## Decided in pixels, not in kilometres nor by altitude: "too close to tell apart" is a fact about the
## screen. Coming down spreads the same towns over more pixels, so the groups come apart on their own,
## a few at a time, with no threshold to tune per planet.
##
## Pure and node-free, like [StarMapPoi]: it is handed screen positions and answers with indices.

## How much further apart two badges must drift to LEAVE a group than they had to be to join it. The
## chart's one figure for this (the names, the body whose towns are shown): the planet turns under the
## camera, and a pair sitting on the threshold would otherwise merge and split every other frame.
const KEEP: float = 0.75


## Sort [param indices] into groups. Each group is the indices drawn as one marker, its first member
## being its SEED: the point the others were measured against, and the group's name from one frame to
## the next. A group of one is a point drawn on its own.
##
## [param at] gives the screen position of each of [param indices], in the same order.
## [param reach] is how close to a seed, in pixels, a point must be to join it.
## [param alone] are indices never grouped — the selected town: a place you asked for that then vanished
## into a number would read as the chart ignoring you.
## [param before] is last frame's answer as index → seed, for the hysteresis above.
##
## Greedy, in the order given: the first point seeds a group, each next one joins the first seed within
## reach or seeds its own. The order is the towns' own, which does not change as the view turns, so the
## same towns seed the same groups from frame to frame.
static func group(indices: PackedInt32Array, at: PackedVector2Array, reach: float,
		alone: PackedInt32Array = PackedInt32Array(), before: Dictionary = {}) -> Array[PackedInt32Array]:
	var groups: Array[PackedInt32Array] = []
	var seeds_at: PackedVector2Array = PackedVector2Array()
	var joinable: Array[bool] = []
	for n: int in range(indices.size()):
		var index: int = indices[n]
		var lonely: bool = alone.has(index)
		var joined: bool = false
		if not lonely:
			for g: int in range(groups.size()):
				if not joinable[g]:
					continue
				var first: int = groups[g][0]
				var stays: bool = before.get(index, -1) == first and before.get(first, -1) == first
				if at[n].distance_to(seeds_at[g]) < (reach / KEEP if stays else reach):
					groups[g].append(index)
					joined = true
					break
		if not joined:
			groups.append(PackedInt32Array([index]))
			seeds_at.append(at[n])
			joinable.append(not lonely)
	return groups


## [method group]'s answer as index → seed, which is what the next call wants for [param before]. Only
## the members of real groups are written: a point on its own has nothing to stay with.
static func memory(groups: Array[PackedInt32Array]) -> Dictionary:
	var out: Dictionary = {}
	for members: PackedInt32Array in groups:
		if members.size() < 2:
			continue
		for index: int in members:
			out[index] = members[0]
	return out
