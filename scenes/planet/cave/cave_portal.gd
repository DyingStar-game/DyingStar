class_name CavePortal
extends RefCounted
## Version 8 entrances. A porch is a gallery bored into the relief along a straight axis (horizontal into a
## cliff, descending up to 24° into gentler ground), so its mouth is wherever that gallery meets the terrain.
## A doline (sinkhole) is a wide oculus opening the ground above the first chamber's vault.
## One convex mouth outline drives the terrain cut, the gallery walls and presence, like earlier openings.

const RING := CaveGenerator.RING_SEGMENTS
## Steepest porch descent (deg) and the grade the porch keeps while joining the network.
const MAX_DESCENT_DEG := 24.0
const TRANSITION_GRADE_DEG := 18.0
## How deep (m) every mouth point must sit under the relief before the porch may bend towards the network.
const COVERED_M := 1.0
## Spacing (m) of porch rings along the gallery.
const STEP_M := 1.5
## An eroded mouth carries this many outline points per vestibule ring segment, so its notches show.
const ERODED_DETAIL := 3
## Rock (m) a doline keeps between the ground and its chamber: a base plus a share of the oculus radius, so a
## wide collapse reads as a thick lip, never a sheet of paper over the void (2 m + 0.3 × radius, at most 30 m).
const DOLINE_CRUST_BASE_M := 2.0
const DOLINE_CRUST_SHARE := 0.3
const DOLINE_CRUST_MAX_M := 30.0


## Strength of the seeded entrance erosion (profile entrance_noise), 0 for the historical smooth outlines.
static func erosion_amount(spec: Dictionary) -> float:
    return clampf(float(spec.get("entrance_noise", 0.0)), 0.0, 1.0)


static func erosion(spec: Dictionary) -> FastNoiseLite:
    var noise := FastNoiseLite.new()
    noise.seed = (int(spec.seed) ^ 0x4b17) & 0x7fffffff
    noise.frequency = 0.3
    noise.fractal_octaves = 3
    noise.fractal_gain = 0.45
    return noise


# ---------------------------------------------------------------- outlines

## Porch mouth seen from outside: RING + 1 points from the right floor corner over the vault to the left one
## (network ring order), x lateral and y up from the floor. Slender mouths taper into a pointed fissure, wide
## ones into an ogive; a seeded lean breaks the symmetry. Every point lies on the convex hull of the curve.
static func porch_arch(spec: Dictionary) -> PackedVector2Array:
    var rng := RandomNumberGenerator.new()
    rng.seed = int(spec.seed) * 7919 + 104723
    var width := float(spec.entrance_width_m)
    var height := float(spec.entrance_height_m)
    var slender := height / maxf(width, 0.1)
    var taper := clampf(0.9 + (slender - 0.8) * 0.6, 0.85, 2.2) * rng.randf_range(0.9, 1.15)
    var walls := rng.randf_range(0.55, 0.85)
    var lean := rng.randf_range(-0.16, 0.16) * width
    var amount := erosion_amount(spec)
    var count := RING * (ERODED_DETAIL if amount > 0.0 else 1)
    var center := Vector2(lean * 0.5, height * 0.4)
    var noise := erosion(spec) if amount > 0.0 else null
    var points := PackedVector2Array()
    for index in count + 1:
        var angle := PI * index / count
        var c := cos(angle)
        var s := sin(angle)
        var point := Vector2(signf(c) * pow(absf(c), taper) * width * 0.5 + lean * s * s, pow(s, walls) * height)
        if noise:
            # Erosion pushes the outline out or bites into it along rays from the centre: notches, beaks and
            # overhanging lips, the outline staying star-shaped (so simple). The sill and its corners stay put.
            var bite := noise.get_noise_2d(c * 2.2, s * 2.2)
            point = center + (point - center) * (1.0 + 0.45 * amount * smoothstep(0.0, 0.35, s) * bite)
            point.y = maxf(point.y, 0.0)
        points.append(point)
    points[0] = Vector2(width * 0.5, 0.0)
    points[count] = Vector2(-width * 0.5, 0.0)
    # Smooth mouths keep the historical convex outline; eroded ones are clipped in convex parts (CaveTerrainCut).
    return points if noise else _onto_hull(points, center)


