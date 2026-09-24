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
