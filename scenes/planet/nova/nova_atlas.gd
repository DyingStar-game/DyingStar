@tool
class_name NovaAtlas
extends RefCounted
## Where each Nova variant lies on a body: the dock's globe and the places its buttons go to.
##
## Truth is the EXPORT level of the modifier pack, the one chunks read (PlanetData.get_chunk_populate_zones).
## The coarser levels are no map: they are conservative summaries, a zone touching a tile marks it "full". On
## tarsis_3 they cover 94 % of the body where the export level covers 3 %.
##
## Spots. Every export tile holding zones is cut into SUB × SUB points, each classified like a vertex (first
## matching zone of its tile). A variant's points are grouped by their GROUP_NSIDE cell: one spot per cell, at
## the point nearest the cell's mean, preferring a point whose whole tile is that variant (away from any
## edge). Spots are sorted largest first.
##
## Edges. Two neighbouring points of a tile that disagree mark a frontier; it is bisected to BISECT_STEPS, so
## the place sits on the line itself, a few centimetres from either side. One edge per (variant, other
## variant, cell), sorted by how much frontier the cell holds.
##
## Map. A longitude/latitude picture of the body, one byte per pixel = the variant id: what the dock's
## miniature shows. Painted from the base level first (the first whose tiles are a few pixels wide), then
## from the export level on top. Both are needed on tarsis_3: its export level lacks the inside of the large
## zones (the exporter keeps only their outline there), while far chunks, which read the coarse levels, show
## them whole — the map shows the planet as it looks from afar, with the export level's exact borders.
##
## Relief. With the body's PlanetData at hand (its scene is open), [method relief_of] reads its heights over
## the same longitude/latitude frame, for the globe's shading. Cached like the atlas.
##
## Built once per pack (seconds, on a worker) and cached in CACHE_DIR, keyed by the pack and the variants.

## Cell grouping spots and edges (nside 16: cells of ~3.7°, ~400 km on tarsis_3).
const GROUP_NSIDE := 16
## Points per tile side: about one per map pixel, SUB at least and SUB_MAX at most (a streamed pack is
## surveyed at a coarse level, whose tiles are tens of pixels wide).
const SUB := 4
const SUB_MAX := 24
## Where a point sits in its cell of the tile. Not the middle: the middles of a tile's cells lie on the
## parallels the zones are clipped along (the lon/lat boxes of finer tiles), where the point-in-outline
## test answers "outside" for the two pieces of a zone meeting there — lines and dots of bare ground
## across the map.
const OFF_X := 0.31
const OFF_Y := 0.44
## Widest gap of bare ground the map closes between two painted pixels (see _close_gaps), pixels.
const GAP_PX := 3
## Halvings of a frontier between two points a quarter tile apart (~1.6 km on tarsis_3 → ~2.5 cm).
const BISECT_STEPS := 16
## Where built atlases are kept.
const CACHE_DIR := "user://nova_atlas"
## Bump when what an atlas holds changes.
const FORMAT := 10
## The atlas surveys the finest level of the pack holding at most this many tiles, the export level at
## best. A pack whose zones cover the whole body has every tile of every level: tarsis_3's export level is
## 10.7 million tiles, minutes of reading for places a level of 50 km tiles finds as well (the frontiers
## are bisected to centimetres at any level).
const SURVEY_MAX_TILES := 250000
## The map's size: 4096 px around the body (~10 km a pixel on tarsis_3).
const MAP_SIZE := Vector2i(4096, 2048)
## The relief's size, and the pyramid level its heights are read from (768 tiles of 32 × 32 at nside 8).
const RELIEF_SIZE := Vector2i(1024, 512)
const RELIEF_NSIDE := 8
## The map's base level is the first whose tiles are at most this many pixels wide.
const BASE_TILE_PX := 8.0

## The body.
var body := ""
## The pack's export level.
var export_nside := 0
## Variant id → Array of {dir: Vector3, count: int}, largest first. count = classified points (area).
var spots := {}
## Variant id → Array of {dir: Vector3, other: int, count: int}, longest frontier first.
var edges := {}
## Variant id of every point of the body, longitude/latitude (west → east, north → south), R8 or L8.
var map: Image
## Ground height in metres over the body, longitude/latitude like [member map], RF. Null until read, and
## when the body gives no heights; [member relief_read] tells the two apart.
var relief: Image
var relief_read := false

