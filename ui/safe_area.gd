class_name SafeArea
extends RefCounted
## Keeps a full-screen Control's content inside a centred 16:9 area. On a wider screen (21:9,
## 32:9) the menus would otherwise stretch to the edges — captions far left, their controls far
## right, a corner button out at the side of the eye. The background, left full-screen by the
## caller, still fills the screen; only the content is narrowed.

const ASPECT : float = 16.0 / 9.0


## `control` must be anchored to the full rect (its offsets are what this sets). Follows resizes
## for as long as the control lives: the connection goes with it (settings pages come and go).
static func keep(control: Control) -> void:
	var viewport : Viewport = control.get_viewport()
	if viewport == null:
		return
	fit(control)
	var refit : Callable = fit.bind(control)
	viewport.size_changed.connect(refit)
	control.tree_exiting.connect(func() -> void:
		if viewport.size_changed.is_connected(refit):
			viewport.size_changed.disconnect(refit), CONNECT_ONE_SHOT)


static func fit(control: Control) -> void:
	if not is_instance_valid(control) or control.get_viewport() == null:
		return
	var size : Vector2 = control.get_viewport().get_visible_rect().size
	var side : float = side_margin(size)
	control.offset_left = side
	control.offset_right = -side


## The margin on each side that brings `size` down to 16:9; 0 on a screen that is not wider.
static func side_margin(size: Vector2) -> float:
	return maxf(0.0, (size.x - size.y * ASPECT) / 2.0)
