@tool
class_name PlanetTerrain
extends StaticBody3D

signal regenerate()

## Base radius of the planet
var radius: int

var min_height: float = 10000.0
var max_height: float
var resolution: int = 60
var uv_scale: float = 300.0

var terrain_settings: PlanetTerrainSettings

var terrain_material: ShaderMaterial

var biomes_tex: Array[Image] = []

var terrain_map_image: Image

var focus_positions = []
var players_ids: Array[String] = []

@onready var occluder_instance_3d: OccluderInstance3D = $OccluderInstance3D
@export var planet_gravity: PhysicsGrid

func _ready() -> void:
	setup.call_deferred()

func setup():
	if !terrain_settings: return

	if terrain_settings.terrain_map:
		terrain_map_image = terrain_settings.terrain_map.get_image()

		if terrain_map_image.is_compressed():
			terrain_map_image.decompress()

	# loading biome images
	for biome in terrain_settings.biomes_elevations:
		var img = biome.get_image()
		if img.is_compressed():
			img.decompress()
		biomes_tex.push_back(img)

	trigger_update()

func align_with_y(xform: Transform3D, new_y: Vector3) -> Transform3D:
	xform.basis.y = new_y
	xform.basis.x = -xform.basis.z.cross(new_y)
	xform.basis = xform.basis.orthonormalized()
	return xform

func _process(_delta: float) -> void:
	var camera: Camera3D
	if OS.has_feature("editor"):
		if Engine.is_editor_hint():
			camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
			players_ids = ["editor"]
			focus_positions = [camera.global_position + -camera.global_basis.z * 1]

			return

	if GameOrchestrator.is_server():
		focus_positions = []
		players_ids = []

		if !planet_gravity:
			return

		for body in planet_gravity.get_overlapping_bodies():
			if body is Player:
				#prints("server position", body.name, body.global_position)
				focus_positions.push_back(body.global_position)
				players_ids.push_back(body.name)
		return

	camera = get_viewport().get_camera_3d()
	if camera:
		#prints("client position", camera.global_position)
		players_ids = ["client"]
		focus_positions = [camera.global_position + -camera.global_basis.z * 1]

func trigger_update():
	if occluder_instance_3d:
		var occluder = occluder_instance_3d.occluder as SphereOccluder3D
		occluder.radius = radius

	regenerate.emit(resolution)

func norm(value: float):
	return value + 1 / 2.0

func sample_nearest_wrapped(img: Image, uv: Vector2) -> float:
	var w = img.get_width()
	var h = img.get_height()

	# Align with texel centers like GPU
	var u = fposmod(uv.x * w - 0.5, w)
	var v = fposmod(uv.y * h - 0.5, h)

	var x0 = int(floor(u))
	var y0 = int(floor(v))

	return img.get_pixel(x0, y0).r



func sample_bilinear_wrapped(img: Image, uv: Vector2) -> Color:
	var w = img.get_width()
	var h = img.get_height()

	# Align with texel centers like GPU
	var u := fposmod(uv.x * w - 0.5, w)
	var v := fposmod(uv.y * h - 0.5, h)

	var x0 := floori(u)
	var y0 := floori(v)
	var x1 = (x0 + 1) % w
	var y1 = (y0 + 1) % h

	var tx := u - x0
	var ty := v - y0

	var c00 := img.get_pixel(x0, y0)
	var c10 := img.get_pixel(x1, y0)
	var c01 := img.get_pixel(x0, y1)
	var c11 := img.get_pixel(x1, y1)

	var cx0 := c00.lerp(c10, tx)
	var cx1 := c01.lerp(c11, tx)
	return cx0.lerp(cx1, ty)


## pos = 3D position (world or object space)
## normal = surface normal (normalized)
## blend_sharpness = how sharp blending is (0 = very soft, high = sharp)
func get_box_uv(pos: Vector3, normal: Vector3, sharpness: float = 4.0) -> Vector2:
	var n = normal.abs()

	# Apply sharpness (higher = sharper blending)
	n.x = pow(n.x, sharpness)
	n.y = pow(n.y, sharpness)
	n.z = pow(n.z, sharpness)

	var sum = n.x + n.y + n.z
	if sum == 0.0:
		return Vector2.ZERO
	n /= sum  # normalize weights

	# Generate UVs for each axis projection
	var uv_x = Vector2(pos.z, pos.y)
	var uv_y = Vector2(pos.x, pos.z)
	var uv_z = Vector2(pos.x, pos.y)

	# Blend UVs, but normalize by the same weights (reduces distortion)
	var blended_uv = (uv_x * n.x + uv_y * n.y + uv_z * n.z) / (n.x + n.y + n.z)

	# Wrap to [0, 1] range for repeating textures
	return blended_uv - blended_uv.floor()

