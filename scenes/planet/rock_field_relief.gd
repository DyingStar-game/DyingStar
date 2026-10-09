@tool
class_name RockFieldRelief
## Rocky terrain: rock blocks, ledges, buttes and inclined strata laid OVER the
## ground — a deterministic height offset added INSIDE
## PlanetData.sample_height_for_direction right after the mountains, so the
## mesh, the collision, the normal probes, the server's below-surface catch,
## the grade profiles and the spawners all stand on the same rocks.
##
## Authored in QGIS as a `rocky_terrain` polygon (layers/rocky_terrain.py),
## exported by export_rocky_terrain.py as a POPULATE record of kind ROCKY whose
## props are the ruggedness preset resolved at export, plus the unit centre,
## wind and dip vectors (cx/cy/cz, wx/wy/wz, dpx/dpy/dpz — no trig here, so the
## Windows client and the Linux server read the same bits) and the measured
## means of the joint and butte terms.
##
## One formula for the ground AND the cliffs. Each Voronoi cell of
## [code]cell_m[/code] is a block that TERRACES the ground under it
## (MountainNoise.terrace, steps of [code]step_m[/code]) with a phase of its own:
##   · on the flat the blocks are slabs at staggered heights;
##   · on a slope the terrace cuts it into ledges — a cliff of blocks;
##   · the dip vector tilts the terrace input — inclined strata;
##   · rare cells of a coarser lattice rise as buttes (their walls get the
##     ledges too), and the lattice is squeezed along the wind (k) — yardangs.
## Near a block edge the two blocks' terraced values blend over
## max(joint width, pitch), so the grid never samples a hard step (no
## crenellation), and a groove of joint_depth_m marks the edge.
##
## Contract (MountainRelief's): [method field_offset] is a PURE function of the
## direction, the ground height below, the field constants and the grid pitch —
## integer-hash noise only, + − × ÷ √ — and its C# twin (RockFieldNative.cs)
## and Python twin (export/planet/rock_field_noise.py) do the same operations
## in the same order, pinned bit-exact by test_rock_field_relief.gd. Every term
## is zero-mean (the terrace by construction, the joints and buttes by their
## exported means) and DROPPED, never faded, once the pitch reaches its cell / 3
## — a coarser LOD loses the rocks, not the mean ground.

## Bump when the relief below — or anything the chunk bakes for it (CUSTOM1,
## the "rock_scree" meta) — changes: re-keys the chunk cache of every planet
## with rocky terrain (PlanetTerrain's "_rk" suffix). 2: scree in the ground's
## baked colour. 3: meandering block edges (warp), darker scree. 4: chalk
## type (soft knobs), CUSTOM1 RGBA with the type code and the altitude.
const ALGO_VERSION := 4
## A term is dropped once the grid pitch reaches its cell / this.
const GATE_DIV := 3.0
## Seed offsets — the same in the three twins.
const SEED_JX := 1
const SEED_JY := 2
const SEED_JZ := 3
const SEED_PHASE := 31
const SEED_BJX := 41
const SEED_BJY := 42
const SEED_BJZ := 43
const SEED_BPICK := 59
const SEED_BRADIUS := 61
const SEED_BHEIGHT := 63
const SEED_WX := 71
const SEED_WY := 72
const SEED_WZ := 73
const SEED_LUMP := 81
const SEED_LUMP2 := 82
## Block edges meander: the lattice input is warped by this share of a block,
## over this many blocks (slope 0.25 × 3.75 / 2 < 1: the warp never folds).
const WARP_AMP := 0.25
const WARP_WAVELENGTH := 2.0
## Floors (the exporter applies the same).
const CELL_MIN_M := 10.0
const FEATHER_MIN_M := 250.0

