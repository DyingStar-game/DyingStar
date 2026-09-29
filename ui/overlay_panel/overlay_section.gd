class_name OverlaySection
extends Node
## One block of an OverlayPanel: an amber heading and whatever content a subclass builds under it.
##
## A section says whether it is ACTIVE (its gate: a debug toggle, "the dev clock is shifted"…) and,
## when it shows changing values, how often to refresh them. The panel shows active sections only,
## hides itself when none is, and calls restart() whenever a section appears — so a value is never
## shown stale for one period, which the F8 capture (one frame) would catch.
##
## A Node rather than a RefCounted: its signal connections then die with the panel that owns it.

var title_key : String
## Seconds between refresh() calls while shown; 0 = never refreshed by the clock (built once).
var period_s : float
## The content, heading included, as placed in the panel. Set by build().
var box : VBoxContainer = null

var _gate : Callable
var _left : float = 0.0


func _init(p_title_key: String = "", p_gate: Callable = Callable(), p_period_s: float = 0.0) -> void:
	title_key = p_title_key
	_gate = p_gate
	period_s = p_period_s


## Shown or not; a section without a gate always is.
func is_active() -> bool:
	return not _gate.is_valid() or bool(_gate.call())


func build(factory: SettingsRowFactory) -> VBoxContainer:
	box = VBoxContainer.new()
	if title_key != "":
		box.add_child(factory.header(title_key))
	_build_content(box, factory)
	return box


## Refresh now, and count the next period from here.
func restart() -> void:
	_left = period_s
	refresh()


## Called by the panel every frame while the section is shown.
func tick(delta: float) -> void:
	if period_s <= 0.0:
		return
	_left -= delta
	if _left <= 0.0:
		restart()


func refresh() -> void:
	pass


func _build_content(_content: VBoxContainer, _factory: SettingsRowFactory) -> void:
	pass
