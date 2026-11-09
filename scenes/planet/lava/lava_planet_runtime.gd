extends Node3D
## Shared PlanetTerrain subsystem. Physics is tick-command driven; camera/LOD
## never starts, retires or changes a physical patch. The authority installs
## canonical checkpoints. Only the client creates materials and cosmetic smoke.
##
## A patch installed with an eruption "plan" (LavaPlanetPatch.eruption_plan) is driven here: its tick follows the
## shared clock (Globals.reference_time), every peer derives the same crater commands from (tick, plan), and the
## ticks run on a worker, catching up a few at a time after a late arrival. Patches without a plan are advanced by
## their owner through advance_patch (offline preview, tests).
##
## Network replicas do not simulate: the authority's driven patches grow a LavaSummary (wet mask + Voronoi seeds,
## ~3 KB) the server publishes every LavaSummary.INTERVAL_MS, and a client shows it through install_summary /
## apply_summary (a LavaSummaryView rebuilt on a worker, drawn by the same renderer).

const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const Builder = preload("res://scenes/planet/lava/lava_planet_patch.gd")
const Smoke = preload("res://scenes/planet/lava/lava_edge_smoke.gd")
const Summary = preload("res://scenes/planet/lava/lava_summary.gd")
const SummaryView = preload("res://scenes/planet/lava/lava_summary_view.gd")
## Ticks between two recorded state digests (5 s): the authority publishes them, replicas compare.
const DIGEST_TICKS := 50
## Digests a replica keeps to compare with the authority's late ones.
const DIGEST_KEEP := 24
## Patches this runtime accepts at once (the client only receives the volcanoes near it).
var max_patches := 2
## Ticks one worker job may run per frame while catching up: higher = faster catch-up, longer jobs.
var catch_up_ticks := 6
var patches: Dictionary = {}
var server_mode := true
var planet_name := ""
var paused := false
var physics_pending := false
var smoke_enabled := true
var last_physics_ms := 0.0
var last_visual_ms := 0.0
## Shared clock in ms (tests replace it).
var clock_ms: Callable = func() -> int: return int(Globals.reference_time() * 1000.0)
var _overlay_head: ShaderMaterial
var _overlay_targets: Dictionary = {} # Weak references: never retain retired chunks.
var _jobs: Array = [] # [{key, job, task}] in flight on WorkerThreadPool.


## Worker payload of a driven patch: [member from_tick]..[member to_tick] with the plan's commands.
class DriveJob:
	extends RefCounted
	var solver: RefCounted
	var packet: Dictionary
	var plan: Dictionary
	var to_tick := 0
	var ok := true
	var cpu_usec := 0
	## tick -> SHA-256 hex of the state at that tick, for ticks multiple of DIGEST_TICKS.
	var digests: Dictionary = {}
	## Client: the patch's surface, whose next textures this job packs after its ticks (upload on the main thread).
	var surface: RefCounted
	## Client: the edge-smoke scan is due; [member edges] receives it (LavaEdgeSmoke.edges_of).
	var scan_edges := false
	var edges: Array = []
	## Authority: the patch's LavaSummary, grown every DIGEST_TICKS; encoded after the ticks when asked.
	var summary: RefCounted
	var encode_summary := false
	var summary_bytes := PackedByteArray()

	func run() -> void:
		var started := Time.get_ticks_usec()
		while ok and solver.tick < to_tick:
			var next: int = solver.tick + 1
			ok = solver.advance_tick(next, Builder.eruption_commands(solver, packet, plan, next))
			if ok and next % DIGEST_TICKS == 0:
				digests[next] = solver.state_digest()
				if summary != null:
					summary.grow(solver)
		if ok and encode_summary and summary != null:
			summary.grow(solver)
			summary_bytes = summary.encode(solver)
		if ok and surface != null and not solver.visual_dirty.is_empty():
			surface.prepare(solver, 0.1, true)
		if ok and scan_edges:
			edges = Smoke.edges_of(solver)
		cpu_usec = Time.get_ticks_usec() - started


## Worker payload of a summary patch: rebuilds its view from a received summary, then packs its textures and
## finds its hot edges for the smoke (~0.2 s of GDScript for 3 700 wet cells).
class SummaryJob:
	extends RefCounted
	var view: RefCounted
	var bytes: PackedByteArray
	var surface: RefCounted
	var interval_s := 3.0
	var ok := false
	var edges: Array = []

	func run() -> void:
		var fields := Summary.reconstruct(bytes, view.positions, view.bed)
		if fields.is_empty():
			return
		view.apply(fields)
		ok = true
		if surface != null:
			surface.prepare(view, interval_s, true)
		edges = Smoke.edges_of(view)


