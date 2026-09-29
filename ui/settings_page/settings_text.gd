class_name SettingsText
extends RefCounted
## Wording shared by the settings pages, so the same label does not exist twice under two keys.
##
## These return translation KEYS, not translated text. Assigning a key to a Control's `text` lets
## Godot translate it at draw time and, crucially, translate it AGAIN when the language changes —
## text translated once by hand would freeze in whatever language was active when it was written.


## The two words every toggle button shows. They were written out twelve times across two pages.
static func on_off(on: bool) -> String:
	return "%%MENU_ON" if on else "%%MENU_OFF"


## Characters on a line of a tooltip (tooltip()).
const TOOLTIP_CHARS : int = 64


## Already-translated text cut into lines of at most `width` characters, at spaces, keeping its own
## line breaks. Godot's tooltips do not wrap: a long explanation ran across the whole screen.
static func tooltip(text: String, width: int = TOOLTIP_CHARS) -> String:
	var out : PackedStringArray = []
	for paragraph in text.split("\n"):
		var line : String = ""
		for word in paragraph.split(" ", false):
			if line != "" and line.length() + 1 + word.length() > width:
				out.append(line)
				line = word
			else:
				line = word if line == "" else line + " " + word
		out.append(line)
	return "\n".join(out)
