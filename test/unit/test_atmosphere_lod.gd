extends GutTest
## A body's air is drawn at the level its size on screen calls for (AtmosphereLod): the player's own
## by the sky, another's as a disc seen through its whole column of air, with a shell around it once its
## air spans a pixel — and the terrain shader is handed that body's own column.

const LOD := preload("res://scenes/planet/atmosphere_lod.gd")
const ATMOSPHERES := "res://scenes/planet/atmospheres/"


func _profile(body := "tarsis_3") -> AtmosphereProfile:
	return load(ATMOSPHERES + body + ".tres") as AtmosphereProfile


func test_pixels_per_radian_of_a_1080p_view_at_75_degrees() -> void:
	assert_almost_eq(LOD.pixels_per_radian(1080.0, 75.0), 703.7, 0.1)


func test_no_air_is_never_drawn() -> void:
	assert_eq(LOD.choose(false, false, 50.0, LOD.Level.NONE), LOD.Level.NONE)
	assert_false(LOD.has_air(null))


func test_the_players_own_body_is_the_skys() -> void:
	assert_eq(LOD.choose(true, true, 50.0, LOD.Level.SHELL), LOD.Level.OWN)


func test_a_pixel_of_air_brings_the_shell() -> void:
	assert_eq(LOD.choose(true, false, 1.2, LOD.Level.DISC), LOD.Level.SHELL)
	assert_eq(LOD.choose(true, false, 0.9, LOD.Level.DISC), LOD.Level.DISC, "not yet")


func test_the_shell_holds_a_little_below_its_threshold() -> void:
	assert_eq(LOD.choose(true, false, 0.9, LOD.Level.SHELL), LOD.Level.SHELL, "no flicker")
	assert_eq(LOD.choose(true, false, 0.5, LOD.Level.SHELL), LOD.Level.DISC)


func test_sandboxs_veil_brightens_its_disc() -> void:
	# Its published albedo is 0.32 over a 0.15 ground: the veil sends back more than the ground alone.
	var gamma_tau := LOD.column_gamma_tau(_profile())
	for channel in 3:
		var albedo := LOD.column_albedo(gamma_tau[channel], 0.15)
		assert_between(albedo, 0.32, 0.47, "channel %d: brighter than the ground, a plane albedo" % channel)
	assert_gt(LOD.column_albedo(gamma_tau.z, 0.15), LOD.column_albedo(gamma_tau.x, 0.15), "bluer: its air")


func test_no_air_leaves_the_ground_as_it_is() -> void:
	assert_almost_eq(LOD.column_albedo(0.0, 0.3), 0.3, 1e-6)


func test_a_thick_column_tends_to_white_not_black() -> void:
	# A gas giant under 96 bar: light that is only scattered, never absorbed, must come back out.
	var gamma_tau := LOD.column_gamma_tau(_profile("tarsis_5"))
	assert_gt(gamma_tau.z, 10.0, "an optically thick column")
	assert_gt(LOD.column_albedo(gamma_tau.z, 0.15), 0.9)


func test_the_terrain_gets_the_bodys_own_column() -> void:
	var air := _profile()
	var params := LOD.chunk_params(air, LOD.Level.DISC)
	var scattering: Vector4 = params["far_air_scattering"]
	var expected := LOD.column_gamma_tau(air)
	assert_almost_eq(scattering.z, expected.z, 1e-6)
	assert_eq(scattering.w, 1.0, "the shader's on switch")
	assert_eq(params["far_air_absorption"], LOD.column_absorption(air))
	assert_eq(LOD.chunk_params(air, LOD.Level.SHELL), params, "the disc stays under the shell")


func test_the_own_body_switches_the_terrains_air_off() -> void:
	assert_eq(LOD.chunk_params(_profile(), LOD.Level.OWN), {"far_air_scattering": Vector4.ZERO})
	assert_eq(LOD.chunk_params(_profile(), LOD.Level.NONE), {"far_air_scattering": Vector4.ZERO})


func test_the_shell_wraps_the_top_of_the_air_and_shows_only_at_its_level() -> void:
	var air := _profile()
	var body: Node3D = add_child_autofree(Node3D.new())
	var camera: Camera3D = add_child_autofree(Camera3D.new())
	var lod := LOD.new(air, body)
	var shell := body.get_node("AtmosphereShell") as MeshInstance3D
	assert_almost_eq(shell.scale.x, air.planet_radius + air.atmosphere_top, 1.0)
	assert_eq(shell.layers, LOD.GlobalsDefs.RENDER_MASK_CELESTIAL, "drawn with the far bodies")
	assert_false(shell.visible)
	# Far enough for 2 px of air on this viewport, whatever its size.
	var per_rad := LOD.pixels_per_radian(camera.get_viewport().get_visible_rect().size.y, camera.fov)
	var distance := air.atmosphere_top * per_rad / 2.0
	body.global_position = Vector3(0.0, 0.0, -distance)
	assert_true(lod.update(body.global_position, camera, false, Vector3.UP), "the level changed")
	assert_eq(lod.level, LOD.Level.SHELL)
	assert_true(shell.visible)
	var center: Vector3 = (shell.material_override as ShaderMaterial).get_shader_parameter("planet_center")
	assert_almost_eq(center.z, -distance, 1.0, "camera-relative centre")
	assert_false(lod.update(body.global_position, camera, false, Vector3.UP), "same level, nothing to hand out")
	lod.update(body.global_position, camera, true, Vector3.UP)
	assert_eq(lod.level, LOD.Level.OWN)
	assert_false(shell.visible, "the sky draws the player's own air")
	lod.release()
