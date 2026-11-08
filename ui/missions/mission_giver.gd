class_name MissionGiver
extends Resource

## Who gives a mission, as the player sees it: a faction (and one of its divisions), its name, its
## colour and its logo. The mission service only stores two slugs (giverFaction, giverDivision); the
## game owns what they look like, here. A faction of its own is one .tres of this class in
## MissionGivers.DIR, with no code to write; the ARES subsidiaries come from AresBrand
## (AresMissionGiver) so their colours are never copied.

## The faction's slug, as the mission service stores it (giverFaction): "freeport".
@export var faction: String = ""
## The division's slug (giverDivision), "" for the faction itself.
@export var division: String = ""
## The giver's name on the screens: a translation key, or a proper noun shown as it is.
@export var name_key: String = ""
## The giver's colour: its tiles' band, its name.
@export var tint: Color = Color(0.55, 0.58, 0.63)
## The giver's logo, white on transparent (tinted with [member tint]); none = its name in its place.
@export var mark: Texture2D


## The faction's slug.
func faction_id() -> String:
	return faction


## The division's slug, "" for the faction itself.
func division_id() -> String:
	return division


## Whether this giver stands for its whole faction (a mission naming the faction but no division).
func is_faction_itself() -> bool:
	return division_id() == ""


## One string per giver ("ares/mining"), the filters' value.
func key() -> String:
	return MissionGivers.key_of(faction_id(), division_id())


func colour() -> Color:
	return tint


## The giver's name, translated when it is a key.
func display_name() -> String:
	return TranslationServer.translate(name_key) if name_key.begins_with("%%") else name_key


## The giver's logo, [param height] px high: its mark tinted, or its name when it has none.
func logo_control(height: float) -> Control:
	if mark == null:
		var word := AresBrand.screen_label(display_name(), int(height * 0.5), colour())
		word.custom_minimum_size = Vector2(0, height)
		word.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		return word
	var picture := TextureRect.new()
	picture.texture = mark
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.custom_minimum_size = Vector2(height * mark.get_width() / maxf(mark.get_height(), 1.0), height)
	picture.modulate = colour()
	return picture