## Doline oculus in the site's horizontal plane: an irregular, slightly oval, convex ring of 48 points.
static func oculus(spec: Dictionary) -> PackedVector2Array:
    var rng := RandomNumberGenerator.new()
    rng.seed = int(spec.seed) * 6151 + 92821
    var radius := float(spec.entrance_width_m) * 0.5
    var stretch := rng.randf_range(0.75, 1.0)
    var turn := rng.randf_range(0.0, TAU)
    var phases := [rng.randf_range(0.0, TAU), rng.randf_range(0.0, TAU)]
    var amount := erosion_amount(spec)
    var noise := erosion(spec) if amount > 0.0 else null
    var count := 96 if noise else 48
    var points := PackedVector2Array()
    for index in count:
        var angle := TAU * index / count
        var reach := radius * (1.0 + 0.08 * sin(3.0 * angle + phases[0]) + 0.05 * sin(5.0 * angle + phases[1]))
        if noise:
            # Scalloped collapse rim: bays and promontories, sampled on a circle so the outline closes seamlessly.
            reach = maxf(radius * 0.4, reach + radius * 0.35 * amount * noise.get_noise_2d(cos(angle) * 2.6, sin(angle) * 2.6))
        points.append(Vector2(cos(angle) * reach, sin(angle) * reach * stretch).rotated(turn))
    if noise:
        return points  # star-shaped around the centre; clipped in convex parts
    var hull := Geometry2D.convex_hull(points)
    hull.resize(hull.size() - 1)
    return hull


## Version 9 light shaft hole in the ground around shaft [param index]'s axis (site plane, x and z): a small
## irregular, slightly oval ring, seeded per shaft. Star-shaped around the axis, clipped in convex parts.
static func light_rim(spec: Dictionary, index: int, radius: float) -> PackedVector2Array:
    var noise := FastNoiseLite.new()
    noise.seed = (int(spec.seed) * 31 + index * 7919 + 0x51a7) & 0x7fffffff
    noise.frequency = 0.5
    noise.fractal_octaves = 2
    var rng := RandomNumberGenerator.new()
    rng.seed = int(spec.seed) * 4099 + index * 613 + 17
    var stretch := rng.randf_range(0.7, 1.0)
    var turn := rng.randf_range(0.0, TAU)
    var points := PackedVector2Array()
    for step in 40:
        var angle := TAU * step / 40
        var reach := radius * maxf(0.55, 1.0 + 0.35 * noise.get_noise_2d(cos(angle) * 2.0, sin(angle) * 2.0))
        points.append(Vector2(cos(angle) * reach, sin(angle) * reach * stretch).rotated(turn))
    return points


## Convex pieces covering an outline exactly, for the terrain cut. A convex outline is its own single piece.
static func convex_parts(outline: PackedVector2Array) -> Array[PackedVector2Array]:
    var parts: Array[PackedVector2Array] = []
    var hull := Geometry2D.convex_hull(outline)
    if absf(_area(hull) - absf(_area(outline))) < 0.0001:
        parts.append(outline)
        return parts
    parts.assign(Geometry2D.decompose_polygon_in_convex(outline))
    var covered := 0.0
    for part in parts:
        covered += absf(_area(part))
    if parts.is_empty() or absf(covered - absf(_area(outline))) > 0.001 * absf(_area(outline)):
        # Fallback: triangles always tile a simple polygon exactly.
        parts.clear()
        var indices := Geometry2D.triangulate_polygon(outline)
        for index in range(0, indices.size(), 3):
            parts.append(PackedVector2Array([outline[indices[index]], outline[indices[index + 1]], outline[indices[index + 2]]]))
    return parts


static func _area(polygon: PackedVector2Array) -> float:
    var area := 0.0
    for index in polygon.size():
        area += polygon[index].cross(polygon[(index + 1) % polygon.size()])
    return area * 0.5


## Distance from the oculus centre to its farthest rim point: the throat below opens wider, under an overhang.
static func oculus_outer_radius(spec: Dictionary) -> float:
    var farthest := 0.0
    for point in oculus(spec):
        farthest = maxf(farthest, point.length())
    return farthest


## Rock thickness (m) a doline keeps over its network, all around its throat: grows with the oculus.
static func doline_crust(spec: Dictionary) -> float:
    return minf(DOLINE_CRUST_BASE_M + DOLINE_CRUST_SHARE * oculus_outer_radius(spec), DOLINE_CRUST_MAX_M)


## Moves curve points that fall inside the hull onto it, along rays from [param center]. The ordered curve
## then coincides with the hull boundary, so the clipped terrain edge and the gallery rim are the same line.
static func _onto_hull(points: PackedVector2Array, center: Vector2) -> PackedVector2Array:
    var hull := Geometry2D.convex_hull(points)
    var result := points.duplicate()
    for index in range(1, points.size() - 1):
        var direction := points[index] - center
        if direction.length() < 0.0001:
            continue
        result[index] = center + direction * maxf(1.0, _exit(hull, center, direction))
    return result


