extends Node3D
## The light of an erupting vent, client side, in its VolcanoPlume's frame (vent at the origin, +Y up):
##   - one orange light, no shadows, that lights the cone's flanks and the ground around a few km;
##   - a halo on the vent itself (a sphere whose shader glows towards its centre), the only "bloom";
##   - a few incandescent flows down the flanks, laid on the relief once the camera comes near.
## Everything follows the eruption's strength, given by the plume once a frame (update). Nothing here
## lights the sky: nights stay black, the glow is local.
##
## No class_name: VolcanoPlume preloads it by path.

## The light: colour of the glow, energy at full eruption, reach, falloff exponent (Godot's
## omni_attenuation: 1 = 1/d, lower = flatter), how high above the vent it hangs.
const LIGHT_COLOR := Color(1.0, 0.42, 0.12)
const LIGHT_ENERGY := 90.0
const LIGHT_RANGE_M := 6000.0
const LIGHT_DECAY := 0.75
const LIGHT_MIN_Y_M := 80.0
const LIGHT_MAX_Y_M := 400.0
## The halo: radius (m) as a share of the vent radius, bounds, and its smallest apparent size
## (radius / distance), so a far vent stays a soft dot instead of a pixel.
const HALO_VENT_SHARE := 2.0
const HALO_MIN_M := 150.0
const HALO_MAX_M := 900.0
const HALO_MIN_ANGLE := 0.006
## The flows: how many, their length range (m), march step (m), width at the source / the toe (m),
## lift over the relief (m), the camera distance under which they are laid (m) and the relief reads
## spent on them per frame (each read can decode terrain data: spread over frames).
const FLOW_COUNT := 4
const FLOW_MIN_M := 500.0
const FLOW_MAX_M := 1600.0
const FLOW_STEP_M := 25.0
const FLOW_WIDTH_START_M := 34.0
const FLOW_WIDTH_END_M := 10.0
const FLOW_LIFT_M := 1.5
const FLOW_BUILD_M := 25000.0
const FLOW_READS_PER_FRAME := 24
## A flow stops where the ground is flatter than this slope (rise per metre).
const FLOW_MIN_SLOPE := 0.03
## Flow heat: rises in this many seconds when an eruption starts, cools in this many after it ends.
const FLOW_HEAT_UP_S := 30.0
const FLOW_COOL_S := 240.0
const SHADER_DIR := "res://assets/_universe/environment/terrain/volcano/"

@export_group("Explosion flash")
## Peak of the flash of an eruption's FIRST explosion, in multiples of the vent's full glow: the light,
## the halo and the whole lower plume jump this high. 20 = a burst that lights the slopes and the ground
## for kilometres as the eruption opens.
@export var flash_first: float = 20.0
## Peak of the flash of a later explosion of the same eruption (times the vent's full glow), before the
## explosion's own drop: they come every half minute or so, so smaller.
@export var flash_later: float = 10.0
## Time constant (s) of the white-orange burst that opens a flash: very short, it is the bang of light.
@export var flash_white_s: float = 0.1
## Time constant (s) of the red glow that follows: after it 37 % is left, after three 5 %. 1.5 to 2 s
## reads as glowing debris and gas cooling.
@export var flash_red_s: float = 1.7
## Share (0..1) of the peak carried by the white burst; the rest is the red glow. Higher = a sharper,
## whiter flash with less afterglow.
@export var flash_white_share: float = 0.6
## Flicker of the flash while it falls (0 = smooth decay, 1 = it stutters to black and back).
@export var flash_flicker: float = 0.35
## Reach (m) of the vent's light at the height of a flash (6 km otherwise): the slopes and the ground
## light up this far, for the flash only.
@export var flash_range_m: float = 12000.0
## How much the halo swells at the first explosion's peak (0 = not at all, 2 = to three times its size).
@export var flash_halo_grow: float = 2.0
## How brightly a flash lights the plume from the INSIDE, up to half its height, per unit of flash:
## higher = the whole lower plume glows, not just its underside.
@export var flash_plume_inner: float = 0.15
## Strength (0..1) of the brief brightening of the whole screen at the first explosion's peak, for a
## player looking at the volcano within flash_screen_m. Back to normal with the flash (under a second).
@export var flash_screen: float = 0.25
## The screen flash is felt within this distance (m) of the vent, fading to nothing at it.
@export var flash_screen_m: float = 4000.0

