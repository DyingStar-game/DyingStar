extends RefCounted
## Test helper: a RemoteTileSource whose disk cache already holds a synthetic planet's elevation
## tiles, with its presence maps known — what a PlanetData reads now that the game reads no local
## heights.pack (tiles only come from the tile service, through this cache).
##
## Off the network: the fetcher answers 404 to everything, and nothing is ever queued since every
## presence map is filled. Preload it (not a class_name): a test helper, not a game class.
##
##   const FakeTileCache := preload("res://test/unit/fake_tile_cache.gd")
##   pd.remote_source = FakeTileCache.make("user://my_test_cache/", "p", 16, 1, 32, tiles)


## [param tiles]: Vector2i(ipix, nside) -> PackedByteArray, the exact bytes a pack tile holds
## (uint16 or float32 samples, as publish_tiles.py serves them). Every level nside_min..nside_max
## gets its presence maps; a tile absent from [param tiles] is "not published".
static func make(cache_root: String, planet: String, tile_res: int, nside_min: int, nside_max: int,
		tiles: Dictionary) -> RemoteTileSource:
	var src := RemoteTileSource.new()
	src.cache_root = cache_root
	src.planet = planet
	src.version = "fake"
	src.base_url = "http://fake.invalid"
	src.tile_res = tile_res
	src.nside_min = nside_min
	src.nside_max = nside_max
	src.fetcher = func(_url: String) -> Array:
		return [404, PackedByteArray()]
	RemoteTileSource._remove_tree("%s%s" % [cache_root, planet])
	var ns := nside_min
	while ns <= nside_max:
		var npix := 12 * ns * ns
		for base in range(0, npix, src.shard_tiles):
			var bits := PackedByteArray()
			bits.resize((mini(src.shard_tiles, npix - base) + 7) >> 3)
			bits.fill(0)
			@warning_ignore("integer_division")
			src._present["n%d/f%d" % [ns, base / src.shard_tiles]] = bits
		ns *= 2
	for key: Vector2i in tiles:
		var ip := key.x
		var level := key.y
		@warning_ignore("integer_division")
		var shard := ip / src.shard_tiles
		var map_key := "n%d/f%d" % [level, shard]
		var bits: PackedByteArray = src._present[map_key]
		var i := ip - shard * src.shard_tiles
		bits[i >> 3] = bits[i >> 3] | (1 << (i & 7))
		src._present[map_key] = bits
		AtomicFile.write_buffer(src.tile_cache_path(level, ip), envelope(tiles[key]))
	return src


## publish_tiles.tile_blob(payload, compress=False): "DSTL", CRC32 of the payload, flags 0.
static func envelope(payload: PackedByteArray) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(RemoteTileSource.TILE_HEADER)
	b.encode_u32(0, RemoteTileSource.TILE_MAGIC)
	b.encode_u32(4, RemoteTileSource._crc32(payload))
	b.encode_u32(8, 0)
	b.append_array(payload)
	return b


## A tile of [param tile_res]² uint16 samples, every one [param value] (normalised 0..1).
static func flat_u16(tile_res: int, value: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(tile_res * tile_res * 2)
	var q := int(round(value * 65535.0))
	for i in tile_res * tile_res:
		b.encode_u16(i * 2, q)
	return b
