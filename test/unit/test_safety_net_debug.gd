extends GutTest
## Settings > Debug > safety net: the red drawn on the client must be the sphere
## the server collides with (PlanetTerrain.base_sphere_radius), to the centimetre,
## or the red would show where the net is not — or hide where it is.

const RADIUS := 6356000.0
const OFFSET := -1700.0


func _terrain() -> PlanetTerrain:
	var data := PlanetData.new()
	data.radius = RADIUS
	data.height_offset = OFFSET
	var terrain := PlanetTerrain.new()
	terrain.planet_data = data
	return terrain


func test_the_sphere_sits_below_the_lowest_relief() -> void:
	var data := PlanetData.new()
	data.radius = RADIUS
	data.height_offset = OFFSET
	assert_eq(PlanetTerrain.base_sphere_radius(data), RADIUS + OFFSET - PlanetTerrain.BASE_SPHERE_INSET_M)
	data.height_offset = -2.0 * RADIUS
	assert_eq(PlanetTerrain.base_sphere_radius(data), 0.5 * RADIUS, "never a sphere of radius <= 0")


func test_the_patch_lies_on_the_server_sphere() -> void:
	var terrain := _terrain()
	var net := SafetyNetDebug.new()
	net.setup(terrain)
	var dir := HEALPix.lonlat2vec(-39.5556, 24.8560)
	net._build_patch(dir)
	var r := PlanetTerrain.base_sphere_radius(terrain.planet_data)
	var verts: PackedVector3Array = net._patch.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(verts.size(), (SafetyNetDebug.PATCH_CELLS + 1) * (SafetyNetDebug.PATCH_CELLS + 1))
	var worst := 0.0
	var reach := 0.0
	for v in verts:
		var world: Vector3 = v + net._patch.position
		worst = maxf(worst, absf(world.length() - r))
		reach = maxf(reach, world.normalized().angle_to(dir) * r)
	assert_lt(worst, 0.01, "every vertex on the sphere (worst %.4f m)" % worst)
	assert_gt(reach, SafetyNetDebug.PATCH_HALF_M, "the patch covers PATCH_HALF_M around the camera")
	net.free()
	terrain.free()
