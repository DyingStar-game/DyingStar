extends GutTest
## Settings > Graphics: the gallery first (screenshots, videos), then the display lines, then the
## generated rendering options. SettingsManager.render is swapped for a throwaway model, so nothing
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


func test_display_follows_and_the_rendering_options_close_the_page() -> void:
	assert_eq((_rows.get_child(1) as Label).text, "%%MENU_GFX_SECTION_DISPLAY", "Display right after the gallery")
	var last : Node = _rows.get_child(_rows.get_child_count() - 1)
	assert_gt(last.find_children("*", "OptionButton", true, false).size(), 10, "the generated options last")
