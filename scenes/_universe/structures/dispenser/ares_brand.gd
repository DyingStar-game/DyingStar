class_name AresBrand
extends RefCounted

## The ARES corporation and its subsidiaries as the player sees them: each its own colour, its name
## under the ARES mark. ONE place for them — a machine says which subsidiary runs it (ItemDispenser
## .brand), and its screen, its lights and its logo take their colours from here, never from a copy.
## Brand names are proper nouns, shown as they are in every language (like the logo itself).

enum Subsidiary { CORP, HAULING, MINING, SCIENCE, SECURITY, LIVING, MACHINERY, ENERGY, PHARMA }

## Read off the brand sheet (2026-10-13).
const COLOURS: Dictionary = {
	Subsidiary.CORP: Color(1.0, 1.0, 1.0),
	Subsidiary.HAULING: Color(1.0, 0.8, 0.0),
	Subsidiary.MINING: Color(1.0, 0.4, 0.0),
	Subsidiary.SCIENCE: Color(0.0, 0.5, 1.0),
	Subsidiary.SECURITY: Color(0.7, 0.05, 0.0),
	Subsidiary.LIVING: Color(0.7, 0.0, 0.7),
	Subsidiary.MACHINERY: Color(0.6, 0.0, 1.0),
	Subsidiary.ENERGY: Color(0.0, 0.47, 0.0),
	Subsidiary.PHARMA: Color(0.0, 1.0, 1.0),
}
const NAMES: Dictionary = {
	Subsidiary.CORP: "CORP.",
	Subsidiary.HAULING: "HAULING",
	Subsidiary.MINING: "MINING",
	Subsidiary.SCIENCE: "SCIENCE",
	Subsidiary.SECURITY: "SECURITY",
	Subsidiary.LIVING: "LIVING",
	Subsidiary.MACHINERY: "MACHINERY",
	Subsidiary.ENERGY: "ENERGY",
	Subsidiary.PHARMA: "PHARMA.",
}


## The colour of [param subsidiary].
static func colour(subsidiary: Subsidiary) -> Color:
	return COLOURS.get(subsidiary, Color.WHITE)


## The name of [param subsidiary], under ARES in its logo ("MINING").
static func name_of(subsidiary: Subsidiary) -> String:
	return str(NAMES.get(subsidiary, ""))


## The brand's font (Xolonium, the game's own), or null when it is missing (the default one then).
static func font() -> Font:
	return load(FONT_PATH) if ResourceLoader.exists(FONT_PATH) else null


# -- The logo ------------------------------------------------------------------------------------------
# The ARES mark (the CORP. logo with CORP. taken out, MARK_PATH) tinted, and the subsidiary's name
# written where CORP. was, in the game's font: the brand sheet's layout.

## The emblem and the word ARES, white on transparent: 431 x 146 px, CORP.'s place left empty.
const MARK_PATH: String = "res://assets/textures/decals/ares_logo/ares_logo_mark.png"
const FONT_PATH: String = "res://assets/fonts/Xolonium/Xolonium-Regular.ttf"
const MARK_SIZE := Vector2(431, 146)
## Where the name goes in the mark (px): CORP.'s place, under ARES; and its cap height.
const NAME_AT := Vector2(140, 92)
const NAME_CAP_PX: float = 44.0
## A font size whose capitals stand NAME_CAP_PX high, per pixel of cap: Xolonium's caps are ~0.7 em.
const CAP_TO_SIZE: float = 1.0 / 0.7


## The logo of [param subsidiary] for a screen, [param height] px high.
static func logo_control(subsidiary: Subsidiary, height: float) -> Control:
	var scale: float = height / MARK_SIZE.y
	var box := Control.new()
	box.custom_minimum_size = MARK_SIZE * scale
	var mark := TextureRect.new()
	mark.texture = load(MARK_PATH)
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.size = MARK_SIZE * scale
	mark.modulate = colour(subsidiary)
	box.add_child(mark)
	var label := Label.new()
	label.text = name_of(subsidiary)
	label.position = Vector2(NAME_AT.x, NAME_AT.y - NAME_CAP_PX * 0.25) * scale
	label.add_theme_font_size_override("font_size", int(NAME_CAP_PX * CAP_TO_SIZE * scale))
	label.add_theme_color_override("font_color", colour(subsidiary))
	if font() != null:
		label.add_theme_font_override("font", font())
	box.add_child(label)
	return box


## The logo of [param subsidiary] in the world, [param height] m high, centred, facing +Z.
static func logo_3d(subsidiary: Subsidiary, height: float) -> Node3D:
	var px: float = height / MARK_SIZE.y  # metres per pixel of the mark
	var mark := Sprite3D.new()
	mark.name = "AresLogo"
	mark.texture = load(MARK_PATH)
	mark.pixel_size = px
	mark.modulate = colour(subsidiary)
	mark.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	var label := Label3D.new()
	label.text = name_of(subsidiary)
	label.modulate = colour(subsidiary)
	label.outline_size = 0
	label.pixel_size = px
	label.font_size = int(NAME_CAP_PX * CAP_TO_SIZE)
	label.font = font()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	# The sprite is centred on its texture: from its centre to CORP.'s place, y up.
	label.position = Vector3(NAME_AT.x - MARK_SIZE.x * 0.5, MARK_SIZE.y * 0.5 - NAME_AT.y + NAME_CAP_PX * 0.25, 0.001) * px
	mark.add_child(label)
	return mark