## The ruggedness levels, in the order of the record's `level`.
const LEVELS: Array[String] = ["flat", "low", "medium", "rugged", "very_rugged"]
## Level presets — the same numbers as tools/planettech/qgis/export/planet/
## rocky_terrain.py PRESETS / INTENSITY (test_rock_field_relief_py.py holds
## them equal). Only the debug injection reads them here: a pack record always
## carries resolved values.
const PRESETS := {
	"flat": {"cell_m": 120.0, "step_m": 0.0, "riser": 0.25, "joint_depth_m": 0.0,
			"joint_width_m": 30.0, "butte_rate": 0.0, "butte_height_m": 0.0,
			"butte_cell_m": 600.0, "butte_wall_m": 40.0, "detail_m": 3.0, "feather_m": 250.0},
	"low": {"cell_m": 150.0, "step_m": 3.0, "riser": 0.3, "joint_depth_m": 1.0,
			"joint_width_m": 30.0, "butte_rate": 0.0, "butte_height_m": 0.0,
			"butte_cell_m": 600.0, "butte_wall_m": 40.0, "detail_m": 4.0, "feather_m": 300.0},
	"medium": {"cell_m": 120.0, "step_m": 8.0, "riser": 0.25, "joint_depth_m": 2.0,
			"joint_width_m": 30.0, "butte_rate": 0.02, "butte_height_m": 25.0,
			"butte_cell_m": 600.0, "butte_wall_m": 40.0, "detail_m": 6.0, "feather_m": 400.0},
	"rugged": {"cell_m": 100.0, "step_m": 18.0, "riser": 0.2, "joint_depth_m": 4.0,
			"joint_width_m": 30.0, "butte_rate": 0.05, "butte_height_m": 50.0,
			"butte_cell_m": 600.0, "butte_wall_m": 45.0, "detail_m": 8.0, "feather_m": 500.0},
	"very_rugged": {"cell_m": 90.0, "step_m": 35.0, "riser": 0.15, "joint_depth_m": 6.0,
			"joint_width_m": 30.0, "butte_rate": 0.10, "butte_height_m": 90.0,
			"butte_cell_m": 600.0, "butte_wall_m": 50.0, "detail_m": 10.0, "feather_m": 600.0},
}
const INTENSITY: Array[float] = [0.3, 0.5, 0.7, 0.85, 1.0]
## The rock types (the QGIS `style`), in the order of the record's `type` and of
## the shader's type code (CUSTOM1.z = level + 8 × type).
const STYLES: Array[String] = ["slabs", "columnar", "yardang", "strata", "chalk"]
## Chalk: soft knobs of this height per level (m), over LUMP_WAVELENGTH_M —
## export/planet/rocky_terrain.py CHALK_LUMP_M (debug copy).
const CHALK_LUMP_M: Array[float] = [0.0, 1.5, 3.0, 5.0, 8.0]
const LUMP_WAVELENGTH_M := 160.0

static var _native_tried := false
static var _script: Script = null
## Tests flip this to exercise the GDScript path.
static var use_native := true


static func native_available() -> bool:
	if not _native_tried:
		_native_tried = true
		_script = NativeScript.load_usable("res://scenes/planet/native/RockFieldNative.cs",
				["Configure", "Offset", "Surface"])
	return _script != null


## One prepared rocky_terrain record.
class Field:
	extends RefCounted
	## The outline (polygon, full, bbox) — MountainRelief.envelope reads it.
	var zone: MountainRelief.Zone
	var feather_m := 400.0
	var cell_m := 120.0
	var step_m := 8.0
	var riser := 0.25
	var joint_depth_m := 0.0
	var joint_width_m := 30.0
	var joint_mean_m := 0.0
	var butte_rate := 0.0
	var butte_height_m := 0.0
	var butte_cell_m := 600.0
	var butte_wall_m := 40.0
	var butte_mean_m := 0.0
	## Soft knobs (chalk): height (m) and wavelength (m); 0 = none.
	var lump_m := 0.0
	var lump_wavelength_m := LUMP_WAVELENGTH_M
	var seed := 0
	## Unit centre, unit wind tangent, squeeze along the wind (1 − 1/elongation).
	var c := Vector3.UP
	var w := Vector3.RIGHT
	var k := 0.0
	## Dip direction × tan(dip).
	var dp := Vector3.ZERO
	## 0 flat … 4 very rugged, and the shader's intensity / small-block size.
	var level := 2
	## Index in STYLES.
	var type_id := 0
	var intensity := 0.7
	var detail_m := 6.0
	var ruggedness := "medium"
	var style := "slabs"
	var name := ""
	## RockFieldNative, null without the assembly.
	var native: RefCounted = null


