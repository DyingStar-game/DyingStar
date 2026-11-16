class_name CharacterSheet
extends RefCounted

## A player's character as the backend keeps it: a name, the look as a CharacterDocument, a portrait and a few
## fields to filter a list of characters by. The game writes
##
##   {"name": "...", "appearance": {CharacterDocument}, "appearance_version": 1,
##    "thumbnail": "<WebP, base64>", "filters": {"gender": "female", "age": 34, "origin": "Race_White", ...}}
##
## and the backend adds "id", "created_at" and "updated_at" (kept as they are here). Only "appearance" is the
## truth: "filters" and "thumbnail" are derived from it and written again on every save, and
## "appearance_version" repeats the document's version so the backend can find the sheets an upgrade will
## touch without reading them (tools/character/convert_characters.tscn upgrades them).

## The portrait's side (px) and WebP quality.
const THUMBNAIL_SIZE: int = 256
const THUMBNAIL_QUALITY: float = 0.8


## A sheet for [param look] named [param name], with [param thumbnail] (or none) -- [param base]'s other fields
## (id, dates...) kept.
static func make(name: String, look: CharacterAppearance, thumbnail: Image = null, base: Dictionary = {}) -> Dictionary:
	var sheet: Dictionary = base.duplicate(true)
	var doc: Dictionary = CharacterDocument.to_document(look)
	sheet["name"] = name
	sheet["appearance"] = doc
	sheet["appearance_version"] = doc["version"]
	sheet["filters"] = filters_of(look)
	if thumbnail != null:
		sheet["thumbnail"] = Marshalls.raw_to_base64(thumbnail.save_webp_to_buffer(true, THUMBNAIL_QUALITY))
	return sheet


## What a list of characters can be sorted or filtered by (more may come: always derived from the look).
static func filters_of(look: CharacterAppearance) -> Dictionary:
	var cat: Dictionary = CharacterAppearance.catalogue()
	var origin: String = ""
	var weight := 0.0
	for i in mini(look.origins.size(), (cat["origins"] as Array).size()):
		if look.origins[i] > weight:
			weight = look.origins[i]
			origin = String(cat["origins"][i])
	return {
		"gender": "female" if look.is_female() else "male",
		"age": int(roundf(look.years())),
		"origin": origin,
		"hair": CharacterDocument._asset("hair", look.hair),
		"beard": CharacterDocument._asset("beard", look.beard),
	}


## [param sheet] read: CharacterDocument.from_document's result plus "name" (and the sheet itself as "sheet").
static func read(sheet: Variant, with_steps: Variant = null) -> Dictionary:
	if not sheet is Dictionary:
		return {"look": null, "from": 0, "warnings": [], "error": "not a character sheet", "name": "", "sheet": {}}
	var out: Dictionary = CharacterDocument.from_document((sheet as Dictionary).get("appearance"), with_steps)
	out["name"] = String((sheet as Dictionary).get("name", ""))
	out["sheet"] = sheet
	return out


## [param sheet] brought to the game's version: {"sheet": the sheet with its look written again at this version
## and its filters recomputed (id, name, dates and thumbnail kept), "changed": whether it was written in an older
## version, "from", "warnings", "error" (the sheet unchanged then)}.
static func upgrade(sheet: Variant) -> Dictionary:
	var read_back: Dictionary = read(sheet)
	var from: Variant = read_back["from"]
	var out: Dictionary = {"sheet": sheet, "changed": false, "from": from, "warnings": read_back["warnings"],
			"error": read_back["error"]}
	if read_back["look"] == null:
		return out
	out["sheet"] = make(read_back["name"], read_back["look"], null, sheet)
	out["changed"] = int(from) < CharacterDocument.VERSION
	return out


## The sheet's portrait, or null.
static func thumbnail_of(sheet: Dictionary) -> Image:
	var data: PackedByteArray = Marshalls.base64_to_raw(String(sheet.get("thumbnail", "")))
	if data.is_empty():
		return null
	var image := Image.new()
	return image if image.load_webp_from_buffer(data) == OK else null