## Largest ray parameter t where [param origin] + t × [param direction] crosses the closed polygon's boundary
## (exact parametric test: no long helper segment whose tolerance would let hits slide past an edge's end).
static func _exit(polygon: PackedVector2Array, origin: Vector2, direction: Vector2) -> float:
    var best := -1.0
    for index in polygon.size():
        var a := polygon[index]
        var edge := polygon[(index + 1) % polygon.size()] - a
        var denominator := direction.cross(edge)
        if absf(denominator) < 1.0e-12:
            continue
        var t := (a - origin).cross(edge) / denominator
        var u := (a - origin).cross(direction) / denominator
        if t >= 0.0 and u >= -1.0e-9 and u <= 1.0 + 1.0e-9:
            best = maxf(best, t)
    return best


# ---------------------------------------------------------------- porch geometry

## The straight part of a porch in the site frame: from the mouth (origin, on the ground) along [code]forward[/code],
## with [code]up[/code] the cross-section's vertical. The descent is pinned in the placement.
static func porch_axes(descent_deg: float) -> Dictionary:
    var descent := deg_to_rad(descent_deg)
    return {"forward": Vector3(0.0, -sin(descent), cos(descent)), "up": Vector3(0.0, cos(descent), sin(descent))}


## Terrain-cut frame of a porch: local X lateral, local Y pointing out of the relief along the axis, local Z
## the cross-section's vertical. Its XZ plane holds the mouth outline; the prism runs along Y.
static func porch_frame(site_frame: Transform3D, descent_deg: float) -> Transform3D:
    var axes := porch_axes(descent_deg)
    return site_frame * Transform3D(Basis(Vector3.RIGHT, -axes.forward, axes.up), Vector3.ZERO)


## Centre line of the bend joining the straight porch to the network vestibule ring, in the site frame.
static func porch_bend(placement: CavePlacement) -> Dictionary:
    return _bend(placement.portal_descent_deg, placement.portal_axis_m, placement.network_origin())


static func _bend(descent_deg: float, axis: float, network_origin: Vector3) -> Dictionary:
    var axes := porch_axes(descent_deg)
    var start: Vector3 = axes.forward * axis
    var end := network_origin + Vector3(0.0, 0.0, CaveNaturalOpening.REAR_Z)
    return {"start": start, "end": end, "forward": axes.forward, "length": start.distance_to(end)}


static func _hermite(bend: Dictionary, u: float) -> Vector3:
    var length := float(bend.length)
    return (2*u*u*u - 3*u*u + 1) * (bend.start as Vector3) + (u*u*u - 2*u*u + u) * length * (bend.forward as Vector3) \
        + (-2*u*u*u + 3*u*u) * (bend.end as Vector3) + (u*u*u - u*u) * length * Vector3.BACK


static func _hermite_tangent(bend: Dictionary, u: float) -> Vector3:
    var length := float(bend.length)
    return ((6*u*u - 6*u) * (bend.start as Vector3) + (3*u*u - 4*u + 1) * length * (bend.forward as Vector3)
        + (-6*u*u + 6*u) * (bend.end as Vector3) + (3*u*u - 2*u) * length * Vector3.BACK).normalized()


## Network vestibule ring in its own 2D section (x lateral, y up), identical to CaveNetwork's ring at REAR_Z. With
## [param count] above RING + 1 (an eroded mouth), extra points lie on the ring's own edges: the seam is unchanged.
static func vestibule_section(spec: Dictionary, count: int = RING + 1) -> PackedVector2Array:
    var section := PackedVector2Array()
    for index in RING + 1:
        var angle := PI * index / RING
        var point := Vector2(cos(angle) * float(spec.entrance_width_m) * 0.5, sin(angle) * float(spec.entrance_height_m))
        if int(spec.version) >= 9:
            var phase := float(int(spec.seed) % 997) * 0.031
            var weather := sin(angle) * (0.08 + 0.1 * erosion_amount(spec))
            point.x += sin(angle) * sin(angle) * float(spec.entrance_width_m) * 0.06 * sin(phase)
            point.y *= 1.0 - weather * (0.6 + 0.4 * sin(angle * 3.0 + phase))
        section.append(point)
    if count == RING + 1:
        return section
    var detail := (count - 1) / RING
    var fine := PackedVector2Array()
    for index in count:
        var segment := mini(index / detail, RING - 1)
        fine.append(section[segment].lerp(section[segment + 1], float(index - segment * detail) / detail))
    return fine


