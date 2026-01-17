class_name HEALPix
## HEALPix (Hierarchical Equal Area isoLatitude Pixelisation) math library.
##
## Implements NESTED ordering for hierarchical LOD traversal.
## 12 base pixels, each subdivides into 4 children (quadtree).
## At resolution N_side = 2^k, there are 12 × N_side² total pixels.
##
## Reference: Gorski et al. 2005, "HEALPix: A Framework for High-Resolution
## Discretization and Fast Analysis of Data Distributed on the Sphere"

## Number of base (root-level) pixels.
const BASE_PIXEL_COUNT := 12

## JR/JP tables for base pixel → (jrll, jpll) in the NESTED scheme.
## jrll = ring index offset, jpll = phi offset.
## These define how each base pixel maps to the sphere.
const JRLL: Array[int] = [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4]
const JPLL: Array[int] = [1, 3, 5, 7, 0, 2, 4, 6, 1, 3, 5, 7]

## Lookup tables for Z-order (Morton) curve bit interleaving.
## Used by nest2ring / ring2nest and pixel subdivision.
static var _utab: PackedInt32Array = PackedInt32Array()
static var _ctab: PackedInt32Array = PackedInt32Array()
static var _tables_built := false

static func _build_tables() -> void:
	if _tables_built:
		return
	_utab.resize(256)
	_ctab.resize(256)
	for i in 256:
		# Spread bits of byte: 0bABCDEFGH → 0b0A0B0C0D0E0F0G0H
		_utab[i] = (i & 0x1) | ((i & 0x2) << 1) | ((i & 0x4) << 2) | ((i & 0x8) << 3) \
			| ((i & 0x10) << 4) | ((i & 0x20) << 5) | ((i & 0x40) << 6) | ((i & 0x80) << 7)
		# Compact (reverse): 0b0A0B0C0D0E0F0G0H → 0bABCDEFGH
		_ctab[i] = (i & 0x1) | ((i & 0x4) >> 1) | ((i & 0x10) >> 2) | ((i & 0x40) >> 3) \
			| ((i & 0x100) >> 4) | ((i & 0x400) >> 5) | ((i & 0x1000) >> 6) | ((i & 0x4000) >> 7)
	_tables_built = true


## Spread bits for x-coordinate (even bit positions).
## Places each bit of v at every other position: bit_k → position 2*k.
## Supports up to 20-bit input (nside up to 1,048,576).
static func _spread_bits(v: int) -> int:
	_build_tables()
	var result := _utab[v & 0xFF] | (_utab[(v >> 8) & 0xFF] << 16)
	if v > 0xFFFF:
		result |= _utab[(v >> 16) & 0xFF] << 32
	return result


## Compact bits from even positions.
## Extracts bits at positions 0, 2, 4, … and packs them contiguously.
## Supports inputs up to 40 bits (nside up to 1,048,576).
static func _compress_bits(v: int) -> int:
	_build_tables()
	if v <= 0xFFFF:
		var raw := ((v & 0x5555) | ((v & 0x55550000) >> 15))
		return _ctab[raw & 0xFF] | (_ctab[(raw >> 8) & 0xFF] << 4)
	# General path: bit-by-bit extraction for large values.
	var result := 0
	var bit := 0
	var p := v
	while p > 0:
		result |= (p & 1) << bit
		p >>= 2
		bit += 1
	return result


## Convert (x, y) within a base pixel to the NESTED sub-pixel index.
## x, y are in [0, nside-1].
static func xy2nest(x: int, y: int) -> int:
	return _spread_bits(x) | (_spread_bits(y) << 1)


## Convert NESTED sub-pixel index to (x, y) within a base pixel.
## Returns Vector2i(x, y) in [0, nside-1].
static func nest2xy(ipix_in_face: int) -> Vector2i:
	var x := _compress_bits(ipix_in_face)
	var y := _compress_bits(ipix_in_face >> 1)
	return Vector2i(x, y)


# ---------------------------------------------------------------------------
# Core coordinate conversions
# ---------------------------------------------------------------------------

