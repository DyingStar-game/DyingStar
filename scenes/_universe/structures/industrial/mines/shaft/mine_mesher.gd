class_name MineMesher
extends RefCounted
## A village mine's rock, cell by cell, through the caves' native mesher (CaveNetworkMesher.BuildRegion): the same
## rough walls as a StarGrotte network, from the volumes MineLayout.graph lists.

const MESHER_PATH := "res://scenes/planet/cave/CaveNetworkMesher.cs"
## Depth (m) under the collar down to which the shaft is still in the open air: the sun and the sky light it fully.
const SKY_OPEN_M := 3.0
## Depth (m) over which the daylight then fades out: from SKY_OPEN_M + SKY_FADE_M down, only lamps and torches light.
const SKY_FADE_M := 15.0

static var _script: Script


## Loads the native mesher once; false when the C# assembly is missing or stale (no mine is meshed then).
static func warm() -> bool:
    if _script == null:
        _script = NativeScript.load_usable(MESHER_PATH, ["Configure", "BuildRegion", "BuildFragments"])
    return _script != null


## A mesher configured with [param graph] (MineLayout.graph). Read only afterwards: cells of it may be built on
## several workers at once. A new graph needs a new mesher.
static func configure(graph: Dictionary) -> RefCounted:
    if not warm():
        return null
    var mesher: RefCounted = _script.new()
    mesher.call("Configure", graph)
    return mesher


## The surfaces of cell [param cell] ([param size] m cubes, lattice [param step] m), the ground (y > 0) cut away:
## {wall, wall_normals, floor, floor_normals} triangle soups in the mine frame. Any thread.
static func build_cell(mesher: RefCounted, cell: Vector3i, size: float, step: float) -> Dictionary:
    return mesher.call("BuildRegion", AABB(Vector3(cell) * size, Vector3.ONE * size), step, 0.0)


## Share of open sky (1 in the open air .. 0 underground) at [param depth_m] under the collar: what the cave rock's
## shader lets in of the sun and the sky (cave_corundum_rock.gdshader, open_air_source 1), and what MineSite.underground_at
## takes off the player's sun and sky.
static func open_sky(depth_m: float) -> float:
    return 1.0 - smoothstep(SKY_OPEN_M, SKY_OPEN_M + SKY_FADE_M, depth_m)


## The visible mesh of a built cell, or null when it holds no surface: wall then floor surface. Each vertex's colour
## carries its share of open sky in red ([method open_sky]; the collar is at y = 0 in the mine frame).
static func to_mesh(built: Dictionary, wall_material: Material, floor_material: Material) -> ArrayMesh:
    var mesh := ArrayMesh.new()
    for part: Array in [["wall", wall_material], ["floor", floor_material]]:
        var vertices: PackedVector3Array = built.get(part[0], PackedVector3Array())
        if vertices.is_empty():
            continue
        var arrays := []
        arrays.resize(Mesh.ARRAY_MAX)
        arrays[Mesh.ARRAY_VERTEX] = vertices
        arrays[Mesh.ARRAY_NORMAL] = built.get(part[0] + "_normals", PackedVector3Array())
        var colours := PackedColorArray()
        colours.resize(vertices.size())
        for index in vertices.size():
            var sky := open_sky(-vertices[index].y)
            colours[index] = Color(sky, sky, sky, 1.0)
        arrays[Mesh.ARRAY_COLOR] = colours
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        if part[1] != null:
            mesh.surface_set_material(mesh.get_surface_count() - 1, part[1])
    return mesh if mesh.get_surface_count() > 0 else null


## The collision triangles of a built cell (wall and floor).
static func faces(built: Dictionary) -> PackedVector3Array:
    var out: PackedVector3Array = built.get("wall", PackedVector3Array()).duplicate()
    out.append_array(built.get("floor", PackedVector3Array()))
    return out