## Porch walls and floor in the site frame. Each outline point runs along the straight axis from where it first
## enters the relief (its rim, on the terrain cut) and, past the straight part, along the bend whose section
## morphs into the vestibule ring. Inner walls get seeded relief that never reaches the rim or the surface.
## With a version 9 approach (CaveApproach) the relief is the hollow's: the mouth opens in its cliff, and the
## hollow's own surfaces come with the porch's, under [code]approach[/code].
static func build_porch(data: PlanetData, placement: CavePlacement, opening: Dictionary) -> Dictionary:
    var spec := placement.profile.snapshot(placement.seed)
    var frame := placement.surface_transform()
    var arch: PackedVector2Array = opening.arch
    var axes := porch_axes(placement.portal_descent_deg)
    var forward: Vector3 = axes.forward
    var up: Vector3 = axes.up
    var axis := placement.portal_axis_m
    var hollow := CaveApproach.model(spec, placement.portal_descent_deg, axis) if opening.get("approach", false) else {}
    var relief := func(x: float, z: float) -> float:
        var ground := CaveEntrance.ground_in_frame(data, frame, x, z).y
        return ground if hollow.is_empty() else minf(ground, CaveApproach.height(hollow, x, z))
    # In a hollow the porch starts where its prism does, by the cliff: the scree in front is the hollow's own.
    var first := 0.0 if hollow.is_empty() else minf(CaveApproach.prism_start(hollow), axis)
    var rims: Array[float] = []
    for point in arch:
        rims.append(_rim(relief, forward, up, point, axis, first))
    var approach := {} if hollow.is_empty() else CaveApproach.build(data, frame, spec, placement.portal_descent_deg, axis, opening)
    var section := vestibule_section(spec, arch.size())
    if not approach.is_empty():
        var seam := CavePorchSeam.refine(approach, arch, rims, section, axes)
        arch = seam.arch
        rims = seam.rims
        section = seam.section
    var rings: Array[PackedVector3Array] = []
    var count := maxi(1, int(ceil((axis - first) / STEP_M)))
    var rng := RandomNumberGenerator.new()
    rng.seed = int(placement.seed) * 31 + 7
    var phase := rng.randf_range(0.0, TAU)
    var center := Vector2(0.0, float(spec.entrance_height_m) * 0.4)
    var span := minf(float(spec.entrance_width_m), float(spec.entrance_height_m))
    var bulge := clampf(span * 0.14, 0.4, 3.5) * (0.5 + float(spec.roughness))
    var noise := erosion(spec) if float(spec.get("entrance_noise", 0.0)) > 0.0 else null
    for step in count + 1:
        var s := lerpf(first, axis, float(step) / count)
        var ring := PackedVector3Array()
        for index in arch.size():
            # The cut starts at its front cap across the WHOLE floor. On a cross slope its two feet
            # meet the relief at different depths; starting the floor on that diagonal leaves a triangle
            # of the cut uncovered. Keep the sill at the cap, and clip only the arch's upper rim.
            var foot := index == 0 or index == arch.size() - 1
            var at := s if foot else maxf(s, rims[index])
            var point := forward * at + Vector3.RIGHT * arch[index].x + up * arch[index].y
            if index > 0 and index < arch.size() - 1:
                # Bulges and overhangs, zero on the rim (it lies on the cut) and growing over 3 m inside. Outward
                # relief stays under the rock left above; inward relief never closes more than a fifth of the mouth.
                var outward := (arch[index] - center).normalized()
                var angle := PI * float(index) / (arch.size() - 1)
                var wave := 0.6 * sin(angle * 3.0 + at * 0.23 + phase) \
                    + 0.3 * sin(angle * 5.0 - at * 0.41 + phase * 2.0) \
                    + 0.1 * sin(angle * 9.0 + at * 0.7)
                if noise:
                    wave = lerpf(wave, clampf(noise.get_noise_3d(point.x, point.y, point.z) * 2.0, -1.0, 1.0), float(spec.entrance_noise))
                var amount := bulge * smoothstep(rims[index], rims[index] + 3.0, at) * wave
                var room := float(relief.call(point.x, point.z)) - point.y - 0.4
                amount = clampf(amount, -(arch[index] - center).length() * 0.2, maxf(0.0, room))
                point += (Vector3.RIGHT * outward.x + up * outward.y) * amount
            if int(spec.version) >= 9:
                # The sill varies too: a constant-width flat strip reads as an excavated road.
                var fade := smoothstep(rims[index], rims[index] + 4.0, at)
                var pinch := (0.06 + 0.05 * sin(at * 0.23 + phase + signf(point.x))) * fade
                point.x *= 1.0 - pinch
            ring.append(point)
        rings.append(ring)
    var bend := porch_bend(placement)
    var bend_steps := maxi(2, int(ceil(float(bend.length) / STEP_M)))
    var start: PackedVector3Array = rings.back()
    for step in range(1, bend_steps + 1):
        var u := float(step) / bend_steps
        var middle := _hermite(bend, u)
        var tangent := Vector3.BACK if step == bend_steps else _hermite_tangent(bend, u)
        var normal := tangent.cross(Vector3.RIGHT)
        var blend := smoothstep(0.0, 1.0, u)
        var ring := PackedVector3Array()
        for index in arch.size():
            var shape := arch[index].lerp(section[index], blend)
            var point := middle + Vector3.RIGHT * shape.x + normal * shape.y
            if step < bend_steps:
                point += (start[index] - (forward * axis + Vector3.RIGHT * arch[index].x + up * arch[index].y)) * (1.0 - blend)
                if int(spec.version) >= 9 and index > 0 and index < arch.size() - 1:
                    # A changing asymmetric section through the bend, fading to its exact shared ends.
                    var inward := (Vector3.RIGHT * shape.x + normal * (shape.y - center.y)).normalized()
                    var angle := PI * float(index) / (arch.size() - 1)
                    var recess := bulge * sin(PI * u) * (0.55 + 0.45 * sin(u * 9.0 + angle * 3.0 + phase))
                    point -= inward * minf(recess, span * 0.12)
            ring.append(point)
        if step == bend_steps:
            # Exactly the network's ring, so the two meshes share their seam.
            ring = PackedVector3Array()
            for point in section:
                ring.append(placement.network_origin() + Vector3(point.x, point.y, CaveNaturalOpening.REAR_Z))
        rings.append(ring)
    var wall := CaveGenerator._empty_surface()
    var floor := CaveGenerator._empty_surface()
    var segments := arch.size() - 1
    for step in range(1, rings.size()):
        var before := rings[step - 1]
        var after := rings[step]
        var inside := (before[0] + before[-1]) * 0.5 + (before[segments / 2] - (before[0] + before[-1]) * 0.5) * 0.4
        for index in segments:
            CaveGenerator._quad(wall, before[index], before[index + 1], after[index + 1], after[index], inside)
        CaveGenerator._quad(floor, before[-1], before[0], after[0], after[-1], inside + Vector3.UP * 2.0)
        if hollow.is_empty() and step <= count:
            # The eroded arch can overhang its two floor feet. Coarse terrain is cut against that
            # wider outline: bury lateral footings under the walls so the cut cannot reveal sky
            # beside the narrower floor. Keep the original walking floor and its shared edges.
            for corner: int in [0, segments]:
                var a := before[corner]
                var b := after[corner]
                var sign_x := 1.0 if corner == 0 else -1.0
                var reach := float(opening.width) * 0.5 + 0.75
                var outer_a := Vector3(sign_x * maxf(reach, absf(a.x) + 0.75), a.y - 0.15, a.z)
                var outer_b := Vector3(sign_x * maxf(reach, absf(b.x) + 0.75), b.y - 0.15, b.z)
                CaveGenerator._quad(floor, a, b, outer_b, outer_a, (a + b) * 0.5 + up * 2.0)
                CaveGenerator._quad(wall, outer_a, outer_b, outer_b - up, outer_a - up, inside)
    if hollow.is_empty():
        # A short buried apron under the sill AND its flared lower sides covers the displayed
        # terrain's interpolation error. Never project a horizontal collar around the whole cliff.
        var rim: PackedVector3Array = rings[0]
        var outer := PackedVector3Array()
        # Tall pointed mouths can put their FIRST interior sample above 2 m. Select the first
        # two side segments by topology, rather than a height cutoff that would omit them entirely.
        for index in rim.size():
            var point := rim[index]
            var out := point + Vector3.RIGHT * signf(point.x) * 0.4 - forward * 0.5 - up * 0.6
            if index < 3 or index >= rim.size() - 3:
                out.y = minf(out.y, CaveEntrance.ground_in_frame(data, frame, out.x, out.z).y - 0.2)
            outer.append(out)
        for index in rim.size():
            var next := (index + 1) % rim.size()
            if not (index < 2 or index >= rim.size() - 3):
                continue
            var facing := (rim[index] + rim[next]) * 0.5 + up - forward
            CaveGenerator._quad(wall, rim[index], rim[next], outer[next], outer[index], facing)
            CaveGenerator._quad(wall, outer[index], outer[next], outer[next] - up, outer[index] - up, facing)
    var porch := {"wall": wall, "floor": floor, "rings": rings}
    if not hollow.is_empty():
        porch.approach = approach
    return porch


