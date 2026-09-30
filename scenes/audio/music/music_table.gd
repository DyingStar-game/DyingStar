class_name MusicTable
extends Resource

## The table that pairs a place with the music played there. THE one place where that is decided:
## open music_table.tres in the Inspector to see, reorder and edit every pairing of the game.
##
## The single exception is a MusicZone carrying its own playlist, for a building whose music is nobody
## else's business.

## Tried in order; the first rule that fits wins. Put the specific ones above the general ones.
## No rule fitting means silence.
@export var rules: Array[MusicRule] = []

## Seconds over which the old music fades out while the new one fades in.
@export_range(0.0, 20.0, 0.1, "suffix:s") var crossfade_s: float = 4.0

## Seconds a new situation must hold before the music follows it. Without it, pacing along the edge of
## a zone or bobbing in and out of weightlessness restarts a track at every step.
@export_range(0.0, 20.0, 0.1, "suffix:s") var settle_s: float = 2.0


## The playlist for [param context], or null for silence.
func playlist_for(context: MusicContext) -> MusicPlaylist:
	if _zone_decides(context):
		return context.zone_playlist
	var rule: MusicRule = rule_for(context)
	return rule.playlist if rule != null else null


## The rule covering [param context], or null when none does.
func rule_for(context: MusicContext) -> MusicRule:
	for rule: MusicRule in rules:
		if rule != null and rule.matches(context):
			return rule
	return null


## Why playlist_for answers what it does, in words, for the debug panel. Rules are numbered as the
## Inspector lists them, from 0.
func why(context: MusicContext) -> String:
	if _zone_decides(context):
		return "the zone's own playlist"
	var rule: MusicRule = rule_for(context)
	if rule == null:
		return "no rule fits"
	var text: String = "rule %d: %s" % [rules.find(rule), MusicRule.Situation.keys()[rule.situation]]
	return text + (" '%s'" % rule.only if rule.only != "" else "")


func _zone_decides(context: MusicContext) -> bool:
	return not context.in_menu and context.zone_playlist != null
