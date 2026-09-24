class_name LanguageSettings
extends RefCounted
## The display language: which one is in use, and how "follow the OS" resolves to a real one.
##
## Split out of SettingsManager, which already owns video, audio, debug toggles and keybindings and
## had reached the point where one more setting pushed it over the linter's public-method ceiling.
## That ceiling was the symptom; the cause is that "where settings are stored" and "what a language
## is" are two jobs.
##
## It does NOT own storage. The ConfigFile and the save call are handed in, so there is still exactly
## one settings file and one writer — precisely what the old tools/localization/localization_manager
## got wrong by keeping its own user://settings.json beside user://settings.ini.

## Emitted after the language changed, for text built by SCRIPT. A Control whose text is set in the
## scene re-reads itself on NOTIFICATION_TRANSLATION_CHANGED and needs nothing; a label assigned once
## from code would keep the old language until something else rewrote it.
signal changed(language: String)

## The languages we ship: code -> the language written in ITS OWN words, in the order a picker should
## list them. One structure rather than a list of codes beside a table of names: two edits per
## language is one edit too many, and they drift.
##
## The names are never translated, on purpose — someone who picked a language they cannot read must
## still recognise their own and find the way back.
##
## "auto" is deliberately absent: it is a CHOICE, not a language, and resolve() turns it into one.
const LANGUAGES : Dictionary = {"en": "English", "fr": "Français"}
## Follow the OS. Stored as this rather than as the language it resolves to today.
const AUTO : String = "auto"
## Used both when the OS speaks a language we do not ship and when a stored code is no longer valid.
const FALLBACK : String = "en"
const SECTION : String = "general"
const KEY : String = "language"

var _config : ConfigFile
var _save : Callable


func _init(config: ConfigFile, save: Callable) -> void:
	_config = config
	_save = save


## The player's CHOICE: AUTO, or a code from LANGUAGES. Stored as chosen rather than as the language
## it currently resolves to — saving the resolved code would pin someone who picked "auto" to
## whatever their OS happened to say the day they first launched the game.
func choice() -> String:
	return _config.get_value(SECTION, KEY, AUTO)


## The language actually in use. Resolves AUTO against the OS and falls back for anything we do not
## ship. OS.get_locale_language() gives the bare code ("fr" out of "fr_CA"), so a Canadian French
## system lands on French rather than on the fallback.
func resolve() -> String:
	var picked : String = choice()
	if picked != AUTO:
		return picked if LANGUAGES.has(picked) else FALLBACK
	var system : String = OS.get_locale_language()
	return system if LANGUAGES.has(system) else FALLBACK


## Persist the choice and apply it live, so the menus switch under the player's eyes.
func select(picked: String) -> void:
	if choice() == picked:
		return
	_config.set_value(SECTION, KEY, picked)
	_save.call()
	apply()
	changed.emit(resolve())


## Hand the resolved language to the engine. Called at boot as well as on every change: a setting
## loaded but never applied reads exactly like one that did not persist.
func apply() -> void:
	TranslationServer.set_locale(resolve())
