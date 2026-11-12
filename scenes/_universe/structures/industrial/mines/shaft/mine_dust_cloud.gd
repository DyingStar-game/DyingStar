class_name MineDustCloud
extends MeshInstance3D
## The dust a falling layer of a mine's face raises (client): it rushes up the gallery from the face, hides
## everything for a moment, then clears little by little. A volume drawn by mine_dust.gdshader, held in a chain of
## capsules along the gallery's axis that grows up the gallery as it spreads; the dust thins out along the axis at a
## ragged, rolling front, ahead of which the chain's round end holds none.
##
## No network state: every client sees its own from the fall (MineSite._layer_fell), so who arrives later sees none.

const SHADER := preload("res://scenes/_universe/structures/industrial/mines/shaft/mine_dust.gdshader")
## Most segments of the chain (the shader's MAX_SEGMENTS).
const MAX_SEGMENTS := 16
## Length (m) of a segment, unless the reach needs longer ones to fit MAX_SEGMENTS.
const SEGMENT_M := 5.0
## Time (s) the dust takes to thicken to its peak.
const RISE_S := 1.0
## Optical depth at which a thing counts as hidden (98 % of it): the visibility is this over the density.
const HIDDEN_DEPTH := 3.912
## How far (m) the noise pushes the front forward or holds it back (the shader's front_ragged_m).
const FRONT_RAGGED_M := 3.0
## Length (m) over which the dust thins out behind its front (the shader's front_soft_m).
const FRONT_SOFT_M := 8.0

var clear_s := 40.0
var spread_s := 6.0
var visibility_m := 0.8

var _points := PackedVector3Array()
var _along := PackedFloat32Array()
var _material: ShaderMaterial = null
var _born_ms := 0


## The cloud's axis in gallery [param id] of [param layout]: from the face at [param from_m] back towards the
## station, at most [param reach_m], raised [param lift_m] above the floor. Mine frame, face first.
static func gallery_path(layout: Dictionary, id: int, from_m: float, reach_m: float, lift_m: float) -> PackedVector3Array:
    var gallery: Dictionary = layout.galleries[id]
    var span := clampf(reach_m, 0.0, maxf(from_m, 0.0))
    var count := clampi(ceili(span / SEGMENT_M), 1, MAX_SEGMENTS)
    var out := PackedVector3Array()
    for index in count + 1:
        out.append(MineLayout.point_at(gallery, from_m - span * float(index) / float(count)) + Vector3.UP * lift_m)
    return out


## Extinction (per m) of the dust [param age] s after the fall: up to its peak in RISE_S, where one sees
## [param thickest_m] at most, then thinning as the square of the time left, none at [param clear_after_s].
static func density_at(age: float, clear_after_s: float, thickest_m: float) -> float:
    if age >= clear_after_s or age < 0.0:
        return 0.0
    var left := 1.0 - age / clear_after_s
    return HIDDEN_DEPTH / maxf(thickest_m, 0.01) * minf(age / RISE_S, 1.0) * left * left


## How far (m) up the gallery the dust has gone [param age] s after the fall, on a path [param length_m] long: fast
## at first, slowing, nine tenths of the way at [param spread_time_s].
static func front_at(age: float, spread_time_s: float, length_m: float) -> float:
    var tau := maxf(spread_time_s, 0.01) / log(10.0)
    return length_m * (1.0 - exp(-maxf(age, 0.0) / tau))


## Places the cloud on [param path] (mine frame, face first, see gallery_path), [param radius] m round it. Call once
## it is in the tree, under the mine.
func setup(path: PackedVector3Array, radius: float, colour: Color) -> void:
    var box := AABB(path[0], Vector3.ZERO)
    for point in path:
        box = box.expand(point)
    box = box.grow(radius + 0.5)
    position = box.get_center()
    var along := 0.0
    for index in path.size():
        if index > 0:
            along += path[index].distance_to(path[index - 1])
        _points.append(path[index] - position)
        _along.append(along)
    var mesh_box := BoxMesh.new()
    mesh_box.size = box.size
    mesh = mesh_box
    _material = ShaderMaterial.new()
    _material.shader = SHADER
    _material.set_shader_parameter(&"radius", radius)
    _material.set_shader_parameter(&"dust_color", colour)
    _material.set_shader_parameter(&"reach_m", maxf(_along[_along.size() - 1], 1.0))
    _material.set_shader_parameter(&"front_ragged_m", FRONT_RAGGED_M)
    _material.set_shader_parameter(&"front_soft_m", FRONT_SOFT_M)
    material_override = _material
    cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _born_ms = Time.get_ticks_msec()
    _update(0.0)


func _process(_delta: float) -> void:
    # Its own clock: the frame delta is clamped on a slow frame, and the dust must clear on time.
    var age := (Time.get_ticks_msec() - _born_ms) / 1000.0
    if age >= clear_s:
        queue_free()
        return
    _update(age)


func _update(age: float) -> void:
    if _material == null or _points.size() < 2:
        return
    var reach: float = _along[_along.size() - 1]
    var front := front_at(age, spread_s, reach)
    # The chain runs past the front by the noise's push: its round end lies where there is no dust left, and the
    # shader's own front (thinning along the axis) is what shows.
    var chain_end := front + FRONT_RAGGED_M + 0.5
    var starts := PackedVector3Array()
    var ends := PackedVector3Array()
    var along := PackedFloat32Array()
    starts.resize(MAX_SEGMENTS)
    ends.resize(MAX_SEGMENTS)
    along.resize(MAX_SEGMENTS)
    var count := 0
    for index in range(1, _points.size()):
        if count >= MAX_SEGMENTS or _along[index - 1] > chain_end:
            break
        var t := clampf((chain_end - _along[index - 1]) / maxf(_along[index] - _along[index - 1], 1.0e-6), 0.0, 1.0)
        starts[count] = _points[index - 1]
        ends[count] = _points[index - 1].lerp(_points[index], t)
        along[count] = _along[index - 1]
        count += 1
    _material.set_shader_parameter(&"seg_a", starts)
    _material.set_shader_parameter(&"seg_b", ends)
    _material.set_shader_parameter(&"seg_along", along)
    _material.set_shader_parameter(&"seg_count", count)
    _material.set_shader_parameter(&"front_m", front)
    _material.set_shader_parameter(&"density", density_at(age, clear_s, visibility_m))
    _material.set_shader_parameter(&"drift", age)
