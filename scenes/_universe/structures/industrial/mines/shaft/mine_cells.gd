class_name MineCells
extends Node3D
## The rock of a village mine, streamed in cubic cells around the people near it: a cell is meshed on a worker
## (MineMesher), then turned into a mesh (client) or a collision body (server) on the main thread, one per frame.
## When a face moves on, only the cells it reshapes are built again; the old cell stays until the new one is ready,
## so the rock never opens for a frame.
##
## Positions are in the mine frame: this node sits at the mine's origin, unrotated relative to it.

const GlobalsDefs := preload("res://scenes/globals/globals.gd")
## Edge (m) of a cell.
const CELL_M := 32.0
## Workers building cells at once.
const MAX_TASKS := 2
## Seconds between two looks at who is near.
const VIEW_PERIOD_S := 0.25

## Distance (m) from a viewer within which the rock is built: the client draws it, the server collides with it.
var view_radius_m := 160.0
## Distance (m) past view_radius_m before a built cell is freed again.
var keep_margin_m := 48.0
## Lattice spacing (m) of the mesher.
var step_m := 1.0
## Materials of the walls and of the floors (client).
var wall_material: Material = null
var floor_material: Material = null
## Server: collision bodies instead of meshes.
var physics := false
## Returns the viewers' positions in the mine frame (Array[Vector3]).
var viewers := Callable()

var _mesher: RefCounted = null
var _version := 0
## Every cell the volumes may reach, and when each last changed (its version).
var _cells: Dictionary = {}
var _changed: Dictionary = {}
## Built cells: Vector3i -> {node, version}.
var _built: Dictionary = {}
## Running builds: Vector3i -> {id, result, version}.
var _tasks: Dictionary = {}
var _wanted: Dictionary = {}
var _next_view := 0.0
var _assembled_frame := -1
## The configuration running on a worker ({id, graph, changed, all, result}) and the next one waiting.
var _configuring: Dictionary = {}
var _queued: Dictionary = {}


## Mesh the rock of [param graph] (MineLayout.graph). [param changed] lists the cells whose rock differs from the
## previous graph; empty = all of them (a new mine). The mesher is configured on a worker (tens of ms for a deep
## mine); graphs given meanwhile are merged into the next configuration.
func set_graph(graph: Dictionary, changed: Dictionary = {}) -> void:
    if _queued.is_empty():
        _queued = {"graph": graph, "changed": changed.duplicate(), "all": changed.is_empty()}
    else:
        _queued.graph = graph
        _queued.all = bool(_queued.all) or changed.is_empty()
        (_queued.changed as Dictionary).merge(changed)
    _start_configure()


func _start_configure() -> void:
    if _configuring.has("id") or _queued.is_empty():
        return
    var job := _queued
    _queued = {}
    var result: Array = [null, {}]
    var graph: Dictionary = job.graph
    job.result = result
    job.id = WorkerThreadPool.add_task(func():
        result[0] = MineMesher.configure(graph)
        result[1] = MineLayout.cells(graph, CELL_M))
    _configuring = job


## A configuration done: its mesher replaces the previous one, its changed cells are built again.
func _finish_configure() -> void:
    if not _configuring.has("id") or not WorkerThreadPool.is_task_completed(_configuring.id):
        return
    WorkerThreadPool.wait_for_task_completion(_configuring.id)
    var job := _configuring
    _configuring = {}
    var mesher: RefCounted = job.result[0]
    if mesher == null:
        push_warning("[MineCells] mesher natif indisponible : la mine n'est pas maillée")
    else:
        _mesher = mesher
        _version += 1
        _cells = job.result[1]
        if bool(job.all):
            for cell: Vector3i in _built:
                _changed[cell] = _version
            for cell: Vector3i in _cells:
                _changed[cell] = _version
        else:
            for cell: Vector3i in job.changed:
                _changed[cell] = _version
        _next_view = 0.0
    _start_configure()


## How many cells are built, being built, and possible.
func stats() -> Dictionary:
    return {"built": _built.size(), "tasks": _tasks.size(), "cells": _cells.size()}


