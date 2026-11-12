class_name MineRock
extends RockMining
## A block of rock fallen from a village mine's face: a mining rock (Horizon type "miningrock", RockMining) whose
## shape is the block's, not a scene mesh. It is mined like any rock: a fault, the drill, a cut, until its pieces can
## be carried.
##
## Only [member mine_block] travels (MineFracture.layer_ref plus the block's index): every peer rebuilds the block
## from it (MineFracture.blocks_for), the mine near or not, so it has exactly the cracks the face showed, and so do
## its pieces (they inherit it, see _split_data, and carve it with their cut history).
##
## Everything RockMining does waits for that shape (its _ready and the replicated data it is handed): it measures,
## carves and paints the source mesh. The body stands at the block's centroid. The server keeps a block still where it
## stood in the wall until the new face is built round it (else it starts inside the old rock and Jolt flings it),
## then it drops, passing through the players near it on the way (see SPARE_PLAYERS_M).

const TYPE := "miningrock"
const SCENE := "scenes/_universe/structures/industrial/mines/shaft/mine_rock.tscn"
## Speed (m/s) a block leaves the wall with, into the gallery, when it is released where it stood.
const RELEASE_SPEED_M_S := 0.6
## A block falls through the players this close (m, past its own size) when it leaves the wall: dropped on the
## driller, a block of rock pushed them through the gallery's floor. It meets them again once it lies still away
## from them.
const SPARE_PLAYERS_M := 2.5
## Longest (s) a falling block passes through the players.
const SPARE_MAX_S := 6.0
## Distance (m) past which a block is not drawn: several hundred triangles each, and a mined gallery holds many.
const VISIBLE_M := 120.0

## The block this rock is made of: MineFracture.layer_ref of its layer, plus "index".
var mine_block: Dictionary = {}

var _shaped := false
var _failed := false
## Replicated data handed over before the shape was known, applied once it is.
var _pending: Dictionary = {}
var _block: Dictionary = {}
var _holding := false
## Server: the players a falling block passes through, and since when (s).
var _spared: Array[Node] = []
var _spared_since := 0.0


func _ready() -> void:
    if Engine.is_editor_hint():
        return
    set_process(true)
    _try_shape()


func apply_prop_data(data: Dictionary) -> void:
    if data.get("mine_block") is Dictionary and (mine_block.is_empty() or not _shaped):
        mine_block = (data.mine_block as Dictionary).duplicate(true)
    if not _shaped:
        _pending.merge(data, true)
        if is_inside_tree():
            _try_shape()
        return
    super.apply_prop_data(data)


## Carry contract: a block not shaped yet has no size to judge, so it cannot be picked up.
func interact(interactor: Node = null) -> bool:
    return _shaped and super.interact(interactor)


## The mine this block came from, when it is live here.
func mine() -> MineSite:
    return MineSite.find(str(mine_block.get("mine", "")))


func _split_data() -> Dictionary:
    return {"mine_block": mine_block}


## The block, once known: the rock's source mesh, then RockMining starts as on any rock.
func _try_shape() -> bool:
    if _shaped or _failed or mine_block.is_empty() or not is_inside_tree():
        return _shaped
    var gap := MineFracture.BODY_GAP_M if GameOrchestrator.is_server() else 0.0
    var blocks: Variant = MineFracture.blocks_for(mine_block, gap)
    if blocks == null:
        return false
    var index := int(mine_block.get("index", -1))
    for block: Dictionary in blocks:
        if int(block.index) == index and float(block.volume) > 0.0:
            _install(block)
            return true
    _failed = true
    set_process(false)
    push_warning("[MineRock] %s: no block %d in layer %s" % [uuid, index, MineFracture.ref_key(mine_block, gap)])
    return false


