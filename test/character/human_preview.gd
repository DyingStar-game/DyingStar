extends Node3D

## A row of baked bodies with random looks (CharacterAppearance.random), idling, to eyeball the builder.
## Arguments after `--`: `--count=6 --seed=1` how many and from which seed; `--zoom=2 --aim_y=1.1` closer;
## `--face` frames the faces (same two, and `--yaw=70` turned; `--spacing=0.5` further apart, m); `--preset=default_male` one preset;
## `--outfit=0` outfits from that one on, one per body, on the body they suit; `--gd` the GDScript morph;
## `--beard=1` beard styles from that one on; `--eye=0` eye colours from that one on; `--hair=1` hair styles
## from that one on, `--brows=0` eyebrows,
## `--length=0.5` the cut; `--still` no idle clip; `--level` every head at the same height; `--life` gives
## the faces their life (FaceLife), `--voice=0.7` a voice; `--years=60 --tone=0.2` age and skin tone;
## `--skin=freckles:0.8,wrinkles:1` skin details (the others at 0); `--axis=width:1` an overall axis from -1 to +1;
## `--cut=<hex>` a head of hair's settings (HairCut), `--beardcut=<hex>` a beard's (BeardCut), `--randcut=1`
## random hair (their bytes go to the file);
## `--looks=<code>,<code>` encoded looks, one per body; `--set=FLAME_Identity_00:1` sliders by key; `--unit=jaw_open:0.5`
## sets life shapes and holds them; `--nolods` bakes
## without LODs. Writes the bake times to user://human_preview.txt.

