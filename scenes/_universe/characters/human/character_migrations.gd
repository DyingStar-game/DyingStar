class_name CharacterMigrations
extends RefCounted

## Brings an old CharacterDocument up to the current version, one step at a time: steps()[i] turns a document of
## version i + 1 into one of version i + 2. Each step is a pure function Dictionary -> Dictionary (it may rename a
## slider, map a removed outfit onto another, rescale a field...), so the same chain runs in the game on read and in
## tools/character/convert_characters.tscn over a whole backend export.
##
## When to add a version (CharacterDocument.VERSION + 1 and a step here):
##   - NOT for an addition: a new slider, style, outfit, origin or field with a default reads fine in old documents
##     (a missing field takes its default) and old games skip what they do not know;
##   - YES for a rename, a removal that must land on something else, or a field whose meaning or scale changes.
## A step is never removed or edited once shipped; each version keeps a frozen sample document in
## test/data/character/v<N>.json that the tests read through the whole chain.


## The steps, oldest first.
static func steps() -> Array[Callable]:
	return [outfit_to_garments]


## 1 -> 2: the character wears garments (GDD equipment), no longer one outfit. An outfit was a MakeHuman suit and
## its shoes; the catalogue lists the garments each one became (assets.outfit[i].garments), in their own colours.
static func outfit_to_garments(doc: Dictionary) -> Dictionary:
	var out: Dictionary = doc.duplicate(true)
	var outfit: String = String(out.get("outfit", ""))
	out.erase("outfit")
	var garments: Array = []
	for entry: Variant in CharacterAppearance.catalogue()["assets"].get("outfit", []):
		if entry is Dictionary and String(entry.get("id", "")) == outfit:
			for id: Variant in entry.get("garments", []):
				garments.append({"id": String(id), "tint": 0})
	out["garments"] = garments
	return out


## [param doc] at the version [param with_steps] lead to (null: the game's steps()): {"doc", "from", "to", "error"}.
## A document newer than the chain is refused (cutting what a newer game wrote would lose it silently).
static func migrate(doc: Dictionary, with_steps: Variant = null) -> Dictionary:
	var chain: Array = steps() if with_steps == null else with_steps
	var latest: int = 1 + chain.size()
	var raw: Variant = doc.get("version", 0)
	var version: int = int(raw) if raw is int or raw is float else 0
	var out: Dictionary = {"doc": doc, "from": version, "to": version, "error": ""}
	if version < 1:
		out["error"] = "no version"
		return out
	if version > latest:
		out["error"] = "version %d is newer than this game's (%d): update the game" % [version, latest]
		return out
	var current: Dictionary = doc.duplicate(true)
	while version < latest:
		current = (chain[version - 1] as Callable).call(current)
		version += 1
		current["version"] = version
	out["doc"] = current
	out["to"] = version
	return out