const FLASH_WHITE := Color(1.0, 0.82, 0.58)
const FLASH_RED := Color(1.0, 0.3, 0.06)

var _flash_age := INF
var _flash_peak := 0.0
var _screen: ColorRect = null
var _relief: Callable
var _vent_radius := 300.0
var _seed := 0
var _vent_alt_m := 0.0
var _light: OmniLight3D
var _halo: MeshInstance3D
var _halo_mat := ShaderMaterial.new()
var _flow_mat: ShaderMaterial
var _flows: MeshInstance3D
var _flow_heat := 0.0
## Flow laying state: the flows' centre lines (Array of PackedVector3Array) and the one being marched.
var _lines: Array = []
var _cur := PackedVector3Array()
var _cur_len := 0.0
var _cur_max := 0.0
var _laying := false
var _laid := false


## [param relief]: Callable(x, z) -> ground height in the plume's frame. [param seed_v]: the volcano's
## seed, so every client draws the same flows. [param vent_alt_m]: the vent's altitude (m over the planet's
## reference sphere), for the dust sea the halo and the flows are seen through.
func setup(relief: Callable, vent_radius: float, seed_v: int, vent_alt_m: float = 0.0) -> void:
	_relief = relief
	_vent_radius = vent_radius
	_seed = seed_v
	_vent_alt_m = vent_alt_m


func _ready() -> void:
	name = "VentGlow"
	var y := clampf(_vent_radius, LIGHT_MIN_Y_M, LIGHT_MAX_Y_M)
	_light = OmniLight3D.new()
	_light.name = "VentLight"
	_light.light_color = LIGHT_COLOR
	_light.omni_range = LIGHT_RANGE_M
	_light.omni_attenuation = LIGHT_DECAY
	_light.shadow_enabled = false
	_light.light_specular = 0.1
	_light.position = Vector3(0.0, y, 0.0)
	_light.visible = false
	add_child(_light)
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	_halo_mat.shader = load(SHADER_DIR + "vent_halo.gdshader")
	_halo = MeshInstance3D.new()
	_halo.name = "VentHalo"
	_halo.mesh = sphere
	_halo.material_override = _halo_mat
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_halo.position = Vector3(0.0, y * 0.5, 0.0)
	_halo.visible = false
	add_child(_halo)
	_halo_mat.set_shader_parameter("halo_alt_m", _vent_alt_m + _halo.position.y)


## The dust sea as it is drawn now (DustSea.light_material), for the halo and the flows: both are drawn after
## the pass that paints the sea and fade through it by themselves. Called by the plume when it reads its light.
func sea() -> void:
	DustSea.light_material(_halo_mat)
	if _flow_mat != null:
		DustSea.light_material(_flow_mat)


## Strength (0..1) of a flash [param age_s] after its explosion, in two beats: a white burst of time
## constant [param white_s] carrying [param white_share] of the peak, then a red glow falling over
## [param red_s]; stuttering by [param flicker] (0..1). Instant rise; 0 before it and once spent. Pure.
static func flash_envelope(age_s: float, white_s: float, red_s: float, white_share: float, flicker: float) -> float:
	if age_s < 0.0 or age_s > maxf(white_s, red_s) * 8.0:
		return 0.0
	var share: float = clampf(white_share, 0.0, 1.0)
	var fall: float = share * exp(-age_s / maxf(white_s, 0.01)) + (1.0 - share) * exp(-age_s / maxf(red_s, 0.01))
	var stutter: float = 0.5 + 0.5 * sin(age_s * 61.0) * sin(age_s * 23.0 + 1.3)
	return fall * (1.0 - clampf(flicker, 0.0, 1.0) * stutter)


## How white (0..1) a flash still is [param age_s] after its explosion: the white burst's share of what is
## left; 0 = all red glow. Pure.
static func flash_whiteness(age_s: float, white_s: float, red_s: float, white_share: float) -> float:
	if age_s < 0.0:
		return 0.0
	var share: float = clampf(white_share, 0.0, 1.0)
	var white: float = share * exp(-age_s / maxf(white_s, 0.01))
	var red: float = (1.0 - share) * exp(-age_s / maxf(red_s, 0.01))
	return white / maxf(white + red, 0.000001)


