extends EditorNode3DGizmoPlugin


func _init():
	create_material("lines", Color(0.2, 0.7, 1.0))
	create_handle_material("handles")


# Pour fonctionner seulement sur VehicleLift
func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is VehicleLift


func _get_gizmo_name() -> String:
	return "VehicleLift"


func _redraw(gizmo: EditorNode3DGizmo):
	gizmo.clear()
	var node = gizmo.get_node_3d() as VehicleLift
	
	var offset_pos = Vector3(0, 0, node.guide_z_offset)
	var bottom_pos = Vector3(0, -node.descent_depth, node.guide_z_offset)
	
	# Lignes
	var lines = PackedVector3Array([
		Vector3.ZERO, offset_pos, # Horizontale (+Z local)
		offset_pos, bottom_pos	  # Verticale (-Y local)
	])
	gizmo.add_lines(lines, get_material("lines", gizmo))
	
	# Poignées
	var handles = PackedVector3Array([offset_pos, bottom_pos])
	gizmo.add_handles(handles, get_material("handles", gizmo), [])


func _get_handle_name(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> String:
	return "Décalage Falaise (Z)" if handle_id == 0 else "Profondeur Descente (-Y)"


func _get_handle_value(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool) -> Variant:
	var node = gizmo.get_node_3d() as VehicleLift
	return node.guide_z_offset if handle_id == 0 else node.descent_depth


# Bouger poignée
func _set_handle(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool, camera: Camera3D, screen_pos: Vector2):
	var node = gizmo.get_node_3d() as VehicleLift
	
	var ray_from = camera.project_ray_origin(screen_pos)
	var ray_dir = camera.project_ray_normal(screen_pos)
	var ray_to = ray_from + ray_dir * 4096.0
	
	if handle_id == 0:
		var axis_from = node.global_position
		var axis_to = node.to_global(Vector3(0, 0, 1000.0))
		
		var points = Geometry3D.get_closest_points_between_segments(ray_from, ray_to, axis_from, axis_to)
		var local_point = node.to_local(points[1])
		var limits = _get_property_range(node, "guide_z_offset")
		node.guide_z_offset = clamp(local_point.z, limits.x, limits.y)
		
	elif handle_id == 1:
		var axis_from = node.to_global(Vector3(0, 0, node.guide_z_offset))
		var axis_to = node.to_global(Vector3(0, -1000.0, node.guide_z_offset))
		
		var points = Geometry3D.get_closest_points_between_segments(ray_from, ray_to, axis_from, axis_to)
		var local_point = node.to_local(points[1])
		var limits = _get_property_range(node, "descent_depth")
		node.descent_depth = clamp(-local_point.y, limits.x, limits.y)


# Undo / Redo à la fin du bougeage de poignée
func _commit_handle(gizmo: EditorNode3DGizmo, handle_id: int, secondary: bool, restore: Variant, cancel: bool):
	var node = gizmo.get_node_3d() as VehicleLift
	var ur = EditorInterface.get_editor_undo_redo()
	
	if handle_id == 0:
		if cancel:
			node.guide_z_offset = restore
		else:
			ur.create_action("Modifier Décalage Z")
			ur.add_do_property(node, "guide_z_offset", node.guide_z_offset)
			ur.add_undo_property(node, "guide_z_offset", restore)
			ur.commit_action(false)
		
	elif handle_id == 1:
		if cancel:
			node.descent_depth = restore
		else:
			ur.create_action("Modifier Profondeur Descente")
			ur.add_do_property(node, "descent_depth", node.descent_depth)
			ur.add_undo_property(node, "descent_depth", restore)
			ur.commit_action(false)


func _get_property_range(node: Object, property_name: String) -> Vector2:
	for p in node.get_property_list():
		if p.name == property_name:
			var parts = p.hint_string.split(",")
			if parts.size() >= 2:
				return Vector2(float(parts[0]), float(parts[1]))
	return Vector2(-INF, INF) # Valeur de secours
