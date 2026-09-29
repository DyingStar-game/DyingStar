class_name ReadoutSection
extends OverlaySection
## A section of text lines read from somewhere else: `lines` is a Callable returning them (bbcode
## allowed), called at every refresh. The section knows how to show text; what the text says is the
## provider's business — so a readout is a pure function, testable without a panel.

enum Tone { BODY, ALERT }

var tone : Tone
var _lines : Callable
## Called every frame while shown, for a provider that must measure continuously (the vehicle's
## acceleration window) even though its text refreshes less often.
var _ticker : Callable
var _text : RichTextLabel = null


func _init(p_title_key: String, lines: Callable, p_period_s: float, gate: Callable = Callable(),
		p_tone: Tone = Tone.BODY, ticker: Callable = Callable()) -> void:
	super(p_title_key, gate, p_period_s)
	_lines = lines
	tone = p_tone
	_ticker = ticker


func text() -> String:
	return "" if _text == null else _text.text


func refresh() -> void:
	if _text != null:
		_text.text = "\n".join(PackedStringArray(_lines.call()))


func tick(delta: float) -> void:
	if _ticker.is_valid():
		_ticker.call(delta)
	super(delta)


func _build_content(content: VBoxContainer, factory: SettingsRowFactory) -> void:
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.mouse_filter = Control.MOUSE_FILTER_PASS
	# The lines are built with tr() and numbers: nothing left for the label to translate.
	_text.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_text.add_theme_font_override("normal_font", SettingsRowFactory.FONT)
	_text.add_theme_font_size_override("normal_font_size", factory.control_size if factory.control_size > 0 else 14)
	if tone == Tone.ALERT:
		_text.add_theme_color_override("default_color", SettingsStyle.ALERT_COLOR)
	content.add_child(_text)
