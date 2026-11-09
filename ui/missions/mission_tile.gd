class_name MissionTile
extends Button

## One mission as a card, for the mission board and the kiosks: on the left a faceted band in its
## giver's colour (MissionGivers) with the giver's logo and the category's pictogram
## (MissionCategories); on the right its title, its giver, its reward and how long it has left.
## Built in code at a [member zoom] of BASE_SIZE, so the board's giant tiles and a kiosk's small ones
## are the same tile. A plain button: a kiosk listens to [signal picked], the board ignores the mouse.

signal picked(mission: Dictionary)

## A tile's size at zoom 1 (px).
const BASE_SIZE := Vector2(440, 210)
## The share of the width the coloured band takes.
const BAND_SHARE: float = 0.36
const CARD := Color(0.11, 0.12, 0.14)
const CARD_HOVER := Color(0.16, 0.17, 0.2)
const TEXT := Color(0.92, 0.93, 0.95)
const DIM := Color(1.0, 1.0, 1.0, 0.6)
const TITLE_PX: int = 21
const LINE_PX: int = 20
const LOGO_PX: float = 34.0
const ICON_PX: float = 76.0
const PAD_PX: float = 16.0

var mission: Dictionary = {}
var giver: MissionGiver
var zoom: float = 1.0


## Show [param shown] at [param scale] times BASE_SIZE, its time left counted from [param now]
## (Unix s; 0 = the system clock).
func setup(shown: Dictionary, scale: float = 1.0, now: float = 0.0) -> MissionTile:
	mission = shown
	zoom = scale
	giver = MissionGivers.of_mission(mission)
	custom_minimum_size = BASE_SIZE * zoom
	focus_mode = Control.FOCUS_NONE
	clip_contents = true
	for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = CARD_HOVER if state == "hover" or state == "pressed" else CARD
		box.set_corner_radius_all(int(10 * zoom))
		if state == "hover":
			box.border_color = giver.colour()
			box.set_border_width_all(int(maxf(2.0 * zoom, 1.0)))
		add_theme_stylebox_override(state, box)
	_build(now if now > 0.0 else Time.get_unix_time_from_system())
	pressed.connect(func() -> void: picked.emit(mission))
	return self


## Call attention to the tile for [param seconds]: a frame in its giver's colour that pulses, then
## fades. What a board does for a mission that just arrived.
func highlight(seconds: float) -> void:
	var frame := Panel.new()
	frame.name = "Highlight"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(giver.colour(), 0.18)
	box.border_color = giver.colour().lightened(0.2)
	box.set_border_width_all(int(maxf(5.0 * zoom, 2.0)))
	box.set_corner_radius_all(int(10 * zoom))
	frame.add_theme_stylebox_override("panel", box)
	add_child(frame)
	var pulse := frame.create_tween()
	for i: int in range(maxi(int(seconds / 1.0) - 1, 1)):
		pulse.tween_property(frame, "modulate:a", 0.35, 0.5)
		pulse.tween_property(frame, "modulate:a", 1.0, 0.5)
	pulse.tween_property(frame, "modulate:a", 0.0, 1.0)
	pulse.tween_callback(frame.queue_free)


## Whether the tile is calling attention to itself (highlight).
func is_highlighted() -> bool:
	return has_node("Highlight")


## The line under the title: the reward, "—" when it pays nothing countable.
static func reward_line(of: Dictionary) -> String:
	var rewards: Variant = of.get("rewards") if of.get("rewards") != null else of.get("reward")
	return ServiceTypes.rewards_text(rewards)


## The time line of [param of] at [param now] (playtest 2026-11-09). Taken ([param assignment]): the time
## left to the player's own deadline (`deadlineAt`, else the mission's end). Not taken: the time it gives
## once taken (`assignmentDeadlineHours`, the simulator's tiers), else when the offer ends, else that it
## has no end.
static func deadline_line(of: Dictionary, now: float, assignment: Variant = null) -> String:
	var taken := assignment is Dictionary and not (assignment as Dictionary).is_empty()
	var left: int = MissionQuery.seconds_left(of, now, assignment)
	if taken and left >= 0:
		return TranslationServer.translate("%%MISSION_TIME_LEFT") % ServiceTypes.duration(left)
	var hours: int = ServiceTypes.num(of.get("assignmentDeadlineHours"), 0)
	if not taken and hours > 0:
		return TranslationServer.translate("%%MISSION_TIME_LIMIT") % ServiceTypes.duration(hours * 3600)
	if left >= 0:
		return TranslationServer.translate("%%MISSION_DEADLINE_IN") % ServiceTypes.duration(left)
	return TranslationServer.translate("%%MISSION_NO_DEADLINE")


func _build(now: float) -> void:
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 0)
	add_child(row)

	var band := FacetPattern.new()
	band.colour = giver.colour()
	band.seed_text = str(mission.get("id", mission.get("title", "")))
	band.custom_minimum_size = Vector2(BASE_SIZE.x * BAND_SHARE * zoom, 0)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(band)
	var badges := VBoxContainer.new()
	badges.set_anchors_preset(Control.PRESET_FULL_RECT)
	badges.alignment = BoxContainer.ALIGNMENT_CENTER
	badges.add_theme_constant_override("separation", int(10 * zoom))
	badges.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.add_child(badges)
	var logo := giver.logo_control(LOGO_PX * zoom)
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_whiten(logo)  # on the giver's own colour, the logo reads in white
	badges.add_child(logo)
	var icon_rect := TextureRect.new()
	icon_rect.name = "CategoryIcon"
	icon_rect.texture = MissionCategories.icon(mission.get("category"))
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.custom_minimum_size = Vector2.ONE * ICON_PX * zoom
	icon_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badges.add_child(icon_rect)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, int(PAD_PX * zoom))
	row.add_child(margin)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", int(4 * zoom))
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(info)
	var title := _line(ServiceTypes.dash(mission.get("title")), TITLE_PX, TEXT)
	title.name = "Title"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.max_lines_visible = 2
	title.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info.add_child(title)
	var who := _line(giver.display_name(), LINE_PX, giver.colour())
	who.name = "Giver"
	info.add_child(who)
	var kind := _line(MissionCategories.label(mission.get("category")), LINE_PX, DIM)
	kind.name = "Category"
	info.add_child(kind)
	var reward := _line(reward_line(mission), LINE_PX, TEXT)
	reward.name = "Reward"
	info.add_child(reward)
	var deadline := _line(deadline_line(mission, now), LINE_PX, DIM)
	deadline.name = "Deadline"
	info.add_child(deadline)


func _line(text: String, font_px: int, ink: Color) -> Label:
	var line := AresBrand.screen_label(text, int(font_px * zoom), ink)
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.custom_minimum_size = Vector2(1, 0)  # may shrink: a long title is cut, not the card widened
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


## The giver's logo is drawn on its own colour: every part of it in white instead.
static func _whiten(node: Node) -> void:
	if node is CanvasItem:
		(node as CanvasItem).self_modulate = Color.WHITE
	if node is TextureRect:
		(node as TextureRect).modulate = Color.WHITE
	if node is Label:
		(node as Label).add_theme_color_override("font_color", Color.WHITE)
	for child: Node in node.get_children():
		_whiten(child)

