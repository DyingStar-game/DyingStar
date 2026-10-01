extends GutTest
## Settings > Graphics: the gallery first (screenshots, videos), the benchmark, the display
## lines and the generated rendering options. (The main menu's Scene section, with its hour, needs a
## live stage: absent here.) SettingsManager.render is swapped for a throwaway model, so nothing
## reaches the real user://settings.ini.

const PAGE : PackedScene = preload("res://ui/settings_page/graphical_page/graphical_settings_page.tscn")

var _real_render : RenderSettings
var _rows : VBoxContainer


func before_each() -> void:
	_real_render = SettingsManager.render
	var render := RenderSettings.new(ConfigFile.new(), func() -> void: pass, {"method": "forward_plus"})
	render.ensure_initialized(false)
	SettingsManager.render = render
	var page : Control = PAGE.instantiate()
	add_child_autofree(page)
	_rows = page.get_node("ScrollContainer/MarginContainer/VBoxContainer")


func after_each() -> void:
	SettingsManager.render = _real_render


func test_the_gallery_comes_first_with_two_folders() -> void:
	var gallery : Node = _rows.get_child(0)
	assert_eq((gallery.get_child(0) as Label).text, "%%MENU_GFX_SECTION_GALLERY", "the Gallery heading")
	var opens : Array[Node] = gallery.find_children("*", "Button", true, false)
	assert_eq(opens.size(), 2, "one Open button per folder")
	var captions : Array = gallery.find_children("*", "Label", true, false).map(func(l: Label) -> String: return l.text)
	assert_has(captions, "%%MENU_GALLERY_SCREENSHOTS", "screenshots")
	assert_has(captions, "%%MENU_GALLERY_VIDEOS", "videos")


func test_the_benchmark_follows_the_gallery_and_says_why_it_cannot_run_here() -> void:
	var benchmark : Node = _rows.get_child(1)
	assert_eq((benchmark.get_child(0) as Label).text, "%%MENU_GFX_SECTION_BENCHMARK", "the Benchmark heading")
	var buttons : Array[Node] = benchmark.find_children("*", "Button", true, false)
	assert_eq(buttons.size(), 2, "Run, and Open folder")
	var run : Button = buttons[0] as Button
	assert_true(run.disabled, "no player in a test: nothing to measure")
	var tip : String = run.tooltip_text.replace("\n", " ")
	assert_string_contains(tip, tr("%%MENU_BENCH_WHY_UNAVAILABLE"), "the tooltip says why")
	assert_false((buttons[1] as Button).disabled, "the reports folder opens any time")


func test_display_follows_and_the_rendering_options_close_the_page() -> void:
	assert_eq((_rows.get_child(2) as Label).text, "%%MENU_GFX_SECTION_DISPLAY", "Display right after the benchmark")
	var last : Node = _rows.get_child(_rows.get_child_count() - 1)
	assert_gt(last.find_children("*", "OptionButton", true, false).size(), 10, "the generated options last")