## Prepare a decoded rocky_terrain record (ModifierPack._decode_populate output).
## Pure, like MountainRelief.prepare_zone.
static func prepare(z: Dictionary) -> Field:
	var f := Field.new()
	f.name = str(z.get("name", ""))
	f.ruggedness = str(z.get("ruggedness", f.ruggedness))
	f.style = str(z.get("style", f.style))
	f.level = clampi(int(z.get("level", f.level)), 0, 4)
	f.type_id = clampi(int(z.get("type", maxi(STYLES.find(f.style), 0))), 0, STYLES.size() - 1)
	f.lump_m = maxf(float(z.get("lump_m", 0.0)), 0.0)
	f.lump_wavelength_m = maxf(float(z.get("lump_wavelength_m", LUMP_WAVELENGTH_M)), 2.0 * CELL_MIN_M)
	f.intensity = clampf(float(z.get("intensity", f.intensity)), 0.0, 1.0)
	f.detail_m = maxf(float(z.get("detail_m", f.detail_m)), 0.1)
	f.feather_m = maxf(float(z.get("feather_m", f.feather_m)), FEATHER_MIN_M)
	f.cell_m = maxf(float(z.get("cell_m", f.cell_m)), CELL_MIN_M)
	f.step_m = maxf(float(z.get("step_m", f.step_m)), 0.0)
	f.riser = clampf(float(z.get("riser", f.riser)), 0.02, 1.0)
	f.joint_depth_m = maxf(float(z.get("joint_depth_m", f.joint_depth_m)), 0.0)
	f.joint_width_m = maxf(float(z.get("joint_width_m", f.joint_width_m)), 1.0)
	f.joint_mean_m = float(z.get("joint_mean_m", 0.0))
	f.butte_rate = clampf(float(z.get("butte_rate", f.butte_rate)), 0.0, 1.0)
	f.butte_height_m = maxf(float(z.get("butte_height_m", f.butte_height_m)), 0.0)
	f.butte_cell_m = maxf(float(z.get("butte_cell_m", f.butte_cell_m)), CELL_MIN_M)
	f.butte_wall_m = clampf(float(z.get("butte_wall_m", f.butte_wall_m)), 1.0,
			f.butte_cell_m * 0.5)
	f.butte_mean_m = float(z.get("butte_mean_m", 0.0))
	f.seed = int(z.get("seed", 0))
	f.c = Vector3(float(z.get("cx", 0.0)), float(z.get("cy", 1.0)), float(z.get("cz", 0.0)))
	f.w = Vector3(float(z.get("wx", 1.0)), float(z.get("wy", 0.0)), float(z.get("wz", 0.0)))
	f.k = clampf(float(z.get("k", 0.0)), 0.0, 0.95)
	f.dp = Vector3(float(z.get("dpx", 0.0)), float(z.get("dpy", 0.0)), float(z.get("dpz", 0.0)))
	var mz := MountainRelief.Zone.new()
	mz.prm = MountainNoise.Params.new()
	mz.prm.feather_m = f.feather_m
	var poly: PackedVector2Array = z.get("polygon", PackedVector2Array())
	if str(z.get("coverage", "partial")) == "full" or poly.size() < 3:
		mz.full = true
	else:
		mz.polygon = poly
		mz.bbox = MountainRelief._bounds(poly, 0.0)
	f.zone = mz
	if use_native and native_available():
		var n: RefCounted = _script.new()
		n.Configure(mz.polygon if not mz.full else PackedVector2Array(), f.feather_m,
				f.cell_m, f.step_m, f.riser, f.joint_depth_m, f.joint_width_m, f.joint_mean_m,
				f.butte_rate, f.butte_height_m, f.butte_cell_m, f.butte_wall_m, f.butte_mean_m,
				f.seed, f.c, f.w, f.k, f.dp, f.intensity, f.detail_m, f.lump_m,
				f.lump_wavelength_m)
		n.Level = shader_code(f)
		f.native = n
	return f


