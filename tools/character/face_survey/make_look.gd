extends Node

## Builds a look from a JSON of settings and prints its code ("LOOK <encoded>"), for the face survey's tests
## (a fitted face shown in the creator: test/character/creator_shot.tscn -- --look=<code>). A dev tool: no look made
## from a real person's photo is ever shipped.
##
##   godot --headless --path . res://tools/character/face_survey/make_look.tscn -- <spec.json>
##
## spec: {"years": 33, "macros": {"gender": 0, "height": 0.45}, "origins": {"Race_White": 1},
##        "fields": {"skin_tone": 0.1, ...}, "choices": {"hair": "medium_wavy"}, "cut": {"tie": 2, ...},
##        "beard_cut": {"length": 0.2, ...}, "sliders": {"Eye_Size": 0.3, ...},
##        "targets": {"FLAME_Identity_00": 1.2, ...}}
## "sliders" are stored values (-1..1); "targets" are shape-key weights, divided by the slider's reach.

func _ready() -> void:
	var spec: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_cmdline_user_args()[0]))
	var a := CharacterAppearance.new()
	for k: String in spec.get("macros", {}):
		a.macros[k] = float(spec["macros"][k])
	if spec.has("years"):
		a.macros["age"] = HumanMacros.age_of(float(spec["years"]))
	for k: String in spec.get("origins", {}):
		a.origins[(CharacterAppearance.catalogue()["origins"] as Array).find(k)] = float(spec["origins"][k])
	for k: String in spec.get("fields", {}):
		a.set(k, spec["fields"][k])
	for k: String in spec.get("choices", {}):
		var entries: Array = CharacterAppearance.catalogue()["assets"][k]
		for i in entries.size():
			if entries[i]["id"] == spec["choices"][k]:
				a.set(k, i)
	# Format v4: the head of hair is its settings -- the chosen style's, then "cut" ({"length": 0.7, "tie": 2, ...}).
	a.cut = a.style_cut(a.hair)
	for k: String in spec.get("cut", {}):
		a.cut.set(k, spec["cut"][k])
	# The beard likewise: the chosen style's settings at fields.beard_length kept, then "beard_cut".
	a.beard_cut = a.beard_style_cut(a.beard, a.beard_length)
	a.beard_length = 1.0
	for k: String in spec.get("beard_cut", {}):
		a.beard_cut.set(k, spec["beard_cut"][k])
	for k: String in spec.get("sliders", {}):
		var id: int = CharacterAppearance.modifier_id(k)
		if id != -1:
			a.modifiers[id] = float(spec["sliders"][k])
	for k: String in spec.get("targets", {}):
		var id: int = CharacterAppearance.modifier_id(k)
		if id != -1:
			a.modifiers[id] = clampf(float(spec["targets"][k]) / CharacterAppearance.slider_range(k), -1.0, 1.0)
	a.canonicalise()
	print("LOOK ", a.encode())
	get_tree().quit()
