extends GutTest
## InterfaceHider: the interface goes, exactly that comes back — and what was already hidden stays so.


func test_hide_then_restore() -> void:
	var shown := CanvasLayer.new()
	var already_hidden := CanvasLayer.new()
	already_hidden.visible = false
	add_child_autofree(shown)
	add_child_autofree(already_hidden)
	var hidden : Array[Node] = InterfaceHider.hide_all(get_tree())
	assert_false(shown.visible, "the interface is gone")
	assert_has(hidden, shown, "and remembered")
	assert_does_not_have(hidden, already_hidden, "what was hidden is not ours to show")
	InterfaceHider.restore(hidden)
	assert_true(shown.visible, "back")
	assert_false(already_hidden.visible, "still hidden")


func test_a_freed_node_is_skipped() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var hidden : Array[Node] = InterfaceHider.hide_all(get_tree())
	layer.free()
	InterfaceHider.restore(hidden)
	pass_test("no crash on a node freed in between")
