class_name CaveApproach
extends RefCounted
## Version 9 porch approach. A porch diving through gentle ground used to open a straight trench whose walls
## were the mouth's outline drawn along the axis: it read as a cutting; bored into a mountain flank, its mouth
## was a hole in a grassy slope. Here every porch opens at the foot of a cliff. In gentle ground it stands at
## the back of a collapse hollow: a path sloping down at the porch's grade between talus aprons that steepen
## into banks of 30–56° up to the ground. In a flank it is a notch: a terrace in front of the mouth, steep
## flanks of 60–78°, the cliff above. Into a real cliff the porch is bored straight, as before.
## Either way the cliff curves forward around the mouth. A height field in
## the site frame (x lateral, z along the heading, y up), from the profile and the pinned fit only: the terrain
## cut never queries the relief. Its rim lies on the real ground; the real ground also clips its inside.
## Rows along the heading (at least ROW_M apart), more across the cliff; at least COLUMNS columns across, about
## COLUMN_M apart on the widest row.
const ROWS := 28
const ROW_M := 0.6
const CLIFF_ROWS := 10
const COLUMNS := 24
const COLUMN_M := 0.75
## Largest change (m) of the rim's lateral reach between two rows, and the cap on rows it may add.
const RIM_STEP_M := 1.5
const MAX_ROWS := 140
## The rim is simplified to within this distance (m), so the terrain cut keeps few convex parts.
const RIM_TOLERANCE_M := 0.2
## Grade of the talus aprons beside the path (tan 18°), and the rock (m) the fit keeps over the mouth: the
## cliff the porch opens in stands that much above its vault.
const TALUS_TAN := 0.325
const COVER_M := 2.5
## Slope of the cliff's face (tan 72°), and how far (m) its top bulges back over the mouth: the vault keeps
## COVER_M − (CREST_M + 0.3) × CLIFF_TAN of rock under the face.
const CLIFF_TAN := 3.0
const CREST_M := 0.4
## Steepest ground (tan 50°) where a porch gets an approach; beyond, the relief is the cliff.
const MAX_SLOPE_TAN := 1.2

static var _outlines := {}
static var _lock := Mutex.new()


## Version 9 porches get an approach (and the fit keeps COVER_M of rock over their mouth).
static func for_profile(spec: Dictionary) -> bool:
    return int(spec.version) >= 9 and str(spec.entrance_type) != "shaft"


## A fitted version 9 porch (its straight part [param axis_m] is known) opens in its approach, unless the relief
## is already a cliff: there the mouth is bored straight into the rock face, which a vertical cut through the
## hollow's plan would slice from top to bottom.
static func applies(spec: Dictionary, descent_deg: float, axis_m: float) -> bool:
    return for_profile(spec) and axis_m > 0.0 and ground_slope(spec, descent_deg, axis_m) <= MAX_SLOPE_TAN


## Grade of the ground the fit found (rise per metre along the heading): the plane through the entrance point
## and COVER_M above the vault of the first covered station.
static func ground_slope(spec: Dictionary, descent_deg: float, axis_m: float) -> float:
    var top := 0.0
    for point in CavePortal.porch_arch(spec):
        top = maxf(top, point.y)
    var descent := deg_to_rad(descent_deg)
    var reach := maxf(axis_m * cos(descent) + top * sin(descent), 0.5)
    return clampf((top * cos(descent) - axis_m * sin(descent) + COVER_M) / reach, 0.0, 8.0)


