@tool
class_name CavePreviewBuilder
## Main-thread assembly shared by the workbench and exported preview scenes.
## Planetary registration and server residency remain outside this preview builder.

const GlobalsDefs := preload("res://scenes/globals/globals.gd")


static func instantiate(data: Dictionary, library: CaveAssetLibrary, visual: bool = true, physics: bool = true,
        texture_origin: Vector3 = Vector3.ZERO) -> Node3D:
    var root := Node3D.new()
    root.name = "CavePreview"
    root.set_meta("cave_spec", data.spec)
    root.set_meta("asset_library", library.resource_path if library else "")
    if visual:
        var mesh := ArrayMesh.new()
        for key in ["wall", "floor"]:
            var surface: Dictionary = data[key]
            if surface.vertices.is_empty():
                continue
            var arrays: Array = []
            arrays.resize(Mesh.ARRAY_MAX)
            var vertices: PackedVector3Array = surface.vertices
            if texture_origin != Vector3.ZERO:
                vertices = vertices.duplicate()
                for index in vertices.size():
                    vertices[index] += texture_origin
            arrays[Mesh.ARRAY_VERTEX] = vertices
            arrays[Mesh.ARRAY_NORMAL] = surface.normals
            arrays[Mesh.ARRAY_TEX_UV] = surface.uvs
            if surface.has("colors"):
                arrays[Mesh.ARRAY_COLOR] = surface.colors  # entrances: ground cover (CaveGroundCover)
            mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
            var material: Material = null
            if library:
                material = library.wall_material if key == "wall" else library.floor_material
            mesh.surface_set_material(mesh.get_surface_count() - 1, material)
        var instance := MeshInstance3D.new()
        instance.name = "CaveSurface"
        instance.mesh = mesh
        # Triplanar textures share the site's coordinates with the entrance, while geometry and physics stay put.
        instance.position = -texture_origin
        root.add_child(instance)
    if physics:
        var body := StaticBody3D.new()
        body.name = "CaveCollision"
        body.collision_layer = GlobalsDefs.LAYER_WORLD
        body.collision_mask = 0
        var shape := ConcavePolygonShape3D.new()
        shape.set_faces(data.faces)
        var collision := CollisionShape3D.new()
        collision.shape = shape
        body.add_child(collision)
        root.add_child(body)
    if library and (visual or physics):
        _add_decorations(root, data, library, visual, physics)
    return root


static func _add_decorations(root: Node3D, data: Dictionary, library: CaveAssetLibrary,
        visual: bool, physics: bool) -> void:
    var request := decoration_request(library)
    var plan: Dictionary = data.get("decoration_plan", {})
    if plan.get("signature", "") != request.signature:
        plan = prepare_decorations(data, request)
    for rule in library.decoration_rules():
        if rule == null or rule.mesh == null:
            continue
        var placements: Array = plan.groups.get(rule.rule_name, [])
        if placements.is_empty():
            continue
        if visual:
            var multimesh := MultiMesh.new()
            multimesh.transform_format = MultiMesh.TRANSFORM_3D
            multimesh.mesh = rule.mesh
            multimesh.instance_count = placements.size()
            for index in placements.size():
                multimesh.set_instance_transform(index, placements[index])
            var instance := MultiMeshInstance3D.new()
            instance.name = "Decor_" + rule.rule_name.validate_node_name()
            instance.multimesh = multimesh
            instance.material_override = rule.material
            root.add_child(instance)
        if physics and rule.collision_shape:
            var body := StaticBody3D.new()
            body.name = "DecorCollision_" + rule.rule_name.validate_node_name()
            body.collision_layer = GlobalsDefs.LAYER_WORLD
            body.collision_mask = 0
            for transform in placements:
                var shape := CollisionShape3D.new()
                shape.shape = rule.collision_shape
                shape.transform = transform
                body.add_child(shape)
            root.add_child(body)


## Snapshot mesh bounds on the main thread; geometry workers receive plain immutable values only.
static func decoration_request(library: CaveAssetLibrary) -> Dictionary:
    var rules: Array[Dictionary] = []
    if library:
        for rule in library.decoration_rules():
            if rule and rule.mesh:
                rules.append(_rule_snapshot(rule))
    var request := {"budget": library.instance_budget if library else 0, "rules": rules}
    request["signature"] = str([library.library_id if library else "", request]).sha256_text()
    return request


static func _rule_snapshot(rule: CaveDecorationRule) -> Dictionary:
    var result := {"bounds": rule.mesh.get_aabb()}
    for property in ["rule_name", "scale_min", "scale_max", "spacing_m", "radius_m", "max_instances",
            "support", "zone", "distribution", "max_slope_deg", "align_to_surface"]:
        result[property] = rule.get(property)
    return result