## Convert z = cos(theta) and phi to NESTED pixel index.
static func vec2pix_nest_from_zphi(nside: int, z: float, phi: float) -> int:
	var za := absf(z)
	var tt := phi / (PI * 0.5)  # range [0, 4)
	while tt < 0.0:
		tt += 4.0
	while tt >= 4.0:
		tt -= 4.0

	var npface := nside * nside

	var face: int
	var ix: int
	var iy: int

	if za <= 2.0 / 3.0:
		# Equatorial belt
		var temp1 := float(nside) * (0.5 + tt)
		var temp2 := float(nside) * z * 0.75

		var jp := int(temp1 - temp2)  # ascending
		var jm := int(temp1 + temp2)  # descending

		# Face column: standard HEALPix uses jp >> order_ (= jp / nside).
		# The previous formula (jp + nside) / (2*nside) was wrong — it
		# shifted the result by -1 for the upper two equatorial columns,
		# mapping faces 6→5, 7→6.  This caused vec2pix_nest to return
		# a pixel on the wrong face, breaking sample_height_boundary.
		@warning_ignore("integer_division")
		var ifp := jp / nside  # face column [0,4]
		@warning_ignore("integer_division")
		var ifm := jm / nside

		if ifp == ifm:
			face = ifp | 4  # bitwise OR, not +4 (handles ifp==4 → face 4)
		elif ifp < ifm:
			face = ifp
		else:
			face = ifm + 8

		ix = jm & (nside - 1)
		iy = nside - (jp & (nside - 1)) - 1
	else:
		# Polar cap
		var tp := tt - floorf(tt)  # fractional part of tt
		var tmp := float(nside) * sqrt(3.0 * (1.0 - za))

		var jp := int(tp * tmp)
		var jm := int((1.0 - tp) * tmp)

		jp = mini(jp, nside - 1)
		jm = mini(jm, nside - 1)

		if z > 0:
			face = int(tt)
			if face >= 4:
				face = 3
			ix = nside - jm - 1
			iy = nside - jp - 1
		else:
			face = int(tt) + 8
			if face >= 12:
				face = 11
			ix = jp
			iy = jm

	return face * npface + xy2nest(ix, iy)


## Convert a 3D unit direction vector to NESTED pixel index.
static func vec2pix_nest(nside: int, dir: Vector3) -> int:
	var d := dir.normalized()
	var z := d.y  # y-up in Godot
	var phi := atan2(d.z, d.x)
	if phi < 0.0:
		phi += TAU
	return vec2pix_nest_from_zphi(nside, z, phi)


## Convert a NESTED pixel index to a unit direction vector.
static func pix2vec_nest(nside: int, ipix: int) -> Vector3:
	# Delegate to _face_xy_to_vec at pixel centre (ix + 0.5, iy + 0.5).
	# This guarantees the returned direction matches the centre of the
	# grid produced by get_pixel_grid(), which uses _face_xy_to_vec for
	# every vertex.  The old pix2ang_nest path had a phi-shift mismatch
	# in the equatorial belt that placed the pixel centre up to
	# PI/(2·nside) away from the grid centre — large enough at coarse
	# nside to make backface / horizon culling reject visible chunks.
	var npface := nside * nside
	@warning_ignore("integer_division")
	var face := ipix / npface
	var local := ipix % npface
	var xy := nest2xy(local)
	return _face_xy_to_vec(face, float(xy.x) + 0.5, float(xy.y) + 0.5, nside)


# ---------------------------------------------------------------------------
# Pixel boundaries (corners and edges)
# ---------------------------------------------------------------------------

## Return the 4 corner directions of a HEALPix pixel.
## Order: [south, east, north, west] (counterclockwise from bottom).
static func get_pixel_corners(nside: int, ipix: int) -> PackedVector3Array:
	var npface := nside * nside
	@warning_ignore("integer_division")
	var face := ipix / npface
	var local := ipix % npface
	var xy := nest2xy(local)
	var ix := xy.x
	var iy := xy.y

	var result := PackedVector3Array()
	# Corner positions relative to pixel (ix, iy):
	# South: (ix + 0.5, iy - 0.5) — but we use actual corners
	# The pixel corners in face-local coordinates are:
	# (ix, iy), (ix+1, iy), (ix+1, iy+1), (ix, iy+1)
	result.append(_face_xy_to_vec(face, float(ix), float(iy), nside))          # SW
	result.append(_face_xy_to_vec(face, float(ix + 1), float(iy), nside))      # SE
	result.append(_face_xy_to_vec(face, float(ix + 1), float(iy + 1), nside))  # NE
	result.append(_face_xy_to_vec(face, float(ix), float(iy + 1), nside))      # NW

	return result