## Axis position (m), from [param from] on, where an outline point first lies under the relief ([param relief]:
## plan x, z → height): its rim on the cut.
static func _rim(relief: Callable, forward: Vector3, up: Vector3, point: Vector2, axis: float, from: float = 0.0) -> float:
    var s := from
    while s < axis:
        var p := forward * s + Vector3.RIGHT * point.x + up * point.y
        if float(relief.call(p.x, p.z)) >= p.y:
            break
        s += 0.25
    if s <= from or s >= axis:
        return minf(s, axis)
    # Refine between the last open sample and the first covered one.
    var low := s - 0.25
    var high := s
    for iteration in 8:
        var mid := (low + high) * 0.5
        var p := forward * mid + Vector3.RIGHT * point.x + up * point.y
        if float(relief.call(p.x, p.z)) >= p.y:
            high = mid
        else:
            low = mid
    return high


## Doline throat: walls from the lattice's open sky loop (network frame) up to the oculus on the ground, joined
## on the union of both loops' angles so the lattice seam is kept vertex for vertex. The walls bell outwards.
## A version 9 light shaft (opening kind "light") is built the same way around its own axis, from its loop
## (cave.lights) to its rim, in as many bands as its height needs, with a bell scaled to its narrow pipe.
static func build_skylight(data: PlanetData, placement: CavePlacement, opening: Dictionary, cave: Dictionary) -> Dictionary:
    var frame := placement.surface_transform()
    var origin := placement.network_origin()
    var light := opening.has("light")
    # Site-frame plan position of the axis: the doline's is under the site origin (the fit put it there).
    var axis: Vector2 = opening.get("center", Vector2.ZERO)
    var shift := Vector3(axis.x, 0.0, axis.y)
    var loop: PackedVector3Array = cave.lights[int(opening.light)] if light else cave.sky
    # The mesher sorted each loop by angle around its axis.
    var bottom: Array[Vector3] = []
    var bottom_angles: Array[float] = []
    var mean_y := 0.0
    for point: Vector3 in loop:
        bottom.append(point + origin - shift)
        bottom_angles.append(atan2(bottom.back().z, bottom.back().x))
        mean_y += bottom.back().y / loop.size()
    var rim: PackedVector2Array = opening.polygon
    # As many bands as the throat's height needs (a thick doline crust or a deep light shaft).
    var height := CaveEntrance.ground_in_frame(data, frame, axis.x, axis.y).y - mean_y
    var bands := clampi(int(ceil(height / 3.0)), 8, 48)
    var bell := 1.0
    if light:
        var reach := 0.0
        for point in rim:
            reach = maxf(reach, point.length())
        bell = clampf(reach / 6.0, 0.15, 1.0)
    # Columns at every sky vertex (kept exactly: the lattice seam) and at every rim vertex.
    var columns_at: Array[Dictionary] = []
    for index in bottom.size():
        columns_at.append({"angle": bottom_angles[index], "low": bottom[index]})
    for point in rim:
        var angle := atan2(point.y, point.x)
        columns_at.append({"angle": angle, "low": _between(bottom, bottom_angles, angle)})
    columns_at.sort_custom(func(a: Dictionary, b: Dictionary): return float(a.angle) < float(b.angle))
    var columns: Array[PackedVector3Array] = []
    var rng := RandomNumberGenerator.new()
    rng.seed = int(placement.seed) * 17 + 3
    var phase := rng.randf_range(0.0, TAU)
    var spec := placement.profile.snapshot(placement.seed)
    var amount := erosion_amount(spec)
    var noise := erosion(spec) if amount > 0.0 else null
    for entry in columns_at:
        var angle := float(entry.angle)
        var low: Vector3 = entry.low
        var direction := Vector2(cos(angle), sin(angle))
        var flat := direction * _exit(rim, Vector2.ZERO, direction)
        var high := Vector3(flat.x, CaveEntrance.ground_in_frame(data, frame, axis.x + flat.x, axis.y + flat.y).y, flat.y)
        var column := PackedVector3Array()
        for band in bands + 1:
            var t := float(band) / bands
            var point := low.lerp(high, t)
            var outward := Vector3(point.x, 0.0, point.z).normalized()
            # A bell: the throat widens under the rim, the classic collapse profile. Erosion turns it into ledges
            # and overhangs (inward and outward), still zero on both seams.
            var swell := 1.2 + 0.8 * sin(angle * 3.0 + t * 5.0 + phase)
            if noise:
                swell = 1.2 + 2.0 * amount * noise.get_noise_3d(cos(angle) * 3.0, sin(angle) * 3.0, t * 2.5)
            point += outward * sin(PI * t) * swell * bell * (0.6 + 0.4 * t)
            column.append(point + shift)
        columns.append(column)
    var wall := CaveGenerator._empty_surface()
    var rim_points := PackedVector3Array()
    var outward := PackedVector3Array()
    var lift := PackedFloat32Array()
    for index in columns.size():
        var a := columns[index]
        var b := columns[(index + 1) % columns.size()]
        for band in bands:
            var inside := Vector3(shift.x, (a[band].y + a[band + 1].y) * 0.5, shift.z)
            CaveGenerator._quad(wall, a[band], b[band], b[band + 1], a[band + 1], inside)
        rim_points.append(a[bands])
        outward.append(Vector3(cos(float(columns_at[index].angle)), 0.0, sin(float(columns_at[index].angle))))
        lift.append(1.0)
    var exposed_wall := {"vertices": wall.vertices.duplicate(), "normals": wall.normals.duplicate()}
    # The lip sealed to the terrain shown around it (CaveEntrance.seal_rim).
    CaveEntrance.seal_rim(data, frame, rim_points, outward, lift, true, wall)
    return {"wall": wall, "floor": CaveGenerator._empty_surface(), "exposed_wall": exposed_wall}


