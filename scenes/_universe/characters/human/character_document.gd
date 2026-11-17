class_name CharacterDocument
extends RefCounted

## A character's look as a lasting JSON document: what the backend keeps, what a player exports or imports.
## Unlike the replicated string (CharacterAppearance.encode: positions in the catalogue, for the network), every
## choice here is named -- a slider by its key, a hair style, a beard, eyebrows, a garment or an eye colour by its
## catalogue id, an origin by its name, a parting / tie / beard shape by its enum name -- so a reordered or pruned
## catalogue never turns a saved character into someone else.
##
##   {"format": "dyingstar.character", "version": 1, "written_by": "<game version>",
##    "body": {gender, age, height}, "origins": {name: weight}, "skin": {tone, warmth, dimples, freckles, ...},
##    "eyes": {"colour": id}, "hair": {style, eumelanin, pheomelanin, grey, length, "cut": {..., part, tie}},
##    "eyebrows": id, "eyelashes": id, "beard": {style, length, "cut": {..., shape}},
##    "garments": [{"id": id, "tint": 0..255}, ...], "sliders": {key: value}}
##
## Version 2 wears garments; version 1 had one "outfit" (CharacterMigrations turns it into its garments).
##
## Values are floats rounded to 1e-3 (every one lives on a byte grid: k / 255 or k / 127, which 1e-3 keeps
## exactly), origins and sliders at 0 are left out. Reading is forgiving: a missing field takes its default, an
## unknown name (a slider or a style since removed) is skipped with a warning; only a document of another format or
## of a NEWER version than this game is refused. An older version goes through CharacterMigrations first.

const FORMAT: String = "dyingstar.character"
## The document's current version: 1 + CharacterMigrations.steps().size() (a test holds them together).
const VERSION: int = 2
## Decimals kept on every value.
const DECIMALS: float = 1000.0
const HAIR_CUT_FIELDS: Array[String] = ["length", "sides", "volume", "curl", "density", "fringe", "recession",
		"crown_bald", "low_line", "flyaways"]
const BEARD_CUT_FIELDS: Array[String] = ["moustache", "chin", "cheeks", "neck", "length", "density", "connect"]


## The document of [param look] (canonicalised first).
static func to_document(look: CharacterAppearance) -> Dictionary:
	look.canonicalise()
	var cat: Dictionary = CharacterAppearance.catalogue()
	var body: Dictionary = {}
	for m: String in HumanMacros.MACROS:
		body[m] = _r(look.macros[m])
	var origins: Dictionary = {}
	for i in CharacterAppearance.ORIGINS:
		if look.origins[i] > 0.0 and i < (cat["origins"] as Array).size():
			origins[String(cat["origins"][i])] = _r(look.origins[i])
	var skin: Dictionary = {"tone": _r(look.skin_tone), "warmth": _r(look.skin_warmth), "dimples": _r(look.dimples)}
	for detail: StringName in CharacterAppearance.SKIN_DETAILS:
		skin[String(detail)] = _r(look.get(detail))
	var hair_cut: Dictionary = {}
	for field in HAIR_CUT_FIELDS:
		hair_cut[field] = _r(look.cut.get(field))
	hair_cut["part"] = HairCut.Part.keys()[look.cut.part]
	hair_cut["tie"] = HairCut.Tie.keys()[look.cut.tie]
	var beard_cut: Dictionary = {}
	for field in BEARD_CUT_FIELDS:
		beard_cut[field] = _r(look.beard_cut.get(field))
	beard_cut["shape"] = BeardCut.Shape.keys()[look.beard_cut.shape]
	var sliders: Dictionary = {}
	var ids: Array = look.modifiers.keys()
	ids.sort()
	for id: int in ids:
		sliders[String(cat["modifiers"][id]["key"])] = _r(look.modifiers[id])
	return {
		"format": FORMAT, "version": VERSION,
		"written_by": str(ProjectSettings.get_setting("application/config/version", "")),
		"body": body, "origins": origins, "skin": skin,
		"eyes": {"colour": _id(cat["eye_colours"], look.eye_colour)},
		"hair": {"style": _asset("hair", look.hair), "eumelanin": _r(look.hair_eumelanin),
				"pheomelanin": _r(look.hair_pheomelanin), "grey": _r(look.hair_grey), "length": _r(look.hair_length),
				"cut": hair_cut},
		"eyebrows": _asset("eyebrows", look.eyebrows), "eyelashes": _asset("eyelashes", look.eyelashes),
		"beard": {"style": _asset("beard", look.beard), "length": _r(look.beard_length), "cut": beard_cut},
		"garments": _garments(look),
		"sliders": sliders,
	}


