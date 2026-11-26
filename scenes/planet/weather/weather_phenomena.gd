class_name WeatherPhenomena
extends Node3D
## The local weather that is seen as things standing on the ground: the dust devils and dust walls of the
## planet's ClimateWeather (WeatherRelief), drawn round the eye. A child of the Planet: its own frame is the
## body's, so what it draws turns with the ground.
##
## It draws what the weather says and nothing else: the same devils and walls WeatherRelief adds to the wind
## and the dust of a sample, at the same places. Their dust in the air round the eye (a wall passing over
## the player) is the sample's affair, drawn by the dust layer.

const DEVIL_SHADER := preload("res://scenes/planet/weather/dust_devil.gdshader")
const WALL_SHADER := preload("res://scenes/planet/weather/dust_wall_volume.gdshader")
## How often the weather is asked what stands round the eye (s), and how far devils are drawn (m).
const REFRESH_S := 0.5
const DEVIL_RANGE_M := 12000.0
## Nothing is drawn for an eye farther from the body's centre than this many radii (another body, deep space).
const EYE_RADII_MAX := 2.0
## A wall is a box of dust (a volume, see dust_wall_volume.gdshader) standing on the relief under it
## (WallGround: under a front tens of kilometres long the ground rises and falls by kilometres): the box
## goes from WALL_UNDER_M under the lowest ground to the wall's height over the highest. It is WALL_DEEPER
## times as deep as the wall's dust (the haze trailing it, seen from above); its billows are read from a 3D
## noise WALL_NOISE_SIZE across.
const WALL_UNDER_M := 250.0
const WALL_DEEPER := 6.0
const WALL_NOISE_SIZE := 128
## The blend skirt of a seamless noise image: NoiseTexture2D's and NoiseTexture3D's default.
const NOISE_SKIRT := 0.1
## A wall's life, drawn: at its birth it is WALL_BORN of its height and length (height, length) and grows
## to the whole; its height as the weather has it (WeatherRelief.wall_tall: born and thinning out).
const WALL_BORN := Vector2(0.2, 0.45)
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
## The dust's colour, low and high. At the foot (the first few hundred metres) it is the ground's under the
## thing now, this share of the way paler (toward the white grains of the dust sea, DustSea.WHITE); higher
## up, mostly the ground's dust still (DustSea.BODY_GROUND_SHARE of it over the sea, the sea's own palette
## in it): a wall looks like the ground it rides over. The ground is read again every TINT_REFRESH_S (s) under
## the thing as it travels, and its colour eased toward over TINT_EASE_S (s): read once at its birth, a
## wall born on yellow ground stayed yellow over a pink range (2026-11-25).
const DUST_PALE := 0.25
const TINT_REFRESH_S := 3.0
## The share of the dust sea's extinction that fogs a wall, a devil or a spark seen from inside the sea
## (dust_sea_light.gdshaderinc sea_fog_share): they loom out of the fog from two or three times the sea's 1 km.
const SEA_FOG_SHARE := 0.4
const TINT_EASE_S := 4.0

## The eye the phenomena are drawn round: a Callable returning a Node3D. Not set: the viewport's camera.
var eye: Callable

var _planet: Planet
var _since := REFRESH_S
var _shown := {}  # id → [node, velocity (the body's frame, m/s), its DustSparks (a wall's) or null, the thing]
var _devil_mesh: Mesh
var _wall_mesh: Mesh
## The grain of every phenomenon (2-D) and the billows of the walls (3-D): what a NoiseTexture2D / NoiseTexture3D
## of the settings in _ready would hold, made on a worker (_noise_task). A NoiseTexture makes its image the first
## time on the main thread, at once: the 128^3 seamless cells were 2.5 s in the frame the player's planet arrived
## (2026-11-24). Null until made; nothing is shown before.
var _noise: Texture2D = null
var _billows: Texture3D = null
var _noise_task := -1
var _noise_images: Array = []  # written by the task: [the grain's Image, the billows' Array[Image]]
var _wall_grounds := {}  # a wall's id → the ground under it (WallGround)
var _open_air := 1.0  # 1 in the open, 0 with the eye in a cave (CAVE_*)
var _wall_sounds := {}  # a wall's id → its sound (DustWallSound), client only
var _tints := {}  # id → [the ground's dust colour now, the one eased toward, when it is read next (s)]