## Point of the angle-sorted sky loop at [param angle], on the segment between its two angular neighbours.
static func _between(loop: Array[Vector3], angles: Array[float], angle: float) -> Vector3:
    for index in loop.size():
        var next := (index + 1) % loop.size()
        var from := angles[index]
        var to := angles[next] + (TAU if next == 0 else 0.0)
        var at := angle + (TAU if angle < from else 0.0)
        if at >= from and at <= to:
            return loop[index].lerp(loop[next], (at - from) / maxf(to - from, 0.000001))
    return loop[0]


# ---------------------------------------------------------------- fitting and checks

## Pins the entrance to the relief: porch descent and straight length, network offset and depth; for a
## doline the offset that centres the throat under the click and the depth of its sky loop. Worker-safe.
static func fit(data: PlanetData, placement: CavePlacement, cave: Dictionary) -> Dictionary:
    var spec: Dictionary = cave.spec
    var frame := placement.surface_transform()
    var cover := placement.cover_m
    var points := CaveGenerator.cover_points(cave)
    if str(spec.entrance_type) == "shaft":
        var sky: Dictionary = cave.graph.sky
        var offset := Vector3(-float(sky.center.x), 0.0, -float(sky.center.y))
        # Where the rim would reach past the throat the lip thickens, keeping its walls steep (≥ ~55°); a wide
        # oculus keeps a crust in proportion (doline_crust), so its overhanging lip is never a thin sheet.
        var lip := maxf(maxf(0.0, oculus_outer_radius(spec) - float(sky.radius)) * 1.4, doline_crust(spec))
        var depth := ceilf(maxf(_required_depth(data, frame, points, offset, cover, 1),
            _required_depth(data, frame, points, offset, 0.0, 1) + lip) * 10.0) / 10.0
        return {"error": "", "offset": offset, "depth": depth, "descent": 0.0, "axis": 0.0,
            "sky_depth": depth - float(sky.top), "lights": light_wells(cave, offset, depth), "relief_signature": data.relief_signature}
    var grade := (CaveEntrance.ground_in_frame(data, frame, 0.0, 20.0).y
        - CaveEntrance.ground_in_frame(data, frame, 0.0, 0.0).y) / 20.0
    var descent := clampf(MAX_DESCENT_DEG - rad_to_deg(atan(maxf(grade, 0.0))), 0.0, MAX_DESCENT_DEG)
    var axes := porch_axes(descent)
    var arch := porch_arch(spec)
    # A version 9 porch opens in its approach's cliff (CaveApproach), under more rock.
    var cover_m := CaveApproach.COVER_M if CaveApproach.for_profile(spec) else COVERED_M
    var axis := -1.0
    var covered_run := 0.0
    var s := 0.0
    while s <= 300.0:
        if _covered(data, frame, arch, axes, s, cover_m):
            covered_run += 0.5
            if covered_run > 4.0:
                axis = s - 4.0
                break
        else:
            covered_run = 0.0
        s += 0.5
    if axis < 0.0:
        return {"error": "Le relief ne recouvre pas ce porche : choisir un versant ou une falaise plus marqués."}
    var height := float(spec.entrance_height_m)
    # While the bend straightens the section its vault rises (h·(1 − cos descent)): lengthen the straight part
    # until the whole bend stays under the relief too.
    for lengthen in 40:
        var start: Vector3 = axes.forward * axis
        var bend := maxf(12.0, height * 1.5)
        var depth := 0.0
        var offset := Vector3.ZERO
        for iteration in 10:
            offset = Vector3(0.0, 0.0, start.z + bend - CaveNaturalOpening.REAR_Z)
            depth = maxf(_required_depth(data, frame, points, offset, cover, 7), -start.y)
            var needed := maxf(maxf(12.0, height * 1.5), (depth + start.y) / tan(deg_to_rad(TRANSITION_GRADE_DEG)))
            if needed <= bend + 0.05:
                break
            bend = needed
        if bend > 400.0:
            return {"error": "Le réseau est trop profond sous ce porche : choisir un relief plus haut."}
        depth = ceil(maxf(_required_depth(data, frame, points, offset, cover, 1), -start.y) * 10.0) / 10.0
        var origin := offset + Vector3.DOWN * depth
        if _bend_clearance(data, frame, _bend(descent, axis, origin), height) >= 0.5:
            return {"error": "", "offset": offset, "depth": depth, "descent": descent, "axis": axis, "sky_depth": 0.0,
                "lights": light_wells(cave, offset, depth), "relief_signature": data.relief_signature}
        axis += 2.0
    return {"error": "Le relief ne recouvre pas la galerie de ce porche : choisir un autre emplacement."}


