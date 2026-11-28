class_name HumanMeshCache
extends RefCounted

## Baked bodies, shared by shape: two avatars with the same CharacterAppearance.shape_hash wear the same
## mesh and Skin (colours are per avatar, never in the mesh). Bakes run on WorkerThreadPool, at most
## MAX_RUNNING at a time -- thirty players walking into view at once queue up instead of filling the pool
## other systems (terrain, navigation) share -- and the CAPACITY most recently used bodies are kept.
##
## Main thread only (request, poll); the workers only run HumanBuilder.build on data made beforehand.

## Baked bodies kept (each ~3-5 MB of vertex data on the GPU and in RAM).
const CAPACITY: int = 48
## Bakes running at once.
const MAX_RUNNING: int = 2

static var _done: Dictionary = {}  # shape_hash -> HumanBuilder.Baked
static var _lru: Array[int] = []  # shape hashes, least recently used first
static var _running: Dictionary = {}  # shape_hash -> [task id, result holder Array]
static var _queue: Array[HumanBuilder.Order] = []
static var _template: Dictionary = {}  # bone name -> global rest of the template skeleton
static var _template_rests: Array[Transform3D] = []  # the same, in the bank's bone order (made once the bank is in)
static var _polled_frame: int = -1


## Set the template skeleton the bodies keep their rest rotations and bone directions from (once: the
## first unmodified one).
static func set_template(skeleton: Skeleton3D) -> void:
	if not _template.is_empty() or skeleton == null:
		return
	for bone in skeleton.get_bone_count():
		_template[skeleton.get_bone_name(bone)] = skeleton.get_bone_global_rest(bone)


static func has_template() -> bool:
	return not _template.is_empty()


## The template's rests in the bank's bone order (main thread, bank ready).
static func _bases() -> Array[Transform3D]:
	if _template_rests.is_empty():
		for name in HumanBuilder.prepare().bank.bone_names:
			_template_rests.append(_template.get(name, Transform3D.IDENTITY))
	return _template_rests


## The baked body of [param appearance] if ready, else null and its bake is queued (call poll each frame).
## Only once HumanBuilder.warm() is true. [param lods]: a body without levels of detail will not do (a
## creator preview's, say): it is baked again with them, and replaced. [param live]: the head alone,
## with its blend shapes (HumanBuilder.Order.live) -- cached apart from the plain body.
static func request(appearance: CharacterAppearance, lods: bool = true, live: bool = false) -> HumanBuilder.Baked:
	var key: int = key_of(appearance.shape_hash(), live)
	if _done.has(key) and (live or (_done[key] as HumanBuilder.Baked).lods or not lods):
		_touch(key)
		return _done[key]
	if not _running.has(key) and not _queue.any(func(o: HumanBuilder.Order) -> bool: return _order_key(o) == key):
		_queue.append(HumanBuilder.order_for(appearance, lods, live))
	return null


## The cache key of a shape: its hash, and whether it is the live head.
static func key_of(shape_hash: int, live: bool) -> int:
	return shape_hash | (1 << 40) if live else shape_hash


static func _order_key(order: HumanBuilder.Order) -> int:
	return key_of(order.shape_hash, order.live)


## Drop a queued bake nobody waits for any more (a creator slider dragged past that shape). A bake
## already running finishes; another avatar still wanting the shape asks for it again.
static func cancel(shape_hash: int, live: bool = false) -> void:
	var key: int = key_of(shape_hash, live)
	for i in range(_queue.size() - 1, -1, -1):
		if _order_key(_queue[i]) == key:
			_queue.remove_at(i)


## The baked body of a shape hash, if ready.
static func baked(shape_hash: int, live: bool = false) -> HumanBuilder.Baked:
	return _done.get(key_of(shape_hash, live))


## Collect finished bakes and start queued ones. Safe to call many times a frame (runs once per frame).
static func poll() -> void:
	var frame: int = Engine.get_process_frames()
	if frame == _polled_frame:
		return
	_polled_frame = frame
	for key: int in _running.keys():
		var task: Array = _running[key]
		if not WorkerThreadPool.is_task_completed(task[0]):
			continue
		PerfTasks.wait(task[0], "human_mesh_cache")
		_running.erase(key)
		var result: HumanBuilder.Baked = task[1][0] if not (task[1] as Array).is_empty() else null
		if result != null:
			_store(key, result)
	while _running.size() < MAX_RUNNING and not _queue.is_empty():
		var order: HumanBuilder.Order = _queue.pop_front()
		var key: int = _order_key(order)
		if (_done.has(key) and ((_done[key] as HumanBuilder.Baked).lods or not order.lods)) or _running.has(key):
			continue
		var holder: Array = []
		var template: Array[Transform3D] = _bases()
		var id: int = PerfTasks.add_task("human:build", func() -> void: holder.append(HumanBuilder.build(order, template)),
				false, "HumanBuilder")
		_running[key] = [id, holder]


## Bake now, on this thread (tests, tools, a preview that must not wait a frame).
static func build_now(appearance: CharacterAppearance, lods: bool = true, live: bool = false) -> HumanBuilder.Baked:
	var key: int = key_of(appearance.shape_hash(), live)
	if _done.has(key) and (live or (_done[key] as HumanBuilder.Baked).lods or not lods):
		_touch(key)
		return _done[key]
	var result: HumanBuilder.Baked = HumanBuilder.build(HumanBuilder.order_for(appearance, lods, live), _bases())
	_store(key, result)
	return result


## Whether anything is still baking or queued.
static func busy() -> bool:
	return not _running.is_empty() or not _queue.is_empty()


static func clear() -> void:
	for h: int in _running.keys():
		PerfTasks.wait(_running[h][0], "human_mesh_cache")
	_running.clear()
	_queue.clear()
	_done.clear()
	_lru.clear()


static func _store(h: int, result: HumanBuilder.Baked) -> void:
	_done[h] = result
	_touch(h)
	while _lru.size() > CAPACITY:
		_done.erase(_lru.pop_front())


static func _touch(h: int) -> void:
	_lru.erase(h)
	_lru.append(h)
