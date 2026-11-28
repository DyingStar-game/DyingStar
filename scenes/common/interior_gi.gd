class_name InteriorGi
extends RefCounted
## Bounce light for one building: a VoxelGI fitted to the building's own meshes and baked at runtime.
##
## SDFGI cannot run at this project's coordinates (it loses the GPU, measured 2026-11-27); VoxelGI follows its
## node instead of the camera and was measured working at 3.3e10 m on D3D12 and Vulkan. The probe is a child of
## the building, so it rides with the planet's steps like everything else on it. Baking reads only the
## building's own geometry (bake(from_node)), so a village around it costs nothing.
##
## Development tool for now (render lab, village bench): nothing in the shipped game builds one.

## Name of the VoxelGI node added under a building, so a second call finds it instead of stacking another.
const NODE_NAME := &"InteriorGi"
## Every VoxelGI built here joins this group: the render lab tunes them all, whoever baked them.
const GROUP := &"interior_gi"
## Margin around the building's meshes, metres, so light leaking through a doorway still has cells to land in.
const MARGIN_M := 2.0
## A building larger than this on any axis is not boxed: the cells would be too coarse to be worth the cost.
const MAX_SIZE_M := 160.0
## The grid chosen by eye in the town hall and the garage (2026-11-27): 512 with the sky's light kept
## (VoxelGIData.interior off). Finer than 128 by 64 times in cells: a longer bake, to measure.
const DEFAULT_SUBDIV := VoxelGI.SUBDIV_512
## Bakes are kept here, one file per building scene and grid (cache_path): a 512 bake of the town hall took
## 8.1 s, the next one is a file read.
const CACHE_DIR := "user://interior_gi"
## Raise to drop every kept bake (a change in how they are made).
const CACHE_VERSION := 1


## The VoxelGI of [param building], built and baked if it has none yet; null when the building has no mesh or is
## too large. [param subdiv] trades cell size for bake time and memory (VoxelGI.SUBDIV_*).
static func ensure(building: Node3D, subdiv: VoxelGI.Subdiv = DEFAULT_SUBDIV) -> VoxelGI:
	var existing := building.get_node_or_null(NodePath(NODE_NAME)) as VoxelGI
	if existing != null:
		return existing
	var box := local_aabb(building)
	if box.size == Vector3.ZERO:
		return null
	if box.size.x > MAX_SIZE_M or box.size.y > MAX_SIZE_M or box.size.z > MAX_SIZE_M:
		push_warning("[InteriorGi] %s is %s m: too large for one VoxelGI, skipped" % [building.name, box.size])
		return null
	var gi := VoxelGI.new()
	gi.name = NODE_NAME
	gi.subdiv = subdiv
	gi.size = box.size + Vector3.ONE * (2.0 * MARGIN_M)
	gi.position = box.get_center()
	gi.add_to_group(GROUP)
	building.add_child(gi)
	var started := Time.get_ticks_msec()
	var cache := cache_path(building, subdiv, box)
	if cache != "" and ResourceLoader.exists(cache):
		var data := ResourceLoader.load(cache, "VoxelGIData", ResourceLoader.CACHE_MODE_IGNORE) as VoxelGIData
		if data != null:
			gi.data = data
			print("[InteriorGi] %s: read from %s in %d ms" % [building.name, cache, Time.get_ticks_msec() - started])
			return gi
	gi.bake(building)
	print("[InteriorGi] %s: %.0f x %.0f x %.0f m baked in %d ms" % [building.name, gi.size.x, gi.size.y, gi.size.z,
			Time.get_ticks_msec() - started])
	if cache != "" and gi.data != null:
		DirAccess.make_dir_recursive_absolute(CACHE_DIR)
		# Compressed: a 512 grid is mostly empty space, and uncompressed it weighed 90 MB for the town hall.
		var err := ResourceSaver.save(gi.data, cache, ResourceSaver.FLAG_COMPRESS)
		if err != OK:
			push_warning("[InteriorGi] could not keep %s's bake in %s (error %d)" % [building.name, cache, err])
	return gi


## Where the bake of [param building] is kept, or "" for a building that is not an instanced scene. Every
## instance of one scene has the same geometry, so one bake serves them all and every later session: the key
## is the scene, its last change, the grid and the box (a box that moved means the geometry did).
static func cache_path(building: Node3D, subdiv: VoxelGI.Subdiv, box: AABB) -> String:
	var scene := building.scene_file_path
	if scene == "":
		return ""
	var key := "%s|%d|%d|%s|%d" % [scene, FileAccess.get_modified_time(scene), subdiv, box, CACHE_VERSION]
	return "%s/%s_%s.res" % [CACHE_DIR, scene.get_file().get_basename(), key.md5_text().left(12)]


## The box around every visual instance under [param building], in the building's own frame. Computed from the
## relative transforms, never from world positions, which are ~3e10 m out here.
static func local_aabb(building: Node3D) -> AABB:
	var to_local := building.global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for node in building.find_children("*", "VisualInstance3D", true, false):
		var visual := node as VisualInstance3D
		if visual is VoxelGI or visual is Light3D or visual is ReflectionProbe or visual is Decal:
			continue
		var part: AABB = (to_local * visual.global_transform) * visual.get_aabb()
		if first:
			box = part
			first = false
		else:
			box = box.merge(part)
	return box