func rotate_uv(uv: Vector2, rot: float) -> Vector2:
	var mid = 0.5;
	return Vector2(
		cos(rot) * (uv.x - mid) + sin(rot) * (uv.y - mid) + mid,
		cos(rot) * (uv.y - mid) - sin(rot) * (uv.x - mid) + mid
	);

func get_cube_uv(normalized_pos: Vector3) -> Vector2:
	var x = normalized_pos.x
	var y = normalized_pos.y
	var z = normalized_pos.z

	var abs_x = abs(x)
	var abs_y = abs(y)
	var abs_z = abs(z)

	var u: float
	var v: float

	# +X face
	if abs_x >= abs_y and abs_x >= abs_z:
		if x > 0.0:
			u = -z / abs_x
			v = y / abs_x
		else:
			# -X face
			u = z / abs_x
			v = y / abs_x

	# +Y face (top)
	elif abs_y >= abs_x and abs_y >= abs_z:
		if y > 0.0:
			u = -x / abs_y   # <- rotated so it matches +Z face edges
			v = z / abs_y
		else:
			# -Y face (bottom)
			u = -x / abs_y   # same orientation, flipped vertically for continuity
			v = -z / abs_y

	# +Z face
	else:
		if z > 0.0:
			u = x / abs_z
			v = y / abs_z
		else:
			# -Z face
			u = -x / abs_z
			v = y / abs_z

	# Map from [-1, 1] → [0, 1]
	return Vector2((u + 1.0) * 0.5, (v + 1.0) * 0.5)

func cubemap_uv_simple(direction: Vector3) -> Vector2:
	var abs_dir = direction.abs()
	var major_axis = 0
	var max_axis = abs_dir.x
	if abs_dir.y > max_axis:
		major_axis = 1
		max_axis = abs_dir.y
	if abs_dir.z > max_axis:
		major_axis = 2
		max_axis = abs_dir.z
	
	var uv = Vector2()
	
	match major_axis:
		0:
			if direction.x > 0.0:
				uv = Vector2(-direction.z, direction.y) / max_axis
			else:
				uv = Vector2(direction.z, direction.y) / max_axis
		1:
			if direction.y > 0.0:
				uv = Vector2(direction.x, -direction.z) / max_axis
			else:
				uv = Vector2(direction.x, direction.z) / max_axis
		2:
			if direction.z > 0.0:
				uv = Vector2(direction.x, direction.y) / max_axis
			else:
				uv = Vector2(-direction.x, direction.y) / max_axis
	
	return uv * 0.5 + Vector2(0.5, 0.5)
	

func cubemap_project_seamless(direction: Vector3) -> Vector2:
	var abs_dir = direction.abs()
	var major_axis = 0
	var max_axis = abs_dir.x

	# Find dominant axis
	if abs_dir.y > max_axis:
		major_axis = 1
		max_axis = abs_dir.y
	if abs_dir.z > max_axis:
		major_axis = 2
		max_axis = abs_dir.z

	var uv = Vector2()

	# Determine face and compute base UV
	match major_axis:
		0:
			if direction.x > 0.0:
				uv = Vector2(-direction.z, direction.y) / max_axis
			else:
				uv = Vector2(direction.z, direction.y) / max_axis
		1:
			if direction.y > 0.0:
				uv = Vector2(direction.x, -direction.z) / max_axis
			else:
				uv = Vector2(direction.x, direction.z) / max_axis
		2:
			if direction.z > 0.0:
				uv = Vector2(direction.x, direction.y) / max_axis
			else:
				uv = Vector2(-direction.x, direction.y) / max_axis

	# Map from [-1, 1] → [0, 1]
	uv = uv * 0.5 + Vector2(0.5, 0.5)
	
	# --- Blend UV with adjacent faces near edges ---
	var edge_blend = 0.005
	var blend_uv = uv
	var blend_weight = 0.0
	
	if uv.x < edge_blend or uv.x > 1.0 - edge_blend or uv.y < edge_blend or uv.y > 1.0 - edge_blend:
		# Get neighboring directions
		var eps = 0.001
		var neighbors = [
			(direction + Vector3(eps, 0, 0)).normalized(),
			(direction - Vector3(eps, 0, 0)).normalized(),
			(direction + Vector3(0, eps, 0)).normalized(),
			(direction - Vector3(0, eps, 0)).normalized(),
			(direction + Vector3(0, 0, eps)).normalized(),
			(direction - Vector3(0, 0, eps)).normalized()
		]
		var avg_uv = Vector2()
		var count = 0
		for n in neighbors:
			avg_uv += cubemap_uv_simple(n)
			count += 1
		avg_uv /= float(count)

		# Distance from edge to control blend
		var edge_dist = min(uv.x, uv.y, 1.0 - uv.x, 1.0 - uv.y)
		blend_weight = smoothstep(edge_blend, 0.0, edge_dist)
		
		blend_uv = uv.lerp(avg_uv, blend_weight)

	return blend_uv