func _ready() -> void:
	_planet = get_parent() as Planet
	if OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless":
		set_process(false)  # nothing to draw, and no one to draw it for
		return
	var grain := FastNoiseLite.new()
	grain.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	grain.frequency = 0.012
	grain.fractal_octaves = 4
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
	_noise_task = WorkerThreadPool.add_task(func() -> void: _noise_images = noise_images(grain, cells), false,
			"weather noise")
	_wall_mesh = BoxMesh.new()


## What NoiseTexture2D (256 px, seamless) and NoiseTexture3D (WALL_NOISE_SIZE, seamless) make of [param grain] and
## [param cells] with their other settings left as they are: [the grain's Image, its mipmaps made; the billows'
## Array[Image]]. Any thread.
static func noise_images(grain: Noise, cells: Noise) -> Array:
	var flat := grain.get_seamless_image(256, 256, false, false, NOISE_SKIRT, true)
	flat.generate_mipmaps()
	return [flat, cells.get_seamless_image_3d(WALL_NOISE_SIZE, WALL_NOISE_SIZE, WALL_NOISE_SIZE, false, NOISE_SKIRT, true)]


## The textures, once their images are made: true when they are there.
func _noise_ready() -> bool:
	if _noise != null:
		return true
	if _noise_task < 0 or not WorkerThreadPool.is_task_completed(_noise_task):
		return false
	WorkerThreadPool.wait_for_task_completion(_noise_task)
	_noise_task = -1
	_noise = ImageTexture.create_from_image(_noise_images[0])
	var layers: Array[Image] = []
	layers.assign(_noise_images[1])
	var billows := ImageTexture3D.new()
	billows.create(layers[0].get_format(), WALL_NOISE_SIZE, WALL_NOISE_SIZE, WALL_NOISE_SIZE, false, layers)
	_billows = billows
	_noise_images = []
	return true


## The eye now, null when there is none.
func _eye() -> Node3D:
	return eye.call() if eye.is_valid() else get_viewport().get_camera_3d()


func _process(delta: float) -> void:
	if not _noise_ready():
		return  # nothing is shown before the textures are made
	var camera_now := _eye()
	var over_ground := NAN  # the eye's height over the ground, read once a frame when a wall's sound needs it
	for entry: Array in _shown.values():
		(entry[0] as Node3D).position += (entry[1] as Vector3) * delta
		if entry[2] != null and camera_now != null:
			var under := _wall_ground(entry[3])
			(entry[2] as DustSparks).advance(delta, entry[3], to_local(camera_now.global_position), under, _wall_bottom(under))
			var sound: DustWallSound = _wall_sounds.get(int((entry[3] as Dictionary)["id"]))
			if sound != null:
				if is_nan(over_ground):
					over_ground = _planet.surface_altitude_of(camera_now.global_position)
				sound.advance(delta, entry[3], to_local(camera_now.global_position), _planet.planet_data.radius, over_ground)
	_since += delta
	if _since < REFRESH_S:
		return
	_since = 0.0
	var weather := _planet.current_weather_source() as ClimateWeather if _planet != null else null
	var camera := camera_now
	var seen := {}
	if weather != null and weather.local_enabled and camera != null and _planet.planet_data != null \
			and _planet.to_local(camera.global_position).length() < _planet.planet_data.radius * EYE_RADII_MAX:
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
	_tints.erase(id)
	if _wall_sounds.has(id):
		(_wall_sounds[id] as Node).queue_free()
		_wall_sounds.erase(id)
	_shown.erase(id)


func _exit_tree() -> void:
	for under: WallGround in _wall_grounds.values():
		under.finish()
	if _noise_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_noise_task)
		_noise_task = -1


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
			if not Sfx3D.muted():
				var sound := DustWallSound.new()
				add_child(sound)
				sound.setup(id)
				_wall_sounds[id] = sound
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
	var tints := _tints_of(thing)
	# The dust sea's light and fog (DustSea): a thing standing in the sea is lit and veiled as the sea is.
	var lit_material := (node.get_child(0) as GeometryInstance3D).material_override as ShaderMaterial
	DustSea.light_material(lit_material)
	lit_material.set_shader_parameter("sea_fog_share", SEA_FOG_SHARE)
	lit_material.set_shader_parameter("sun_tint", _sun_tint(frame.basis.y.normalized().dot(to_sun),
			frame.origin.length() - _planet.planet_data.radius))
	if entry[2] != null:
		(entry[2] as DustSparks).sea(SEA_FOG_SHARE)
	if not thing.has("length_m"):
		lit_material.set_shader_parameter("foot_alt_m", frame.origin.length() - _planet.planet_data.radius)
	for child: Node in node.get_children():
		if child is DustDevilSound:
			(child as DustDevilSound).set_strength(float(thing["strength"]))
			continue
		var part := child as GeometryInstance3D
		part.set_instance_shader_parameter("tint", tints[0])
		part.set_instance_shader_parameter("tint_high", tints[1])
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
			if under.colour_texture != null:
				material.set_shader_parameter("ground_colour", under.colour_texture)
				material.set_shader_parameter("ground_colour_on", 1)
				material.set_shader_parameter("foot_pale", DUST_PALE)
			_sort_wall(part, node)
			material.set_shader_parameter("ground_span", under.span)
			material.set_shader_parameter("ground_shift", under.shift_m(frame.origin - up_now * frame.origin.dot(up_now)
					+ up_now * _planet.planet_data.radius))
			part.set_instance_shader_parameter("spent", float(thing.get("spent", 0.0)))
			part.set_instance_shader_parameter("body", 1.0 / WALL_DEEPER)


