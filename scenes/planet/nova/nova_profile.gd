@tool
class_name NovaProfile
extends Resource
## One Nova file: the settings this level overrides, nothing else.
##
## Levels are archetype (nova/archetypes/<biome_type>.tres), body biome
## (nova/bodies/<body>/<biome_type>.tres) and variant
## (nova/bodies/<body>/<biome_type>/<variant>.tres). A key absent here is inherited from the
## level above, live: improving an archetype improves every body that did not override that key.
## Keys and kinds: see NovaSchema.

## Overridden settings, flat key → value ("ground/tile_m" → 12.0). Edited by the Nova dock.
@export var values: Dictionary = {}

## Free note for the team: why this level differs from its base.
@export_multiline var note: String = ""


## True when this level sets [param key] itself.
func has_own(key: String) -> bool:
	return values.has(key)


## This level's own value of [param key], or null.
func own(key: String) -> Variant:
	return values.get(key, null)


## Overrides [param key] at this level (coerced to its schema kind).
func set_own(key: String, value: Variant) -> void:
	values[key] = NovaSchema.coerce(key, value)
	emit_changed()


## Drops this level's override of [param key]: the value comes from the base again.
func revert(key: String) -> void:
	if values.erase(key):
		emit_changed()