var _pack: ModifierPack
var _pack_mutex := Mutex.new()
## The finest level the atlas reads: the export level of a pack on disk; of a streamed pack, the finest
## level that arrives whole (its floor). Finer tiles would each be a download.
var _deepest := 0
var _own := {}  # "level/tile" → that tile's own zones
var _map_bytes := PackedByteArray()


## The atlas of [param nova]'s body, from the cache when the pack and the variants have not changed, else built
## (seconds to a minute: call it from a worker). [param pack] as NovaBody.pack_for.
static func load_or_build(nova: NovaBody, pack: ModifierPack, p_export_nside: int) -> NovaAtlas:
	var a := NovaAtlas.new()
	a.body = nova.planet_name
	a.export_nside = p_export_nside
	a._pack = pack
	if pack == null or not pack.get_levels().has(p_export_nside):
		# No pack (no tile service), or not a level of this pack (0 from an unread manifest): an atlas built
		# on it would be empty, and cached empty. Leave it unusable and uncached instead.
		push_warning("[Nova] atlas of %s: no modifier pack, or level %d is not in it" % [a.body, p_export_nside])
		a.export_nside = 0
		return a
	a._deepest = p_export_nside
	if pack is RemoteModifierPack:
		a._deepest = mini(p_export_nside, (pack as RemoteModifierPack).source.floor_nside_max)
	var key := _cache_key(nova, pack, p_export_nside)
	var cache := CACHE_DIR.path_join(a.body + ".atlas")
	var f := FileAccess.open(cache, FileAccess.READ)
	if f != null:
		var got: Variant = f.get_var()
		f.close()
		if got is Dictionary and str((got as Dictionary).get("key", "")) == key \
				and not ((got as Dictionary).get("spots", {}) as Dictionary).is_empty():
			a.spots = got.spots
			a.edges = got.edges
			a.map = Image.new()
			a.map.load_png_from_buffer(got.map)
			a.map.convert(Image.FORMAT_R8)  # a PNG comes back as RGB: keep the one channel that holds the ids
			return a
	a._build(nova)
	if a.spots.is_empty():
		# A build cut short (a script reload under this worker) or a pack without zones: never keep that.
		return a
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	f = FileAccess.open(cache, FileAccess.WRITE)
	if f != null:
		f.store_var({"key": key, "spots": a.spots, "edges": a.edges, "map": a.map.save_png_to_buffer()})
		f.close()
	return a


## Heights of [param data]'s body (metres), from its cache or read from its coarse tiles (seconds: call it
## from a worker). Null when the body gives no heights (flat everywhere): the globe then stays smooth.
static func relief_of(data: PlanetData) -> Image:
	var key := "%d|%s|%s" % [FORMAT, data.planet_name, data.chunk_data_version]
	var cache := CACHE_DIR.path_join(data.planet_name + ".relief")
	var f := FileAccess.open(cache, FileAccess.READ)
	if f != null:
		var got: Variant = f.get_var()
		f.close()
		if got is Dictionary and str((got as Dictionary).get("key", "")) == key:
			return Image.create_from_data(RELIEF_SIZE.x, RELIEF_SIZE.y, false, Image.FORMAT_RF, got.data)
	var heights := PackedFloat32Array()
	heights.resize(RELIEF_SIZE.x * RELIEF_SIZE.y)
	var ns := clampi(RELIEF_NSIDE, maxi(data.export_nside_min, 1), data.export_nside)
	var lo := INF
	var hi := -INF
	for y in RELIEF_SIZE.y:
		var lat := 90.0 - (float(y) + 0.5) * 180.0 / RELIEF_SIZE.y
		for x in RELIEF_SIZE.x:
			var dir := HEALPix.lonlat2vec((float(x) + 0.5) * 360.0 / RELIEF_SIZE.x - 180.0, lat)
			# The heightmap alone, at a coarse level: no mountains, no crevasses, nothing finer than a pixel.
			var h := data._base_height_for_direction(dir, -1, -1, Vector2i(-1, -1), null, ns)
			heights[y * RELIEF_SIZE.x + x] = h
			lo = minf(lo, h)
			hi = maxf(hi, h)
	if hi - lo < 1.0:
		return null
	var bytes := heights.to_byte_array()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	f = FileAccess.open(cache, FileAccess.WRITE)
	if f != null:
		f.store_var({"key": key, "data": bytes})
		f.close()
	return Image.create_from_data(RELIEF_SIZE.x, RELIEF_SIZE.y, false, Image.FORMAT_RF, bytes)


