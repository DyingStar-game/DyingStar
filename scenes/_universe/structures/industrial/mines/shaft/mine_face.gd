class_name MineFace
extends StaticBody3D
## The working face at the end of a mine gallery: what the mining tool aims at (group "mineface", prop layer)
## and where its fault shows. A layer falls when a player holds the tool on the fault for
## MineSite.face_seconds; the gallery then moves on and a new fault shows on the new face.
##
## The fault is a plane through the gallery's axis, tilted at a seeded angle (MineSite.fault_of): it meets the
## face along a line, wherever the rough rock stands, so a decal projected along the gallery draws it exactly
## and a hit is judged by its distance to the plane alone.
##
## Its frame (set by MineSite): origin on the floor at the gallery's dug end, -Z along the gallery, +Y up.

## Name of the group the mining tool looks for.
const GROUP := "mineface"
## The shell standing for the rock of the face is this far (m) behind the smooth dome the mesher starts from:
## the rough rock stands in front of it, so the player meets the rock and the tool's ray the shell.
const SHELL_BEHIND_M := 0.3

var mine: MineSite = null
var gallery: int = -1
var step: int = 0
## Half width and height (m) of the gallery.
var half_width := 3.0
var height := 4.5
## The fault in the face frame: a unit normal in the XY plane and the plane's offset along it.
var fault_normal := Vector2.UP
var fault_offset := 0.0
## How close (m) to the fault a hit counts.
var tolerance_m := 0.15

var _decal: Decal = null
static var _crack_texture: ImageTexture = null


func _init() -> void:
    add_to_group(GROUP)


func _ready() -> void:
    collision_layer = 1 << (Globals.LAYER_PROP - 1)
    collision_mask = 0


## Build the shell and the decal (client) for the current gallery end and fault.
func build(client: bool) -> void:
    for child in get_children():
        child.queue_free()
    _decal = null
    if not client:
        return
    var shape := ConcavePolygonShape3D.new()
    shape.backface_collision = true
    shape.set_faces(_shell())
    var collision := CollisionShape3D.new()
    collision.shape = shape
    add_child(collision)
    _decal = Decal.new()
    _decal.texture_albedo = _crack()
    _decal.modulate = Color(0.05, 0.04, 0.03)
    _decal.albedo_mix = 1.0
    _decal.cull_mask = 0xFFFFF
    var span := maxf(half_width, height) * 2.4
    # Deep enough for the whole dome of the face and its relief; the walls along the gallery are left out by
    # normal_fade (they face across the projection).
    _decal.size = Vector3(span, half_width + 1.6, span)
    _decal.normal_fade = 0.5
    _decal.distance_fade_enabled = true
    _decal.distance_fade_begin = 40.0
    _decal.distance_fade_length = 10.0
    # The decal projects along its -Y: here along the gallery, into the face. Its X runs along the crack line,
    # so its Z (X × Y) is the fault's normal and the crack drawn across the texture lies on the fault plane.
    var along := Vector3(-fault_normal.y, fault_normal.x, 0.0)
    _decal.transform = Transform3D(Basis(along, Vector3.BACK, along.cross(Vector3.BACK)),
        _fault_center() + Vector3.FORWARD * half_width * 0.5)
    add_child(_decal)


## The point of the face frame the fault line passes closest to the gallery's centre.
func _fault_center() -> Vector3:
    var center := Vector2(0.0, height * 0.45)
    var on_plane := center + fault_normal * (fault_offset - center.dot(fault_normal))
    return Vector3(on_plane.x, on_plane.y, 0.0)


## Is [param local] (this face's frame) on the fault?
func is_on_fault_local(local: Vector3) -> bool:
    return absf(Vector2(local.x, local.y).dot(fault_normal) - fault_offset) <= tolerance_m


## Mining tool contract: is the world point [param hit] on the fault?
func is_on_fault_world(hit: Vector3) -> bool:
    return is_on_fault_local(to_local(hit))


## Mining tool contract: how long (s) the tool must be held on the fault.
func perforation_duration() -> float:
    return mine.face_seconds if mine != null else 20.0


## Mining tool contract: how far from its origin the face reaches, for the aim range.
func aim_radius() -> float:
    return maxf(half_width, height)


## Mining tool contract: the action that breaks this face, aimed at [param hit] (world).
func perforate_request(hit: Vector3) -> Dictionary:
    var frame := Transform3D.IDENTITY
    if mine != null:
        frame = mine.global_transform if mine.is_inside_tree() else mine.transform
    var at := frame.affine_inverse() * hit
    return {"action": "perforate_mine_face", "uuid": mine.uuid if mine != null else "", "gallery": gallery, "step": step,
        "hit": {"x": at.x, "y": at.y, "z": at.z}}


## The rock of the face as a shell: the quarter ellipsoid the gallery's rounded end makes, a little behind it.
func _shell() -> PackedVector3Array:
    var a := half_width + SHELL_BEHIND_M
    var h := height + SHELL_BEHIND_M
    var rings := 6
    var sides := 12
    var points: Array[PackedVector3Array] = []
    for ring in rings + 1:
        var phi := PI * 0.5 * ring / rings  # 0 = the rim, PI/2 = the tip
        var row := PackedVector3Array()
        for side in sides + 1:
            var theta := PI * side / sides  # 0 = right floor, PI/2 = top, PI = left floor
            row.append(Vector3(a * cos(theta) * cos(phi), h * sin(theta) * cos(phi), -a * sin(phi)))
        points.append(row)
    var faces := PackedVector3Array()
    for ring in rings:
        for side in sides:
            var p00 := points[ring][side]
            var p01 := points[ring][side + 1]
            var p10 := points[ring + 1][side]
            var p11 := points[ring + 1][side + 1]
            faces.append_array(PackedVector3Array([p00, p10, p11, p00, p11, p01]))
    return faces


## A dark jagged crack across the middle of a transparent square, made once.
static func _crack() -> ImageTexture:
    if _crack_texture != null:
        return _crack_texture
    var size := 256
    var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
    image.fill(Color(0, 0, 0, 0))
    var rng := RandomNumberGenerator.new()
    rng.seed = 7151
    var y := float(size) * 0.5
    for x in size:
        y = clampf(y + rng.randf_range(-1.6, 1.6), size * 0.5 - 6.0, size * 0.5 + 6.0)
        var width := 1.5 + 1.5 * absf(sin(x * 0.07)) + rng.randf_range(0.0, 1.0)
        for dy in range(int(-width - 3.0), int(width + 4.0)):
            var py := int(y) + dy
            if py < 0 or py >= size:
                continue
            var dist := absf(float(dy))
            var alpha := clampf(1.0 - (dist - width) / 3.0, 0.0, 1.0)
            var old := image.get_pixel(x, py)
            image.set_pixel(x, py, Color(0, 0, 0, maxf(old.a, alpha)))
    _crack_texture = ImageTexture.create_from_image(image)
    return _crack_texture