# Catmull–Rom cubic interpolation between 4 points
func cubic_interp(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
	var a = -0.5*p0 + 1.5*p1 - 1.5*p2 + 0.5*p3
	var b = p0 - 2.5*p1 + 2.0*p2 - 0.5*p3
	var c = -0.5*p0 + 0.5*p2
	var d = p1
	return ((a * t + b) * t + c) * t + d


func point_to_uv(point: Vector3) -> Vector2:
	var lon = atan2(point.z, point.x)  # -π .. π
	var lat = asin(point.y)             # -π/2 .. π/2

	var u = clamp(fmod(lon / TAU + 0.5, 1.0), 0.0, 1.0)
	var v = clamp(fmod(lat / PI + 0.5, 1.0), 0.0, 1.0)

	return Vector2(u, v)

func sample_height_triplanar_bilinear(img: Image, pos: Vector3, normal: Vector3, tiling: float) -> float:
	normal = normal.normalized()
	var blend = normal.abs()
	var sum = blend.x + blend.y + blend.z
	if sum > 0.0:
		blend /= sum

	# Project world position to three planes
	var uv_x = Vector2(pos.z, pos.y) * tiling  # YZ projection
	var uv_y = Vector2(pos.x, pos.z) * tiling  # XZ projection
	var uv_z = Vector2(pos.x, pos.y) * tiling  # XY projection

	# Wrap UVs to 0–1
	uv_x = Vector2(fposmod(uv_x.x, 1.0), fposmod(uv_x.y, 1.0))
	uv_y = Vector2(fposmod(uv_y.x, 1.0), fposmod(uv_y.y, 1.0))
	uv_z = Vector2(fposmod(uv_z.x, 1.0), fposmod(uv_z.y, 1.0))

	var hx = sample_bilinear_wrapped(img, uv_x)
	var hy = sample_bilinear_wrapped(img, uv_y)
	var hz = sample_bilinear_wrapped(img, uv_z)

	return hx * blend.x + hy * blend.y + hz * blend.z

func get_biome(point: Vector3) -> float:
	#var v = terrain_settings.biome_noise.get_noise_3dv(point * 10000)
	#v = (v + 1.0) * 0.5
	#
	#v = v * v
	#v = snappedf(v, 1.0 / 8)

	if !terrain_map_image: return 0.0


	var equirect_uv = spherical_uv(point)
	var v := sample_bilinear_wrapped(terrain_map_image, equirect_uv).r

	return clamp(v - 0.001, 0.0, 1.0)

func fract(x: float) -> float:
	return x - floor(x)

func get_polar_uv(pos: Vector3) -> Vector2:
	# top/down projection onto XZ plane
	var u = pos.x * 0.5 + 0.5
	var v = pos.z * 0.5 + 0.5
	return Vector2(u, v)

func octahedral_projection(direction: Vector3) -> Vector2:
	var p = direction / (abs(direction.x) + abs(direction.y) + abs(direction.z))
	var u = p.x + p.z * 0.0  # adjust for mapping
	var v = p.y + p.z * 0.0
	return Vector2(0.5 * (u + 1.0), 0.5 * (v + 1.0))

func spherical_uv(n: Vector3) -> Vector2:
	var u = 0.5 + atan2(n.z, n.x) / (2.0 * PI)
	var v = 0.5 - asin(n.y) / PI
	return Vector2(u, v)

func stereographic_uv(n: Vector3) -> Vector2:
	var denom = 1.0 - n.y
	if abs(denom) < 1e-5:
		return Vector2(0.5, 0.5)
	var u = n.x / denom * 0.5 + 0.5
	var v = n.z / denom * 0.5 + 0.5
	return Vector2(u, v)

func blended_uv(n: Vector3) -> Vector2:
	# Compute both projections
	var uv_sphere = spherical_uv(n)
	var uv_cube = get_cube_uv(n)

	# Blend factor based on latitude to minimize distortion
	# abs(y) → 0 at equator, 1 at poles
	var lat_factor = abs(n.y)

	# Smooth transition: use more spherical near poles, more stereo near equator
	var blend = smoothstep(0.5, 0.6, lat_factor)

	# Interpolate UVs
	return uv_sphere.lerp(uv_cube, blend)

func get_uv(point: Vector3) -> Vector2:
	var uv_cube = get_cube_uv(point) * uv_scale
	var uv_pol = point_to_uv(point) * uv_scale
	var uv = uv_pol
	if abs(point.y) > .95:
		uv = uv_cube

	return uv

func smooth_blend_axis(normalized_pos: Vector3) -> Array[Vector3]:
	var x = normalized_pos.x
	var y = normalized_pos.y
	var z = normalized_pos.z

	var abs_x = abs(x)
	var abs_y = abs(y)
	var abs_z = abs(z)

	# +X face
	if abs_x >= abs_y and abs_x >= abs_z:
		if x > 0.0:
			return [Vector3.UP, Vector3.BACK]
		else:
			# -X face
			return [Vector3.UP, Vector3.FORWARD]

	# +Y face (top)
	elif abs_y >= abs_x and abs_y >= abs_z:
		if y > 0.0:
			return [Vector3.FORWARD, Vector3.LEFT]
		else:
			# -Y face (bottom)
			return [Vector3.FORWARD, Vector3.LEFT]

	# +Z face
	else:
		if z > 0.0:
			return [Vector3.UP, Vector3.LEFT]
		else:
			# -Z face
			return [Vector3.UP, Vector3.RIGHT]

func random_from_vec3(v: Vector3) -> float:
	var seed_val = int(v.x * 374761393 + v.y * 668265263 + v.z * 2147483647) & 0x7fffffff
	seed_val = (seed_val ^ (seed_val >> 13)) * 1274126177
	seed_val = (seed_val ^ (seed_val >> 16)) & 0x7fffffff
	return float(seed_val) / float(0x7fffffff)

func smooth_blend(point: Vector3, img: Image, uvmult = 1.0) -> float:
	var axis = smooth_blend_axis(point)
	var amount = 0.0
	var uv00 = get_uv((point).normalized()) * uvmult
	var uv10 = get_uv((point + axis[0] * 0.001).normalized()) * uvmult
	var uv01 = get_uv((point + axis[1] * 0.001).normalized()) * uvmult
	var uv11 = get_uv((point + axis[1] * 0.001 + axis[0] * 0.001).normalized()) * uvmult

	amount = lerpf(sample_nearest_wrapped(img, uv00), sample_nearest_wrapped(img, uv10), 0.01)
	amount = lerpf(amount, sample_nearest_wrapped(img, uv01), 0.01)
	amount = lerpf(amount, sample_nearest_wrapped(img, uv11), 0.01)
	return amount

func get_sphere_point(p: Vector3) -> Vector3:
	var np = Vector3()
	var p2 = p * p

	np.x = p.x * sqrt(1 - (p2.y / 2.0) - (p2.z / 2.0) + (p2.y * p2.z) / 3.0)
	np.y = p.y * sqrt(1 - (p2.z / 2.0) - (p2.x / 2.0) + (p2.z * p2.x) / 3.0)
	np.z = p.z * sqrt(1 - (p2.x / 2.0) - (p2.y / 2.0) + (p2.x * p2.y) / 3.0)

	if is_nan(np.x): np.x = 0.0
	if is_nan(np.y): np.y = 0.0
	if is_nan(np.z): np.z = 0.0

	return np

func get_height(normalized_point: Vector3) -> Vector3:
	var elev = 0.0

	if !biomes_tex: return Vector3.ZERO
	if !terrain_map_image: return Vector3.ZERO

	var b := get_biome(normalized_point)


	var layer_count := biomes_tex.size()

	var scaled := b * float(layer_count - 1)

	var lower_layer = floori(scaled)
	var upper_layer = lower_layer + 1
	assert(upper_layer < layer_count, "upper layer is out of bound: " + str(upper_layer))
	assert(lower_layer >= 0, "lower layer must be superior or equal to 0")
	var blend = fract(scaled)

	var uv = get_uv(normalized_point)


	var lower_h = sample_bilinear_wrapped(biomes_tex[lower_layer], uv).r
	var upper_h = sample_bilinear_wrapped(biomes_tex[upper_layer], uv).r

	elev += lerp(lower_h, upper_h, blend)

	elev += b * 10

	elev *= 200 + 1500 * (1.0 - abs(normalized_point.y) + 0.4)

	return normalized_point * (radius + (elev * terrain_settings.elev_scale))