## Convert face-local fractional pixel coordinates to a unit direction vector.
## (fx, fy) are in [0, nside] — continuous coordinates within the base face.
## Verified against healpy pix2vec for all 49 152 pixels at nside = 64.
static func _face_xy_to_vec(face: int, fx: float, fy: float, nside: int) -> Vector3:
	var ns := float(nside)

	# Ring index (continuous) and azimuthal index
	var jr := float(JRLL[face]) * ns - fx - fy
	var nr: float
	var z: float
	var kp: float
	var phi: float

	if jr < ns:
		# North polar cap
		nr = jr
		z = 1.0 - nr * nr / (3.0 * ns * ns)
		kp = float(JPLL[face]) * nr + fx - fy
		if nr > 0.0:
			phi = kp * PI / (4.0 * nr)
		else:
			phi = 0.0
	elif jr > 3.0 * ns:
		# South polar cap
		nr = 4.0 * ns - jr
		z = -1.0 + nr * nr / (3.0 * ns * ns)
		kp = float(JPLL[face]) * nr + fx - fy
		if nr > 0.0:
			phi = kp * PI / (4.0 * nr)
		else:
			phi = 0.0
	else:
		# Equatorial belt
		nr = ns
		z = (2.0 * ns - jr) * 2.0 / (3.0 * ns)
		kp = float(JPLL[face]) * ns + fx - fy
		phi = kp * PI / (4.0 * ns)

	var st := sqrt(maxf(1.0 - z * z, 0.0))
	return Vector3(st * cos(phi), z, st * sin(phi))


## Analytical inverse of [method _face_xy_to_vec].
## Given a direction and a known base face, compute the continuous
## (fx, fy) face coordinates at [param nside] WITHOUT integer
## quantisation.  Returns Vector2(fx, fy) where each component
## is in [0, nside) for directions inside the face.
## This avoids the vec2pix_nest round-trip which always snaps to
## integer sub-pixel indices and can mis-classify boundary directions.
static func _vec_to_face_xy(dir: Vector3, face: int, nside: int) -> Vector2:
	var d := dir.normalized()
	var z := d.y
	var phi := atan2(d.z, d.x)
	if phi < 0.0:
		phi += TAU

	var ns := float(nside)
	var za := absf(z)
	var jr: float
	var kp: float
	var scale: float  # ns for equatorial, nr for polar caps

	if za <= 2.0 / 3.0:
		# Equatorial belt — same derivation as _face_xy_to_vec:
		#   jr = JRLL[face]*ns - fx - fy
		#   kp = JPLL[face]*ns + fx - fy   =>   phi = kp * PI/(4*ns)
		jr = ns * (2.0 - z * 1.5)
		scale = ns
		kp = phi * 4.0 * ns / PI
	elif z > 0.0:
		# North polar cap
		scale = ns * sqrt(3.0 * (1.0 - za))
		jr = scale
		kp = phi * 4.0 * scale / PI
	else:
		# South polar cap
		scale = ns * sqrt(3.0 * (1.0 + z))
		jr = 4.0 * ns - scale
		kp = phi * 4.0 * scale / PI

	# Handle the phi = 0 / 2π discontinuity.  Faces whose JPLL phi-offset
	# is near 2π (e.g. equatorial face 3 with JPLL=7) would otherwise see
	# kp jump from ~8*scale to ~0 when phi wraps.  Bring kp into the
	# expected half-period window around JPLL[face]*scale.
	var kp_face := float(JPLL[face]) * scale
	if kp - kp_face > 4.0 * scale:
		kp -= 8.0 * scale
	elif kp - kp_face < -4.0 * scale:
		kp += 8.0 * scale

	# Solve:  fx + fy = JRLL[face]*ns - jr,
	#         fx - fy = kp - JPLL[face]*scale
	var sum_fxfy := float(JRLL[face]) * ns - jr
	var diff_fxfy := kp - kp_face

	var fx := (sum_fxfy + diff_fxfy) * 0.5
	var fy := (sum_fxfy - diff_fxfy) * 0.5
	return Vector2(fx, fy)


# ---------------------------------------------------------------------------
# Hierarchical operations (LOD)
# ---------------------------------------------------------------------------

## Return the parent pixel index at nside/2.
## The parent of pixel ipix at nside is ipix / 4 at nside/2.
static func parent_pixel(ipix: int) -> int:
	return ipix / 4


