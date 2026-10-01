class_name PerfLabel
extends RichTextLabel
## The frame rate and the GPU time, green / yellow / red, refreshed four times a second: what an
## option costs, read without leaving the page. The text is PerfReadout's, the in-game panel's line.
##
## A node of its own so it can stand anywhere and keep itself current: it sits at the end of the
## settings' tab row, on every tab, where it used to be the first line of the Graphics tab only.

## How often the line is refreshed.
const PERIOD_S : float = 0.25


func _init(font_size: int = SettingsStyle.FONT_SIZE) -> void:
	bbcode_enabled = true
	fit_content = true
	autowrap_mode = TextServer.AUTOWRAP_OFF
	scroll_active = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Figures and units, nothing to translate.
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	add_theme_font_override("normal_font", SettingsRowFactory.FONT)
	add_theme_font_size_override("normal_font_size", font_size)


func _ready() -> void:
	var timer := Timer.new()
	timer.wait_time = PERIOD_S
	timer.autostart = true
	timer.timeout.connect(refresh)
	add_child(timer)
	refresh()


func refresh() -> void:
	text = "\n".join(PerfReadout.lines())
