class_name AutoScroll
extends Node
## Scrolls its parent ScrollContainer on its own while the content is taller than the view: a pause
## at the top, down at a steady speed, a pause at the bottom, back up — in a loop, so a long list
## (the Server box's zones) is read whole without a hand on the mouse. From TheMoye's #330.
##
## Watches the overflow every frame and rebuilds the loop only when it changes; content that fits
## again goes back to the top. A Node, not a Control: the ScrollContainer keeps one content child.

## Pixels per second, whatever the length: a longer list takes longer, it never reads faster.
var speed_px_s : float = 20.0
## Seconds held at each end.
var pause_s : float = 3.0

var _content : Control
var _scroll : ScrollContainer = null
var _tween : Tween = null
var _overflow : int = -1


func _init(content: Control = null) -> void:
	_content = content


## How far the view can move: 0 while the content fits.
static func max_scroll(content_h: float, view_h: float) -> int:
	return maxi(0, ceili(content_h - view_h))


func is_running() -> bool:
	return _tween != null and _tween.is_valid()


func _ready() -> void:
	_scroll = get_parent() as ScrollContainer


func _process(_delta: float) -> void:
	if _scroll == null or not is_instance_valid(_content):
		return
	var overflow : int = max_scroll(_content.size.y, _scroll.size.y)
	if overflow == _overflow:
		return
	_overflow = overflow
	_restart()


func _restart() -> void:
	if _tween != null:
		_tween.kill()
		_tween = null
	_scroll.scroll_vertical = 0
	if _overflow <= 0:
		return
	var travel_s : float = _overflow / speed_px_s
	_tween = create_tween().set_loops()
	_tween.tween_interval(pause_s)
	_tween.tween_property(_scroll, "scroll_vertical", _overflow, travel_s)
	_tween.tween_interval(pause_s)
	_tween.tween_property(_scroll, "scroll_vertical", 0, travel_s)
