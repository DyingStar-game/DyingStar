class_name PoiIconRule
extends Resource

## One line of the "which picture goes with which kind of place" table.
##
## A rule is matched against a point-of-interest record from the QGIS export and, if it fits, decides
## the picture, the tint and the wording shown for it. Rules are tried in order and the first that fits
## wins, so the specific ones go above the general ones.
##
## ⚠️ Matching on the NAME is not a shortcut, it is the only thing that works today: twenty-two of the
## twenty-seven records ship with an EMPTY poi_type, and what they actually are is written in their
## name (major_railway_city_08, mining_village_02). Both routes are offered so that filling poi_type in
## later improves matters without breaking anything.

## The picture. A rule with no icon still matches — it can be used to set a wording or a tint alone.
@export var icon: Texture2D = null

## Matched against the record's poi_type, ignoring case. Empty means "do not test this".
@export var poi_type: String = ""

## Matched against the START of the record's raw name, ignoring case. Empty means "do not test this".
## A prefix rather than an exact name because the export numbers its sites: mining_village_01..04.
@export var name_prefix: String = ""

## Tint applied to the picture and to the label, so a kind of place is told apart before its name is
## readable.
@export var tint: Color = Color(1.0, 1.0, 1.0, 1.0)

## Translation key naming this kind of place, shown in the info panel. It is what lets the panel say
## "Railway city" for the twenty-two records whose own poi_type is blank. Leave empty to fall back to
## whatever the export wrote.
@export var label_key: String = ""


## Does this rule fit [param poi]? A rule that tests nothing matches everything, which is how a
## catch-all is written without a special case.
func matches(poi: Dictionary) -> bool:
	if poi_type != "" and str(poi.get("kind", "")).to_lower() != poi_type.to_lower():
		return false
	if name_prefix != "" \
			and not str(poi.get("name", "")).to_lower().begins_with(name_prefix.to_lower()):
		return false
	return true