## Return the 4 child pixel indices at nside*2.
## Children of pixel ipix at nside are [4*ipix, 4*ipix+1, 4*ipix+2, 4*ipix+3]
## at nside*2.
static func child_pixels(ipix: int) -> PackedInt32Array:
	var base := ipix * 4
	return PackedInt32Array([base, base + 1, base + 2, base + 3])


## Return the nside (resolution parameter) for a given LOD depth.
## depth 0 → nside=1 (12 pixels), depth k → nside=2^k.
static func depth_to_nside(depth: int) -> int:
	return 1 << depth


## Return the LOD depth for a given nside.
## nside must be a power of 2.
static func nside_to_depth(nside: int) -> int:
	var d := 0
	var n := nside
	while n > 1:
		n >>= 1
		d += 1
	return d


## Total number of pixels at a given nside.
static func npix(nside: int) -> int:
	return 12 * nside * nside


## Approximate angular size (side length in radians) of a pixel at given nside.
static func pixel_angular_size(nside: int) -> float:
	return sqrt(PI / 3.0) / float(nside)


## Approximate side length in meters of a pixel at given nside and planet radius.
static func pixel_side_length(nside: int, radius: float) -> float:
	return radius * pixel_angular_size(nside)


# ---------------------------------------------------------------------------
# Neighbor lookup
# ---------------------------------------------------------------------------

## Return the 8 neighbor pixel indices for a given NESTED pixel.
## Returns a dictionary with keys: "N", "NE", "E", "SE", "S", "SW", "W", "NW".
## Some neighbors may be -1 at the very edges (shouldn't happen for valid pixels).
static func get_neighbors_nest(nside: int, ipix: int) -> Dictionary:
	# Face and local coordinates
	var npface := nside * nside
	@warning_ignore("integer_division")
	var face := ipix / npface
	var local := ipix % npface
	var xy := nest2xy(local)
	var ix := xy.x
	var iy := xy.y

	var result := {}

	# 8 neighbor offsets: (dx, dy) and direction name
	var offsets := [
		[0, 1, "N"], [1, 1, "NE"], [1, 0, "E"], [1, -1, "SE"],
		[0, -1, "S"], [-1, -1, "SW"], [-1, 0, "W"], [-1, 1, "NW"],
	]

	for off in offsets:
		var nx := ix + int(off[0])
		var ny := iy + int(off[1])
		var dir_name: String = off[2]

		if nx >= 0 and nx < nside and ny >= 0 and ny < nside:
			# Same face
			result[dir_name] = face * npface + xy2nest(nx, ny)
		else:
			# Cross face boundary — use the face neighbor tables
			var nb := _get_cross_face_neighbor(face, ix, iy, int(off[0]), int(off[1]), nside)
			result[dir_name] = nb

	return result


