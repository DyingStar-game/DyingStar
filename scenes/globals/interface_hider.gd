class_name InterfaceHider
extends RefCounted
## Takes every piece of interface off the game window, and puts exactly that back. Shared by the F7
## photo (one frame without the HUD) and the benchmark (minutes without it: a HUD costs draw time and
## would land in what is measured).


## Hide everything drawn on the game window's own canvas, and every debug visual in the world, and
## return what was hidden, so exactly that comes back. Two kinds of roots cover the canvas: the
## CanvasLayers (HUD, chat, menus, toasts) and the top-level CanvasItems drawn straight on the default
## canvas (a Control under a Node3D, like the player's interface). Anything inside a SubViewport is
## skipped — that is a screen in the world. The world's debug visuals cannot be told from scenery, so
## they say so themselves, by joining Globals.GROUP_DEBUG_OVERLAY.
static func hide_all(tree: SceneTree) -> Array[Node]:
	var window : Viewport = tree.root
	var hidden : Array[Node] = []
	for node in tree.get_nodes_in_group(Globals.GROUP_DEBUG_OVERLAY):
		if node.get("visible") == true:
			node.set("visible", false)
			hidden.append(node)
	for node in window.find_children("*", "CanvasLayer", true, false):
		var layer := node as CanvasLayer
		if layer.visible and layer.get_viewport() == window:
			layer.visible = false
			hidden.append(layer)
	for node in window.find_children("*", "CanvasItem", true, false):
		var item := node as CanvasItem
		if (item.visible and item.get_viewport() == window and item.get_canvas_layer_node() == null
				and not (item.get_parent() is CanvasItem)):
			item.visible = false
			hidden.append(item)
	return hidden


## Show again what hide_all() hid. Something freed meanwhile is skipped; something that was already
## hidden was never in the list, so it stays hidden.
static func restore(hidden: Array[Node]) -> void:
	for node in hidden:
		if is_instance_valid(node):
			node.set("visible", true)
