#extends Label
extends RichTextLabel


@export var scroll_speed := 20.0  # px/s, identique quel que soit le nombre de zones
@export var pause := 3.0          # secondes en haut et en bas


@onready var _scroll: ScrollContainer = get_parent()


var _tween: Tween
var _max_scroll := -1


func _ready() -> void:
	visible = false
	# Connected once, for the panel's whole life: the value is known the moment the panel is shown
	# (the F8 capture shows it for one frame), and hiding it no longer tries to disconnect a
	# callable that was never connected (nor showing it to connect the same one twice).
	NetworkOrchestrator.set_gameserver_zones.connect(_set_gameserver_zones)

## INFO Original Version
## One line per zone of the Godot server simulating us: its world (space or a planet) and, when
## the zone is only part of that world, its bounds in that world's coordinates.
#func _set_gameserver_zones(zones):
	#var lines: PackedStringArray = []
	#for zone in zones:
		#var label: String = str(zone.get("world", "?"))
		#if label == "planet":
			#label += " " + str(zone.get("planet_name", zone.get("planet_uuid", "?")))
		#var b = zone.get("bounds")
		#if b == null:
			#label += " (whole)"
		#else:
			#label += "\n  X: %.0f .. %.0f\n  Y: %.0f .. %.0f\n  Z: %.0f .. %.0f" % [
				#b["min_x"], b["max_x"], b["min_y"], b["max_y"], b["min_z"], b["max_z"]]
		#lines.append(label)
	#text = "\n".join(lines)


func _process(_delta: float) -> void:
	var max_scroll := maxi(0, get_content_height() - int(_scroll.size.y))
	if max_scroll == _max_scroll:
		return  # rien n'a changé : le défilement en cours continue
	_max_scroll = max_scroll
	_rebuild_tween()


func _rebuild_tween() -> void:
	if _tween:
		_tween.kill()
	_scroll.scroll_vertical = 0
	if _max_scroll <= 0:
		return  # tout tient, pas besoin de défiler
	var duration := _max_scroll / scroll_speed
	_tween = create_tween().set_loops()
	_tween.tween_interval(pause)
	_tween.tween_property(_scroll, "scroll_vertical", _max_scroll, duration)
	_tween.tween_interval(pause)
	_tween.tween_property(_scroll, "scroll_vertical", 0, duration)


func _full(v: float) -> String:
	var s := str(int(absf(v)))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += " "
		out += s[i]
	return ("-" if v < 0.0 else "") + out


func _axis_row(axis: String, lo: float, hi: float) -> String:
	return "[cell][color=#888]%s[/color][/cell][cell][right]%s[/right][/cell][cell][right]%s[/right][/cell]" % [axis, _full(lo), _full(hi)]


func _set_gameserver_zones(zones):
	var blocks := PackedStringArray()
	for zone in zones:
		var label := str(zone.get("world", "?"))
		label.replace("[", "[lb]")
		if label == "planet":
			label += " " + str(zone.get("planet_name", zone.get("planet_uuid", "?")))
		var b = zone.get("bounds")
		if b == null:
			blocks.append("[color=#ffd75e]%s[/color] (whole)" % label)
		else:
			blocks.append("[color=#ffd75e]%s[/color]\n[table=3]%s%s%s[/table]" % [
				label,
				_axis_row("X", b.get("min_x", 0.0), b.get("max_x", 0.0)),
				_axis_row("Y", b.get("min_y", 0.0), b.get("max_y", 0.0)),
				_axis_row("Z", b.get("min_z", 0.0), b.get("max_z", 0.0))])
	
	var new_text := "\n".join(blocks)
	if new_text != text:
		text = new_text


func _on_normal_player_display_debug(show: bool) -> void:
	visible = show
