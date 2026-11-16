extends GutTest
## The aerial perspective's table is aimed on the camera before each frame is drawn
## (AtmosphereRenderer._aim_aerial_lut, on RenderingServer.frame_pre_draw). The renderer hangs on the
## player, which leaves the tree and comes back each time it changes frame (a vehicle, another body):
## leaving let go of the aim and nothing took it back, so from the first ride on the table stayed aimed
## where the camera looked then, and far relief went black when looking up (2026-11-14).

var _renderer: AtmosphereRenderer


func before_each() -> void:
	# Never put in the tree: its _ready builds a whole sky. Only the aim's hook is exercised.
	_renderer = AtmosphereRenderer.new()


func after_each() -> void:
	_renderer._exit_tree()  # lets go of the signal whatever the test left
	_renderer.free()


func _aimed() -> bool:
	return RenderingServer.frame_pre_draw.is_connected(_renderer._aim_aerial_lut)


func test_no_table_no_aim() -> void:
	_renderer._enter_tree()
	assert_false(_aimed(), "nothing to aim before the table is built")


func test_the_table_is_aimed_again_after_leaving_the_tree_and_coming_back() -> void:
	_renderer._aerial_lut_material = ShaderMaterial.new()
	_renderer._follow_camera()
	assert_true(_aimed(), "aimed once the table exists")
	_renderer._follow_camera()
	assert_true(_aimed(), "asked twice: still one hook, no error")
	_renderer._exit_tree()
	assert_false(_aimed(), "out of the tree: let go")
	_renderer._enter_tree()
	assert_true(_aimed(), "back in the tree: aimed again")
