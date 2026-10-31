class_name PlaceNameRule
extends RefCounted
## What a player may propose as the name of a place they discovered (Discovery): the same rule on the client,
## which says what is wrong before sending, and on the server, which never trusts the client.
##
## Letters of any alphabet (accents included), digits, spaces, apostrophes and hyphens, 3 to 40 of them once
## the spaces are tidied. ARES (the admins) still reads every name before it is published.

const MIN_LENGTH := 3
const MAX_LENGTH := 40

static var _allowed: RegEx = null


## [param raw] with its edges trimmed and every run of spaces made one.
static func clean(raw: String) -> String:
	var words := PackedStringArray()
	for word in raw.strip_edges().split(" ", false):
		words.append(word)
	return " ".join(words)


## Why [param raw] cannot be proposed, as a translation key, or "" when it can.
static func error_key(raw: String) -> String:
	var name := clean(raw)
	if name.length() < MIN_LENGTH:
		return "%%PLACE_NAME_TOO_SHORT"
	if name.length() > MAX_LENGTH:
		return "%%PLACE_NAME_TOO_LONG"
	if _allowed == null:
		_allowed = RegEx.create_from_string("^[\\p{L}\\p{N}' \\-]+$")
	if _allowed.search(name) == null:
		return "%%PLACE_NAME_BAD_CHARACTERS"
	return ""
