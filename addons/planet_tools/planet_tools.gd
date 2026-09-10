@tool
extends EditorPlugin
## Editor helpers for placing objects on a planet surface.
##
## Adds two things to the 3D viewport toolbar: a "Snap to surface" button (and a
## Ctrl+Shift+G shortcut). It moves the currently selected object(s) onto the
## planet terrain along their radial direction from the planet centre — the
## correct "down" on a sphere — using PlanetTerrain.compute_surface_transform.
## Unlike Godot's built-in "Snap Object to Floor", it needs no collision and
## works anywhere on the planet, not just near the north pole.
##
## And a "Fly in planet frame" toggle, shown only when the edited scene HAS a body: it flies the
## viewport as if it were over that body — local up always world up, forward following the curvature.
## See PlanetTerrain's editor-flight section for how, and why the body moves rather than the camera.

var _snap_button: Button
var _fly_button: Button


func _enter_tree() -> void:
	_snap_button = Button.new()
	_snap_button.text = "Snap to planet surface"
	_snap_button.flat = true
	_snap_button.focus_mode = Control.FOCUS_NONE
	_snap_button.tooltip_text = "Snap selected object(s) onto the planet " \
		+ "surface below them (Ctrl+Shift+G)"
	_snap_button.pressed.connect(_snap_selection)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _snap_button)

	_fly_button = Button.new()
	_fly_button.text = "Fly in planet frame"
	_fly_button.flat = true
	_fly_button.toggle_mode = true
	_fly_button.focus_mode = Control.FOCUS_NONE
	_fly_button.tooltip_text = "Fly the viewport over the body: up stays up and " \
		+ "forward follows the curvature. Middle-mouse pan strafes along the ground."
	_fly_button.toggled.connect(_set_flight)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _fly_button)

	# The toolbar is where this belongs rather than the inspector: flying is something you do WHILE
	# working on something else, and an inspector checkbox would mean selecting the terrain node —
	# and losing the toggle the moment you select the object you actually came to place.
	scene_changed.connect(_refresh_fly_button)
	_refresh_fly_button(null)


func _exit_tree() -> void:
	if _snap_button:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _snap_button)
		_snap_button.queue_free()
		_snap_button = null
	if _fly_button:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _fly_button)
		_fly_button.queue_free()
		_fly_button = null


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

## Show the flight toggle only when the edited scene actually has a body to fly over, and mirror what
## that scene already carries. The button is a VIEW of PlanetTerrain.editor_planet_flight, never a
## second source of truth — set_pressed_no_signal so reading the state cannot write it back.
func _refresh_fly_button(_scene_root) -> void:
	if _fly_button == null:
		return
	var terrain := _edited_planet_terrain()
	_fly_button.visible = terrain != null
	if terrain != null:
		_fly_button.set_pressed_no_signal(terrain.editor_planet_flight)


func _set_flight(on: bool) -> void:
	var terrain := _edited_planet_terrain()
	if terrain == null:
		return
	terrain.editor_planet_flight = on


## The body of the scene being edited, or null. Guards the empty-editor case, where there is no root.
func _edited_planet_terrain() -> PlanetTerrain:
	var root := EditorInterface.get_edited_scene_root()
	return null if root == null else _find_planet_terrain(root) as PlanetTerrain