static func _cache_key(nova: NovaBody, pack: ModifierPack, nside: int) -> String:
	var keys := PackedStringArray()
	for v in nova.variants:
		keys.append(str(v.key))
	# A pack's path names its version (a streamed one) or its file.
	return "%d|%d|%s|%s" % [FORMAT, nside, pack.get_path(), "/".join(keys).sha256_text()]


## Variant id of [param dir], read from the zones of the finest level the atlas reads (the export level's
## as a vertex is, for a pack on disk; of a streamed pack its floor's, whose outlines are coarser: near a
## frontier the ground may show the other side). Thread-safe.
func variant_at(nova: NovaBody, dir: Vector3) -> int:
	if _pack == null or export_nside <= 0:
		return 1
	return _classify(nova, _zones_of(HEALPix.vec2pix_nest(_deepest, dir)), dir)


## The map pixel of [param dir].
static func map_pixel(dir: Vector3) -> Vector2i:
	var ll := HEALPix.vec2lonlat(dir)
	return Vector2i(posmod(int((ll.x + 180.0) / 360.0 * MAP_SIZE.x), MAP_SIZE.x),
			clampi(int((90.0 - ll.y) / 180.0 * MAP_SIZE.y), 0, MAP_SIZE.y - 1))


## Mark [param dir] as variant [param id] on the map, over a footprint [param px] pixels wide at the equator
## (wider towards the poles, where a pixel covers less ground).
func _plot(dir: Vector3, id: int, px: float) -> void:
	var at := map_pixel(dir)
	var half_y := int(px * 0.5)
	var half_x := int(px * 0.5 / maxf(sqrt(1.0 - dir.y * dir.y), 0.02))
	for y in range(maxi(at.y - half_y, 0), mini(at.y + half_y, MAP_SIZE.y - 1) + 1):
		for dx in range(-half_x, half_x + 1):
			_map_bytes[y * MAP_SIZE.x + posmod(at.x + dx, MAP_SIZE.x)] = id


## The zones of a tile: its own and, when the pack says so, those its ancestors' tiles hold for it (a zone
## covering a tile whole is written once, on the coarsest tile it covers: PlanetData.populate_zones_at).
func _zones_of(ipix: int, nside: int = _deepest) -> Array:
	var own := _own_zones(nside, ipix)
	if not _pack.populate_inherits():
		return own
	var levels := _pack.get_levels()
	var coarsest := int(levels[0]) if not levels.is_empty() else 1
	var ancestors := []
	@warning_ignore("integer_division")
	var ns := nside / 2
	var ip := ipix >> 2
	while ns >= coarsest:
		ancestors.append(_own_zones(ns, ip))
		@warning_ignore("integer_division")
		ns = ns / 2
		ip = ip >> 2
	return ModifierPack.merge_inherited_zones(own, ancestors)


## A tile's own zones, kept: an ancestor is asked for by every tile under it.
func _own_zones(nside: int, ipix: int) -> Array:
	var key := "%d/%d" % [nside, ipix]
	_pack_mutex.lock()
	var known: Variant = _own.get(key)
	if known == null:
		var raw := _pack.read_tile(nside, ipix)
		known = [] if raw.is_empty() else _pack.decode_tile(raw, 0.0, ModifierPack.MASK_POPULATE).get("populate_zones", [])
		_own[key] = known
	_pack_mutex.unlock()
	return known


## Every tile of a level that may hold zones: all of them when zones are inherited (a tile with no record
## of its own can lie whole inside a zone), else those the pack has.
func _tiles_of(nside: int) -> PackedInt64Array:
	if not _pack.populate_inherits():
		return _pack.get_tile_ipix(nside)
	var all := PackedInt64Array()
	all.resize(12 * nside * nside)
	for k in all.size():
		all[k] = k
	return all


static func _classify(nova: NovaBody, zones: Array, dir: Vector3) -> int:
	return PlanetChunk.nova_variant_in(PlanetChunk.nova_entries(nova, zones), dir)


## The level the atlas is built from: see SURVEY_MAX_TILES.
func _survey_level() -> int:
	var best := 0
	for level: int in _pack.get_levels():
		if level <= _deepest and level > best and _pack.get_tile_ipix(level).size() <= SURVEY_MAX_TILES:
			best = level
	return best if best > 0 else _deepest