## The hollow of a porch pinned at [param descent_deg] with a straight part of [param axis_m] (CavePortal.fit).
## The ground is modelled as a plane rising along the heading, through the entrance point and COVER_M above the
## vault of the first covered station: where the fit found the relief.
static func model(spec: Dictionary, descent_deg: float, axis_m: float) -> Dictionary:
    var side := 0.0
    var top := 0.0
    for point in CavePortal.porch_arch(spec):
        side = maxf(side, absf(point.x))
        top = maxf(top, point.y)
    var rng := RandomNumberGenerator.new()
    rng.seed = int(spec.seed) * 2971 + 811
    var descent := deg_to_rad(descent_deg)
    var tan_d := tan(descent)
    var tan_a := ground_slope(spec, descent_deg, axis_m)
    # From gentle ground (a collapse hollow) to a mountain flank (a notch with steep sides).
    var steep := clampf((tan_a - 0.15) / 0.65, 0.0, 1.0)
    # The cliff's top edge passes just behind the vault of the first covered station, where the fit keeps
    # COVER_M of rock: behind it the ground is untouched. Its face meets the path [code]run[/code] in front.
    var back := axis_m * cos(descent) + top * sin(descent) + 0.3
    var run := back * (tan_a + tan_d) / (CLIFF_TAN + tan_a + tan_d)
    # The path is as wide as the mouth's floor; the talus aprons on either side, gentle by the path and
    # steepening towards the rim, reach further on one side: collapses are never symmetric.
    var floor_half := side + 0.3
    var apron := lerpf(rng.randf_range(2.5, 5.0), 0.8, steep)
    var lopsided := rng.randf_range(0.8, 3.0) * (1.0 if rng.randf() < 0.5 else -1.0)
    # The cliff's top runs straight across the mouth's span (so every point of the porch is in front of it until
    # covered) and curves forward beyond, around the hollow's sides.
    var curve := 0.6 / maxf(back * (tan_a + tan_d), 4.0)
    # The porch's prism only cuts from where its vault can meet the cliff (see prism_start): the hollow is at
    # least as wide as the mouth from there, its front tip rounded before.
    var cut_z := back - run - 1.0 - top * sin(descent) - 0.5
    var noise := FastNoiseLite.new()
    noise.seed = (int(spec.seed) ^ 0x2b7d) & 0x7fffffff
    noise.frequency = 0.12
    noise.fractal_octaves = 2
    var m := {"tan_d": tan_d, "tan_a": tan_a, "cos_d": cos(descent), "sin_d": sin(descent), "back": back, "run": run,
        "side": side, "top": top, "floor_half": floor_half, "apron": apron, "lopsided": lopsided * (1.0 - steep),
        "curve": curve, "banks": Vector2(lerpf(30.0, 60.0, steep), lerpf(56.0, 78.0, steep)),
        "round": clampf(cut_z - 0.5, 0.0, floor_half), "noise": noise}
    # The porch (its prism and rings) starts half a metre before the first station where a point of its mouth
    # meets the cliff: the cliff is cut by the mouth's outline, never by the prism's flat end. Never before the
    # hollow is wider than the mouth: the prism would cut the ground beside its rounded front.
    var axes := CavePortal.porch_axes(descent_deg)
    var arch := CavePortal.porch_arch(spec)
    var earliest := (float(m.round) + 0.5) / cos(descent)
    var station := earliest
    while station < axis_m:
        var met := false
        for point in arch:
            var p: Vector3 = (axes.forward as Vector3) * station + Vector3.RIGHT * point.x + (axes.up as Vector3) * point.y
            if height(m, p.x, p.z, false) >= p.y + 0.01:
                met = true
                break
        if met:
            break
        station += 0.25
    m.start = minf(maxf(earliest, station - 0.5), axis_m)
    # From here to the cliff the path stays under the plane of the porch's floor.
    m.level_z = float(m.start) * cos(descent) - 1.0
    return m


