class_name KnownEngineErrors
extends RefCounted

## Engine errors a test cannot avoid and that are not its own, marked handled so GUT does not fail it.

## concrete_floor_001.tres (pulled in by a spawn building's pad, the cargo depot's floor) mixes
## triplanar and height mapping: the engine says so, once, the first time it loads.
static func forgive_floor_material(test: GutTest) -> void:
	for e in test.get_errors():
		if (str(e.code) + str(e.rationale)).contains("Height mapping"):
			e.handled = true