func _build(nova: NovaBody) -> void:
	var n := _survey_level()
	var shift := 0
	while (GROUP_NSIDE << shift) < n:
		shift += 1
	# Every classified point: a tile whose first zone is full is one point (its centre) weighing sub*sub and
	# marked uniform; any other tile is sub*sub points of weight 1.
	var pts := PackedVector3Array()
	var pids := PackedByteArray()
	var pgroups := PackedInt32Array()
	var puniform := PackedByteArray()  # 1 = a point of a tile wholly one variant
	var sums := {}  # "id|group" → [Vector3 sum, count]
	var edge_acc := {}  # "id|other|group" → {id, other, a, b, zones, count}
	_map_bytes.resize(MAP_SIZE.x * MAP_SIZE.y)
	_map_bytes.fill(1)
	_paint_base(nova)
	var tile_px := HEALPix.pixel_side_length(n, 1.0) / TAU * MAP_SIZE.x
	var sub := clampi(roundi(tile_px), SUB, SUB_MAX)
	for ipix in _tiles_of(n):
		var zones := _zones_of(ipix, n)
		if zones.is_empty():
			continue
		var g := int(ipix) >> (2 * shift)
		var entries := PlanetChunk.nova_entries(nova, zones)
		# A footprint half as wide again as the tile: a HEALPix tile is a diamond in longitude/latitude,
		# and footprints of its own width left unpainted points all over the map.
		if str((zones[0] as Dictionary).get("coverage", "")) == "full":
			var c := HEALPix.pix2vec_nest(n, ipix)
			var cid := nova.variant_id_for_zone(zones[0])
			_add_point(pts, pids, pgroups, puniform, sums, c, cid, g, sub * sub, true)
			_plot(c, cid, tile_px * 1.5)
			continue
		var fxy := HEALPix.pix2face_xy(n, ipix)
		var dirs: Array[Vector3] = []
		var local := PackedByteArray()
		local.resize(sub * sub)
		for j in sub:
			for i in sub:
				var d := HEALPix._face_xy_to_vec(int(fxy.face), float(fxy.ix) + (float(i) + OFF_X) / sub,
						float(fxy.iy) + (float(j) + OFF_Y) / sub, n)
				var id := PlanetChunk.nova_variant_in(entries, d)
				dirs.append(d)
				local[j * sub + i] = id
		var uniform := true
		for k in sub * sub:
			uniform = uniform and local[k] == local[0]
		for k in sub * sub:
			_add_point(pts, pids, pgroups, puniform, sums, dirs[k], local[k], g, 1, uniform)
			# The ground outside zones is what is left unpainted, never painted itself: two zones drawn side
			# by side rarely share their outline, and the points falling in the gap between them speckled
			# the map with bare ground the game does not show (PlanetChunk.NOVA_SLIVER_SHARES).
			if local[k] > 1:
				_plot(dirs[k], local[k], tile_px * 1.5 / sub)
		if uniform:
			continue
		for j in sub:
			for i in sub:
				var a := local[j * sub + i]
				for nb: Vector2i in [Vector2i(i + 1, j), Vector2i(i, j + 1)]:
					if nb.x >= sub or nb.y >= sub:
						continue
					var b := local[nb.y * sub + nb.x]
					if a == b:
						continue
					var da := dirs[j * sub + i]
					var db := dirs[nb.y * sub + nb.x]
					for pair: Array in [[a, b, da, db], [b, a, db, da]]:
						var ek := "%d|%d|%d" % [pair[0], pair[1], g]
						var e: Dictionary = edge_acc.get(ek, {})
						if e.is_empty():
							edge_acc[ek] = {"id": pair[0], "other": pair[1], "a": pair[2], "b": pair[3],
									"zones": entries, "count": 1}
						else:
							e.count = int(e.count) + 1
	_close_gaps()
	_build_spots(nova, sums, pts, pids, pgroups, puniform)
	_build_edges(edge_acc)
	map = Image.create_from_data(MAP_SIZE.x, MAP_SIZE.y, false, Image.FORMAT_R8, _map_bytes)
	_map_bytes = PackedByteArray()


## Fills the gaps of bare ground at most GAP_PX pixels wide between two painted pixels, down the columns
## then along the rows: the lines the footprints leave between rings of tiles, and the slivers between
## zones that do not share their outline. Bare ground wider than that stays.
func _close_gaps() -> void:
	var size := _map_bytes.size()
	for step: int in [MAP_SIZE.x, 1]:
		for i in size:
			if _map_bytes[i] != 1:
				continue
			var before := 0
			var after := 0
			for k in range(1, GAP_PX + 1):
				if before == 0 and i - k * step >= 0 and _map_bytes[i - k * step] > 1:
					before = _map_bytes[i - k * step]
				if after == 0 and i + k * step < size and _map_bytes[i + k * step] > 1:
					after = _map_bytes[i + k * step]
			if before > 0 and after > 0:
				_map_bytes[i] = before


