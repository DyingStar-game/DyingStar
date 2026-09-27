extends Node
## F7 (action "screenshot", remappable in Settings > Controls): save what is on screen as a PNG in
## <game folder>/screenshots and put the same image on the clipboard. Global autoload, so it works in
## every scene, menus included. Client-only: a dedicated server has no screen.
##
## The image is what the player sees, HUD included. Encoding a PNG takes a noticeable fraction of a
## second at 4K, so it runs on a worker thread: the game never hitches on the key press.

var _toast: ScreenToast = null
var _busy: bool = false


func _ready() -> void:
	_toast = ScreenToast.new()
	add_child(_toast)


func _unhandled_input(event: InputEvent) -> void:
	if GameOrchestrator.is_server():
		return
	if event.is_action_pressed("screenshot") and not _busy:
		take()


func take() -> void:
	_busy = true
	# The confirmation of the previous shot must not end up in this one: clear it, then read back
	# the first frame drawn without it.
	_toast.clear()
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = CapturePaths.screenshots_dir().path_join("screenshot_%s.png" % CapturePaths.stamp())
	WorkerThreadPool.add_task(_save.bind(image, path), false, "screenshot")


## Worker thread: nothing here may touch the scene tree.
func _save(image: Image, path: String) -> void:
	image.convert(Image.FORMAT_RGB8)  # the viewport carries an alpha channel nobody wants in a shot
	var err: Error = image.save_png(path)
	_saved.call_deferred(path, err)


func _saved(path: String, err: Error) -> void:
	_busy = false
	if err != OK:
		push_warning("Screenshot: cannot write %s (%s)" % [path, error_string(err)])
		_toast.show_message(tr("%%SCREENSHOT_FAILED") % path)
		return
	if ClipboardImage.copy_png(path):
		_toast.show_message(tr("%%SCREENSHOT_SAVED") % path)
	else:
		_toast.show_message(tr("%%SCREENSHOT_SAVED_NOT_COPIED") % path)
