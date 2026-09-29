class_name LoadingSplash
extends RefCounted
## The game's loading splash (the "Loading" node GameOrchestrator keeps on the root, a CanvasLayer at
## layer 100): shown, told what it is loading, and given a progress bar under its text. One place for
## it, used by the menu stage ("Loading…") and by entering the universe ("Loading the Universe…",
## then "Spawning…"). The bar only moves forward.

const BAR_NAME : StringName = &"ProgressBar"


static func show(tree: SceneTree, text_key: String) -> void:
	var screen : CanvasLayer = _screen(tree)
	if screen == null:
		return
	screen.visible = true
	say(tree, text_key)
	var bar : ProgressBar = _bar(screen)
	if bar != null:
		bar.value = 0.0


static func hide(tree: SceneTree) -> void:
	var screen : CanvasLayer = _screen(tree)
	if screen != null:
		screen.visible = false


static func say(tree: SceneTree, text_key: String) -> void:
	var label : Label = _label(_screen(tree))
	if label != null:
		label.text = text_key


## 0..1, never backwards: loading may re-evaluate its estimate, the bar must not flicker back.
static func progress(tree: SceneTree, value: float) -> void:
	var bar : ProgressBar = _bar(_screen(tree))
	if bar != null:
		bar.value = maxf(bar.value, clampf(value, 0.0, 1.0))


static func _screen(tree: SceneTree) -> CanvasLayer:
	var loading : Node = tree.root.get_node_or_null("Loading")
	return loading.get_node_or_null("LoadingScreen") as CanvasLayer if loading != null else null


static func _label(screen: CanvasLayer) -> Label:
	return screen.find_child("Label", true, false) as Label if screen != null else null


## Built once, under the text: a thin amber bar over a faint track.
static func _bar(screen: CanvasLayer) -> ProgressBar:
	var label : Label = _label(screen)
	if label == null:
		return null
	var bar : ProgressBar = label.get_parent().get_node_or_null(NodePath(BAR_NAME)) as ProgressBar
	if bar != null:
		return bar
	bar = ProgressBar.new()
	bar.name = BAR_NAME
	bar.show_percentage = false
	bar.max_value = 1.0
	bar.step = 0.0
	bar.anchor_left = 0.35
	bar.anchor_right = 0.65
	bar.anchor_top = label.anchor_bottom
	bar.anchor_bottom = label.anchor_bottom
	bar.offset_top = label.offset_bottom + 8.0
	bar.offset_bottom = label.offset_bottom + 14.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = SettingsStyle.ACTIVE_COLOR
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1.0, 1.0, 1.0, 0.15)
	bar.add_theme_stylebox_override("fill", fill)
	bar.add_theme_stylebox_override("background", track)
	label.get_parent().add_child(bar)
	return bar