## Compute the neighbor pixel index when crossing to another base face.
## This handles the topology of the HEALPix icosahedral sphere.
static func _get_cross_face_neighbor(face: int, ix: int, iy: int,
		dx: int, dy: int, nside: int) -> int:
	var nx := ix + dx
	var ny := iy + dy
	var nbface: int
	var nbx: int
	var nby: int

	# HEALPix face adjacency table.
	# For each face and exit direction, gives [neighbor_face, transform_code].
	# Transform codes: 0=identity, 1=rotate90, 2=rotate180, 3=rotate270, 4=flip_x, 5=flip_y, 6=flip_xy, 7=swap_xy
	# N: North (iy >= nside), S: South (iy < 0), E: East (ix >= nside), W: West (ix < 0)

	# Determine which boundary we're crossing
	var cross_x := 0  # -1=west, 0=none, 1=east
	var cross_y := 0  # -1=south, 0=none, 1=north

	if nx < 0:
		cross_x = -1
	elif nx >= nside:
		cross_x = 1
	if ny < 0:
		cross_y = -1
	elif ny >= nside:
		cross_y = 1

	# Use simplified face neighbor lookup.
	# HEALPix has 3 rows of 4 faces:
	#   Top row (N polar): faces 0-3
	#   Middle row (equatorial): faces 4-7
	#   Bottom row (S polar): faces 8-11
	var row := face / 4  # 0=north, 1=equatorial, 2=south
	var col := face % 4  # 0-3 within row

	if cross_x == 0 and cross_y == 0:
		# No crossing — shouldn't reach here
		return face * nside * nside + xy2nest(nx, ny)

	# Handle single-axis crossings first, then diagonal
	if cross_y == 1 and cross_x == 0:
		# North boundary
		nbx = nx
		nby = ny - nside
		if row == 0:
			# N polar → wrap within polar: face → (face+1)%4
			nbface = (col + 1) % 4
			nbx = nside - 1 - nby
			nby = nx
		elif row == 1:
			# Equatorial → north polar
			nbface = col
			nbx = ny - nside
			nby = nside - 1 - nx
			# Swap and adjust for the particular face connectivity
			nbx = nside - 1 - (ny - nside)
			nby = nx
		else:
			# S polar → equatorial
			nbface = 4 + col
			nbx = nx
			nby = ny - nside
	elif cross_y == -1 and cross_x == 0:
		# South boundary
		nbx = nx
		nby = ny + nside
		if row == 0:
			# N polar → equatorial
			nbface = 4 + col
			nbx = nx
			nby = nside + ny
		elif row == 1:
			# Equatorial → south polar
			nbface = 8 + col
			nbx = nside - 1 - nx
			nby = nside + ny
			# Adjust
			nbx = nside + ny
			nby = nside - 1 - nx
		else:
			# S polar → wrap within polar: face → (face+1)%4 + 8
			nbface = 8 + (col + 3) % 4
			nbx = nside + ny
			nby = nside - 1 - nx
	elif cross_x == 1 and cross_y == 0:
		# East boundary
		nbx = nx - nside
		nby = ny
		if row == 0:
			nbface = 4 + col
			nbx = 0
			nby = ny
		elif row == 1:
			nbface = 4 + (col + 1) % 4
			nbx = 0
			nby = ny
		else:
			nbface = 4 + (col + 1) % 4
			nbx = nx - nside
			nby = ny
	elif cross_x == -1 and cross_y == 0:
		# West boundary
		nbx = nx + nside
		nby = ny
		if row == 0:
			nbface = 4 + (col + 3) % 4
			nbx = nside - 1
			nby = ny
		elif row == 1:
			nbface = 4 + (col + 3) % 4
			nbx = nside - 1
			nby = ny
		else:
			nbface = 4 + col
			nbx = nside - 1
			nby = ny
	else:
		# Diagonal crossing — approximate by going through the corner.
		# For simplicity, find the pixel nearest to the corner point.
		var corner_fx := clampf(float(nx), 0.0, float(nside) - 0.001)
		var corner_fy := clampf(float(ny), 0.0, float(nside) - 0.001)
		var corner_dir := _face_xy_to_vec(face, corner_fx, corner_fy, nside)
		return vec2pix_nest(nside, corner_dir)

	# Clamp to valid range
	nbx = clampi(nbx, 0, nside - 1)
	nby = clampi(nby, 0, nside - 1)
	nbface = clampi(nbface, 0, 11)

	return nbface * nside * nside + xy2nest(nbx, nby)


# ---------------------------------------------------------------------------
# Mesh generation helpers
# ---------------------------------------------------------------------------

## Generate a grid of directions for a HEALPix pixel suitable for terrain meshing.
## Returns a 2D array (PackedVector3Array per row) of (resolution+1)² directions.
## The grid covers the pixel from corner to corner with uniform subdivision.
static func get_pixel_grid(nside: int, ipix: int, resolution: int) -> Array[PackedVector3Array]:
	var npface := nside * nside
	@warning_ignore("integer_division")
	var face := ipix / npface
	var local := ipix % npface
	var xy := nest2xy(local)
	var base_ix := xy.x
	var base_iy := xy.y

	var rows: Array[PackedVector3Array] = []
	var res := resolution
	var inv_res := 1.0 / float(res)

	for vy in range(res + 1):
		var row := PackedVector3Array()
		row.resize(res + 1)
		var fy := float(base_iy) + float(vy) * inv_res
		for vx in range(res + 1):
			var fx := float(base_ix) + float(vx) * inv_res
			row[vx] = _face_xy_to_vec(face, fx, fy, nside)
		rows.append(row)

	return rows


## Return the base face (0-11) and local (ix, iy) for a nested pixel index.
static func pix2face_xy(nside: int, ipix: int) -> Dictionary:
	var npface := nside * nside
	@warning_ignore("integer_division")
	var face := ipix / npface
	var local := ipix % npface
	var xy := nest2xy(local)
	return {"face": face, "ix": xy.x, "iy": xy.y}