func setup(data: PlanetData, authority_only: bool) -> void:
	planet_name = data.planet_name
	server_mode = authority_only


func install_patch(description: Dictionary) -> bool:
	var key := str(description.get("key", ""))
	if key.is_empty() or key.length() > 160 or str(description.get("planet", "")) != planet_name:
		return false
	if not patches.has(key) and patches.size() >= max_patches:
		return false
	if not description.get("frame") is Transform3D or not description.get("checkpoint") is PackedByteArray:
		return false
	if not _valid_frame(description.frame):
		return false
	var plan: Dictionary = description.get("plan", {})
	if not plan.is_empty() and not Builder.valid_plan(plan):
		return false
	var solver = Core.new() if server_mode else load("res://scenes/planet/lava/viscous_lava_solver.gd").new()
	if not solver.restore(description.checkpoint):
		return false
	remove_patch(key)
	# The checkpoint is not kept: the solver holds the state, and 665 KB per patch would only be a stale copy.
	var kept := description.duplicate(true)
	kept.erase("checkpoint")
	var entry := {"solver": solver, "description": kept, "plan": plan, "since_tick": 0.0,
		"holder": null, "surface": null, "mesh": null, "smoke": null, "overlay": null, "retired": false,
		"digests": {}, "expected": {}, "diverged": false, "tick": int(solver.tick),
		"cleaned": solver.cleanup_complete(), "summary": Summary.new() if server_mode and not plan.is_empty() else null,
		"want_summary": false, "summary_bytes": PackedByteArray(), "summary_tick": -1}
	if not server_mode:
		if solver.cleanup_complete():
			entry.retired = true
			solver.release_views()
		else: _create_visuals(entry)
	patches[key] = entry
	_refresh_terrain_overlays()
	return true


static func _valid_frame(frame: Transform3D) -> bool:
	return frame.origin.is_finite() and frame.basis.is_finite() and absf(frame.basis.determinant() - 1.0) <= 0.00001


## CLIENT: a patch shown from the authority's summaries: [param description] (frame, key, planet) and the grid
## bytes [param grid] (LavaSummary.encode_grid). Nothing is drawn before the first apply_summary.
func install_summary(description: Dictionary, grid: PackedByteArray) -> bool:
	var key := str(description.get("key", ""))
	if server_mode or key.is_empty() or key.length() > 160 or str(description.get("planet", "")) != planet_name:
		return false
	if not patches.has(key) and patches.size() >= max_patches:
		return false
	if not description.get("frame") is Transform3D or not _valid_frame(description.frame):
		return false
	var view := SummaryView.from_grid(grid)
	if view == null:
		return false
	remove_patch(key)
	var kept := description.duplicate(true)
	kept.erase("grid")
	patches[key] = {"solver": view, "summary_view": true, "description": kept, "plan": {}, "since_tick": 0.0,
		"interval_s": Summary.INTERVAL_MS / 1000.0, "holder": null, "surface": null, "mesh": null, "smoke": null,
		"overlay": null, "retired": true, "digests": {}, "expected": {}, "diverged": false, "tick": 0,
		"cleaned": false, "pending": PackedByteArray()}
	return true


## CLIENT: a new summary (LavaSummary.encode) for the patch [param key] of install_summary. It is rebuilt on a
## worker; a newer one arriving meanwhile replaces it.
func apply_summary(key: String, bytes: PackedByteArray) -> void:
	if not patches.has(key) or not patches[key].get("summary_view", false) or bytes.is_empty():
		return
	var entry: Dictionary = patches[key]
	if entry.retired:
		_create_visuals(entry)
		entry.smoke.deferred_scan = true
		_refresh_terrain_overlays()
	entry.pending = bytes


## AUTHORITY: asks the next worker job of a driven patch to encode its summary (see latest_summary).
func request_summary(key: String) -> void:
	if patches.has(key) and patches[key].get("summary") != null:
		patches[key].want_summary = true


## AUTHORITY: the latest encoded summary of a patch, [tick, bytes], or [] before the first one.
func latest_summary(key: String) -> Array:
	if not patches.has(key) or int(patches[key].get("summary_tick", -1)) < 0:
		return []
	return [int(patches[key].summary_tick), patches[key].summary_bytes]


## Tick a driven patch should have reached now: 100 ms steps since its eruption started.
func target_tick(key: String) -> int:
	var plan: Dictionary = patches[key].plan
	return maxi(0, (int(clock_ms.call()) - int(plan.start_unix_ms)) / 100)


