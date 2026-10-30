class_name CaveWorkbenchTheme
extends RefCounted
## One palette for authoring windows only; never changes the game's theme.

const INK := Color("e3edf4")
const MUTED := Color("97abba")
const ACCENT := Color("61dcc3")


static func create() -> Theme:
    var theme := Theme.new()
    theme.default_font_size = 15
    for type in ["Label", "Button", "LineEdit", "OptionButton", "CheckButton", "ItemList", "TabContainer"]:
        theme.set_color("font_color", type, INK)
    theme.set_stylebox("panel", "PanelContainer", box("111d29", 12, 18))
    theme.set_stylebox("panel", "TabContainer", box("172634", 8, 12))
    theme.set_stylebox("tab_selected", "TabContainer", box("28434b", 6, 12))
    theme.set_stylebox("tab_unselected", "TabContainer", box("111d29", 6, 12))
    theme.set_color("font_selected_color", "TabContainer", ACCENT)
    for type in ["Button", "OptionButton"]:
        theme.set_stylebox("normal", type, box("243646", 7, 10))
        theme.set_stylebox("hover", type, box("345666", 7, 10))
        theme.set_stylebox("pressed", type, box("286b63", 7, 10))
        theme.set_stylebox("disabled", type, box("182633", 7, 10))
        theme.set_stylebox("focus", type, outline())
        theme.set_color("font_disabled_color", type, Color("667a88"))
    for type in ["LineEdit", "ItemList"]:
        theme.set_stylebox("normal" if type == "LineEdit" else "panel", type, box("0d1823", 6, 9))
        theme.set_stylebox("focus", type, outline())
        theme.set_color("font_selected_color", type, INK)
        theme.set_color("selection_color", type, Color("286b63"))
    theme.set_stylebox("selected", "ItemList", box("286b63", 4, 6))
    theme.set_stylebox("selected_focus", "ItemList", box("286b63", 4, 6))
    theme.set_constant("v_separation", "ItemList", 10)
    theme.set_constant("separation", "VBoxContainer", 10)
    theme.set_constant("separation", "HBoxContainer", 10)
    return theme


static func box(colour: String, radius: int, padding: int) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = Color(colour)
    style.set_corner_radius_all(radius)
    style.content_margin_left = padding
    style.content_margin_right = padding
    style.content_margin_top = padding
    style.content_margin_bottom = padding
    return style


static func outline() -> StyleBoxFlat:
    var style := box("00000000", 7, 0)
    style.set_border_width_all(2)
    style.border_color = ACCENT
    return style