const PUPPET := preload("res://scenes/_universe/characters/humanoids/human_puppet.tscn")
const SPACING := 0.75
const FACE_SPACING := 0.34


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var count: int = int(args.get("count", "3" if args.has("face") else "6"))
	var spacing: float = float(args.get("spacing", FACE_SPACING if args.has("face") else SPACING))
	var seed_base: int = int(args.get("seed", "1"))
	var lines: PackedStringArray = []
	var morph: HumanMorph = HumanBuilder.prepare()
	if args.has("gd"):
		morph._native = null
	lines.append("native morph: %s" % morph.is_native())
	for i in count:
		var puppet: Node3D = PUPPET.instantiate()
		add_child(puppet)
		puppet.position = Vector3((i - (count - 1) * 0.5) * spacing, 0.0, 0.0)
		puppet.rotation_degrees.y = float(args.get("yaw", "0"))
		var look: CharacterAppearance = CharacterAppearance.preset(args["preset"]) if args.has("preset") \
				else CharacterAppearance.random(seed_base + i)
		if args.has("looks"):  # encoded looks, one per body (CharacterAppearance.encode)
			var codes: PackedStringArray = String(args["looks"]).split(",")
			look = CharacterAppearance.decode(codes[i % codes.size()])
		if args.has("outfit"):
			look.outfit = (int(args["outfit"]) + i) % maxi(CharacterAppearance.choice_count("outfit"), 1)
			look.macros["gender"] = 1.0 if CharacterAppearance.catalogue()["assets"]["outfit"][look.outfit]["gender"] == "male" else 0.0
		if args.has("cut"):  # a head of hair by its settings' bytes (HairCut.to_bytes, hex)
			look.hair = maxi(look.hair, 1)
			look.cut = HairCut.from_bytes(String(args["cut"]).hex_decode())
		if args.has("randcut"):  # a random head of hair each (the survey's library: tools/character/face_survey)
			look.hair = maxi(look.hair, 1)
			look.cut = random_cut(int(args["randcut"]) * 1000 + i)
			lines.append("CUT %d %s" % [i, look.cut.key()])
		if args.has("eye"):
			look.eye_colour = (int(args["eye"]) + i) % maxi((CharacterAppearance.catalogue()["eye_colours"] as Array).size(), 1)
		if args.has("beard"):
			look.beard = (int(args["beard"]) + i) % maxi(CharacterAppearance.choice_count("beard"), 1)
			look.beard_cut = look.beard_style_cut(look.beard)
		if args.has("beardcut"):  # a beard by its settings' bytes (BeardCut.to_bytes, hex)
			look.beard = maxi(look.beard, 1)
			look.beard_cut = BeardCut.from_bytes(String(args["beardcut"]).hex_decode())
		if args.has("years"):
			look.macros["age"] = HumanMacros.age_of(float(args["years"]))
		if args.has("tone"):
			look.skin_tone = float(args["tone"])
		if args.has("axis"):  # "width:1" -> that overall axis moved, from -value to +value across the row
			var kv: PackedStringArray = String(args["axis"]).split(":")
			for axis: Array in FaceAxes.axes():
				if String(axis[0]) == kv[0]:
					var reach: float = float(kv[1]) if kv.size() > 1 else 1.0
					FaceAxes.move(look, axis[2], lerpf(-reach, reach, float(i) / maxf(count - 1, 1)))
		if args.has("sweep"):  # "Nose_Dorsum_Hump:1" -> that slider from -value to +value across the row
			var sk: PackedStringArray = String(args["sweep"]).split(":")
			var sid: int = CharacterAppearance.modifier_id(sk[0])
			if sid != -1:
				var sreach: float = float(sk[1]) if sk.size() > 1 else 1.0
				look.modifiers[sid] = lerpf(-sreach, sreach, float(i) / maxf(count - 1, 1))
		if args.has("set"):  # any sliders by key: "FLAME_Identity_00:1,Eye_Size:-0.5" (stored values, -1..1)
			for pair in String(args["set"]).split(",", false):
				var kv: PackedStringArray = pair.split(":")
				var id: int = CharacterAppearance.modifier_id(kv[0])
				if id != -1 and kv.size() == 2:
					look.modifiers[id] = float(kv[1])
		if args.has("skin"):  # skin details: "freckles:0.8,wrinkles:1" (the others at 0), or "0" for none
			for detail: StringName in CharacterAppearance.SKIN_DETAILS:
				look.set(detail, 0.0)
			for pair in String(args["skin"]).split(",", false):
				var kv: PackedStringArray = pair.split(":")
				if kv.size() == 2:
					look.set(StringName(kv[0]), float(kv[1]))
		if args.has("origin"):  # one origin at full weight, from that one on, one per body
			look.origins.fill(0.0)
			look.origins[(int(args["origin"]) + i) % CharacterAppearance.ORIGINS] = 1.0
		if args.has("hair"):  # styles from that one on, one per body
			look.hair = (int(args["hair"]) + i) % maxi(CharacterAppearance.choice_count("hair"), 1)
			look.cut = look.style_cut(look.hair)
		if args.has("brows"):
			look.eyebrows = (int(args["brows"]) + i) % maxi(CharacterAppearance.choice_count("eyebrows"), 1)
		if args.has("length"):
			look.hair_length = float(args["length"])
		var ha: HumanAppearance = puppet.get_node("HumanAppearance")
		ha.face_life = args.has("unit") or args.has("life")
		ha.use_lods = not args.has("nolods")
		var t0: int = Time.get_ticks_usec()
		ha.set_appearance_now(look)
		if args.has("level"):  # every head at the same height (1.62 m), whatever the body's
			var bones: Skeleton3D = puppet.get_node("Body/Armature/GeneralSkeleton")
			puppet.position.y += 1.54 - (bones.global_transform * bones.get_bone_global_rest(bones.find_bone("Head")).origin).y
		var face: FaceLife = puppet.get_node("FaceLife")
		if args.has("unit"):  # fixed shapes ("jaw_open:0.8,smile"): FaceLife stands still
			face.set_process(false)
			for unit in String(args["unit"]).split(","):
				var kv: PackedStringArray = unit.split(":")
				ha.set_face_shape(StringName(kv[0]), float(kv[1]) if kv.size() > 1 else 1.0)
		face.voice_level = float(args.get("voice", "0"))
		var baked: HumanBuilder.Baked = HumanMeshCache.baked(look.shape_hash())
		var live: HumanBuilder.Baked = HumanMeshCache.baked(look.shape_hash(), true)
		lines.append("look %d %s: bake %.1f ms (apply %.1f ms) hips %.3f, %d + %d surfaces, tone %.2f, %.0f y%s" % [i, look.encode(),
				baked.build_ms, (Time.get_ticks_usec() - t0) / 1000.0, baked.hips_height, baked.mesh.get_surface_count(),
				baked.head_mesh.get_surface_count(), look.skin_tone, look.years(),
				", live head %.1f ms" % live.build_ms if live != null else ""])
		var player: AnimationPlayer = puppet.get_node("AnimationPlayer")
		for clip in player.get_animation_list():
			if String(clip) == "Idle" and not args.has("still"):
				player.play(clip)
				break
	var f := FileAccess.open("user://human_preview.txt", FileAccess.WRITE)
	f.store_string("\n".join(lines))
	f.close()
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.environment.ssao_enabled = true
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, 30.0, 0.0)
	sun.shadow_enabled = true
	sun.light_energy = 1.4
	add_child(sun)
	var cam := Camera3D.new()
	add_child(cam)
	var width: float = count * spacing
	if args.has("face"):
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = width * 9.0 / 16.0 / float(args.get("zoom", "1"))
		var aim := Vector3(float(args.get("aim_x", "0")), float(args.get("aim_y", "1.5")), 0.0)  # aim_x: m to the right
		cam.look_at_from_position(aim + Vector3(0.0, 0.0, 3.0), aim)
	else:
		cam.fov = 30.0
		var body_aim: float = float(args.get("aim_y", "0.92"))
		cam.look_at_from_position(Vector3(0.0, body_aim + 0.08, (width * 1.7 + 1.2) / float(args.get("zoom", "1"))),
				Vector3(0.0, body_aim, 0.0))
	cam.make_current()


## A head of hair's settings drawn over their whole range, for the survey's library of renders.
static func random_cut(seed_value: int) -> HairCut:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var cut := HairCut.new()
	cut.length = rng.randf()
	cut.sides = rng.randf()
	cut.volume = rng.randf()
	cut.curl = rng.randf()
	cut.density = rng.randf_range(0.3, 0.8)
	cut.fringe = rng.randf() if rng.randf() < 0.4 else 0.0
	cut.recession = rng.randf() if rng.randf() < 0.3 else 0.0
	cut.crown_bald = rng.randf() if rng.randf() < 0.15 else 0.0
	cut.low_line = rng.randf() if cut.recession == 0.0 and rng.randf() < 0.35 else 0.0
	cut.part = rng.randi() % HairCut.Part.size()
	cut.tie = rng.randi() % HairCut.Tie.size() if rng.randf() < 0.25 else HairCut.Tie.LOOSE
	return cut
