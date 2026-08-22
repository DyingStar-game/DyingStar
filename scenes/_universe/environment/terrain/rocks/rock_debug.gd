class_name RockDebug
extends RefCounted
## Bisection switches + timing helpers for the "walking into a rock field costs 30 FPS" problem.
##
## VERDICT (measured 2026-09-05, five runs on tarsis_4, ~40 rocks in the field). One suspect, and
## only one: Mesh.create_convex_shape(clean, simplify=TRUE) in RockMining._build_mesh_collider.
## It does not hull the points, it runs the engine's convex DECOMPOSITION — 90.3 ms on the
## 749-vertex rock mesh against 1.68 ms for the plain QuickHull (tools/perf/hull_stats.gd).
##
##   run                  fps      proc     per rock: spawn   ready    hull
##   normal               15.9     125 ms             99.6 ms  96.0 ms  95.5 ms  <-- 96 % of a rock
##   --rocks-hidden       22-40    166 ms             79.0 ms  78.0 ms  79.7 ms  NOT the rendering
##   --rocks-no-csg       36-42     90 ms             65.8 ms  65.4 ms  65.0 ms  NOT the CSG node
##   --rocks-shared-mat   38-45     91 ms             68.4 ms  68.0 ms  67.8 ms  NOT the materials
##   --rocks-scene-hull   45-47     33 ms              0.7 ms   0.3 ms  skipped  <-- 140x cheaper
##
## The mesh was never the problem either: one rock is 749 verts / 1494 tris, and prim= in the
## heartbeat never moved between runs. The fix is in _shared_uncut_hull — build the expensive (and
## better, 32-point) collider ONCE and share the resource, since every uncut rock of a variant is
## the same shape. The flags below stay: they are how the above was obtained, and how a regression
## would be caught.
##
##   --rocks-no-csg      render an uncut rock through a plain MeshInstance3D (the CSG node is put
##                       back the moment a cut actually has to be carved).
##   --rocks-scene-hull  keep the scene's authored collision shape, build no hull. Aim rays get
##                       less precise — diagnosis only.
##   --rocks-shared-mat  paint every rock with ONE shared material: all rocks then look identical
##                       (no per-rock ore, no crack lines) — diagnosis only.
##   --rocks-hidden      hide the rock meshes but keep everything else. Splits CPU from GPU.
##   --rocks-verbose     restore the per-rock `[cut]` prints. They are off by default because EVERY
##                       print() here is routed through CustomLogger -> Obs -> the C# OpenTelemetry
##                       bridge, so four lines per rock on a field spawn are a cost of their own.

static var no_csg: bool = false
static var scene_hull: bool = false
static var shared_material: bool = false
static var hidden: bool = false
static var verbose_cuts: bool = false


static func _static_init() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	no_csg = "--rocks-no-csg" in args
	scene_hull = "--rocks-scene-hull" in args
	shared_material = "--rocks-shared-mat" in args
	hidden = "--rocks-hidden" in args
	verbose_cuts = "--rocks-verbose" in args
	if no_csg or scene_hull or shared_material or hidden or verbose_cuts:
		print("[RockDebug] no_csg=%s scene_hull=%s shared_mat=%s hidden=%s verbose=%s" % [
			no_csg, scene_hull, shared_material, hidden, verbose_cuts])


## Open a timing scope. Returns 0 — and closes to a no-op — in the editor, where the @tool half of
## RockMining runs without any autoload, and on the dedicated server, where ClientPerf is disabled.
static func t() -> int:
	if Engine.is_editor_hint():
		return 0
	return ClientPerf.scope_begin()


static func t_end(scope_name: String, token: int) -> void:
	if token == 0 or Engine.is_editor_hint():
		return
	ClientPerf.scope_end(scope_name, token)
