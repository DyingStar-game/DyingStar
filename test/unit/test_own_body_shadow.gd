extends GutTest
## Our own torch, worn on the head, sits behind our shoulders: they must not cut the bottom of its
## beam. Our body goes on a render layer of its own, the torch leaves that layer out of its shadows,
## and the lights that only reach the local layer (sun, moons) reach that one too.


func test_the_torch_takes_no_shadow_from_our_own_body() -> void:
	var body := Node3D.new()
	var torso := MeshInstance3D.new()
	var arm := MeshInstance3D.new()
	body.add_child(torso)
	torso.add_child(arm)  # nested, as in the puppet's skeleton
	var torch := SpotLight3D.new()
	add_child_autofree(body)
	add_child_autofree(torch)
	PlayerClient.keep_out_of_torch_shadow(body, torch)
	for mesh: MeshInstance3D in [torso, arm]:
		assert_eq(mesh.layers, Globals.RENDER_MASK_OWN_BODY,
				"only the own-body layer: a mesh casts as soon as ONE of its layers is in the mask")
	assert_eq(torch.shadow_caster_mask & Globals.RENDER_MASK_OWN_BODY, 0, "the torch leaves our body out")
	assert_ne(torch.shadow_caster_mask & Globals.RENDER_MASK_LOCAL, 0, "and still takes the world's shadows")


func test_the_sun_still_lights_our_body() -> void:
	var sun := PlayerSunLight.new()
	add_child_autofree(sun)
	sun.set_process(false)
	assert_ne(sun.light_cull_mask & Globals.RENDER_MASK_OWN_BODY, 0, "else our body goes black by day")
	assert_ne(sun.light_cull_mask & Globals.RENDER_MASK_LOCAL, 0)
	assert_eq(sun.light_cull_mask & Globals.RENDER_MASK_CELESTIAL, 0, "distant bodies stay the star's")


func test_our_body_layer_is_its_own() -> void:
	assert_eq(Globals.RENDER_MASK_OWN_BODY & (Globals.RENDER_MASK_LOCAL | Globals.RENDER_MASK_CELESTIAL), 0)