## [param doc] read back: {"look": CharacterAppearance or null, "from": the version it was written in,
## "warnings": Array of String (names skipped...), "error": "" or why it was refused}.
## [param with_steps]: CharacterMigrations.migrate's (null: the game's).
static func from_document(doc: Variant, with_steps: Variant = null) -> Dictionary:
	var out: Dictionary = {"look": null, "from": 0, "warnings": [], "error": ""}
	if not doc is Dictionary or String((doc as Dictionary).get("format", "")) != FORMAT:
		out["error"] = "not a %s document" % FORMAT
		return out
	var migrated: Dictionary = CharacterMigrations.migrate(doc, with_steps)
	out["from"] = migrated["from"]
	if migrated["error"] != "":
		out["error"] = migrated["error"]
		return out
	var d: Dictionary = migrated["doc"]
	var warnings: Array = out["warnings"]
	var cat: Dictionary = CharacterAppearance.catalogue()
	var look := CharacterAppearance.new()
	var body: Dictionary = _dict(d, "body")
	for m: String in HumanMacros.MACROS:
		look.macros[m] = _f(body, m, look.macros[m])
	var origins: Dictionary = _dict(d, "origins")
	for origin: Variant in origins:
		var i: int = (cat["origins"] as Array).find(String(origin))
		if i < 0 or i >= CharacterAppearance.ORIGINS:
			warnings.append("unknown origin '%s'" % origin)
			continue
		look.origins[i] = _f(origins, origin, 0.0)
	var skin: Dictionary = _dict(d, "skin")
	look.skin_tone = _f(skin, "tone", look.skin_tone)
	look.skin_warmth = _f(skin, "warmth", look.skin_warmth)
	look.dimples = _f(skin, "dimples", look.dimples)
	for detail: StringName in CharacterAppearance.SKIN_DETAILS:
		look.set(detail, _f(skin, String(detail), look.get(detail)))
	look.eye_colour = _find(cat["eye_colours"], _dict(d, "eyes").get("colour"), "eye colour", warnings)
	var hair: Dictionary = _dict(d, "hair")
	look.hair = _find_asset("hair", hair.get("style"), warnings)
	look.hair_eumelanin = _f(hair, "eumelanin", look.hair_eumelanin)
	look.hair_pheomelanin = _f(hair, "pheomelanin", look.hair_pheomelanin)
	look.hair_grey = _f(hair, "grey", look.hair_grey)
	look.hair_length = _f(hair, "length", look.hair_length)
	var hair_cut: Dictionary = _dict(hair, "cut")
	for field in HAIR_CUT_FIELDS:
		look.cut.set(field, _f(hair_cut, field, look.cut.get(field)))
	look.cut.part = _enum(HairCut.Part, hair_cut.get("part"), look.cut.part, "parting", warnings)
	look.cut.tie = _enum(HairCut.Tie, hair_cut.get("tie"), look.cut.tie, "tie", warnings)
	look.eyebrows = _find_asset("eyebrows", d.get("eyebrows"), warnings)
	look.eyelashes = _find_asset("eyelashes", d.get("eyelashes"), warnings)
	var beard: Dictionary = _dict(d, "beard")
	look.beard = _find_asset("beard", beard.get("style"), warnings)
	look.beard_length = _f(beard, "length", look.beard_length)
	var beard_cut: Dictionary = _dict(beard, "cut")
	for field in BEARD_CUT_FIELDS:
		look.beard_cut.set(field, _f(beard_cut, field, look.beard_cut.get(field)))
	look.beard_cut.shape = _enum(BeardCut.Shape, beard_cut.get("shape"), look.beard_cut.shape, "beard shape", warnings)
	var worn: Variant = d.get("garments")
	for g: Variant in (worn if worn is Array else []):
		var id: String = String((g as Dictionary).get("id", "")) if g is Dictionary else String(g)
		var i: int = CharacterAppearance.garment_index(id)
		if i == -1:
			warnings.append("unknown garment '%s'" % id)
			continue
		var tint: Variant = (g as Dictionary).get("tint", 0) if g is Dictionary else 0
		look.garments.append([i, int(tint) if tint is int or tint is float else 0])
	var sliders: Dictionary = _dict(d, "sliders")
	for key: Variant in sliders:
		var id: int = CharacterAppearance.modifier_id(String(key))
		if id < 0:
			warnings.append("unknown slider '%s'" % key)
			continue
		look.modifiers[id] = _f(sliders, key, 0.0)
	look.canonicalise()
	out["look"] = look
	return out