## Total rock offset (m) of [param fields] at [param dir] over a ground at
## [param h_below] (heightmap + mountains). Fields add, like the mountains.
static func offset(dir: Vector3, radius: float, fields: Array, eff_spacing_m: float,
		h_below: float) -> float:
	var total := 0.0
	var m_per_deg := radius * PI / 180.0
	var have_ll := false
	var ll := Vector2.ZERO
	for fv in fields:
		var f: Field = fv
		var env := 1.0
		if not f.zone.full:
			if not have_ll:
				ll = HEALPix.vec2lonlat(dir)
				have_ll = true
			env = MountainRelief.envelope(ll, f.zone, m_per_deg, f.feather_m)
			if env <= 0.0:
				continue
		total += env * field_offset(dir, radius, f, eff_spacing_m, h_below)
	return total


## The shader's type code of [param f]: level + 8 × type (CUSTOM1.z).
static func shader_code(f: Field) -> int:
	return f.level + 8 * f.type_id


## What the shader draws at [param dir]: (intensity × envelope, small-block size
## in metres, shader_code) of the strongest field there, Vector3.ZERO outside
## every field. Pitch-free.
static func surface(dir: Vector3, radius: float, fields: Array) -> Vector3:
	var best := Vector3.ZERO
	var m_per_deg := radius * PI / 180.0
	var have_ll := false
	var ll := Vector2.ZERO
	for fv in fields:
		var f: Field = fv
		var env := 1.0
		if not f.zone.full:
			if not have_ll:
				ll = HEALPix.vec2lonlat(dir)
				have_ll = true
			env = MountainRelief.envelope(ll, f.zone, m_per_deg, f.feather_m)
		var a := env * f.intensity
		if a > best.x:
			best = Vector3(a, f.detail_m, float(shader_code(f)))
	return best


## The field's offset without its envelope — the arithmetic the twins pin.
static func field_offset(dir: Vector3, radius: float, f: Field, eff_spacing_m: float,
		h_below: float) -> float:
	var cell_m := f.cell_m
	var bcell := f.butte_cell_m
	var blocks_on := eff_spacing_m < cell_m / GATE_DIV
	var buttes_on := f.butte_rate > 0.0 and f.butte_height_m > 0.0 \
			and eff_spacing_m < bcell / GATE_DIV
	var lump_wl := f.lump_wavelength_m
	var lumps_on := f.lump_m > 0.0 and eff_spacing_m < lump_wl * 0.5
	if not blocks_on and not buttes_on and not lumps_on:
		return 0.0
	var dx := dir.x
	var dy := dir.y
	var dz := dir.z
	var px := dx * radius
	var py := dy * radius
	var pz := dz * radius
	var wx := f.w.x
	var wy := f.w.y
	var wz := f.w.z
	var kd := f.k * (px * wx + py * wy + pz * wz)
	var w := warp(px - wx * kd, py - wy * kd, pz - wz * kd, cell_m, f.seed)
	var qx: float = w[0]
	var qy: float = w[1]
	var qz: float = w[2]
	var bump := 0.0
	var out := 0.0
	if buttes_on:
		bump = buttes(qx / bcell, qy / bcell, qz / bcell, f, eff_spacing_m)
		out = bump - f.butte_mean_m
	if lumps_on:
		# Soft knobs (chalk): two octaves of zero-mean value noise, the second
		# dropped below a quarter wavelength.
		var sx := qx / lump_wl
		var sy := qy / lump_wl
		var sz := qz / lump_wl
		var nl := MountainNoise.snoise(Vector3(sx, sy, sz), f.seed + SEED_LUMP)
		if eff_spacing_m < lump_wl * 0.25:
			nl = nl + 0.5 * MountainNoise.snoise(Vector3(sx * 2.0, sy * 2.0, sz * 2.0),
					f.seed + SEED_LUMP2)
		out = out + f.lump_m * nl
	if not blocks_on:
		return out
	var step := f.step_m
	var jd := f.joint_depth_m
	if step <= 0.0 and jd <= 0.0:
		return out
	var sd := f.seed
	var vor := voronoi(qx / cell_m, qy / cell_m, qz / cell_m, sd)
	var e_m: float = vor[6] * cell_m
	var jw := f.joint_width_m
	if step > 0.0:
		var s := ((dx - f.c.x) * f.dp.x + (dy - f.c.y) * f.dp.y + (dz - f.c.z) * f.dp.z) * radius
		var x0 := h_below + bump + s
		var riser := f.riser
		var lift := step * (1.0 - riser) * 0.5
		var x1 := x0 + (MountainNoise.cell(vor[0], vor[1], vor[2], sd + SEED_PHASE) - 0.5) * step
		var x2 := x0 + (MountainNoise.cell(vor[3], vor[4], vor[5], sd + SEED_PHASE) - 0.5) * step
		var g1 := MountainNoise.terrace(x1, step, riser) - x1 + lift
		var g2 := MountainNoise.terrace(x2, step, riser) - x2 + lift
		var bw := maxf(jw, eff_spacing_m)
		var t := 0.5 * (1.0 - smoothstep(0.0, bw, e_m))
		out = out + (g1 + (g2 - g1) * t)
	if jd > 0.0 and eff_spacing_m < jw:
		out = out - (jd * (1.0 - smoothstep(0.0, jw, e_m)) - f.joint_mean_m)
	return out