## Sorts wall [param part] (of box [param node]) among the other transparent things (a volcano's plume) by its
## nearest face to the eye, not its middle: the box is tens of kilometres wide, and sorted by its middle a
## plume behind the wall's near face was drawn after it, over it (2026-11-25). Inside the box the wall sorts
## as nearest of all: what is in it is seen through its dust.
func _sort_wall(part: GeometryInstance3D, node: Node3D) -> void:
	var camera := _eye()
	if camera == null:
		return
	var eye := to_local(camera.global_position)
	var unit := node.transform.affine_inverse() * eye
	var nearest := node.transform * unit.clamp(Vector3(-0.5, -0.5, -0.5), Vector3(0.5, 0.5, 0.5))
	part.sorting_offset = eye.distance_to(node.transform.origin) - eye.distance_to(nearest)


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
	return WeatherRelief.wall_tall(wall)


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
	var tints := _tints_of(devil)
	for k in DEVIL_SHELLS:
		var shell := _part(node, _devil_mesh, material, tints, 3.0)
		shell.set_instance_shader_parameter("height_m", float(devil["height_m"]))
		shell.set_instance_shader_parameter("shell", float(k) / (DEVIL_SHELLS - 1))
		shell.set_instance_shader_parameter("spin", float(devil["spin"]))
		shell.set_instance_shader_parameter("slender", float(devil["height_m"]) / float(devil["radius_m"]))
	# Its sound, a little over its foot (the node is scaled: radius across, height up).
	if not Sfx3D.muted():
		var sound := DustDevilSound.new()
		sound.position = Vector3(0.0, 0.03, 0.0)
		node.add_child(sound)
		sound.setup(int(devil["id"]))
		sound.set_strength(float(devil["strength"]))
	return node


func _make_wall(wall: Dictionary) -> Node3D:
	var node := Node3D.new()
	var material := _material(WALL_SHADER)
	material.set_shader_parameter("billows", _billows)
	material.set_shader_parameter("front_margin", WALL_FRONT_MARGIN)
	material.set_shader_parameter("bow", WALL_BOW)
	material.set_shader_parameter("wander", WALL_WANDER)
	material.set_shader_parameter("wander_m", WALL_WANDER_M)
	_part(node, _wall_mesh, material, _tints_of(wall), 0.0)
	return node


## One drawn part of a phenomenon under [param node]: a mesh in the dust's colours ([param tints], _tints_of),
## casting no shadow, kept drawn [param margin] past its box (the shaders move its points).
func _part(node: Node3D, mesh: Mesh, material: Material, tints: Array, margin: float) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	part.extra_cull_margin = margin
	part.set_instance_shader_parameter("tint", tints[0])
	part.set_instance_shader_parameter("tint_high", tints[1])
	node.add_child(part)
	return part


## The colour of the dust the ground under a phenomenon gives now (a wall's: under the middle of its
## front), as a wall's dust (DustSea.wall_dust_of).
func _dust_colour(thing: Dictionary) -> Color:
	var up := HEALPix.lonlat2vec(thing["lon"], thing["lat"])
	return DustSea.wall_dust_of(GroundLook.colour_at(_planet.planet_data, up, WeatherSky.BLOW_FALLBACK_COLOUR))


