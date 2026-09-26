class_name StarMapSearch
extends RefCounted

## Finding a thing on the chart by typing its name.
##
## The chart has no pan: the focus is the only thing that moves the camera, so the only way to reach a
## body is to click it — and at system scale Tarsis VIII is three pixels wide. Typing is the way out of
## that, and it is also the only way to reach a point of interest, which is not drawn at all until you
## are already close to the body carrying it.
##
## Pure functions, no nodes, so the matching can be exercised on its own.

## Ranks, best first. Exact beats prefix beats word-start beats "somewhere inside", because a player
## typing "tar" wants Tarsis before "Palaka-Tarsis Ridge".
const SCORE_EXACT: int = 0
const SCORE_PREFIX: int = 1
const SCORE_WORD: int = 2
const SCORE_INSIDE: int = 3
const NO_MATCH: int = -1

## How many results the panel shows. A list longer than this stops being faster than looking.
const MAX_RESULTS: int = 8

## Accents folded away before comparing, so "Palaka-Pital" is found by typing it without them and a
## French keyboard is never a handicap. Godot has no Unicode normalisation of its own, and the set of
## letters the game's names actually use is small and known.
const FOLD: Dictionary = {
	"à": "a", "â": "a", "ä": "a", "á": "a", "ã": "a", "å": "a",
	"ç": "c",
	"è": "e", "é": "e", "ê": "e", "ë": "e",
	"ì": "i", "í": "i", "î": "i", "ï": "i",
	"ò": "o", "ó": "o", "ô": "o", "ö": "o", "õ": "o",
	"ù": "u", "ú": "u", "û": "u", "ü": "u",
	"ñ": "n", "ý": "y", "ÿ": "y",
	"œ": "oe", "æ": "ae", "ß": "ss",
}


## Lower-cased, accent-folded, and with the separators a level designer uses in identifiers turned into
## spaces — so "mining_village_02" and "Mining village 02" are the same string to search, and a player
## can type either.
static func normalise(text: String) -> String:
	var lowered: String = text.strip_edges().to_lower()
	var out: String = ""
	for i: int in range(lowered.length()):
		var ch: String = lowered[i]
		if FOLD.has(ch):
			out += str(FOLD[ch])
		elif ch == "_" or ch == "-" or ch == ".":
			out += " "
		else:
			out += ch
	while out.contains("  "):
		out = out.replace("  ", " ")
	return out.strip_edges()


## How well [param needle] matches [param haystack], both already normalised. [constant NO_MATCH] when
## it does not.
static func score(needle: String, haystack: String) -> int:
	if needle == "" or haystack == "":
		return NO_MATCH
	if haystack == needle:
		return SCORE_EXACT
	if haystack.begins_with(needle):
		return SCORE_PREFIX
	if haystack.contains(" " + needle):
		return SCORE_WORD
	if haystack.contains(needle):
		return SCORE_INSIDE
	return NO_MATCH


## Indices of the entries matching [param query], best first, capped at [constant MAX_RESULTS].
##
## Each entry is matched on its [code]label[/code] — what the player sees — and on its optional
## [code]alt[/code], the underlying key. The alt is what lets "tarsis_3" find a body the chart calls
## "SandBox - Tarsis III": the two share not one letter, and both are names somebody might type.
static func rank(query: String, entries: Array[Dictionary]) -> Array[int]:
	var needle: String = normalise(query)
	var found: Array[int] = []
	if needle == "":
		return found
	var scored: Array[Dictionary] = []
	for i: int in range(entries.size()):
		var entry: Dictionary = entries[i]
		var label: String = normalise(str(entry.get("label", "")))
		var best: int = score(needle, label)
		var alt: int = score(needle, normalise(str(entry.get("alt", ""))))
		if alt != NO_MATCH and (best == NO_MATCH or alt < best):
			best = alt
		if best == NO_MATCH:
			continue
		# Ties are broken by the SHORTER label. Between "Tarsis I" and "Tarsis I's Ridge Station" the
		# shorter one is what somebody typing "tarsis i" meant; without this the order is arbitrary and
		# the top result changes between runs for no visible reason.
		scored.append({"index": i, "score": best, "length": label.length()})
	scored.sort_custom(_before)
	for row: Dictionary in scored:
		if found.size() >= MAX_RESULTS:
			break
		found.append(int(row["index"]))
	return found


static func _before(a: Dictionary, b: Dictionary) -> bool:
	if int(a["score"]) != int(b["score"]):
		return int(a["score"]) < int(b["score"])
	if int(a["length"]) != int(b["length"]):
		return int(a["length"]) < int(b["length"])
	# Last resort: the order they were added, so the list is stable frame to frame.
	return int(a["index"]) < int(b["index"])