## Convert a direction to longitude/latitude in degrees (EPSG:4326 convention).
## Returns Vector2(longitude, latitude) where:
##   longitude ∈ (-180, 180]
##   latitude ∈ [-90, 90]
static func vec2lonlat(dir: Vector3) -> Vector2:
	var d := dir.normalized()
	var lat := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(d.z, d.x))
	return Vector2(lon, lat)


## Convert longitude/latitude (degrees) to unit direction vector.
static func lonlat2vec(lon: float, lat: float) -> Vector3:
	var lon_r := deg_to_rad(lon)
	var lat_r := deg_to_rad(lat)
	var cl := cos(lat_r)
	return Vector3(cl * cos(lon_r), sin(lat_r), cl * sin(lon_r))


# ---------------------------------------------------------------------------
# Equirectangular UV mapping (for textures / QGIS EPSG:4326 compatibility)
# ---------------------------------------------------------------------------

## Convert a unit direction to equirectangular UV in [0, 1].
## u → longitude: 0 = -180°, 1 = +180°
## v → latitude:  0 = +90° (north pole), 1 = -90° (south pole)
## Matches the existing PlanetData.direction_to_uv() convention.
static func direction_to_uv(dir: Vector3) -> Vector2:
	var d := dir.normalized()
	var u := 0.5 + atan2(d.z, d.x) / TAU
	var v := 0.5 - asin(clampf(d.y, -1.0, 1.0)) / PI
	return Vector2(u, v)


# ---------------------------------------------------------------------------
# Geometry → HEALPix pixel queries
# ---------------------------------------------------------------------------

## Return all NESTED pixel indices at [param nside] that are touched by a
## polygon (or polyline) defined by [param vertices] in (longitude, latitude)
## degrees.  Includes pixels containing each vertex and pixels along edges.
## For a single point, pass a one-element array.
static func query_polygon_pixels(nside: int, vertices: Array) -> Array[int]:
	var pixel_set: Dictionary = {}  # ipix → true (used as a set)

	# Add pixel for each vertex.
	for v in vertices:
		var lon: float
		var lat: float
		if v is Vector2:
			lon = v.x; lat = v.y
		elif v is Array and v.size() >= 2:
			lon = float(v[0]); lat = float(v[1])
		else:
			continue
		var dir := lonlat2vec(lon, lat)
		var ipix := vec2pix_nest(nside, dir)
		pixel_set[ipix] = true

	# Walk edges: sample intermediate points every ~half-pixel to avoid
	# missing pixels that the edge crosses between vertices.
	if vertices.size() >= 2:
		# Approximate angular size of a pixel: sqrt(4π / Npix) radians.
		var total_pix := 12 * nside * nside
		var pixel_rad := sqrt(4.0 * PI / float(total_pix))
		var step_rad := pixel_rad * 0.5  # sample at half-pixel intervals

		for i in vertices.size():
			var j := (i + 1) % vertices.size()
			var v0 = vertices[i]
			var v1 = vertices[j]
			var lon0: float; var lat0: float
			var lon1: float; var lat1: float
			if v0 is Vector2:
				lon0 = v0.x; lat0 = v0.y
			elif v0 is Array and v0.size() >= 2:
				lon0 = float(v0[0]); lat0 = float(v0[1])
			else:
				continue
			if v1 is Vector2:
				lon1 = v1.x; lat1 = v1.y
			elif v1 is Array and v1.size() >= 2:
				lon1 = float(v1[0]); lat1 = float(v1[1])
			else:
				continue

			var d0 := lonlat2vec(lon0, lat0)
			var d1 := lonlat2vec(lon1, lat1)
			var angle := d0.angle_to(d1)
			if angle < 1e-12:
				continue
			var steps := ceili(angle / step_rad)
			for s in range(1, steps):
				var t := float(s) / float(steps)
				var interp := d0.slerp(d1, t).normalized()
				var ipix := vec2pix_nest(nside, interp)
				pixel_set[ipix] = true

	# Also include immediate neighbors of every touched pixel to handle
	# polygon fill (the edge may not cross every interior pixel).
	var extra: Dictionary = {}
	for ipix: int in pixel_set:
		var nb := get_neighbors_nest(nside, ipix)
		for dir_name in nb:
			var nb_ipix: int = nb[dir_name]
			if nb_ipix >= 0:
				extra[nb_ipix] = true
	for ipix: int in extra:
		pixel_set[ipix] = true

	var result: Array[int] = []
	for ipix: int in pixel_set:
		result.append(ipix)
	return result