## Version 9 light shafts pinned for a fitted network ([param offset], [param depth]), in the site frame: the
## plan position of each axis, its hole's radius, and the depth below the entrance point (negative above it)
## of the lattice's top plane, where the network's open pipe meets the walls built up to the ground. The cover
## points include those open loops, so the fitted depth already keeps rock above them.
static func light_wells(cave: Dictionary, offset: Vector3, depth: float) -> PackedVector4Array:
    var wells := PackedVector4Array()
    for light: Dictionary in cave.graph.get("lights", []):
        var center: Vector2 = light.center
        wells.append(Vector4(center.x + offset.x, center.y + offset.z, float(light.rim), depth - float(light.top)))
    return wells


static func _covered(data: PlanetData, frame: Transform3D, arch: PackedVector2Array, axes: Dictionary, s: float,
        cover_m: float = COVERED_M) -> bool:
    for index in range(0, arch.size(), 2):
        var p: Vector3 = (axes.forward as Vector3) * s + Vector3.RIGHT * arch[index].x + (axes.up as Vector3) * arch[index].y
        if CaveEntrance.ground_in_frame(data, frame, p.x, p.z).y - p.y < cover_m:
            return false
    return true


## Depth of the network origin below the site so every roof point keeps [param cover] of rock, at this offset.
static func _required_depth(data: PlanetData, frame: Transform3D, points: PackedVector3Array, offset: Vector3,
        cover: float, stride: int) -> float:
    var required := 0.0
    for index in range(0, points.size(), stride):
        var vertex := points[index]
        var ground := CaveEntrance.ground_in_frame(data, frame, vertex.x + offset.x, vertex.z + offset.z)
        required = maxf(required, vertex.y - ground.y + cover)
    return ceil(required * 10.0) / 10.0


