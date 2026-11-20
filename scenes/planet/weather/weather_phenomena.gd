class_name WeatherPhenomena
extends Node3D
## The local weather that is seen as things standing on the ground: the dust devils and dust walls of the
## planet's ClimateWeather (WeatherLocal), drawn round the eye. A child of the Planet: its own frame is the
## body's, so what it draws turns with the ground.
##
## It draws what the weather says and nothing else: the same devils and walls WeatherLocal adds to the wind
## and the dust of a sample, at the same places. Their dust in the air round the eye (a wall passing over
## the player) is the sample's affair, drawn by the dust layer.

const DEVIL_SHADER := preload("res://scenes/planet/weather/dust_devil.gdshader")
const WALL_SHADER := preload("res://scenes/planet/weather/dust_wall_volume.gdshader")
## How often the weather is asked what stands round the eye (s), and how far devils are drawn (m).
const REFRESH_S := 0.5
const DEVIL_RANGE_M := 12000.0
## A wall is a box of dust (a volume, see dust_wall_volume.gdshader) standing on the relief under it
## (WallGround: under a front tens of kilometres long the ground rises and falls by kilometres): the box
## goes from WALL_UNDER_M under the lowest ground to the wall's height over the highest. It is WALL_DEEPER
## times as deep as the wall's dust (the haze trailing it, seen from above); its billows are read from a 3D
## noise WALL_NOISE_SIZE across.
const WALL_UNDER_M := 250.0
const WALL_DEEPER := 6.0
const WALL_NOISE_SIZE := 128
## A wall's life, drawn: at its birth it is WALL_BORN of its height and length (height, length) and grows
## to the whole; thinning out, it sinks to WALL_SPENT_TALL of its height (its dust spreads and settles).
const WALL_BORN := Vector2(0.2, 0.45)
const WALL_SPENT_TALL := 0.45
## The wall's front, seen from above (the same numbers go to dust_wall_volume.gdshader, see wall_front_m): its
## two ends trail its middle by WALL_BOW of half its length; it wanders back and forth by WALL_WANDER (wall
## depths: the short lobes, the long ones), in waves WALL_WANDER_M metres to the radian (three of them, whose
## lengths never fall in step along a wall); WALL_FRONT_MARGIN wall depths are left ahead of it in the box.
const WALL_BOW := 0.12
const WALL_WANDER := Vector2(0.3, 0.4)
const WALL_WANDER_M := Vector3(800.0, 1900.0, 4300.0)
const WALL_FRONT_MARGIN := 0.85
## A devil is this many shells one inside the other.
const DEVIL_SHELLS := 3
## The light on the dust: its share at night, with the sun on the horizon (dust standing kilometres high
## still catches it: the walls fall in the evening), and the gain on the sun's height (sine).
const LIGHT_NIGHT := 0.08
const LIGHT_HORIZON := 0.3
const LIGHT_GAIN := 1.4
## The weather does not come into a cave: what is drawn here fades out as the eye goes under the ground,
## whole down to CAVE_FULL_M over the terrain's surface and gone at CAVE_GONE_M (m, negative: under it).
## Not a metre or two: the surface read here is the terrain's without its small relief, and an eye standing
## in a hollow of the open ground must not lose the sky. The dust layer round the eye has its own rule
## (WeatherSky: none under the ground).
const CAVE_FULL_M := -10.0
const CAVE_GONE_M := -25.0
## Dust in the air is paler than the ground it comes from: its colour goes this share of the way from the
## ground to the pale ochre of fine dust (WeatherSky.BLOW_FALLBACK_COLOUR).
const DUST_PALE := 0.5

## The eye the phenomena are drawn round: a Callable returning a Node3D (the camera).
var eye: Callable

var _planet: Planet
var _since := REFRESH_S
var _shown := {}  # id → [node, velocity (the body's frame, m/s), its DustSparks (a wall's) or null, the thing]
var _devil_mesh: Mesh
var _wall_mesh: Mesh
var _noise := NoiseTexture2D.new()
var _billows := NoiseTexture3D.new()
var _wall_grounds := {}  # a wall's id → the ground under it (WallGround)
var _open_air := 1.0  # 1 in the open, 0 with the eye in a cave (CAVE_*)


