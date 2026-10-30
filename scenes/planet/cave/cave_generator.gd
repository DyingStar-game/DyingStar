@tool
class_name CaveGenerator
## Entry point of cave geometry: validates a profile snapshot, then meshes its network (CaveNetwork).
## Coordinates are cave-local metres. The caller supplies the planetary placement.

## Version 9 adds chamber families, gallery erosion and light shafts; version 8 caves keep their exact
## geometry. Earlier versions are no longer supported.
const VERSION := 9
const SUPPORTED_VERSIONS := [8, 9]
const RING_SEGMENTS := 20


static func validation_error(spec: Dictionary) -> String:
    for key in ["length_m", "width_m", "height_m", "depth_m", "roughness", "bend", "chambers", "entrance_width_m",
            "entrance_height_m", "shaft_length_m", "chamber_width_m", "chamber_height_m", "exit_width_m", "exit_height_m"]:
        if not spec.has(key) or typeof(spec[key]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(spec[key])):
            return "Paramètre absent ou non fini : " + key
    if typeof(spec.get("seed")) != TYPE_INT or typeof(spec.get("version")) != TYPE_INT:
        return "La graine et la version doivent être des entiers."
    if int(spec.version) not in SUPPORTED_VERSIONS:
        return "Version de générateur non prise en charge (versions 8 et 9 seulement)."
    if spec.width_m < 2.0 or spec.width_m > 80.0 or spec.height_m < 2.0 or spec.height_m > 60.0:
        return "Dimensions du passage hors limites."
    if spec.get("entrance_type", "") not in ["ramp", "shaft", "hangar"]:
        return "Type d’entrée inconnu."
    if typeof(spec.get("exit_open")) != TYPE_BOOL:
        return "La présence d’une sortie doit être un booléen."
    if spec.entrance_width_m < 0.5 or spec.entrance_width_m > 100.0 or spec.entrance_height_m < 0.5 \
            or spec.entrance_height_m > 60.0 or spec.exit_width_m < 1.2 or spec.exit_width_m > 100.0 \
            or spec.exit_height_m < 2.0 or spec.exit_height_m > 60.0:
        return "Dimensions des bouches hors limites."
    if spec.chamber_width_m < spec.width_m or spec.chamber_width_m > 320.0 \
            or spec.chamber_height_m < spec.height_m or spec.chamber_height_m > 160.0:
        return "Dimensions des grandes salles hors limites."
    if spec.shaft_length_m < 6.0 or spec.shaft_length_m > 120.0:
        return "Longueur de la bouche de sortie hors limites."
    if spec.depth_m < 0.0 or spec.chambers != int(spec.chambers) or int(spec.chambers) < 1 or int(spec.chambers) > 12:
        return "Dimensions des salles invalides."
    if spec.roughness < 0.0 or spec.roughness > 1.0 or spec.bend < 0.0 or spec.bend > 1.0:
        return "Irrégularité et courbure doivent rester entre 0 et 1."
    if not _unit(spec.get("entrance_noise", 0.0)):
        return "Érosion de l’entrée : valeur entre 0 et 1."
    if int(spec.version) >= 9:
        if not _unit(spec.get("gallery_noise")):
            return "Érosion des galeries : valeur entre 0 et 1."
        if typeof(spec.get("light_shafts")) != TYPE_INT or int(spec.light_shafts) < 0 \
                or int(spec.light_shafts) > CaveLayoutV8.MAX_LIGHT_SHAFTS:
            return "Puits de lumière : entre 0 et %d." % CaveLayoutV8.MAX_LIGHT_SHAFTS
    return CaveLayoutV8.validation_error(spec)


static func _unit(value: Variant) -> bool:
    return typeof(value) in [TYPE_FLOAT, TYPE_INT] and is_finite(float(value)) and value >= 0.0 and value <= 1.0


## Pure, bounded generation. It is safe to call this method from a worker.
static func build(spec: Dictionary) -> Dictionary:
    var error := validation_error(spec)
    if not error.is_empty():
        return {"error": error}
    return CaveNetwork.build(spec)


## Inside the network's air (its density), with a small contact tolerance for capsule/wall contact.
static func contains(cave: Dictionary, point: Vector3, tolerance: float = 0.3) -> bool:
    return CaveNetwork.contains(cave, point, tolerance)


## Roof points of the network and its vestibule ring: what must stay under the relief.
static func cover_points(cave: Dictionary) -> PackedVector3Array:
    var points: PackedVector3Array = cave.get("cover_points", PackedVector3Array()).duplicate()
    for ring: PackedVector3Array in cave.rings:
        points.append_array(ring)
    return points


static func _empty_surface() -> Dictionary:
    return {"vertices": PackedVector3Array(), "normals": PackedVector3Array(), "uvs": PackedVector2Array()}


static func _quad(surface: Dictionary, a: Vector3, b: Vector3, c: Vector3, d: Vector3, inside: Vector3) -> void:
    _triangle(surface, a, b, c, inside)
    _triangle(surface, a, c, d, inside)


## Godot uses clockwise front faces. Both the normals and the collision face into the cavity.
static func _triangle(surface: Dictionary, a: Vector3, b: Vector3, c: Vector3, inside: Vector3) -> void:
    if (b - a).cross(c - a).length_squared() < 1.0e-16:
        return
    var normal := -(b - a).cross(c - a).normalized()
    if normal.dot(inside - (a + b + c) / 3.0) < 0.0:
        var swap := b
        b = c
        c = swap
        normal = -normal
    var vertices: PackedVector3Array = surface.vertices
    var normals: PackedVector3Array = surface.normals
    var uvs: PackedVector2Array = surface.uvs
    for point in [a, b, c]:
        vertices.append(point)
        normals.append(normal)
        uvs.append(Vector2(point.x + point.y, point.z) * 0.25)
    surface.vertices = vertices
    surface.normals = normals
    surface.uvs = uvs
