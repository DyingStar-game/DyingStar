class_name DustLights
extends Node
## The lamps that light the wind's dust, client side: street lamps, floodlights, neon signs, a truck's
## headlights, a torch. The dust layer near the ground (dust_layer.gdshaderinc) is ray-marched by hand
## (Godot's volumetric fog cannot work this far from the origin), so the scene's lights never reach it
## on their own: lit by the sun alone, it hung as a dark veil in front of every lamp at night.
##
## Every Omni and Spot light in the tree is known (scanned once, then node_added / node_removed, as
## LampShadowBudget does). Twice a second the MAX_LIGHTS that matter most to the eye are picked (lit,
## in reach, the brightest over the distance), and every frame they are handed to the layer camera
## relative: a lamp on a moving truck, or a torch, stays in its beam. No shadows: a beam crosses a wall,
## and the buildings' masks keep the rooms clear.

## As many lamps as the shader takes (dust_light_* arrays). 8 cost 2.8 ms of GPU at a village at night
## (RTX, 2026-10-10) with the scene's 164 spots; each lamp is a march of its own over every pixel near it.
const MAX_LIGHTS: int = 4
## Over this sun energy (the engine's sun light) the lamps light no dust worth drawing: a beam in daylight
## is not seen. None are handed to the shader then, and the beams cost nothing by day.
const DAYLIGHT_ENERGY: float = 0.05
## How often the lamps are picked again (s).
const INTERVAL: float = 0.5
## A lamp farther from the eye than this plus its own reach (m) lights no dust the eye sees.
const REACH_M: float = 150.0
## An omni light's spot slot: no cone.
const OMNI: float = -2.0

var _renderer: AtmosphereRenderer = null
var _lights: Dictionary = {}  # Light3D -> true
var _picked: Array[Light3D] = []
var _elapsed: float = INTERVAL  # pick on the first frame


func _init(renderer: AtmosphereRenderer) -> void:
	_renderer = renderer
	name = "DustLights"


func _ready() -> void:
	for node: Node in get_tree().root.find_children("*", "Light3D", true, false):
		_consider(node)
	get_tree().node_added.connect(_consider)
	get_tree().node_removed.connect(func(node: Node) -> void: _lights.erase(node))


func _process(delta: float) -> void:
	if not is_instance_valid(_renderer.player) or _renderer.player.camera == null or not _renderer.wind_dust_on():
		return
	var eye: Vector3 = _renderer.player.camera.global_position
	_elapsed += delta
	if _elapsed >= INTERVAL:
		_elapsed = 0.0
		var beams: bool = _renderer.wind_dust_level() >= 2 and not daylight(_renderer.sun)
		_picked = pick(_lights.keys(), eye, MAX_LIGHTS) if beams else ([] as Array[Light3D])
	_push(eye)


## Is [param sun] up enough that a lamp's beam is lost in the daylight?
static func daylight(sun: Light3D) -> bool:
	return is_instance_valid(sun) and sun.is_visible_in_tree() and sun.light_energy > DAYLIGHT_ENERGY


func _consider(node: Node) -> void:
	if node is OmniLight3D or node is SpotLight3D:
		_lights[node] = true


## The [param count] lights of [param lights] that matter most to an eye at [param eye]: lit and shown,
## within REACH_M plus their own reach, ranked by importance.
static func pick(lights: Array, eye: Vector3, count: int) -> Array[Light3D]:
	var ranked: Array = []
	for node: Variant in lights:
		var light := node as Light3D
		if not is_instance_valid(light) or not light.is_inside_tree() or not light.is_visible_in_tree() \
				or light.light_energy <= 0.0:
			continue
		var reach: float = reach_of(light)
		var distance: float = light.global_position.distance_to(eye)
		if reach <= 0.0 or distance > REACH_M + reach:
			continue
		ranked.append([importance(light.light_energy, reach, distance), light])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var out: Array[Light3D] = []
	for entry: Array in ranked.slice(0, count):
		out.append(entry[1])
	return out


## How far a light reaches (m): its range, 0 for a light that is neither an omni nor a spot.
static func reach_of(light: Light3D) -> float:
	if light is OmniLight3D:
		return (light as OmniLight3D).omni_range
	if light is SpotLight3D:
		return (light as SpotLight3D).spot_range
	return 0.0


## How much a light of [param energy] reaching [param reach] m matters to an eye [param distance_m]
## away: the light it spreads (energy over its reach squared) over the distance squared.
static func importance(energy: float, reach: float, distance_m: float) -> float:
	return energy * reach * reach / maxf(distance_m * distance_m, 1.0)


## Hand the layer the picked lamps, camera relative: position and reach (xyz, w), colour × energy and
## the falloff exponent (rgb, a), and for a spot its direction and the cosine of its half-angle (w;
## OMNI for none). The arrays are always MAX_LIGHTS long, the count says how many are used.
func _push(eye: Vector3) -> void:
	var pos := PackedVector4Array()
	var col := PackedVector4Array()
	var spot := PackedVector4Array()
	for light: Light3D in _picked:
		if not is_instance_valid(light) or not light.is_inside_tree():
			continue
		var p: Vector3 = light.global_position - eye
		pos.append(Vector4(p.x, p.y, p.z, reach_of(light)))
		var c: Color = light.light_color * light.light_energy
		var decay: float = (light as OmniLight3D).omni_attenuation if light is OmniLight3D \
				else (light as SpotLight3D).spot_attenuation
		col.append(Vector4(c.r, c.g, c.b, decay))
		if light is SpotLight3D:
			var d: Vector3 = -light.global_basis.z.normalized()
			spot.append(Vector4(d.x, d.y, d.z, cos(deg_to_rad((light as SpotLight3D).spot_angle))))
		else:
			spot.append(Vector4(0.0, 0.0, 0.0, OMNI))
	var used: int = pos.size()
	while pos.size() < MAX_LIGHTS:
		pos.append(Vector4.ZERO)
		col.append(Vector4.ZERO)
		spot.append(Vector4(0.0, 0.0, 0.0, OMNI))
	_renderer.set_dust_param(&"dust_light_count", used)
	_renderer.set_dust_param(&"dust_light_pos", pos)
	_renderer.set_dust_param(&"dust_light_col", col)
	_renderer.set_dust_param(&"dust_light_spot", spot)