func _ready() -> void:
	_planet = get_parent() as Planet
	var grain := FastNoiseLite.new()
	grain.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	grain.frequency = 0.012
	grain.fractal_octaves = 4
	_noise.noise = grain
	_noise.seamless = true
	_noise.width = 256
	_noise.height = 256
	var column := CylinderMesh.new()
	column.top_radius = 1.0
	column.bottom_radius = 1.0
	column.height = 1.0
	column.radial_segments = 24
	column.rings = 16
	column.cap_top = false
	column.cap_bottom = false
	_devil_mesh = column
	# Cells: their distance field gives round billows with sharp folds between them.
	var cells := FastNoiseLite.new()
	cells.noise_type = FastNoiseLite.TYPE_CELLULAR
	cells.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	cells.frequency = 0.07
	cells.fractal_octaves = 3
	_billows.noise = cells
	_billows.seamless = true
	_billows.width = WALL_NOISE_SIZE
	_billows.height = WALL_NOISE_SIZE
	_billows.depth = WALL_NOISE_SIZE
	_wall_mesh = BoxMesh.new()


func _process(delta: float) -> void:
	var camera_now: Node3D = eye.call() if eye.is_valid() else null
	for entry: Array in _shown.values():
		(entry[0] as Node3D).position += (entry[1] as Vector3) * delta
		if entry[2] != null and camera_now != null:
			var under := _wall_ground(entry[3])
			(entry[2] as DustSparks).advance(delta, entry[3], to_local(camera_now.global_position), under, _wall_bottom(under))
	_since += delta
	if _since < REFRESH_S:
		return
	_since = 0.0
	var weather := _planet.current_weather_source() as ClimateWeather if _planet != null else null
	var camera: Node3D = eye.call() if eye.is_valid() else null
	var seen := {}
	if weather != null and weather.local_enabled and camera != null and _planet.planet_data != null:
		_open_air = smoothstep(CAVE_GONE_M, CAVE_FULL_M, _planet.surface_altitude_of(camera.global_position))
		var at := HEALPix.vec2lonlat(_planet.to_local(camera.global_position).normalized())
		for devil: Dictionary in weather.devils_near(_planet, at, DEVIL_RANGE_M):
			_show(seen, devil, _make_devil, _devil_frame(devil))
		for wall: Dictionary in weather.walls_near(_planet, at):
			_show(seen, wall, _make_wall, _wall_frame(wall))
	for id: int in _shown.keys():
		if not seen.has(id):
			_forget(id)


## Stops drawing the thing [param id].
func _forget(id: int) -> void:
	var entry: Array = _shown[id]
	(entry[0] as Node).queue_free()
	if entry[2] != null:
		(entry[2] as Node).queue_free()
	if _wall_grounds.has(id):
		(_wall_grounds[id] as WallGround).finish()
		_wall_grounds.erase(id)
	_shown.erase(id)


func _exit_tree() -> void:
	for under: WallGround in _wall_grounds.values():
		under.finish()


## The ground under a wall, kept as long as the wall is drawn.
func _wall_ground(wall: Dictionary) -> WallGround:
	var id: int = wall["id"]
	if not _wall_grounds.has(id):
		_wall_grounds[id] = WallGround.new()
	return _wall_grounds[id]


## The heights of the bottom of a wall's box and of its top, metres over the planet's reference sphere:
## from under the lowest ground under the wall to the wall's height over the highest.
static func _wall_bottom(under: WallGround) -> float:
	return under.low - WALL_UNDER_M


static func _wall_top(under: WallGround, wall: Dictionary) -> float:
	return under.high + wall_tall(wall)