## An explosion now: its light arrives at once (the sound and the shock wave later). [param first]: the
## eruption's first one; [param scale]: its own level (0..1, the later blasts' drop).
func flash(first: bool, scale: float) -> void:
	_flash_age = 0.0
	_flash_peak = (flash_first if first else flash_later) * clampf(scale, 0.0, 1.0)


## The flash's strength now, in multiples of the vent's full glow (0 without one).
func flash_level() -> float:
	return _flash_peak * flash_envelope(_flash_age, flash_white_s, flash_red_s, flash_white_share, flash_flicker)


## The flash's colour now: white-orange in its burst, red in its glow.
func flash_color() -> Color:
	return FLASH_RED.lerp(FLASH_WHITE, flash_whiteness(_flash_age, flash_white_s, flash_red_s, flash_white_share))


## Once a frame from the plume. [param drawn]: the plume is drawn (near and among the nearest);
## [param heat]: eruption strength 0..~1.3; [param flicker]: the plume's flicker, ~0.6..1.
func update(delta: float, eye: Vector3, drawn: bool, heat: float, flicker: float) -> void:
	var rate := 1.0 / FLOW_HEAT_UP_S if heat > _flow_heat else 1.0 / FLOW_COOL_S
	_flow_heat = move_toward(_flow_heat, clampf(heat, 0.0, 1.0), rate * delta)
	_flash_age += delta
	var flashing := flash_level()
	var steady := heat * flicker
	var glow := steady + flashing
	var lit := drawn and glow > 0.02
	_light.visible = lit
	_halo.visible = lit
	# Share of the first explosion's peak reached now: drives the reach, the halo and the screen.
	var burst := clampf(flashing / maxf(flash_first, 0.01), 0.0, 1.0)
	if lit:
		_light.light_energy = LIGHT_ENERGY * glow
		_light.light_color = LIGHT_COLOR.lerp(flash_color(), flashing / maxf(glow, 0.0001))
		_light.omni_range = lerpf(LIGHT_RANGE_M, maxf(flash_range_m, LIGHT_RANGE_M),
				clampf(flashing / maxf(flash_later, 0.01), 0.0, 1.0))
		var size := clampf(_vent_radius * HALO_VENT_SHARE, HALO_MIN_M, HALO_MAX_M)
		size = maxf(size, eye.distance_to(_halo.position) * HALO_MIN_ANGLE)
		_halo.scale = Vector3.ONE * size * (1.0 + flash_halo_grow * burst)
		_halo_mat.set_shader_parameter("intensity", glow)
	_screen_flash(burst if drawn else 0.0, eye)
	if not drawn:
		return
	if not _laid and _flow_heat > 0.0 and eye.length() < FLOW_BUILD_M:
		_lay_some()
	if _flows != null:
		_flows.visible = _flow_heat > 0.01
		_flow_mat.set_shader_parameter("heat", _flow_heat * lerpf(0.85, 1.0, flicker))


## The brief brightening of the screen for a player near the vent and looking at it: an additive tint,
## drawn under the interface. Made on the first flash, hidden the rest of the time.
func _screen_flash(burst: float, eye: Vector3) -> void:
	var strength := 0.0
	if burst > 0.001 and flash_screen > 0.0:
		var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
		var near := 1.0 - smoothstep(flash_screen_m * 0.5, flash_screen_m, eye.length())
		if cam != null and near > 0.0:
			var to_vent := (global_position - cam.global_position).normalized()
			var facing := smoothstep(0.3, 0.9, to_vent.dot(-cam.global_basis.z))
			strength = flash_screen * burst * near * facing
	if strength <= 0.001:
		if _screen != null:
			_screen.visible = false
		return
	if _screen == null:
		var layer := CanvasLayer.new()
		layer.layer = -1  # over the 3D view, under the interface
		add_child(layer)
		_screen = ColorRect.new()
		_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
		_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var add := CanvasItemMaterial.new()
		add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		_screen.material = add
		layer.add_child(_screen)
	_screen.visible = true
	_screen.color = Color(flash_color(), strength)


