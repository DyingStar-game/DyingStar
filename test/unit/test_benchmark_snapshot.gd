extends GutTest
## BenchmarkSnapshot: whatever the benchmark changed comes back, once, and nothing is ever saved.

var _saves : int = 0


func _render() -> RenderSettings:
	var render := RenderSettings.new(ConfigFile.new(), func() -> void: _saves += 1, {"method": "forward_plus"})
	render.ensure_initialized(false)
	return render


func test_restore_gives_back_the_caps_and_the_settings() -> void:
	var render := _render()
	var fps_before : int = Engine.max_fps
	var snapshot := BenchmarkSnapshot.new(render)
	snapshot.take(null, null)
	Engine.max_fps = 0
	render.set_transient({"ssao": 0})
	_saves = 0
	snapshot.restore()
	assert_eq(Engine.max_fps, fps_before, "the frame cap is back")
	assert_false(render.has_transient(), "the overrides are gone")
	assert_eq(_saves, 0, "and nothing was saved on the way")
	Engine.max_fps = fps_before


func test_a_second_restore_does_nothing() -> void:
	var render := _render()
	var fps_before : int = Engine.max_fps
	var snapshot := BenchmarkSnapshot.new(render)
	snapshot.take(null, null)
	snapshot.restore()
	Engine.max_fps = 37
	snapshot.restore()
	assert_eq(Engine.max_fps, 37, "the safety net in _exit_tree must not undo a later change")
	Engine.max_fps = fps_before


func test_the_hidden_interface_comes_back() -> void:
	var layer := CanvasLayer.new()
	add_child_autofree(layer)
	var snapshot := BenchmarkSnapshot.new(_render())
	snapshot.take(null, null)
	layer.visible = false
	snapshot.hold_hidden([layer] as Array[Node])
	snapshot.restore()
	assert_true(layer.visible, "shown again")
