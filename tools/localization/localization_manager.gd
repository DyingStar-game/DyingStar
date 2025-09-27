extends Node

@export var dropdown: OptionButton
var localization_index: Dictionary

func _ready() -> void:
	for id in dropdown.item_count:
		localization_index[dropdown.get_item_text(id)] = id
	var language = "automatic"

	if FileAccess.file_exists("user://settings.json"):
		var file := FileAccess.open("user://settings.json", FileAccess.READ)
		var content := file.get_as_text()
		file.close()
		var json: Dictionary = JSON.parse_string(content)
		if typeof(json) != TYPE_DICTIONARY:
			print("Fichier JSON invalide")
		else :
			language = json["language"]

	if language == "automatic":
		var preferred_language = OS.get_locale_language()
		print("Set language to " + preferred_language)
		TranslationServer.set_locale(preferred_language)
		print(tr("GREET"))
		language = preferred_language
	else:
		TranslationServer.set_locale(language)

	dropdown.text = language
	dropdown.select(localization_index[language])


func _on_option_button_item_selected(index: int) -> void:
	TranslationServer.set_locale(dropdown.get_item_text(index))
	print("Language set to " + dropdown.get_item_text(index))
	var json: Dictionary
	if FileAccess.file_exists("user://settings.json"):
		var file := FileAccess.open("user://settings.json", FileAccess.READ)
		var content := file.get_as_text()
		file.close()
		json = JSON.parse_string(content)
		if typeof(json) != TYPE_DICTIONARY:
			print("Fichier JSON invalide")

	json["language"] = dropdown.get_item_text(index)
	var json_out := JSON.stringify(json, "\t")
	var file_out := FileAccess.open("user://settings.json", FileAccess.WRITE)
	file_out.store_string(json_out)
	file_out.close()