## Marches the flows down the relief, FLOW_READS_PER_FRAME relief reads at a time, then builds them.
func _lay_some() -> void:
	var reads := 0
	while reads < FLOW_READS_PER_FRAME:
		if not _laying:
			if _lines.size() >= FLOW_COUNT:
				_build_flows()
				_laid = true
				return
			_start_flow(_lines.size())
			reads += 1
			continue
		reads += 5
		if not _step_flow():
			_lines.append(_cur)
			_laying = false


func _start_flow(k: int) -> void:
	# Spread around the cone, each its own length, from the volcano's seed: the same on every client.
	var angle := TAU * (float(k) + _hash(k, 1) * 0.7) / float(FLOW_COUNT)
	var r := _vent_radius * 1.15
	var x := cos(angle) * r
	var z := sin(angle) * r
	_cur = PackedVector3Array([Vector3(x, _relief.call(x, z), z)])
	_cur_len = 0.0
	_cur_max = lerpf(FLOW_MIN_M, FLOW_MAX_M, _hash(k, 2))
	_laying = true


## One step downhill (steepest descent, a little wander). False when the flow ends.
func _step_flow() -> bool:
	var p := _cur[_cur.size() - 1]
	var h := FLOW_STEP_M
	var gx: float = (float(_relief.call(p.x + h, p.z)) - float(_relief.call(p.x - h, p.z))) / (2.0 * h)
	var gz: float = (float(_relief.call(p.x, p.z + h)) - float(_relief.call(p.x, p.z - h))) / (2.0 * h)
	var slope := Vector2(gx, gz).length()
	if slope < FLOW_MIN_SLOPE or _cur_len >= _cur_max:
		return false
	var down := -Vector2(gx, gz) / slope
	# Away from the vent too, so a flow never turns back into the crater.
	var out := Vector2(p.x, p.z).normalized()
	var wander := (_hash(_cur.size(), 3 + _lines.size()) - 0.5) * 0.6
	var dir := (down + out * 0.35).normalized().rotated(wander)
	var nx := p.x + dir.x * FLOW_STEP_M
	var nz := p.z + dir.y * FLOW_STEP_M
	_cur.append(Vector3(nx, _relief.call(nx, nz), nz))
	_cur_len += FLOW_STEP_M
	return true


## One mesh for all the flows: a ribbon per line, UV.x = share of the length (0 at the source),
## UV.y = across. Edge points sit on the relief they cross, a little above it.
func _build_flows() -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for line: PackedVector3Array in _lines:
		var n := line.size()
		if n < 3:
			continue
		var base := verts.size()
		for i in n:
			var u := float(i) / float(n - 1)
			var fwd := line[mini(i + 1, n - 1)] - line[maxi(i - 1, 0)]
			var side := Vector3(-fwd.z, 0.0, fwd.x).normalized()
			var half := lerpf(FLOW_WIDTH_START_M, FLOW_WIDTH_END_M, u) * 0.5
			for s in [-1.0, 1.0]:
				var q: Vector3 = line[i] + side * half * s
				verts.append(Vector3(q.x, float(_relief.call(q.x, q.z)) + FLOW_LIFT_M, q.z))
				uvs.append(Vector2(u, 0.5 + 0.5 * s))
		for i in n - 1:
			var a := base + i * 2
			idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	if idx.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_flow_mat = ShaderMaterial.new()
	_flow_mat.shader = load(SHADER_DIR + "flank_lava.gdshader")
	_flow_mat.set_shader_parameter("seed", float(_seed % 997) * 0.13)
	_flow_mat.set_shader_parameter("vent_alt_m", _vent_alt_m)
	DustSea.light_material(_flow_mat)
	_flows = MeshInstance3D.new()
	_flows.name = "FlankFlows"
	_flows.mesh = mesh
	_flows.material_override = _flow_mat
	_flows.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_flows)
	_lines.clear()


func _hash(a: int, b: int) -> float:
	var h := hash(Vector3i(_seed, a, b))
	return float(h & 0xFFFF) / 65535.0
