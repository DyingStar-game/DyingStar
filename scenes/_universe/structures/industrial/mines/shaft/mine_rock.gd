class_name MineRock
extends GenericProp
## A block of rock fallen from a village mine's face (Horizon type "mine_rock"): block [member index] of layer
## [member step] of gallery [member gallery], the rock that stood from [member from_m] to [member to_m] m along it. Only
## those numbers travel: every peer rebuilds the block's shape from its mine (MineSite.fragments_for, MineFracture),
## so it has exactly the cracks the face showed.
##
## Its body stands at the block's centroid, its mesh in the mine's frame under it (the walls' triplanar texture then
## lines up with the rock it came from). The server keeps it still until the new face is built round it, else it
## would start inside the old rock's collision and Jolt would fling it; then it drops out of the wall.
##
## Not minable yet: mineral_id and purity are kept for when it is.

const TYPE := "mine_rock"
const SCENE := "scenes/_universe/structures/industrial/mines/shaft/mine_rock.tscn"
## Speed (m/s) a block leaves the wall with, into the gallery, when it is released where it stood.
const RELEASE_SPEED_M_S := 0.6
## Lightest a block weighs (kg), whatever its volume.
const MIN_MASS_KG := 20.0
## Distance (m) past which a fallen block is not drawn: several hundred triangles each, and a mined gallery holds
## many of them.
const VISIBLE_M := 120.0

# Network fields (mine_rock_def.json).
var gallery: int = -1
var step: int = -1
var index: int = -1
var from_m: float = 0.0
var to_m: float = 0.0
var mineral_id: String = "gold"
var purity: float = 0.0
var host_rock_id: String = ""
var inert_density: float = RockMining.INERT_DENSITY_DEFAULT

var _shape_key := ""
var _shaped := false
var _released := false
var _block: Dictionary = {}


func _ready() -> void:
    super._ready()
    continuous_cd = false
    add_to_group("mine_rock")
    if GameOrchestrator.is_server():
        freeze = true  # until its shape is built and the rock round it too
    set_process(false)
    _request_shape()


func apply_prop_data(data: Dictionary) -> void:
    for field: String in ["gallery", "step", "index"]:
        if data.get(field) != null:
            set(field, int(data[field]))
    for field: String in ["from_m", "to_m", "purity", "inert_density"]:
        if data.get(field) != null:
            set(field, float(data[field]))
    for field: String in ["mineral_id", "host_rock_id"]:
        if data.get(field) != null:
            set(field, str(data[field]))
    if is_inside_tree():
        _request_shape()


## The mine this block fell in: the nearest MineSite above it.
func mine() -> MineSite:
    var node := get_parent()
    while node != null:
        if node is MineSite:
            return node
        node = node.get_parent()
    return null


func _request_shape() -> void:
    if _shaped or gallery < 0 or step < 0 or index < 0 or to_m <= from_m:
        return
    var site := mine()
    if site == null or site.layout().is_empty():
        set_process(true)  # the mine's plan is not known yet: ask again shortly
        return
    var gap := MineFracture.BODY_GAP_M if GameOrchestrator.is_server() else 0.0
    var key := MineFracture.key(gallery, step, from_m, to_m, gap)
    if key == _shape_key:
        return
    _shape_key = key
    site.fragments_for(gallery, step, from_m, to_m, gap, _on_blocks)


func _on_blocks(blocks: Array) -> void:
    if _shaped:
        return
    for block: Dictionary in blocks:
        if int(block.index) == index:
            if float(block.volume) <= 0.0:
                break
            _shape(block)
            return
    push_warning("[MineRock] %s: block %d of layer %d of gallery %d has no rock" % [uuid, index, step, gallery])


func _shape(block: Dictionary) -> void:
    _block = block
    _shaped = true
    var centroid: Vector3 = block.centroid
    var hull := ConvexPolygonShape3D.new()
    hull.points = MineFracture.hull_points(block)
    var collision := CollisionShape3D.new()
    collision.name = "Shape"
    collision.shape = hull
    add_child(collision)
    mass = maxf(float(block.volume) * inert_density, MIN_MASS_KG)
    var site := mine()
    if GameOrchestrator.is_server():
        set_process(true)  # released once the rock round it is built
        return
    var mesh := MineFracture.to_mesh(block, site.wall_material if site != null else null,
        site.crack_material if site != null else null)
    if mesh != null:
        var instance := MeshInstance3D.new()
        instance.name = "Mesh"
        instance.mesh = mesh
        instance.position = -centroid  # the block's vertices are in the mine's frame
        instance.visibility_range_end = VISIBLE_M  # a gallery fills with fallen layers
        add_child(instance)
    if site != null:
        site.rock_arrived(gallery, step, index)


func _process(_delta: float) -> void:
    if not _shaped:
        set_process(false)
        _request_shape()
        return
    if not GameOrchestrator.is_server() or _released:
        set_process(false)
        return
    var site := mine()
    if site == null:
        return
    var below := global_position - site.global_basis.y * maxf(float(_block.get("size", 1.0)), 1.0)
    if not site.rock_ready_at(global_position) or not site.rock_ready_at(below):
        return
    _released = true
    set_process(false)
    freeze = false
    # Still where it stood in the wall: it comes out of it, into the gallery. A rock already lying somewhere (a
    # restart) only wakes.
    var stood := site.global_transform * (_block.centroid as Vector3)
    if global_position.distance_to(stood) < 0.1:
        var out := site.global_basis * site.face_frame(gallery, from_m).basis.z
        linear_velocity = out.normalized() * RELEASE_SPEED_M_S