## Puts the node of [param thing] (made by [param make] on first sight) at [param frame], and keeps it
## moving until the next reading the way it has just moved.
func _show(seen: Dictionary, thing: Dictionary, make: Callable, frame: Transform3D) -> void:
	var id: int = thing["id"]
	seen[id] = true
	var entry: Array = _shown.get(id, [])
	if entry.size() > 2 and entry[2] != null:
		(entry[2] as DustSparks).open_air = _open_air
	if entry.is_empty():
		entry = [make.call(thing), Vector3.ZERO, null, thing]
		add_child(entry[0])
		_shown[id] = entry
		if thing.has("length_m"):  # a wall: its sparks, beside its box
			var sparks := DustSparks.new()
			add_child(sparks)
			sparks.setup(entry[0], ((entry[0] as Node3D).get_child(0) as MeshInstance3D).material_override, _noise)
			entry[2] = sparks
	else:
		entry[3] = thing
		# Along the ground the node glides to its new place; up and down it is put there at once (the ground
		# under a thing, or the box of a wall whose ground was read again, is where it is: nothing to glide).
		var up := frame.basis.y.normalized()
		var step := frame.origin - (entry[0] as Node3D).position
		var rise := up * step.dot(up)
		entry[1] = (step - rise) / REFRESH_S
		frame.origin = (entry[0] as Node3D).position + rise
	var node: Node3D = entry[0]
	node.transform = frame
	var to_sun := _to_sun()
	var light := clampf(LIGHT_HORIZON + LIGHT_GAIN * frame.basis.y.normalized().dot(to_sun), LIGHT_NIGHT, 1.0)
	var sun_local := frame.basis.orthonormalized().inverse() * to_sun
	for part: GeometryInstance3D in node.get_children():
		part.set_instance_shader_parameter("strength", float(thing["strength"]))
		part.set_instance_shader_parameter("light", light)
		part.set_instance_shader_parameter("sun_local", sun_local)
		part.set_instance_shader_parameter("open_air", _open_air)
		part.set_instance_shader_parameter("size", frame.basis.get_scale())
		if thing.has("length_m"):  # a wall
			var under := _wall_ground(thing)
			part.set_instance_shader_parameter("bottom_m", _wall_bottom(under))
			part.set_instance_shader_parameter("wall_tall_m", wall_tall(thing))
			var material := part.material_override as ShaderMaterial
			var up_now := frame.basis.y.normalized()
			material.set_shader_parameter("ground_map", under.texture)
			material.set_shader_parameter("ground_span", under.span)
			material.set_shader_parameter("ground_shift", under.shift_m(frame.origin - up_now * frame.origin.dot(up_now)
					+ up_now * _planet.planet_data.radius))
			part.set_instance_shader_parameter("spent", float(thing.get("spent", 0.0)))
			part.set_instance_shader_parameter("body", 1.0 / WALL_DEEPER)


## The ground point at a longitude and latitude, in the body's frame, and the unit way up there.
func _ground(lon: float, lat: float) -> Array:
	var up := HEALPix.lonlat2vec(lon, lat)
	var data: PlanetData = _planet.planet_data
	return [up * (data.radius + data.sample_height_for_direction(up)), up]


## A devil's frame: on the ground, upright, as wide as its radius and as tall as its height.
func _devil_frame(devil: Dictionary) -> Transform3D:
	var ground := _ground(devil["lon"], devil["lat"])
	var up: Vector3 = ground[1]
	var axes: Array = Planet.local_axes(up)
	var r: float = devil["radius_m"]
	return Transform3D(Basis(axes[0] * r, up * float(devil["height_m"]), -(axes[1] as Vector3) * r), ground[0])


## How tall a wall stands now, metres: small at its birth, sinking as it thins out.
static func wall_tall(wall: Dictionary) -> float:
	return float(wall["height_m"]) * lerpf(WALL_BORN.x, 1.0, float(wall.get("grown", 1.0))) \
			* lerpf(1.0, WALL_SPENT_TALL, float(wall.get("spent", 0.0)))


## Where the foot of a wall's front stands at [param x_m] metres along it, in metres from the middle of its
## box (of [param size]) toward the box's leading face; [param deep_m]: the wall's own depth. The numbers
## dust_wall_volume.gdshader draws the front by (its front_m).
static func wall_front_m(x_m: float, size: Vector3, deep_m: float) -> float:
	var along := x_m / (size.x * 0.5)
	return size.z * 0.5 - deep_m * WALL_FRONT_MARGIN - WALL_BOW * size.x * 0.5 * along * along \
			+ deep_m * (WALL_WANDER.x * (0.6 * sin(x_m / WALL_WANDER_M.x + 1.3) + 0.4 * sin(x_m / WALL_WANDER_M.y + 4.1)) \
			+ WALL_WANDER.y * sin(x_m / WALL_WANDER_M.z + 0.7))


