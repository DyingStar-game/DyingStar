class_name MusicZone
extends Area3D

## A volume with its own music: a building, a room, a whole city.
##
## To use it: add an Area3D with this script, give it a CollisionShape3D covering the place, then
## EITHER write a tag and add a ZONE rule with that tag to music_table.tres (the usual way: the
## pairing stays visible in the table), OR drop a playlist here (the exception: it wins over the table).
##
## PASSIVE BY DESIGN, like ScreenZone and for the same reason: it only makes itself visible on the
## `zone` layer, and the player's own AreaDetector — the single active monitor of the game — sees it.
## MusicDirector asks that detector what it overlaps; nothing here looks for anybody.

const GROUP: StringName = &"music_zone"

## Name of this kind of place, matched by the ZONE rules of the table ("capital", "bar").
@export var tag: StringName = &""

## Optional. Set, it plays here whatever the table says.
@export var playlist: MusicPlaylist = null

## Where zones overlap — a room inside a building — the highest Priority wins. That is the Area3D's own
## property (Inspector > Area3D > Priority): nothing to declare here.


func _ready() -> void:
	collision_layer = Globals.MASK_PROBE  # the `zone` layer the player's probe scans
	collision_mask = 0  # we look for nobody
	monitoring = false
	monitorable = true
	add_to_group(GROUP)


## The zone that speaks for the player among [param areas] (what their detector overlaps), or null.
static func strongest(areas: Array) -> MusicZone:
	var best: MusicZone = null
	for area: Variant in areas:
		var zone: MusicZone = area as MusicZone
		if zone != null and (best == null or zone.priority > best.priority):
			best = zone
	return best
