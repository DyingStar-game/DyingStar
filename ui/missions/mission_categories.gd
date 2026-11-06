class_name MissionCategories
extends RefCounted

## A mission's category as the screens show it: its pictogram and its name. The pictogram is
## ICON_DIR/<category>.png (white on transparent, tinted by the screen); a category without one —
## a new one the service just learnt — shows FALLBACK's, so a tile never lacks its picture.

const ICON_DIR: String = "res://assets/textures/mission_categories/"
const FALLBACK: String = "generic"
## The service's names the game spells otherwise ("divers" is the client's "generic").
const ALIASES: Dictionary = {"divers": "generic"}


## The game's name for [param category] (ALIASES applied), "" when none.
static func id_of(category: Variant) -> String:
	var id: String = "" if category == null else str(category)
	return str(ALIASES.get(id, id))


## The pictogram of [param category], FALLBACK's when it has none, null when even that is missing.
static func icon(category: Variant) -> Texture2D:
	for id: String in [id_of(category), FALLBACK]:
		var path: String = ICON_DIR.path_join(id + ".png")
		if id != "" and ResourceLoader.exists(path):
			return load(path) as Texture2D
	return null


## The translated name of [param category].
static func label(category: Variant) -> String:
	return ServiceTypes.mission_category_label(category)