## A wall's box: x along the front, y up, z the way it runs, the front WALL_FRONT_MARGIN wall depths behind
## its leading face; as long as the wall is now, WALL_DEEPER times as deep, from under the lowest ground
## under it to its height over the highest (heights over the planet's reference sphere: the box does not
## rise and fall with the ground its middle passes over). Asks for that ground to be read again when due.
func _wall_frame(wall: Dictionary) -> Transform3D:
	var ground := _ground(wall["lon"], wall["lat"])
	var up: Vector3 = ground[1]
	var axes: Array = Planet.local_axes(up)
	var way: Vector3 = (axes[0] as Vector3) * float(wall["east"]) + (axes[1] as Vector3) * float(wall["north"])
	var across := up.cross(way)
	var deep: float = float(wall["depth_m"]) * WALL_DEEPER
	var long: float = float(wall["length_m"]) * lerpf(WALL_BORN.y, 1.0, float(wall.get("grown", 1.0)))
	var radius: float = _planet.planet_data.radius
	# The box's middle, on the reference sphere: behind the wall's middle along its way.
	var middle := up * radius - way * deep * (0.5 - WALL_FRONT_MARGIN / WALL_DEEPER)
	var under := _wall_ground(wall)
	under.flat((ground[0] as Vector3).length() - radius)
	under.refresh(_planet.planet_data, middle, across, way, Vector2(long, deep), Time.get_ticks_msec() / 1000.0)
	var bottom := _wall_bottom(under)
	var top := _wall_top(under, wall)
	return Transform3D(Basis(across * long, up * (top - bottom), way * deep), middle + up * (top + bottom) * 0.5)


func _make_devil(devil: Dictionary) -> Node3D:
	var node := Node3D.new()
	var material := _material(DEVIL_SHADER)
	var tint := _dust_colour(devil)
	for k in DEVIL_SHELLS:
		var shell := _part(node, _devil_mesh, material, tint, 3.0)
		shell.set_instance_shader_parameter("shell", float(k) / (DEVIL_SHELLS - 1))
		shell.set_instance_shader_parameter("spin", float(devil["spin"]))
		shell.set_instance_shader_parameter("slender", float(devil["height_m"]) / float(devil["radius_m"]))
	return node


func _make_wall(wall: Dictionary) -> Node3D:
	var node := Node3D.new()
	var material := _material(WALL_SHADER)
	material.set_shader_parameter("billows", _billows)
	material.set_shader_parameter("front_margin", WALL_FRONT_MARGIN)
	material.set_shader_parameter("bow", WALL_BOW)
	material.set_shader_parameter("wander", WALL_WANDER)
	material.set_shader_parameter("wander_m", WALL_WANDER_M)
	_part(node, _wall_mesh, material, _dust_colour(wall), 0.0)
	return node


## One drawn part of a phenomenon under [param node]: a mesh in the dust's colour, casting no shadow, kept
## drawn [param margin] past its box (the shaders move its points).
func _part(node: Node3D, mesh: Mesh, material: Material, tint: Color, margin: float) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	part.extra_cull_margin = margin
	part.set_instance_shader_parameter("tint", tint)
	node.add_child(part)
	return part


## The colour of the dust a phenomenon lifts: the ground's where it stands, as the dust layer takes it
## (WeatherSky.blow_albedo_of).
func _dust_colour(thing: Dictionary) -> Color:
	var up := HEALPix.lonlat2vec(thing["lon"], thing["lat"])
	var albedo := WeatherSky.blow_albedo_of(GroundLook.colour_at(_planet.planet_data, up, WeatherSky.BLOW_FALLBACK_COLOUR))
	return Color(albedo.x, albedo.y, albedo.z).lerp(WeatherSky.BLOW_FALLBACK_COLOUR, DUST_PALE)


func _material(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("noise", _noise)
	return material


## The unit way to the sun, in the body's frame (straight up without a star).
func _to_sun() -> Vector3:
	var sun: Node3D = _planet.star()
	if sun == null:
		return Vector3.UP
	return (_planet.global_transform.basis.inverse() * (sun.global_position - _planet.global_position)).normalized()
