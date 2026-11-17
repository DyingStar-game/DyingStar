@tool
extends Node

## Renders the thumbnails the editor does not have: a model imported from Blender has none, and a scene
## has one only once it was saved from the editor.
##
## One at a time, so browsing stays smooth: the asset is loaded on a thread, put on a stage for a frame
## with its scripts taken off (asset_stage.gd: a picture never runs a scene's code), and its picture
## kept in memory and on disk. The disk copy sits in the editor's own cache folder
## (.godot, never committed) and is named after the file's date, so a re-exported model is drawn again.

const Stage := preload("res://addons/dyingstar/asset_library/asset_stage.gd")

## Where the pictures are kept between editor sessions.
const CACHE_DIR := "res://.godot/editor/ds_asset_thumbs"
## Width and height of a thumbnail, in pixels: enough to stay sharp at the grid's largest zoom.
const SIZE := 256
## Requests served before the editor is given a frame.
const JOBS_PER_FRAME := 8
## In the cache folder: the assets being drawn right now, and those never to draw again.
const IN_PROGRESS_FILE := "in_progress.txt"
const SKIPPED_FILE := "skipped.txt"

## path -> Texture2D, or null for an asset that cannot be drawn (asked once, never again).
var _cache: Dictionary = {}
## Paths being read on a thread: a second reader waits for the first.
var _loading: Dictionary = {}
## Waiting requests: [path, Callable(path, texture)].
var _queue: Array = []
var _busy := false
## Paths being put on a stage, also written to IN_PROGRESS_FILE.
var _in_progress: Dictionary = {}
## Paths that stopped the editor once, read from SKIPPED_FILE: never drawn again.
var _skipped: Dictionary = {}
var _stage: Stage


func _ready() -> void:
	_stage = Stage.new()
	_stage.size = Vector2i(SIZE, SIZE)
	add_child(_stage)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_recall_what_stopped_the_editor()


## An asset still marked as being drawn was being drawn when the editor stopped (a freeze, a crash): it
## is never drawn again, so the same asset cannot stop the editor at every start.
func _recall_what_stopped_the_editor() -> void:
	for line in FileAccess.get_file_as_string(_cache_path(SKIPPED_FILE)).split("\n", false):
		_skipped[line] = true
	var marker := _cache_path(IN_PROGRESS_FILE)
	if not FileAccess.file_exists(marker):
		return
	for line in FileAccess.get_file_as_string(marker).split("\n", false):
		_skipped[line] = true
		push_warning(("DyingStar asset library: the editor stopped while drawing %s. It is left out from now on"
				+ " (delete %s to try it again).") % [line, _cache_path(SKIPPED_FILE)])
	_write_lines(SKIPPED_FILE, _skipped.keys())
	DirAccess.remove_absolute(marker)


## The node that shows the asset at [param path], ready to be put on a stage, or null when it is not to
## be drawn. The asset is marked as being drawn until [method settle] is called for it.
func stage_node(path: String) -> Node3D:
	if _skipped.has(path) or not Stage.may_be_3d(path):
		return null
	_in_progress[path] = true
	_write_lines(IN_PROGRESS_FILE, _in_progress.keys())
	var node: Node3D = Stage.node_of(await load_asset(path))
	if node == null:
		settle(path)
	return node


## The asset at [param path] is on its stage and the editor is still running: it is no longer marked.
func settle(path: String) -> void:
	_in_progress.erase(path)
	_write_lines(IN_PROGRESS_FILE, _in_progress.keys())


func _write_lines(file_name: String, lines: Array) -> void:
	if lines.is_empty():
		DirAccess.remove_absolute(_cache_path(file_name))
		return
	var file := FileAccess.open(_cache_path(file_name), FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(PackedStringArray(lines)))
		file.close()


func _cache_path(file_name: String) -> String:
	return ProjectSettings.globalize_path(CACHE_DIR).path_join(file_name)


## Ask for the thumbnail of the model or scene at [param path]. [param done] is called with the path
## and its texture, or null when the asset cannot be drawn.
func request(path: String, done: Callable) -> void:
	if _cache.has(path):
		done.call(path, _cache[path])
		return
	_queue.append([path, done])
	if not _busy:
		_run()


## Forget the requests not started yet: the list they were for is no longer shown.
func cancel_pending() -> void:
	_queue.clear()


func _run() -> void:
	_busy = true
	var served := 0
	while not _queue.is_empty():
		var job: Array = _queue.pop_front()
		var path: String = job[0]
		if not _cache.has(path):
			_cache[path] = await _thumbnail(path)
		var done: Callable = job[1]
		if done.is_valid():
			done.call(path, _cache[path])
		# A picture read back from the disk takes no frame: without this pause, a few hundred of them
		# would all be read in one.
		served += 1
		if served % JOBS_PER_FRAME == 0:
			await get_tree().process_frame
	_busy = false


func _thumbnail(path: String) -> Texture2D:
	var file := _cache_file(path)
	if FileAccess.file_exists(file):
		var kept := Image.load_from_file(file)
		if kept != null and not kept.is_empty():
			return ImageTexture.create_from_image(kept)
	var node: Node3D = await stage_node(path)
	if node == null:
		return null
	_stage.show_node(node)
	_stage.render_target_update_mode = SubViewport.UPDATE_ONCE
	# Two frames: the first one may be drawn before the stage has taken the new content in.
	await RenderingServer.frame_post_draw
	_stage.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var image := _stage.get_texture().get_image()
	_stage.clear()
	settle(path)
	if image == null or image.is_empty():
		return null
	image.save_png(file)
	return ImageTexture.create_from_image(image)


## Load on a thread, so a heavy model does not freeze the editor while it is read. One reader per path
## at a time: a threaded load hands its result over once only.
func load_asset(path: String) -> Resource:
	while _loading.has(path):
		await get_tree().process_frame
	if ResourceLoader.has_cached(path):
		return load(path)
	_loading[path] = true
	var resource: Resource = null
	if ResourceLoader.load_threaded_request(path) == OK:
		while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
			resource = ResourceLoader.load_threaded_get(path)
	_loading.erase(path)
	return resource


func _cache_file(path: String) -> String:
	return _cache_path("%s_%d_%d.png" % [path.md5_text(), FileAccess.get_modified_time(path), SIZE])