## A phenomenon's two colours now: [its foot's, its body's] (see DUST_PALE). The ground under it is read
## again when due (TINT_REFRESH_S) and eased toward at each refresh (TINT_EASE_S).
func _tints_of(thing: Dictionary) -> Array:
	var id: int = thing["id"]
	var now := Time.get_ticks_msec() / 1000.0
	var held: Array = _tints.get(id, [])
	if held.is_empty():
		var first := _dust_colour(thing)
		held = [first, first, now + TINT_REFRESH_S]
		_tints[id] = held
	elif now >= float(held[2]):
		held[1] = _dust_colour(thing)
		held[2] = now + TINT_REFRESH_S
	held[0] = (held[0] as Color).lerp(held[1], 1.0 - exp(-REFRESH_S / TINT_EASE_S))
	var ground: Color = held[0]
	return [ground.lerp(DustSea.WHITE, DUST_PALE), DustSea.WHITE.lerp(ground, DustSea.BODY_GROUND_SHARE)]


func _material(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("noise", _noise)
	return material


## The hue of the sunlight at [param elevation] m under a sun [param sin_e] high: the star's colour through the
## air (AtmosphereProfile.transmittance_to_star, the air alone), brightest channel 1. White without an air or a sun.
func _sun_tint(sin_e: float, elevation: float) -> Vector3:
	var profile: AtmosphereProfile = _planet.planet_data.atmosphere_profile
	if profile == null or not profile.has_atmosphere():
		return Vector3.ONE
	var air: Color = profile.transmittance_to_star(maxf(elevation, 0.0), maxf(sin_e, 0.02), 0.0)
	var c := Vector3(profile.star_color.r * air.r, profile.star_color.g * air.g, profile.star_color.b * air.b)
	var top := maxf(c.x, maxf(c.y, c.z))
	return c / top if top > 1e-6 else Vector3.ONE


## What is drawn and in which colours, for the dust sea's probe (DustSeaProbe): each wall and devil, its
## distance from [param eye_world], the colours sent (foot, body, sun tint, the wall's ground colour map along
## its front), and the ground's colour under it (GroundLook, raw and as dust) at five points along its front.
func probe(eye_world: Vector3) -> Array:
	var out: Array = []
	var eye := to_local(eye_world)
	var data: PlanetData = _planet.planet_data if _planet != null else null
	for id: int in _shown:
		var entry: Array = _shown[id]
		var thing: Dictionary = entry[3]
		var node: Node3D = entry[0]
		var wall := thing.has("length_m")
		var got := {"id": id, "kind": "wall" if wall else "devil", "distance_m": eye.distance_to(node.position),
			"strength": thing.get("strength"), "ground_dust_eased": (_tints.get(id, [null]) as Array)[0]}
		var part := node.get_child(0) as GeometryInstance3D
		if part != null:
			got["foot_sent"] = part.get_instance_shader_parameter("tint")
			got["body_sent"] = part.get_instance_shader_parameter("tint_high")
			var material := part.material_override as ShaderMaterial
			if material != null:
				for key: String in ["sun_tint", "foot_pale", "sea_rock_tint", "body_ground_share", "ground_colour_on",
						"sea_beta", "sea_eye_alt"]:
					got[key] = material.get_shader_parameter(key)
		var under: WallGround = _wall_grounds.get(id)
		if wall and under != null and under.colour_texture != null:
			var image := under.colour_texture.get_image()
			var row: Array = []
			for i in WallGround.COLOUR_SIZE.x:
				row.append(image.get_pixel(i, WallGround.COLOUR_SIZE.y - 1))  # the leading face's row
			got["colour_map_front_row"] = row
		if data != null:
			var across := Vector2(-float(thing.get("north", 0.0)), float(thing.get("east", 1.0)))
			var half := float(thing.get("length_m", 0.0)) * 0.5
			var points: Array = []
			for f: float in [-0.8, -0.4, 0.0, 0.4, 0.8]:
				var ll := WeatherRelief.moved(Vector2(thing["lon"], thing["lat"]), across * f * half, data.radius)
				var raw := GroundLook.colour_at(data, HEALPix.lonlat2vec(ll.x, ll.y), WeatherSky.BLOW_FALLBACK_COLOUR)
				points.append({"along": f, "ground_raw": raw, "as_haze_dust": WeatherSky.blow_albedo_of(raw),
					"as_wall_dust": DustSea.wall_dust_of(raw)})
			got["ground_under_front"] = points
		out.append(got)
	return out


## The unit way to the sun, in the body's frame (straight up without a star).
func _to_sun() -> Vector3:
	var sun: Node3D = _planet.star()
	if sun == null:
		return Vector3.UP
	return (_planet.global_transform.basis.inverse() * (sun.global_position - _planet.global_position)).normalized()