## The lattice input bent so the block edges meander instead of running dead
## straight for a hundred metres: [qx', qy', qz'] (m).
static func warp(qx: float, qy: float, qz: float, cell_m: float, sd: int) -> Array:
	var lam := cell_m * WARP_WAVELENGTH
	var amp := cell_m * WARP_AMP
	var s := Vector3(qx / lam, qy / lam, qz / lam)
	return [qx + amp * MountainNoise.snoise(s, sd + SEED_WX),
			qy + amp * MountainNoise.snoise(s, sd + SEED_WY),
			qz + amp * MountainNoise.snoise(s, sd + SEED_WZ)]


## Nearest feature cell (ix, iy, iz), the cell across its nearest edge, and the
## distance to that edge in cell units: [ix1, iy1, iz1, ix2, iy2, iz2, edge].
## Inigo Quilez's Voronoi edges, both passes 3×3×3, integer-hash jitter.
static func voronoi(x: float, y: float, z: float, sd: int) -> Array:
	var fx0 := floorf(x)
	var fy0 := floorf(y)
	var fz0 := floorf(z)
	var ix := int(fx0)
	var iy := int(fy0)
	var iz := int(fz0)
	var fx := x - fx0
	var fy := y - fy0
	var fz := z - fz0
	var md := 1.0e9
	var mrx := 0.0
	var mry := 0.0
	var mrz := 0.0
	var mgx := 0
	var mgy := 0
	var mgz := 0
	for k in range(-1, 2):
		for j in range(-1, 2):
			for i in range(-1, 2):
				var rx := float(i) + MountainNoise.cell(ix + i, iy + j, iz + k, sd + SEED_JX) - fx
				var ry := float(j) + MountainNoise.cell(ix + i, iy + j, iz + k, sd + SEED_JY) - fy
				var rz := float(k) + MountainNoise.cell(ix + i, iy + j, iz + k, sd + SEED_JZ) - fz
				var d := rx * rx + ry * ry + rz * rz
				if d < md:
					md = d
					mrx = rx
					mry = ry
					mrz = rz
					mgx = i
					mgy = j
					mgz = k
	var edge := 1.0e9
	var nbx := mgx
	var nby := mgy
	var nbz := mgz
	for k in range(-1, 2):
		for j in range(-1, 2):
			for i in range(-1, 2):
				var gx := mgx + i
				var gy := mgy + j
				var gz := mgz + k
				var rx := float(gx) + MountainNoise.cell(ix + gx, iy + gy, iz + gz, sd + SEED_JX) - fx
				var ry := float(gy) + MountainNoise.cell(ix + gx, iy + gy, iz + gz, sd + SEED_JY) - fy
				var rz := float(gz) + MountainNoise.cell(ix + gx, iy + gy, iz + gz, sd + SEED_JZ) - fz
				var ddx := rx - mrx
				var ddy := ry - mry
				var ddz := rz - mrz
				var dd := ddx * ddx + ddy * ddy + ddz * ddz
				if dd > 1.0e-5:
					var e := ((0.5 * (mrx + rx)) * ddx + (0.5 * (mry + ry)) * ddy \
							+ (0.5 * (mrz + rz)) * ddz) / sqrt(dd)
					if e < edge:
						edge = e
						nbx = gx
						nby = gy
						nbz = gz
	return [ix + mgx, iy + mgy, iz + mgz, ix + nbx, iy + nby, iz + nbz, edge]