## Paint the map from the base level: every tile over its whole footprint. A HEALPix tile is a diamond in
## longitude/latitude, so the footprint is its bounding square (1.5 × its side): neighbours overlap a
## little, and the export level redraws the borders exactly afterwards.
func _paint_base(nova: NovaBody) -> void:
	var base := 0
	for level in _pack.get_levels():
		if level < _survey_level() and HEALPix.pixel_side_length(level, 1.0) / TAU * MAP_SIZE.x <= BASE_TILE_PX:
			base = level
			break
	if base == 0:
		return
	var tile_px := HEALPix.pixel_side_length(base, 1.0) / TAU * MAP_SIZE.x
	var sub := int(ceil(tile_px * 1.5)) + 1
	for ipix in _tiles_of(base):
		var zones := _zones_of(ipix, base)
		if zones.is_empty():
			continue
		if str((zones[0] as Dictionary).get("coverage", "")) == "full":
			var id := nova.variant_id_for_zone(zones[0])
			if id > 1:
				_plot(HEALPix.pix2vec_nest(base, ipix), id, tile_px * 1.5)
			continue
		var fxy := HEALPix.pix2face_xy(base, ipix)
		var entries := PlanetChunk.nova_entries(nova, zones)
		for j in sub:
			for i in sub:
				var d := HEALPix._face_xy_to_vec(int(fxy.face), float(fxy.ix) + (float(i) + OFF_X) / sub,
						float(fxy.iy) + (float(j) + OFF_Y) / sub, base)
				var id := PlanetChunk.nova_variant_in(entries, d)
				if id > 1:
					_plot(d, id, tile_px * 1.5 / sub)


static func _add_point(pts: PackedVector3Array, pids: PackedByteArray, pgroups: PackedInt32Array,
		puniform: PackedByteArray, sums: Dictionary, d: Vector3, id: int, g: int, w: int, uniform: bool) -> void:
	pts.append(d)
	pids.append(id)
	pgroups.append(g)
	puniform.append(1 if uniform else 0)
	var sk := "%d|%d" % [id, g]
	var acc: Array = sums.get(sk, [Vector3.ZERO, 0])
	sums[sk] = [acc[0] + d * float(w), int(acc[1]) + w]


## Second pass: for each (variant, cell), the point nearest the cell's mean, a point of a tile wholly that
## variant winning over one near an edge.
func _build_spots(nova: NovaBody, sums: Dictionary, pts: PackedVector3Array, pids: PackedByteArray,
		pgroups: PackedInt32Array, puniform: PackedByteArray) -> void:
	var best := {}  # "id|group" → [score, dir]
	for k in pts.size():
		var sk := "%d|%d" % [pids[k], pgroups[k]]
		var mean: Vector3 = (sums[sk][0] as Vector3).normalized()
		var score := pts[k].dot(mean) + float(puniform[k])
		var cur: Array = best.get(sk, [-INF, Vector3.ZERO])
		if score > float(cur[0]):
			best[sk] = [score, pts[k]]
	spots.clear()
	for sk: String in best.keys():
		var id := int(sk.get_slice("|", 0))
		# A place must be its variant where a player lands: at the export level. The surveyed level can
		# disagree (a zone simplified away, or one that only the coarse levels hold): such a place is left out.
		if variant_at(nova, best[sk][1]) != id:
			continue
		if not spots.has(id):
			spots[id] = []
		(spots[id] as Array).append({"dir": best[sk][1], "count": int(sums[sk][1])})
	for id in spots.keys():
		(spots[id] as Array).sort_custom(func(p, q): return int(p.count) > int(q.count))


func _build_edges(edge_acc: Dictionary) -> void:
	edges.clear()
	for e: Dictionary in edge_acc.values():
		var a: Vector3 = e.a
		var b: Vector3 = e.b
		for _s in BISECT_STEPS:
			var m := (a + b).normalized()
			if PlanetChunk.nova_variant_in(e.zones, m) == int(e.id):
				a = m
			else:
				b = m
		var id := int(e.id)
		if not edges.has(id):
			edges[id] = []
		(edges[id] as Array).append({"dir": (a + b).normalized(), "other": int(e.other), "count": int(e.count)})
	for id in edges.keys():
		(edges[id] as Array).sort_custom(func(p, q): return int(p.count) > int(q.count))