## Current tick of a patch, -1 when absent (as of its last finished job: safe while a worker runs it).
func patch_tick(key: String) -> int:
	return int(patches[key].tick) if patches.has(key) else -1


## True once a patch's eruption is over and its deposit has cooled and gone (see Core.cleanup_complete).
func is_cleaned_up(key: String) -> bool:
	return patches.has(key) and bool(patches[key].cleaned)


## Latest digest recorded for a driven patch: [tick, sha256 hex], or [] before the first one.
func latest_digest(key: String) -> Array:
	if not patches.has(key):
		return []
	var digests: Dictionary = patches[key].digests
	if digests.is_empty():
		return []
	var best: int = digests.keys().max()
	return [best, digests[best]]


## Canonical checkpoint of a patch, or empty when absent. Waits for its worker job first.
func patch_checkpoint(key: String) -> PackedByteArray:
	if not patches.has(key):
		return PackedByteArray()
	_wait_patch(key)
	return patches[key].solver.checkpoint()


## The authority's digest of [param tick]: compared now if this peer has it, later otherwise. A mismatch stops
## the patch until the next checkpoint repairs it (install_patch).
func expect_digest(key: String, tick: int, digest: String) -> void:
	if not patches.has(key) or tick <= 0 or digest.is_empty():
		return
	var entry: Dictionary = patches[key]
	if entry.digests.has(tick):
		_compare_digest(key, entry, tick, digest)
	elif tick > int(entry.solver.tick):
		entry.expected[tick] = digest


## True when a replica found its state different from the authority's and waits for a checkpoint.
func is_diverged(key: String) -> bool:
	return patches.has(key) and bool(patches[key].diverged)


func _compare_digest(key: String, entry: Dictionary, tick: int, digest: String) -> void:
	if str(entry.digests[tick]) != digest and not entry.diverged:
		entry.diverged = true
		push_warning("[LAVA] %s diverged from the authority at tick %d; waiting for a checkpoint" % [key, tick])


func _create_visuals(entry: Dictionary) -> void:
	entry.solver.presentation_enabled = true
	entry.solver.refresh_views()
	entry.retired = false
	var holder := Node3D.new()
	holder.name = "ViscousLava_%d" % patches.size()
	holder.transform = entry.description.frame
	add_child(holder)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/_universe/environment/terrain/viscous_lava.gdshader")
	var surface = load("res://scenes/planet/lava/viscous_lava_surface.gd").new()
	surface.configure(entry.solver, mat)
	var overlay := ShaderMaterial.new()
	overlay.shader = load("res://assets/_universe/environment/terrain/viscous_lava_ground.gdshader")
	overlay.set_shader_parameter("debug_field", "--lava-overlay-debug" in OS.get_cmdline_user_args())
	surface.add_material(overlay, entry.solver.cell_m)
	var mesh := MeshInstance3D.new()
	mesh.name = "LavaSurface"
	mesh.mesh = surface.mesh
	mesh.material_override = mat
	mesh.custom_aabb = surface.bounds
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mesh)
	var smoke = Smoke.new()
	smoke.name = "LavaEdgeSmoke"
	smoke.deferred_scan = not entry.plan.is_empty()  # driven patches scan on their tick worker
	holder.add_child(smoke)
	smoke.set_smoke_enabled(smoke_enabled)
	entry.merge({"holder": holder, "surface": surface, "mesh": mesh, "smoke": smoke, "overlay": overlay}, true)


func advance_patch(key: String, next_tick: int, commands: PackedInt64Array) -> bool:
	if not patches.has(key):
		return false
	_wait_patch(key)
	var entry: Dictionary = patches[key]
	var started := Time.get_ticks_usec()
	if not entry.solver.advance_tick(next_tick, commands):
		return false
	entry.tick = next_tick
	entry.cleaned = entry.solver.cleanup_complete()
	last_physics_ms = (Time.get_ticks_usec() - started) / 1000.0
	publish_patch(key)
	return true


func publish_patch(key: String) -> void:
	var entry: Dictionary = patches[key]
	var started := Time.get_ticks_usec()
	if not server_mode:
		started = Time.get_ticks_usec()
		if entry.solver.cleanup_complete():
			if not entry.retired:
				_retire_visuals(entry)
				_refresh_terrain_overlays()
		elif entry.retired:
			_create_visuals(entry)
			_refresh_terrain_overlays()
		elif entry.surface.has_prepared() or not entry.solver.visual_dirty.is_empty():
			if entry.surface.has_prepared():
				entry.surface.upload()  # packed by the worker job (DriveJob.surface)
			else:
				entry.surface.publish(entry.solver, 0.1, true)
			entry.mesh.custom_aabb = entry.surface.bounds
			entry.since_tick = 0.0
		last_visual_ms = (Time.get_ticks_usec() - started) / 1000.0