## Height (m) of the tallest butte reaching (x, y, z) — butte-cell units.
static func buttes(x: float, y: float, z: float, f: Field, eff_spacing_m: float) -> float:
	var fx0 := floorf(x)
	var fy0 := floorf(y)
	var fz0 := floorf(z)
	var ix := int(fx0)
	var iy := int(fy0)
	var iz := int(fz0)
	var fx := x - fx0
	var fy := y - fy0
	var fz := z - fz0
	var sd := f.seed
	var bc := f.butte_cell_m
	var wall := maxf(f.butte_wall_m, eff_spacing_m)
	var best := 0.0
	for k in range(-1, 2):
		for j in range(-1, 2):
			for i in range(-1, 2):
				var cx := ix + i
				var cy := iy + j
				var cz := iz + k
				if MountainNoise.cell(cx, cy, cz, sd + SEED_BPICK) >= f.butte_rate:
					continue
				var rx := float(i) + MountainNoise.cell(cx, cy, cz, sd + SEED_BJX) - fx
				var ry := float(j) + MountainNoise.cell(cx, cy, cz, sd + SEED_BJY) - fy
				var rz := float(k) + MountainNoise.cell(cx, cy, cz, sd + SEED_BJZ) - fz
				var d_m := sqrt(rx * rx + ry * ry + rz * rz) * bc
				var r0 := bc * (0.12 + 0.13 * MountainNoise.cell(cx, cy, cz, sd + SEED_BRADIUS))
				if d_m >= r0 + wall:
					continue
				var hgt := f.butte_height_m * (0.6 + 0.4 * MountainNoise.cell(cx, cy, cz,
						sd + SEED_BHEIGHT))
				var b := hgt * (1.0 - smoothstep(r0, r0 + wall, d_m))
				if b > best:
					best = b
	return best


## (joint_mean_m, butte_mean_m) of [param f] — the area means the exporter
## measures (export/planet/rock_field_noise.py term_means, same grid), for a
## debug / test record that has none. Not pinned bit-exact: only its own
## records read the result.
static func term_means(f: Field, radius: float) -> Vector2:
	const GRID := 48
	var c := f.c
	var a := Vector3(0.0, 1.0, 0.0) if absf(c.y) < 0.9 else Vector3(1.0, 0.0, 0.0)
	var u := c.cross(a).normalized()
	var v := c.cross(u)
	var jm := 0.0
	var bm := 0.0
	for pass_i in 2:
		var span := 24.0 * (f.cell_m if pass_i == 0 else f.butte_cell_m)
		if pass_i == 0 and f.joint_depth_m <= 0.0:
			continue
		if pass_i == 1 and (f.butte_rate <= 0.0 or f.butte_height_m <= 0.0):
			continue
		var acc := 0.0
		for ia in GRID:
			for ib in GRID:
				var su := ((ia + 0.5) / GRID - 0.5) * span / radius
				var sv := ((ib + 0.5) / GRID - 0.5) * span / radius
				var p := (c + u * su + v * sv).normalized() * radius
				var q0 := p - f.w * (f.k * p.dot(f.w))
				var wq := warp(q0.x, q0.y, q0.z, f.cell_m, f.seed)
				var q := Vector3(wq[0], wq[1], wq[2])
				if pass_i == 0:
					var e: float = voronoi(q.x / f.cell_m, q.y / f.cell_m, q.z / f.cell_m,
							f.seed)[6] * f.cell_m
					acc += f.joint_depth_m * (1.0 - smoothstep(0.0, f.joint_width_m, e))
				else:
					acc += buttes(q.x / f.butte_cell_m, q.y / f.butte_cell_m, q.z / f.butte_cell_m,
							f, 0.0)
		if pass_i == 0:
			jm = acc / float(GRID * GRID)
		else:
			bm = acc / float(GRID * GRID)
	return Vector2(jm, bm)


