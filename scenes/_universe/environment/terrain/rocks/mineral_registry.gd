class_name MineralRegistry
extends RefCounted

## Central preload registry for all MineralDef resources.
##
## Any GDScript can call MineralRegistry.get_mineral(&"gold") without knowing paths.
## No autoload needed — class_name makes it globally accessible.
##
## To add a mineral:
##   1. Create a MineralDef .tres in assets/_universe/_shared/materials/minerals/<name>/
##   2. Add a named const below.
##   3. Add an entry to ALL.
##
## NAMING: a MineralDef file is `<name>_mineraldef.tres`, its StandardMaterial3D (the preview /
## terrain material built from the same textures) `<name>_material.tres`. Both live in the same
## folder and read the same PNGs, but only the first one belongs here — the type is not visible
## from a bare `<name>.tres`, and the pair silently disagreeing is exactly how corundum ended up
## registered as a StandardMaterial3D (see has_mineral below).

# ── Ore minerals ──────────────────────────────────────────────────────────────
const GOLD       := preload("res://assets/_universe/_shared/materials/minerals/gold/gold_mineraldef.tres")
const IRON       := preload("res://assets/_universe/_shared/materials/minerals/iron/iron_mineraldef.tres")
const CRYPTONITE := preload("res://assets/_universe/_shared/materials/minerals/cryptonite/cryptonite_mineraldef.tres")

# ── Inert minerals ────────────────────────────────────────────────────────────
const BASALT    := preload("res://assets/_universe/_shared/materials/minerals/inert/basalt_mineraldef.tres")
const GRANITE   := preload("res://assets/_universe/_shared/materials/minerals/inert/granite_mineraldef.tres")
const SANDSTONE := preload("res://assets/_universe/_shared/materials/minerals/inert/sandstone_mineraldef.tres")
const CORUNDUM_PURE := preload("res://assets/_universe/_shared/materials/minerals/corindon_pure/corindon_pure_mineraldef.tres")
const CORUNDUM_SAPPHIRE := preload("res://assets/_universe/_shared/materials/minerals/corindon_saphir/corindon_saphir_mineraldef.tres")

## All registered minerals, keyed by StringName id (must match MineralDef.id).
const ALL: Dictionary = {
	&"gold":       GOLD,
	&"iron":       IRON,
	&"cryptonite": CRYPTONITE,
	&"basalt":     BASALT,
	&"granite":    GRANITE,
	&"sandstone":  SANDSTONE,
	&"corundum_pure": CORUNDUM_PURE,
	&"corundum_sapphire": CORUNDUM_SAPPHIRE,
}

## Returns the MineralDef for [param id], or GOLD with a warning when unknown.
static func get_mineral(id: StringName) -> MineralDef:
	var m: Variant = ALL.get(id)
	if m is MineralDef:
		return m as MineralDef
	if id != &"":
		push_warning("MineralRegistry: unknown mineral '%s', falling back to gold." % id)
	return GOLD

## True when [param id] names a registered mineral. Checks the TYPE, not just the key: ALL has
## held entries pointing at a plain StandardMaterial3D instead of a MineralDef, and a bare
## has() then said "yes" while get_mineral() fell back to gold — a caller trusting the pair got
## gold's 19300 kg/m3 for a rock that is not gold.
static func has_mineral(id: StringName) -> bool:
	return ALL.get(id) is MineralDef


## What a mineral dropdown should offer: everything, only the ore-bearing minerals, or only the
## barren host rocks.
enum Kind { ANY, ORE, INERT }

## Comma-joined id list for PROPERTY_HINT_ENUM, so any @tool script can turn a plain `String`
## mineral id into an inspector dropdown (see MiningZone._validate_property) without hard-coding
## the list a second time — add a mineral to ALL and every dropdown grows on its own.
## Entries that are not MineralDef resources are skipped: they cannot be classified, and offering
## one would only let a designer pick an id get_mineral() refuses.
static func enum_hint(kind: Kind = Kind.ANY) -> String:
	var ids := PackedStringArray()
	for id in ALL:
		var m: Variant = ALL[id]
		if not (m is MineralDef):
			continue
		if kind == Kind.ORE and (m as MineralDef).is_inert:
			continue
		if kind == Kind.INERT and not (m as MineralDef).is_inert:
			continue
		ids.append(String(id))
	return ",".join(ids)
