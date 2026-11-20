class_name DustSparks
extends Node3D
## The sparks of static of one dust wall: the grains rub and charge, and the thick of a strong wall flashes.
## Each spark is a thin crooked arc (dust_bolt.gdshader) standing just behind the wall's front for an
## instant, flickering, and a glow in the dust round it (the wall's volume reads the sparks alight from its
## material's "sparks").
##
## Lives beside the wall's box, in the same frame (WeatherPhenomena's). Seen only: no sound, nothing done to
## anyone, and not the same sparks for two players.

const BOLT_SHADER := preload("res://scenes/planet/weather/dust_bolt.gdshader")
## Sparks alight at once at most (the wall's volume shader holds as many: its SPARKS).
const COUNT := 5
## A spark waits between these (s) before it strikes again, and lasts between these.
const WAIT_S := Vector2(0.6, 3.2)
const LAST_S := Vector2(0.1, 0.28)
## How tall an arc is (m, from and to) and how wide its quad is over its height.
const TALL_M := Vector2(180.0, 520.0)
const WIDE := 0.7
## An arc stands between these distances behind the front (m: deeper, the dust would hide it), its foot
## between these shares of the wall's height, along the front up to WINDOW_M from the eye.
const BEHIND_M := Vector2(15.0, 110.0)
const FOOT := Vector2(0.05, 0.6)
const WINDOW_M := 6000.0
## Sparks strike when the wall is at least this strong, and no more once it is this far spent.
const MIN_STRENGTH := 0.35
const MAX_SPENT := 0.8
## A spark alight flickers between these brightnesses, changing this often (s).
const FLICKER := Vector2(0.35, 1.0)
const FLICKER_S := 0.035

## How much of the open air the eye is in (WeatherPhenomena): no spark is seen from under the ground.
var open_air := 1.0

var _box: Node3D
var _material: ShaderMaterial
var _bolts: Array[MeshInstance3D] = []
var _next := PackedFloat64Array()  # when each spark strikes again
var _until := PackedFloat64Array()  # until when it is alight
var _where: Array[Vector3] = []  # where it stands, metres in the box's frame
var _clock := 0.0
var _flicker_at := 0.0
var _lit := PackedVector4Array()


## Sparks for the wall drawn by [param box] (its scaled box node) with [param material] (its volume
## material); [param noise]: the arcs' crookedness.
func setup(box: Node3D, material: ShaderMaterial, noise: Texture2D) -> void:
	_box = box
	_material = material
	var bolt_material := ShaderMaterial.new()
	bolt_material.shader = BOLT_SHADER
	bolt_material.set_shader_parameter("noise", noise)
	bolt_material.render_priority = 1  # over the wall's volume
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	for k in COUNT:
		var bolt := MeshInstance3D.new()
		bolt.mesh = quad
		bolt.material_override = bolt_material
		bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bolt.visible = false
		add_child(bolt)
		_bolts.append(bolt)
		_next.append(randf_range(0.0, WAIT_S.y))
		_until.append(0.0)
		_where.append(Vector3.ZERO)
	_lit.resize(COUNT)


## Strikes, flickers and puts out the sparks. [param wall]: the wall as the weather has it now;
## [param eye]: the eye, in this node's frame; [param under]: the ground under the wall, and
## [param bottom_m] the height of the box's bottom (both over the planet's reference sphere).
func advance(delta: float, wall: Dictionary, eye: Vector3, under: WallGround, bottom_m: float) -> void:
	_clock += delta
	var size := _box.transform.basis.get_scale()
	var frame := _box.transform.orthonormalized()
	var eye_m := frame.affine_inverse() * eye
	var may := float(wall["strength"]) >= MIN_STRENGTH and float(wall.get("spent", 0.0)) <= MAX_SPENT
	var flicker := _clock >= _flicker_at
	if flicker:
		_flicker_at = _clock + FLICKER_S
	for k in COUNT:
		var bolt := _bolts[k]
		if _clock >= _next[k] and may:
			_next[k] = _clock + randf_range(WAIT_S.x, WAIT_S.y)
			_until[k] = _clock + randf_range(LAST_S.x, LAST_S.y)
			var tall := randf_range(TALL_M.x, TALL_M.y)
			var x := clampf(eye_m.x + randf_range(-WINDOW_M, WINDOW_M), -size.x * 0.45, size.x * 0.45)
			var z := WeatherPhenomena.wall_front_m(x, size, float(wall["depth_m"])) - randf_range(BEHIND_M.x, BEHIND_M.y)
			var ground := under.height_at(frame * Vector3(x, 0.0, z)) - bottom_m - size.y * 0.5
			_where[k] = Vector3(x, ground + WeatherPhenomena.wall_tall(wall) * randf_range(FOOT.x, FOOT.y) + tall * 0.5, z)
			# Upright, turned to the eye.
			var at := frame * _where[k]
			var up := frame.basis.y
			var across := up.cross(eye - at).normalized()
			bolt.transform = Transform3D(Basis(across * tall * WIDE, up * tall, across.cross(up)), at)
			bolt.set_instance_shader_parameter("seed", randf() * 10.0)
			bolt.visible = true
			flicker = true
		var alight := _clock < _until[k]
		if not alight:
			bolt.visible = false
			_lit[k] = Vector4.ZERO
		elif flicker:
			var bright := randf_range(FLICKER.x, FLICKER.y)
			bolt.set_instance_shader_parameter("bright", bright)
			bolt.set_instance_shader_parameter("open_air", open_air)
			_lit[k] = Vector4(_where[k].x, _where[k].y, _where[k].z, bright)
	_material.set_shader_parameter("sparks", _lit)