func _retire_visuals(entry: Dictionary) -> void:
	if is_instance_valid(entry.holder):
		remove_child(entry.holder)
		entry.holder.queue_free()
	for key in ["holder", "surface", "mesh", "smoke", "overlay"]: entry[key] = null
	entry.retired = true
	entry.solver.release_views()


func remove_patch(key: String) -> void:
	if not patches.has(key):
		return
	_wait_patch(key)
	var holder = patches[key].holder
	if is_instance_valid(holder):
		# Remove immediately so two replacements cannot draw at the same place.
		remove_child(holder)
		holder.queue_free()
	patches.erase(key)
	_refresh_terrain_overlays()


func clear_patches() -> void:
	for key: String in patches.keys():
		remove_patch(key)


func _process(delta: float) -> void:
	_drive()
	if server_mode:
		return
	for entry: Dictionary in patches.values():
		if entry.retired: continue
		var camera := get_viewport().get_camera_3d()
		if camera != null:
			entry.overlay.set_shader_parameter("patch_from_view", entry.holder.global_transform.affine_inverse() * camera.global_transform)
		if not paused:
			# Between two published states: a tick (0.1 s), or a summary's interval.
			var span: float = entry.get("interval_s", 0.1)
			entry.since_tick = minf(float(entry.since_tick) + delta, span)
			entry.surface.set_interpolation(float(entry.since_tick) / span)
			# Smoke ages every frame; it reads the solver only when no worker job holds it (a summary patch's
			# edges come from its SummaryJob).
			var readable: bool = not physics_pending and not entry.get("summary_view", false)
			entry.smoke.advance(delta, entry.solver if readable else null)


## Joins the finished worker jobs, then starts one job per driven patch that lags its target tick.
func _drive() -> void:
	if not _jobs.is_empty():
		for running: Dictionary in _jobs:
			if not WorkerThreadPool.is_task_completed(running.task):
				return
		var finished := _jobs
		_jobs = []
		for running: Dictionary in finished:
			WorkerThreadPool.wait_for_task_completion(running.task)
			_join(running)
		physics_pending = false
	if paused:
		return
	for key: String in patches:
		var entry: Dictionary = patches[key]
		if entry.get("summary_view", false):
			if not (entry.pending as PackedByteArray).is_empty() and not entry.retired:
				var rebuild := SummaryJob.new()
				rebuild.view = entry.solver
				rebuild.bytes = entry.pending
				rebuild.surface = entry.surface
				rebuild.interval_s = float(entry.interval_s)
				entry.pending = PackedByteArray()
				_jobs.append({"key": key, "job": rebuild,
					"task": WorkerThreadPool.add_task(rebuild.run, false, "lava summary " + key)})
			continue
		if entry.plan.is_empty() or entry.diverged:
			continue
		var target := target_tick(key)
		var tick: int = entry.tick
		if tick >= target and not entry.get("want_summary", false):
			continue  # caught up; a requested summary still gets a job (no ticks, just the encoding)
		var job := DriveJob.new()
		job.solver = entry.solver
		job.packet = entry.description
		job.plan = entry.plan
		job.to_tick = mini(target, tick + catch_up_ticks)
		if not server_mode and not entry.retired:
			job.surface = entry.surface
			job.scan_edges = entry.smoke.scan_wanted
		if entry.get("summary") != null:
			job.summary = entry.summary
			job.encode_summary = bool(entry.want_summary)
		_jobs.append({"key": key, "job": job, "task": WorkerThreadPool.add_task(job.run, false, "lava " + key)})
	physics_pending = not _jobs.is_empty()


func _join(running: Dictionary) -> void:
	if running.job is SummaryJob:
		_after_summary(running.key, running.job)
	else:
		_after_job(running.key, running.job)


func _after_summary(key: String, job: SummaryJob) -> void:
	if not patches.has(key) or patches[key].solver != job.view:
		return
	var entry: Dictionary = patches[key]
	if not job.ok:
		push_warning("[LAVA] %s: malformed summary ignored" % key)
		return
	entry.tick = int(job.view.tick)
	if not job.edges.is_empty() and entry.smoke != null and job.surface == entry.surface:
		entry.smoke.apply_edges(job.edges)
	publish_patch(key)