func _install(block: Dictionary) -> void:
    _block = block
    _shaped = true
    var mesh_node := _mesh_node()
    var mesh := MineFracture.rock_mesh(block)
    if mesh_node is CSGMesh3D:
        (mesh_node as CSGMesh3D).mesh = mesh
    elif mesh_node is MeshInstance3D:
        (mesh_node as MeshInstance3D).mesh = mesh
    if mesh_node != null:
        mesh_node.visibility_range_end = VISIBLE_M
    var server: bool = GameOrchestrator.is_server()
    # Fresh from the wall: still until the rock round it is built (see _hold_release).
    var site := mine()
    if server and site != null and fractures.is_empty() and (_pending.get("fractures", []) as Array).is_empty():
        var stood := site.global_transform * (block.centroid as Vector3)
        _holding = global_position.distance_to(stood) < 0.1
    super._ready()
    if _holding:
        freeze = true
    if not _pending.is_empty():
        var data := _pending
        _pending = {}
        super.apply_prop_data(data)
    # super._ready judged the block before its mineral, host rock and density landed (just above): with
    # the default ones its mass was wrong, so a small block could keep a crack line it cannot use, or
    # miss the one it needs. Judge it again on its real data; a cut history is judged once carved.
    if server and not _apply_cuts_running and not _has_pending_cuts():
        check_rock()
    if not server and site != null:
        site.rock_arrived(int(mine_block.get("gallery", -1)), int(mine_block.get("step", -1)), int(block.index))
    set_process(server and _holding)


## Uncut, the block's hull is its own points (Mesh.create_convex_shape would run the engine's convex decomposition,
## 90 ms per rock, and every block is a shape of its own); once cut, RockMining hulls the carved result.
func _build_mesh_collider() -> void:
    if _has_pending_cuts() or _block.is_empty():
        super._build_mesh_collider()
        return
    var shape_node := get_node_or_null("CollisionShape3D") as CollisionShape3D
    if shape_node == null:
        return
    var hull := ConvexPolygonShape3D.new()
    hull.points = MineFracture.hull_points(_block)
    shape_node.shape = hull
    # The look-at area is the block itself. A sphere 0.6 x its longest side round each block overlapped
    # its neighbours, and the look ray (first area met) took the wrong one: the carry prompt showed only
    # from some sides (playtest 2026-11-11).
    var look := get_node_or_null("Area3D/CollisionShape3D") as CollisionShape3D
    if look != null:
        look.shape = hull
        look.transform = shape_node.transform


func _process(_delta: float) -> void:
    if not _shaped:
        _try_shape()
        return
    if not GameOrchestrator.is_server():
        set_process(false)
        return
    if _holding:
        _hold_release()
    elif not _spared.is_empty():
        _unspare_players()
    else:
        set_process(false)


## Server: let a block fresh from the wall go once the new face round it is built: out of the wall, into the gallery.
func _hold_release() -> void:
    var site := mine()
    if site == null:
        _holding = false
        freeze = false
        return
    var below := global_position - site.global_basis.y * maxf(float(_block.get("size", 1.0)), 1.0)
    if not site.rock_ready_at(global_position) or not site.rock_ready_at(below):
        return
    _holding = false
    _spare_players(float(_block.get("size", 1.0)))
    freeze = false
    var frame := MineSite.face_frame_in(site.layout(), int(mine_block.gallery), float(mine_block.from_m))
    linear_velocity = (site.global_basis * frame.basis.z).normalized() * RELEASE_SPEED_M_S


## Server: pass through the players within reach while falling (see SPARE_PLAYERS_M).
func _spare_players(size: float) -> void:
    for player in get_tree().get_nodes_in_group("player"):
        if player is PhysicsBody3D and (player as Node3D).global_position.distance_to(global_position) < size + SPARE_PLAYERS_M:
            add_collision_exception_with(player)
            (player as PhysicsBody3D).add_collision_exception_with(self)
            _spared.append(player)
    _spared_since = Time.get_ticks_msec() / 1000.0


## Server: meet the spared players again once lying still clear of them (or after SPARE_MAX_S).
func _unspare_players() -> void:
    var late := Time.get_ticks_msec() / 1000.0 - _spared_since > SPARE_MAX_S
    if not sleeping and not late:
        return
    var clear := float(_block.get("size", 1.0)) * 0.5 + 0.8
    for player: Node in _spared.duplicate():
        if is_instance_valid(player) and not late \
                and (player as Node3D).global_position.distance_to(global_position) < clear:
            continue
        if is_instance_valid(player):
            remove_collision_exception_with(player)
            (player as PhysicsBody3D).remove_collision_exception_with(self)
        _spared.erase(player)
