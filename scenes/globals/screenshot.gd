extends Node
## Two capture keys, remappable in Settings > Controls. Global autoload, so they work in every scene,
## menus included. Client-only: a dedicated server has no screen.
##
## - "screenshot" (F7), PHOTO: the world alone. Every piece of interface drawn over it — HUD,
##   crosshair, debug panels, chat, menus, toasts — is hidden for the one frame that is read back, and
##   so is every debug visual drawn in the world (Globals.GROUP_DEBUG_OVERLAY: celestial markers, the
##   cargo envelope…). Screens that live IN the world (a truck's dashboard, a terminal) are part of
##   the picture and stay.
##   Saved in <game folder>/screenshots.
## - "screenshot_debug" (F8), BUG REPORT: the screen as it is, plus the debug panels, shown for that
##   frame even if the player hid them. The chat is there when it is open. Saved in
##   <game folder>/screenshots/debug.
##
## Either way the PNG is copied to the clipboard, with the colours of the screen (see ScreenReadback:
## the window holds linear colour). Encoding it takes a noticeable fraction of a second at 4K, so it
## runs on a worker thread: the game never hitches on the key press.

enum Kind { PHOTO, DEBUG }

var _toast: ScreenToast = null
var _readback: ScreenReadback = null
var _busy: bool = false


func _ready() -> void:
	_toast = ScreenToast.new()
	add_child(_toast)
	_readback = ScreenReadback.new()
	add_child(_readback)


func _unhandled_input(event: InputEvent) -> void:
	if GameOrchestrator.is_server() or _busy:
		return
	if event.is_action_pressed("screenshot"):
		take(Kind.PHOTO)
	elif event.is_action_pressed("screenshot_debug"):
		take(Kind.DEBUG)


func take(kind: Kind) -> void:
	_busy = true
	# The confirmation of the previous shot must not end up in this one.
	_toast.clear()
	var hidden: Array[Node] = []
	if kind == Kind.PHOTO:
		hidden = InterfaceHider.hide_all(get_tree())
	else:
		_force_debug_panels(true)
	# Let the hide / show take effect, then read back the next frame drawn.
	await get_tree().process_frame
	var image: Image = await _readback.capture(get_tree().root)
	if kind == Kind.PHOTO:
		InterfaceHider.restore(hidden)
	else:
		_force_debug_panels(false)
	var dir: String = CapturePaths.screenshots_dir("" if kind == Kind.PHOTO else CapturePaths.DEBUG_SUB)
	var prefix: String = "screenshot" if kind == Kind.PHOTO else "debug"
	var path: String = dir.path_join("%s_%s.png" % [prefix, CapturePaths.stamp()])
	WorkerThreadPool.add_task(_save.bind(image, path), false, "screenshot")


## Show the debug panels for the capture, then give the player's own setting back. Goes through the
## signal rather than SettingsManager.set_show_debug, which would SAVE the forced value.
func _force_debug_panels(on: bool) -> void:
	SettingsManager.show_debug_changed.emit(true if on else SettingsManager.is_show_debug())


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