func _after_job(key: String, job: DriveJob) -> void:
	if not patches.has(key) or patches[key].solver != job.solver:
		return
	var entry: Dictionary = patches[key]
	if not job.summary_bytes.is_empty():
		entry.summary_bytes = job.summary_bytes
		entry.summary_tick = int(job.solver.tick)
		entry.want_summary = false
	last_physics_ms = job.cpu_usec / 1000.0
	entry.tick = int(job.solver.tick)
	entry.cleaned = job.solver.cleanup_complete()
	if not job.ok:
		entry.diverged = true
		push_error("[LAVA] %s refused tick %d; the patch stops" % [key, int(job.solver.tick) + 1])
	for tick: int in job.digests:
		entry.digests[tick] = job.digests[tick]
		if entry.expected.has(tick):
			_compare_digest(key, entry, tick, entry.expected[tick])
			entry.expected.erase(tick)
	while entry.digests.size() > DIGEST_KEEP:
		entry.digests.erase(entry.digests.keys().min())
	for tick: int in entry.expected.keys():
		if tick < int(job.solver.tick): entry.expected.erase(tick)
	if not job.edges.is_empty() and job.surface != null and job.surface == entry.surface:
		entry.smoke.apply_edges(job.edges)
	publish_patch(key)


## Blocks until the worker job of [param key] (if any) is done, so the main thread may touch its solver.
func _wait_patch(key: String) -> void:
	for n in range(_jobs.size() - 1, -1, -1):
		var running: Dictionary = _jobs[n]
		if running.key == key:
			WorkerThreadPool.wait_for_task_completion(running.task)
			_jobs.remove_at(n)
			_join(running)
	physics_pending = not _jobs.is_empty()


func register_terrain_mesh(mesh: MeshInstance3D) -> void:
	if server_mode or _overlay_head == null or not is_instance_valid(mesh):
		return
	# Terrain geometry alone receives this pass; flying rocks, the player and
	# other foreground objects keep their ordinary depth occlusion.
	var chunk_box: AABB = mesh.transform * mesh.get_aabb()
	for entry: Dictionary in patches.values():
		if entry.retired: continue
		# Select by horizontal footprint. A coarse LOD may sit well ABOVE the
		# canonical bed; using the physical height range excludes exactly the
		# terrain triangles this presentation pass must cover.
		var local_box: AABB = entry.description.frame.affine_inverse() * chunk_box
		var extent: Vector3 = entry.surface.bounds.end
		var begin: Vector3 = entry.surface.bounds.position
		if local_box.position.x <= extent.x + 64.0 and local_box.end.x >= begin.x - 64.0 \
			and local_box.position.z <= extent.z + 64.0 and local_box.end.z >= begin.z - 64.0:
			if mesh.material_overlay == null or mesh.material_overlay == _overlay_head:
				mesh.material_overlay = _overlay_head
				_overlay_targets[mesh.get_instance_id()] = weakref(mesh)
				var forget := _forget_terrain_mesh.bind(mesh.get_instance_id())
				if not mesh.tree_exiting.is_connected(forget):
					mesh.tree_exiting.connect(forget, CONNECT_ONE_SHOT)
			return


func _forget_terrain_mesh(instance: int) -> void:
	_overlay_targets.erase(instance)


func _clear_terrain_overlays() -> void:
	for reference: WeakRef in _overlay_targets.values():
		var mesh = reference.get_ref()
		if is_instance_valid(mesh) and mesh.material_overlay == _overlay_head:
			mesh.material_overlay = null
	_overlay_targets.clear()


func _refresh_terrain_overlays() -> void:
	if server_mode:
		return
	_clear_terrain_overlays()
	_overlay_head = null
	var previous: ShaderMaterial
	for entry: Dictionary in patches.values():
		if entry.retired: continue
		entry.overlay.next_pass = null
		if previous != null:
			previous.next_pass = entry.overlay
		else:
			_overlay_head = entry.overlay
		previous = entry.overlay
	var terrain := get_parent()
	if terrain != null and "_active_chunks" in terrain:
		for chunk: Dictionary in terrain._active_chunks.values():
			var mesh: MeshInstance3D = chunk.get("mesh_instance")
			if is_instance_valid(mesh):
				register_terrain_mesh(mesh)


func _exit_tree() -> void:
	for running: Dictionary in _jobs:
		WorkerThreadPool.wait_for_task_completion(running.task)
	_jobs.clear()
	physics_pending = false
	_clear_terrain_overlays()


func set_smoke(enabled: bool) -> void:
	smoke_enabled = enabled
	for entry: Dictionary in patches.values():
		if entry.smoke != null:
			entry.smoke.set_smoke_enabled(enabled)