## A look from text a player or the backend gives: a document (JSON), or the replicated string of any version
## CharacterAppearance.decode reads (an old save or a shared code). Same result as from_document; "from" is
## the document version, or "compact v<N>" for a replicated string.
static func parse(text: String) -> Dictionary:
	var trimmed: String = text.strip_edges()
	if trimmed.begins_with("{"):
		var json := JSON.new()
		if json.parse(trimmed) != OK:
			return {"look": null, "from": 0, "warnings": [],
					"error": "not JSON: %s (line %d)" % [json.get_error_message(), json.get_error_line()]}
		return from_document(json.data)
	var look: CharacterAppearance = CharacterAppearance.decode(trimmed)
	if look == null:
		return {"look": null, "from": 0, "warnings": [], "error": "neither a document nor a look code"}
	var version: int = Marshalls.base64_to_raw(_padded(trimmed))[0]
	return {"look": look, "from": "compact v%d" % version, "warnings": [], "error": ""}


## The document as text (keys sorted: the same look always writes the same bytes).
static func stringify(doc: Dictionary) -> String:
	return JSON.stringify(doc, "\t", true)


static func _r(v: Variant) -> float:
	return roundf(float(v) * DECIMALS) / DECIMALS


static func _id(list: Array, slot: int) -> String:
	if slot < 0 or slot >= list.size():
		return ""
	var entry: Variant = list[slot]
	return String(entry["id"]) if entry is Dictionary else String(entry)


static func _garments(look: CharacterAppearance) -> Array:
	var entries: Array = CharacterAppearance.garment_entries()
	var out: Array = []
	for g: Array in look.garments:
		out.append({"id": String(entries[g[0]]["id"]), "tint": int(g[1])})
	return out


static func _asset(kind: String, slot: int) -> String:
	return _id(CharacterAppearance.catalogue()["assets"].get(kind, []), slot)


static func _find(list: Array, name: Variant, what: String, warnings: Array) -> int:
	if name == null:
		return 0
	for i in list.size():
		if _id(list, i) == String(name):
			return i
	warnings.append("unknown %s '%s'" % [what, name])
	return 0


static func _find_asset(kind: String, name: Variant, warnings: Array) -> int:
	return _find(CharacterAppearance.catalogue()["assets"].get(kind, []), name, kind, warnings)


static func _enum(values: Dictionary, name: Variant, fallback: int, what: String, warnings: Array) -> int:
	if name == null:
		return fallback
	if values.has(String(name)):
		return int(values[String(name)])
	warnings.append("unknown %s '%s'" % [what, name])
	return fallback


static func _dict(d: Dictionary, key: String) -> Dictionary:
	var v: Variant = d.get(key)
	return v if v is Dictionary else {}


static func _f(d: Dictionary, key: Variant, fallback: Variant) -> float:
	var v: Variant = d.get(key)
	return float(v) if v is float or v is int else float(fallback)


static func _padded(text: String) -> String:
	var b64: String = text.replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	return b64