## The resolved props of a debug field of [param level] and [param style] —
## export/planet/rocky_terrain.py resolve_rocky, with fixed values where the
## exporter hashes the position (azimuths 45° / 135°, strata dip 14°, seed by
## level). [param overrides] win, like a typed QGIS field.
static func resolve_debug(level: String, style: String, overrides: Dictionary) -> Dictionary:
	var lv := level if PRESETS.has(level) else "medium"
	var out: Dictionary = (PRESETS[lv] as Dictionary).duplicate()
	out["elongation"] = 1.0
	out["dip_deg"] = 0.0
	out["lump_m"] = 0.0
	out["lump_wavelength_m"] = LUMP_WAVELENGTH_M
	if lv != "flat":
		match style:
			"chalk":
				out["step_m"] = 0.0
				out["joint_depth_m"] = 0.0
				out["butte_rate"] = 0.0
				out["lump_m"] = CHALK_LUMP_M[LEVELS.find(lv)]
			"columnar":
				out["riser"] = maxf(out["riser"] * 0.4, 0.05)
				out["cell_m"] = out["cell_m"] * 0.75
				out["detail_m"] = out["detail_m"] * 0.7
			"yardang":
				out["elongation"] = 3.0
				out["butte_rate"] = maxf(out["butte_rate"] * 3.0, 0.06)
				out["butte_height_m"] = maxf(out["butte_height_m"], 20.0)
				out["butte_cell_m"] = out["butte_cell_m"] * 0.8
			"strata":
				out["dip_deg"] = 14.0
				out["riser"] = out["riser"] * 0.6
	out["dip_azimuth_deg"] = 135.0
	out["wind_azimuth_deg"] = 45.0
	out["seed"] = 1000 + LEVELS.find(lv)
	out.merge(overrides, true)
	out["ruggedness"] = lv
	out["style"] = style
	out["level"] = LEVELS.find(lv)
	out["type"] = maxi(STYLES.find(style), 0)
	out["intensity"] = INTENSITY[LEVELS.find(lv)]
	return out


## A debug / override record Dictionary: a disc of [param radius_km] at
## [param lonlat] (degrees), [param props] the resolved fields (any missing one
## takes the Field default). Computes the vectors the exporter would, once.
static func debug_record(lonlat: Vector2, radius_km: float, radius: float,
		props: Dictionary) -> Dictionary:
	var z := props.duplicate()
	var mpd := radius * PI / 180.0
	var r_deg := radius_km * 1000.0 / mpd
	var lat_c := cos(deg_to_rad(clampf(lonlat.y, -89.5, 89.5)))
	var poly := PackedVector2Array()
	for i in 32:
		var a := TAU * float(i) / 32.0
		poly.append(lonlat + Vector2(cos(a) * r_deg / maxf(lat_c, 0.05), sin(a) * r_deg))
	z["coverage"] = "partial"
	z["polygon"] = poly
	var c := HEALPix.lonlat2vec(lonlat.x, lonlat.y)
	z["cx"] = c.x
	z["cy"] = c.y
	z["cz"] = c.z
	var lo := deg_to_rad(lonlat.x)
	var la := deg_to_rad(lonlat.y)
	var east := Vector3(-sin(lo), 0.0, -cos(lo))
	var north := Vector3(-sin(la) * cos(lo), cos(la), sin(la) * sin(lo))
	var wa := deg_to_rad(float(props.get("wind_azimuth_deg", 0.0)))
	var w := (north * cos(wa) + east * sin(wa)).normalized()
	z["wx"] = w.x
	z["wy"] = w.y
	z["wz"] = w.z
	z["k"] = 1.0 - 1.0 / maxf(float(props.get("elongation", 1.0)), 1.0)
	var da := deg_to_rad(float(props.get("dip_azimuth_deg", 0.0)))
	var dv := (north * cos(da) + east * sin(da)).normalized() \
			* tan(deg_to_rad(float(props.get("dip_deg", 0.0))))
	z["dpx"] = dv.x
	z["dpy"] = dv.y
	z["dpz"] = dv.z
	if not z.has("name"):
		z["name"] = "debug"
	return z
