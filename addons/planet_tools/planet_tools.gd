@tool
extends EditorPlugin
## Editor helpers for placing objects on a planet surface.
##
## Adds a "Snap to surface" button to the 3D viewport toolbar (and a
## Ctrl+Shift+G shortcut). It moves the currently selected object(s) onto the
## planet terrain along their radial direction from the planet centre — the
## correct "down" on a sphere — using PlanetTerrain.compute_surface_transform.
## Unlike Godot's built-in "Snap Object to Floor", it needs no collision and
## works anywhere on the planet, not just near the north pole.

var _snap_button: Button


func _enter_tree() -> void:
	_snap_button = Button.new()
	_snap_button.text = "Snap to planet surface"
	_snap_button.flat = true
	_snap_button.focus_mode = Control.FOCUS_NONE
	_snap_button.tooltip_text = "Snap selected object(s) onto the planet " \
		+ "surface below them (Ctrl+Shift+G)"
	_snap_button.pressed.connect(_snap_selection)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _snap_button)


func _exit_tree() -> void:
	if _snap_button:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _snap_button)
		_snap_button.queue_free()
		_snap_button = null


## Ctrl+Shift+G triggers the same snap as the toolbar button.
func _shortcut_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_G \
			and event.ctrl_pressed and event.shift_pressed:
		_snap_selection()
		get_viewport().set_input_as_handled()


func _snap_selection() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var planet := _find_planet_terrain(scene_root)
	if planet == null:
		push_warning("[PlanetTools] Snap to surface: no PlanetTerrain in the "
			+ "edited scene.")
		return

	# Gather selected Node3Ds, excluding the planet itself.
	var targets: Array[Node3D] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is Node3D and node != planet and not (node is PlanetTerrain):
			targets.append(node)
	if targets.is_empty():
		push_warning("[PlanetTools] Snap to surface: select one or more "
			+ "objects first.")
		return

	# Apply via UndoRedo so the snap is a single undoable action.
	var ur := get_undo_redo()
	ur.create_action("Snap to planet surface")
	var count := 0
	for n3 in targets:
		var old_t := n3.global_transform
		var new_t: Transform3D = planet.compute_surface_transform(n3)
		if new_t == old_t:
			continue  # at the planet centre, or already snapped — skip
		ur.add_do_property(n3, "global_transform", new_t)
		ur.add_undo_property(n3, "global_transform", old_t)
		count += 1
	ur.commit_action()
	print("[PlanetTools] Snapped %d object(s) to the planet surface." % count)


## Depth-first search for the first PlanetTerrain in the edited scene.
func _find_planet_terrain(node: Node) -> Node:
	if node is PlanetTerrain:
		return node
	for child in node.get_children():
		var found := _find_planet_terrain(child)
		if found:
			return found
	return null