## Pure CPU preparation, shared by authoring and the native resident cave task.
static func prepare_decorations(data: Dictionary, request: Dictionary) -> Dictionary:
    var remaining: int = request.budget
    var applicable: Array = request.rules.filter(func(rule: Dictionary):
        return not rule.support.begins_with("entrance_") or not data.get("rock_supports", {}).get(rule.support, []).is_empty())
    if data.has("rock_supports") and request.rules.any(func(rule: Dictionary): return rule.support.begins_with("entrance_")):
        applicable = applicable.filter(func(rule: Dictionary): return rule.support.begins_with("entrance_"))
        # Seeded order prevents the first rock family always occupying the best supports.
        var rng := RandomNumberGenerator.new()
        rng.seed = int(data.spec.seed) + 8345
        for index in range(applicable.size() - 1, 0, -1):
            var other := rng.randi_range(0, index)
            var saved: Dictionary = applicable[index]
            applicable[index] = applicable[other]
            applicable[other] = saved
    var rules_left: int = applicable.size()
    var occupied: Array[AABB] = []
    var groups := {}
    for rule: Dictionary in applicable:
        var share := int(ceil(float(remaining) / maxi(rules_left, 1)))
        rules_left -= 1
        var placements := _decoration_transforms(data, rule, share)
        var separated: Array[Transform3D] = []
        for transform in placements:
            var box: AABB = (transform * (rule.bounds as AABB)).grow(0.08)
            var overlaps := false
            for other in occupied:
                if box.intersects(other):
                    overlaps = true
                    break
            if not overlaps:
                separated.append(transform)
                occupied.append(box)
        remaining -= separated.size()
        groups[rule.rule_name] = separated
    return {"signature": request.signature, "groups": groups}


## Reproducible placements shared by visual instances and optional server colliders.
static func decoration_transforms(data: Dictionary, rule: CaveDecorationRule, budget: int = 500) -> Array[Transform3D]:
    if rule.mesh == null:
        return []
    return _decoration_transforms(data, _rule_snapshot(rule), budget)


static func _decoration_transforms(data: Dictionary, rule: Dictionary, budget: int) -> Array[Transform3D]:
    var transforms: Array[Transform3D] = []
    if budget <= 0:
        return transforms
    var rng := RandomNumberGenerator.new()
    # Explicit string digest, not a process-dependent object/resource identifier.
    var digest := (str(data.spec.seed) + ":" + str(rule.rule_name)).sha256_text()
    rng.seed = digest.substr(0, 12).hex_to_int()
    if rule.support in ["entrance_ground", "entrance_wall"]:
        return CaveEntranceRocks.scatter(data, rule, rng, budget)
    if rule.distribution != "legacy":
        if data.has("graph"):
            return CaveDecorationScatter.network(data, rule, rng, budget)
        if data.has("decor_sections"):
            return CaveDecorationScatter.porch(data, rule, rng, budget)
    # Older libraries ("legacy" rules): a ring of placements around each chamber.
    if data.has("graph"):
        transforms.append_array(_network_decorations(data, rule, rng, mini(rule.max_instances, budget)))
    return transforms


static func _network_decorations(data: Dictionary, rule: Dictionary,
        rng: RandomNumberGenerator, budget: int) -> Array[Transform3D]:
    var result: Array[Transform3D] = []
    for room: Dictionary in data.graph.rooms:
        var station := {"center": room.a, "chamber": 1.0}
        if not zone_matches(data.spec, station, rule.zone):
            continue
        var count := maxi(4, int(TAU * float(room.size.x) * 0.6 / maxf(1, rule.spacing_m)))
        var phase := rng.randf_range(0, TAU)
        for index in count:
            if result.size() >= budget:
                return result
            var angle := phase + TAU * (float(index) + rng.randf_range(-0.15, 0.15)) / count
            var point: Vector3 = room.a + Vector3(cos(angle) * room.size.x * 0.6, 0, sin(angle) * room.size.z * 0.6)
            var scale := rng.randf_range(rule.scale_min, rule.scale_max)
            var basis := Basis(Vector3.UP, rng.randf_range(0, TAU)).scaled(Vector3.ONE * scale)
            if rule.support == "ceiling":
                basis = Basis(Vector3.RIGHT, PI) * basis
            var box := Transform3D(basis, Vector3.ZERO) * (rule.bounds as AABB)
            var radius := maxf(box.size.x, box.size.z) * 0.5
            if _near_network_path(data.graph.links, point, radius + 1.0):
                continue
            var support := _network_surface(data.sampler, room, point, rule.support == "ceiling")
            if not is_finite(support):
                continue  # no support in this room (pit, open chimney, or structural pillar)
            point.y = support - (box.end.y if rule.support == "ceiling" else box.position.y)
            var fits := true
            for corner in 8:
                var p := point + box.get_endpoint(corner)
                # Contact with the floor/ceiling is allowed; protruding through a pillar/wall is not.
                p.y += 0.15 if rule.support != "ceiling" else -0.2
                if float(data.sampler.call("Sample", p)) < -0.2:
                    fits = false
                    break
            if fits:
                result.append(Transform3D(basis, point))
    return result


## Find the actual density boundary instead of assuming v8's tilted, eroded floor is at room.a.y.
## Search stays within this room's authored vertical envelope; a deeper level is not a support.
static func _network_surface(sampler: RefCounted, room: Dictionary, point: Vector3, ceiling: bool) -> float:
    return CaveDecorationScatter.surface(sampler, room, point, ceiling)


static func _near_network_path(links: Array, point: Vector3, clearance: float) -> bool:
    return CaveDecorationScatter.near_path(links, point, clearance)


static func zone_matches(spec: Dictionary, station: Dictionary, zone: String) -> bool:
    var t := (station.center as Vector3).z / float(spec.length_m)
    var mouth := t <= 0.15 or (bool(spec.get("exit_open", false)) and t >= 0.85)
    match zone:
        "entrance": return mouth
        "chamber": return not mouth and float(station.get("chamber", 0.0)) >= 0.45
        "deep": return not mouth and t >= 0.55
        _: return true


static func set_scene_owners(root: Node, node: Node) -> void:
    for child in node.get_children():
        child.owner = root
        set_scene_owners(root, child)