## Are the cells round [param point] (mine frame) built with the latest rock?
func ready_at(point: Vector3) -> bool:
    var cell := Vector3i((point / CELL_M).floor())
    if not _cells.has(cell):
        return true
    var built: Variant = _built.get(cell)
    return built != null and int(built.version) >= int(_changed.get(cell, 0))


func _process(delta: float) -> void:
    _finish_configure()
    if _mesher == null:
        return
    _next_view -= delta
    if _next_view <= 0.0:
        _next_view = VIEW_PERIOD_S
        _update_wanted()
    _collect()
    _dispatch()


func _update_wanted() -> void:
    var points: Array = viewers.call() if viewers.is_valid() else []
    var wanted := {}
    var keep := {}
    var near := view_radius_m + CELL_M
    var far := view_radius_m + keep_margin_m + CELL_M
    for cell: Vector3i in _cells:
        var center := (Vector3(cell) + Vector3.ONE * 0.5) * CELL_M
        for point: Vector3 in points:
            var distance := center.distance_to(point)
            if distance < near:
                wanted[cell] = center.distance_squared_to(point)
            if distance < far:
                keep[cell] = true
    _wanted = wanted
    for cell: Vector3i in _built.keys():
        if not keep.has(cell) or not _cells.has(cell):
            var node: Node = _built[cell].node
            if is_instance_valid(node):
                node.queue_free()
            _built.erase(cell)


func _collect() -> void:
    for cell: Vector3i in _tasks.keys():
        if _assembled_frame == Engine.get_process_frames():
            return
        var task: Dictionary = _tasks[cell]
        if not WorkerThreadPool.is_task_completed(task.id):
            continue
        WorkerThreadPool.wait_for_task_completion(task.id)
        _tasks.erase(cell)
        if not _wanted.has(cell):
            continue
        var built: Variant = _built.get(cell)
        if built != null and int(built.version) >= int(task.version):
            continue
        var node := _assemble(cell, task.result[0])
        if built != null and is_instance_valid(built.node):
            (built.node as Node).queue_free()
        _built[cell] = {"node": node, "version": int(task.version)}
        _assembled_frame = Engine.get_process_frames()


func _dispatch() -> void:
    if _tasks.size() >= MAX_TASKS:
        return
    # Nearest first.
    var order: Array = _wanted.keys()
    order.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return float(_wanted[a]) < float(_wanted[b]))
    for cell: Vector3i in order:
        if _tasks.size() >= MAX_TASKS:
            return
        if _tasks.has(cell):
            continue
        var built: Variant = _built.get(cell)
        var version := int(_changed.get(cell, 0))
        if built != null and int(built.version) >= version:
            continue
        var mesher := _mesher
        var result: Array = [{}]
        var step := step_m
        var id := WorkerThreadPool.add_task(func(): result[0] = MineMesher.build_cell(mesher, cell, CELL_M, step))
        _tasks[cell] = {"id": id, "result": result, "version": _version}


## The node of a built cell (an empty one when it holds no rock surface: still marks the cell as done).
func _assemble(cell: Vector3i, built: Dictionary) -> Node3D:
    var node: Node3D
    if physics:
        var faces := MineMesher.faces(built)
        var body := StaticBody3D.new()
        body.collision_layer = GlobalsDefs.LAYER_WORLD
        body.collision_mask = 0
        if not faces.is_empty():
            var shape := ConcavePolygonShape3D.new()
            shape.set_faces(faces)
            var collision := CollisionShape3D.new()
            collision.shape = shape
            body.add_child(collision)
        node = body
    else:
        var instance := MeshInstance3D.new()
        instance.mesh = MineMesher.to_mesh(built, wall_material, floor_material)
        node = instance
    node.name = "Cell_%d_%d_%d" % [cell.x, cell.y, cell.z]
    add_child(node)
    return node


func _exit_tree() -> void:
    if _configuring.has("id"):
        WorkerThreadPool.wait_for_task_completion(_configuring.id)
        _configuring = {}
    for cell: Vector3i in _tasks:
        WorkerThreadPool.wait_for_task_completion(_tasks[cell].id)
    _tasks.clear()
