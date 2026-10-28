class_name CaveSurfacePicker
extends Node3D
## Tool-only cursor. Picks actual resident terrain collision, never an imagined sphere.
## The caller owns publication, fitting and the single placement validation path.

signal accepted(point: Vector3, heading: float)
signal cancelled

var active: bool = false
var heading: float = 0.0
var valid: bool = false
var _point := Vector3.ZERO
var _marker: MeshInstance3D
var _outline := PackedVector2Array()
var _next_update: int = 0


func _ready() -> void:
    _marker = MeshInstance3D.new()
    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.albedo_color = CaveWorkbenchTheme.ACCENT
    material.no_depth_test = true
    _marker.material_override = material
    add_child(_marker)
    _marker.hide()


func begin(profile: CaveProfile, cave_seed: int, orientation: float) -> void:
    heading = orientation
    # The click is the mouth itself: a porch's sill line (it then turns uphill), or a doline's rim.
    _outline = CavePortal.oculus(profile.snapshot(cave_seed)) if profile.entrance_type == "shaft" else PackedVector2Array(
        [Vector2(-profile.entrance_width_m * 0.5, 0.0), Vector2(profile.entrance_width_m * 0.5, 0.0)])
    active = true
    valid = false
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func stop() -> void:
    active = false
    valid = false
    _marker.hide()


func update_cursor(camera: Camera3D, planet: Node3D, terrain: Node3D, screen_point: Vector2 = Vector2.INF) -> void:
    if not active:
        return
    if Time.get_ticks_msec() < _next_update:
        return
    _next_update = Time.get_ticks_msec() + 50
    var mouse := camera.get_viewport().get_mouse_position() if screen_point == Vector2.INF else screen_point
    var origin := camera.project_ray_origin(mouse)
    var query := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(mouse) * 6000.0)
    var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
    valid = not hit.is_empty() and is_terrain_hit(hit.collider, terrain)
    _marker.visible = valid
    if not valid:
        return
    _point = planet.to_local(hit.position)
    var placement := CavePlacement.new()
    placement.format_version = 2
    var lonlat := coordinates(_point)
    placement.longitude_deg = lonlat.x
    placement.latitude_deg = lonlat.y
    placement.planet_radius_m = _point.length()
    placement.heading_deg = heading
    var frame := planet.global_transform * placement.surface_transform()
    var mesh := ImmediateMesh.new()
    mesh.surface_begin(Mesh.PRIMITIVE_LINES)
    for index in _outline.size():
        for point in [_outline[index], _outline[(index + 1) % _outline.size()]]:
            # Follow the actual terrain so a sloping surface cannot hide the cursor.
            var sample: Vector3 = frame * Vector3(point.x, 0, point.y)
            var up := (sample - planet.global_position).normalized()
            var probe := PhysicsRayQueryParameters3D.create(sample + up * 100, sample - up * 100)
            var surface := camera.get_world_3d().direct_space_state.intersect_ray(probe)
            var at: Vector3 = surface.position + up * 0.15 if not surface.is_empty() else sample
            mesh.surface_add_vertex(to_local(at))
    mesh.surface_add_vertex(to_local(frame * Vector3(0, 0.2, 0)))
    mesh.surface_add_vertex(to_local(frame * Vector3(0, 0.2, 12)))
    mesh.surface_end()
    _marker.mesh = mesh


func show_placed() -> void:
    _marker.show()


func handle_input(event: InputEvent) -> bool:
    if not active:
        return false
    if event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
        stop()
        cancelled.emit()
    elif event is InputEventMouseButton and event.pressed:
        match event.button_index:
            MOUSE_BUTTON_RIGHT:
                stop()
                cancelled.emit()
            MOUSE_BUTTON_WHEEL_UP:
                heading = wrapf(heading + 5.0, -180, 180)
            MOUSE_BUTTON_WHEEL_DOWN:
                heading = wrapf(heading - 5.0, -180, 180)
            MOUSE_BUTTON_LEFT:
                if valid:
                    var point := _point
                    var orientation := heading
                    stop()
                    accepted.emit(point, orientation)
    return true  # Never capture the mouse or move the avatar while placing.


static func coordinates(point: Vector3) -> Vector2:
    var direction := point.normalized()
    return Vector2(rad_to_deg(atan2(-direction.z, direction.x)), rad_to_deg(asin(clampf(direction.y, -1, 1))))


static func is_terrain_hit(collider: Object, terrain: Node) -> bool:
    # Native chunk bodies are direct children. Cave walls and props are descendants elsewhere.
    return collider is StaticBody3D and collider.get_parent() == terrain