## Height of the hollow's surface at plan point ([param x], [param z]) before the real ground clips it.
## Without [param relief] (talus stones and the path's dips) it grows outward from the axis, so each row of the
## outline is one interval.
static func height(m: Dictionary, x: float, z: float, relief: bool = true) -> float:
    var noise: FastNoiseLite = m.noise
    var ground := z * float(m.tan_a)
    var path := -z * float(m.tan_d) - 0.05  # just under the porch floor's plane: that floor starts at the cliff
    var round := float(m.round)
    var side := 1.0 if x >= 0.0 else -1.0
    var half := float(m.floor_half) * (sqrt(clampf(z / round, 0.0, 1.0)) if round > 0.0 else 1.0)
    # Talus aprons rising at 18° by the path and steepening to banks of 30–56° (bays and promontories along
    # them, one side's apron reaching further): a concave valley profile, as scree settles.
    var apron := float(m.apron) + maxf(0.0, float(m.lopsided) * side) \
        + 1.4 * (0.5 + 0.5 * noise.get_noise_2d(z * 0.8, side * 17.0))
    var banks: Vector2 = m.banks
    var bank := tan(deg_to_rad(lerpf(banks.x, banks.y, 0.5 + 0.5 * noise.get_noise_2d(z * 0.5, side * 40.0))))
    var u := maxf(0.0, absf(x) - half)
    var lateral := TALUS_TAN * u + (bank - TALUS_TAN) * u * u / (2.0 * apron) if u < apron \
        else TALUS_TAN * apron + (bank - TALUS_TAN) * apron * 0.5 + (u - apron) * bank
    var valley := path + lateral
    # The cliff: a face of ~72° rising to the ground behind the mouth, straight across its span and curving
    # forward beyond, its top wavering there. Where it meets the valley a fillet of fallen rock rounds its foot.
    # Over the mouth's span its top bulges back a little, never in front of the porch; beyond, it comes forward.
    # Both only ever move away from the axis, so each row of the outline stays one interval.
    var across := absf(x) / maxf(float(m.side), 0.1)
    var beyond := maxf(0.0, absf(x) - float(m.side))
    var back := float(m.back) + (CREST_M * (1.0 - across * across) if across < 1.0 else -float(m.curve) * beyond * beyond)
    var face := ground - maxf(0.0, back - z) * CLIFF_TAN
    var surface := _smooth_max(valley, face, 0.8)
    if relief and surface < ground:
        # Blocks and slumps on the talus and the banks. Up the path, gentle heaps of scree; near the mouth, only
        # shallow dips (the porch's floor plane). Nothing on the rim or the cliff.
        var talus := smoothstep(float(m.floor_half), float(m.floor_half) + 1.7, absf(x))
        var stones := talus * (0.7 * noise.get_noise_2d(x * 3.1 + 17.0, z * 3.1)
            + 0.35 * noise.get_noise_2d(x * 7.0, z * 7.0 - 31.0))
        var open := 1.0 - smoothstep(float(m.level_z) - 2.0, float(m.level_z), z)
        var heaps := 0.55 * open * maxf(0.0, noise.get_noise_2d(x * 0.7 - 12.0, z * 0.7))
        var dips := -0.12 * (1.0 - open) * (0.5 + 0.5 * noise.get_noise_2d(x * 0.9, z * 0.9 + 55.0))
        var bare := clampf(0.5 + (valley - face) / 1.6, 0.0, 1.0)
        surface += (stones + (heaps + dips) * (1.0 - talus)) * minf(1.0, (ground - surface) / 1.5) * bare
    return surface


