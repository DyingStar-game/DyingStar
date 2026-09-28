extends GutTest
## The EVA loop really exists in the puppet's AnimationPlayer. A clip name the player does not know makes
## the animator fall back to the idle IN SILENCE — which is exactly what happened: the .glb calls it
## "LiftAir_Idle_Loop", the importer strips "_Loop", and only the tipped pose showed it was "working".


func test_the_float_clip_is_in_the_puppet() -> void:
	var puppet: Node = (load("res://scenes/_universe/characters/humanoids/human_puppet.tscn") as PackedScene).instantiate()
	var anim_set: CharacterAnimationSet = load("res://scenes/_universe/characters/humanoids/ual_animation_set.tres")
	var players: Array[Node] = puppet.find_children("*", "AnimationPlayer", true, false)
	assert_gt(players.size(), 0, "the puppet has an AnimationPlayer")
	if players.size() > 0:
		assert_true((players[0] as AnimationPlayer).has_animation(anim_set.float_idle),
				"'%s' is a clip the player knows" % anim_set.float_idle)
	puppet.free()