## The bend from the straight porch to the network must stay inside the rock.
static func porch_error(data: PlanetData, placement: CavePlacement) -> String:
    var clearance := _bend_clearance(data, placement.surface_transform(), porch_bend(placement),
        float(placement.profile.entrance_height_m))
    return "" if clearance >= 0.3 else "La galerie d’entrée ressort du relief : choisir un autre emplacement."


## Smallest rock thickness (m) above the bend's vault, measured as if the section were already upright.
static func _bend_clearance(data: PlanetData, frame: Transform3D, bend: Dictionary, height: float) -> float:
    var steps := maxi(2, int(ceil(float(bend.length) / 3.0)))
    var smallest := INF
    for step in steps + 1:
        var top := _hermite(bend, float(step) / steps) + Vector3.UP * height
        smallest = minf(smallest, CaveEntrance.ground_in_frame(data, frame, top.x, top.z).y - top.y)
    return smallest


## Presence in the bent part of a porch (the straight part is the cut prism, tested by CaveEntrance).
static func in_bend(placement: CavePlacement, site_point: Vector3) -> bool:
    var bend := porch_bend(placement)
    var reach := maxf(float(placement.profile.entrance_width_m) * 0.5, float(placement.profile.entrance_height_m)) + 0.5
    var steps := maxi(2, int(ceil(float(bend.length) / 2.0)))
    var previous := _hermite(bend, 0.0)
    for step in range(1, steps + 1):
        var next := _hermite(bend, float(step) / steps)
        if site_point.distance_to(Geometry3D.get_closest_point_to_segment(site_point, previous, next)) <= reach:
            return true
        previous = next
    return false