## Polynomial smooth maximum: max(a, b) with a fillet [param k] wide where they cross.
static func _smooth_max(a: float, b: float, k: float) -> float:
    var h := clampf(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return lerpf(a, b, h) + k * h * (1.0 - h)


## The model's own ground (the plane the fit measured).
static func ground(m: Dictionary, z: float) -> float:
    return z * float(m.tan_a)


## Station (m along the porch axis) from which the porch's prism cuts and its rings start: just before its
## mouth meets the cliff. In front of it the hollow alone opens the ground.
static func prism_start(m: Dictionary) -> float:
    return float(m.start)


## The hollow's rows (z, then the interval's left and right ends), its rim in the site plane (x, z): the right
## ends front to back, the left ones back to front, its convex parts, depth and the porch prism's first station.
## Cached: the terrain cut asks on every chunk.
static func shape(spec: Dictionary, descent_deg: float, axis_m: float) -> Dictionary:
    var key := str([spec.seed, spec.version, spec.entrance_width_m, spec.entrance_height_m,
        spec.get("entrance_noise", 0.0), descent_deg, axis_m])
    _lock.lock()
    var cached: Variant = _outlines.get(key)
    _lock.unlock()
    if cached != null:
        return cached
    var m := model(spec, descent_deg, axis_m)
    var rows: Array[Vector3] = []
    var back := float(m.back) + CREST_M
    var cliff := back - float(m.run) - 1.0 - CREST_M
    var step := maxf(ROW_M, cliff / ROWS)
    var z := 0.0
    while z < back - 0.01:
        rows.append(Vector3(z, _extent(m, z, -1.0), _extent(m, z, 1.0)))
        z = minf(z + step, cliff) if z < cliff else z + (back - cliff) / CLIFF_ROWS
    rows.append(Vector3(back, 0.0, 0.0))
    # Where the rim runs across the heading (the cliff's top, the rounded ends), rows far apart in width would
    # draw it as a staircase: rows are inserted until neighbours differ by at most RIM_STEP_M on both sides.
    var at := 0
    while at < rows.size() - 1 and rows.size() < MAX_ROWS:
        var a := rows[at]
        var b := rows[at + 1]
        if b.x - a.x > 0.01 and maxf(absf(b.y - a.y), absf(b.z - a.z)) > RIM_STEP_M:
            var middle := (a.x + b.x) * 0.5
            rows.insert(at + 1, Vector3(middle, _extent(m, middle, -1.0), _extent(m, middle, 1.0)))
        else:
            at += 1
    # Each side's rim is simplified (Douglas–Peucker, RIM_TOLERANCE_M) and every row's end put back on it: the
    # cut keeps few convex parts, and the mesh's rim is exactly the cut's outline.
    var sides: Array[PackedVector2Array] = []
    for side: int in [1, 2]:  # a row's y and z: its left and right reach
        var chain := PackedVector2Array()
        for row in rows:
            chain.append(Vector2(row[side], row.x))
        sides.append(_simplify(chain, RIM_TOLERANCE_M))
    for index in rows.size():
        rows[index] = Vector3(rows[index].x, _at_z(sides[0], rows[index].x), _at_z(sides[1], rows[index].x))
    var outline := PackedVector2Array()
    var ends: Array[Vector2] = []
    for point in sides[1]:
        ends.append(point)
    for index in range(sides[0].size() - 1, -1, -1):
        ends.append(Vector2(-sides[0][index].x, sides[0][index].y))
    for point in ends:
        if outline.is_empty() or (point.distance_to(outline[-1]) > 0.01 and point.distance_to(outline[0]) > 0.01):
            outline.append(point)
    var deepest := 0.0
    for row in rows:
        deepest = maxf(deepest, row.x * float(m.tan_d))
    var result := {"rows": rows, "outline": outline, "parts": CavePortal.convex_parts(outline),
        "floor_depth": deepest + 1.0, "start": prism_start(m)}
    _lock.lock()
    _outlines[key] = result
    _lock.unlock()
    return result


## Douglas–Peucker: the points of a polyline (x reach, z) that keep it within [param tolerance] of the original.
static func _simplify(points: PackedVector2Array, tolerance: float) -> PackedVector2Array:
    var keep := PackedByteArray()
    keep.resize(points.size())
    keep[0] = 1
    keep[points.size() - 1] = 1
    var spans: Array[Vector2i] = [Vector2i(0, points.size() - 1)]
    while not spans.is_empty():
        var span: Vector2i = spans.pop_back()
        var farthest := -1
        var distance := tolerance
        for index in range(span.x + 1, span.y):
            var on := Geometry2D.get_closest_point_to_segment(points[index], points[span.x], points[span.y])
            if points[index].distance_to(on) > distance:
                distance = points[index].distance_to(on)
                farthest = index
        if farthest >= 0:
            keep[farthest] = 1
            spans.append(Vector2i(span.x, farthest))
            spans.append(Vector2i(farthest, span.y))
    var result := PackedVector2Array()
    for index in points.size():
        if keep[index] == 1:
            result.append(points[index])
    return result


## Reach of a simplified rim chain (ordered by z) at [param z].
static func _at_z(chain: PackedVector2Array, z: float) -> float:
    for index in chain.size() - 1:
        if z <= chain[index + 1].y:
            return lerpf(chain[index].x, chain[index + 1].x,
                clampf((z - chain[index].y) / maxf(chain[index + 1].y - chain[index].y, 1.0e-9), 0.0, 1.0))
    return chain[-1].x


## Distance from the axis where row [param z]'s surface meets the model ground on side [param side].
static func _extent(m: Dictionary, z: float, side: float) -> float:
    if not _below(m, 0.0, z):
        return 0.0
    var inside := 0.0
    var outside := 0.25
    while _below(m, outside * side, z) and outside < 400.0:
        inside = outside
        outside += 0.25
    for iteration in 10:
        var middle := (inside + outside) * 0.5
        if _below(m, middle * side, z):
            inside = middle
        else:
            outside = middle
    return inside


## Inside the hollow: its surface under the model ground by a millimetre at least. Behind the cliff the surface
## is the ground itself, and the smooth maximum's rounding must not count it in.
static func _below(m: Dictionary, x: float, z: float) -> bool:
    return height(m, x, z, false) < ground(m, z) - 0.001


## The hollow's walls and floor in the site frame, minus the porch's prism ([param porch], its terrain-cut
## opening): the mouth in the cliff. Each row is a grid line between its rim points, which lie on the real
## ground; inside, the model clipped by the real ground.
static func build(data: PlanetData, frame: Transform3D, spec: Dictionary, descent_deg: float, axis_m: float,
        porch: Dictionary) -> Dictionary:
    var wall := CaveGenerator._empty_surface()
    var floor := CaveGenerator._empty_surface()
    var m := model(spec, descent_deg, axis_m)
    var rows: Array[Vector3] = shape(spec, descent_deg, axis_m).rows
    var widest := 0.0
    for row in rows:
        widest = maxf(widest, row.y + row.z)
    var columns := clampi(int(ceil(widest / COLUMN_M)), COLUMNS, 96)
    var grid: Array[PackedVector3Array] = []
    for row in rows:
        var line := PackedVector3Array()
        for column in columns + 1:
            var x := lerpf(-row.y, row.z, float(column) / columns)
            var real := CaveEntrance.ground_in_frame(data, frame, x, row.x).y
            var y := real if column == 0 or column == columns else minf(real, height(m, x, row.x))
            line.append(Vector3(x, y, row.x))
        grid.append(line)
    var faces := PackedVector3Array()
    for index in range(1, grid.size()):
        for column in columns:
            var a := grid[index - 1][column]
            var b := grid[index - 1][column + 1]
            var c := grid[index][column + 1]
            var d := grid[index][column]
            faces.append_array(PackedVector3Array([a, b, c, a, c, d]))
    var to_porch := (porch.frame as Transform3D).affine_inverse() * frame
    faces = CaveTerrainCut.subtract(faces, to_porch, porch)
    for index in range(0, faces.size(), 3):
        # A height field: every face, the cliff's too, looks up into the open air.
        var centre := (faces[index] + faces[index + 1] + faces[index + 2]) / 3.0
        var normal := (faces[index + 1] - faces[index]).cross(faces[index + 2] - faces[index]).normalized()
        var target := floor if absf(normal.y) > 0.65 else wall
        CaveGenerator._triangle(target, faces[index], faces[index + 1], faces[index + 2], centre + Vector3.UP * 3.0)
    # The whole rim, one loop (the left side back to front, the right side front to back), sealed to the terrain
    # shown around it (CaveEntrance.seal_rim). Where the path walks in from the ground, at the front, no lip.
    var rim := PackedVector3Array()
    var lift := PackedFloat32Array()
    for index in range(grid.size() - 1, -1, -1):
        rim.append(grid[index][0])
    for index in grid.size():
        if index < grid.size() - 1 or grid[index][columns].distance_to(rim[0]) > 0.01:
            rim.append(grid[index][columns])
    for point in rim:
        lift.append(smoothstep(0.3, 1.5, point.z * (float(m.tan_a) + float(m.tan_d))))
    CaveEntrance.seal_rim(data, frame, rim, CaveEntrance.rim_normals(rim, 1.0, true), lift, true, wall)
    return {"wall": wall, "floor": floor}
