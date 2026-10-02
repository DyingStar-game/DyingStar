class_name PoiIconSet
extends Resource

## The table that pairs a kind of place with the picture the chart draws for it.
##
## Lives as a [code].tres[/code] so that pairing a new picture with a new kind of site is an edit in the
## inspector, not a code change — the artwork and the level design both move faster than this screen
## does, and neither should have to wait on it.

## Tried in order; the first rule that fits wins. Put the specific ones above the general ones.
@export var rules: Array[PoiIconRule] = []

## Used when no rule fits, so an unforeseen kind of site is still drawn and still clickable rather than
## silently absent — an absent marker looks exactly like a bug in the export.
@export var fallback_icon: Texture2D = null
## Tint of the fallback icon, used when no rule fits a place.
@export var fallback_tint: Color = Color(0.82, 0.86, 0.92, 1.0)

## Drawn for several places too close on screen to tell apart, with their number beside it. Of no kind
## in particular, so no rule can supply it.
@export var cluster_icon: Texture2D = null


## The rule covering [param poi], or null when none does.
func rule_for(poi: Dictionary) -> PoiIconRule:
	for rule: PoiIconRule in rules:
		if rule != null and rule.matches(poi):
			return rule
	return null


func icon_for(poi: Dictionary) -> Texture2D:
	var rule: PoiIconRule = rule_for(poi)
	if rule != null and rule.icon != null:
		return rule.icon
	return fallback_icon


## The group picture, or the fallback one while none is set: a group still has to be drawn.
func cluster_picture() -> Texture2D:
	return cluster_icon if cluster_icon != null else fallback_icon


func tint_for(poi: Dictionary) -> Color:
	var rule: PoiIconRule = rule_for(poi)
	return rule.tint if rule != null else fallback_tint


## What to call this kind of place. The rule's wording wins over the export's own poi_type, because the
## export leaves it blank far more often than it fills it in.
func kind_label(poi: Dictionary) -> String:
	var rule: PoiIconRule = rule_for(poi)
	if rule != null and rule.label_key != "":
		return tr(rule.label_key)
	var written: String = str(poi.get("kind", "")).strip_edges()
	return StarMapPoi.pretty_name(written) if written != "" else ""
