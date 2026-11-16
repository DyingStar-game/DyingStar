extends GutTest

## HairGroom grows a head of hair from its settings (HairCut) on the neutral head (HairHead).


func test_a_cut_round_trips_through_its_bytes() -> void:
	var cut := HairCut.preset("bob")
	var back: HairCut = HairCut.from_bytes(cut.to_bytes())
	assert_eq(back.to_bytes(), cut.to_bytes())
	assert_eq(back.part, HairCut.Part.CENTRE)
	assert_eq(cut.to_bytes().size(), HairCut.BYTES)
	cut.low_line = 0.6
	assert_almost_eq(HairCut.from_bytes(cut.to_bytes()).low_line, 0.6, 0.003, "the low hairline")
	assert_eq(HairCut.from_bytes(cut.to_bytes().slice(0, HairCut.V4_BYTES)).low_line, 0.0, "a version 4 cut has none")


func test_every_preset_grows_hair_on_the_scalp_and_out_of_the_head() -> void:
	var head: HairHead = HairHead.shared()
	for id: String in HairCut.PRESETS:
		var started: int = Time.get_ticks_msec()
		var made: Array[HumanAssetData] = HairGroom.new(head).grow(HairCut.preset(id))
		var ms: int = Time.get_ticks_msec() - started
		var cut := HairCut.preset(id)
		# Under strands over the whole head, the scalp seen through them; a buzz cut and shaved sides, the shell.
		var covered: bool = not cut.shell_only() and cut.side_length() >= HairCut.SHELL_ONLY_BELOW
		assert_eq(made[0].style, &"scalp" if covered else &"shell", "%s: a scalp or a shell first" % id)
		assert_gt(made[0].index.size(), 0, "%s: the shell has triangles" % id)
		if cut.shell_only():
			assert_eq(made.size(), 1, "%s: a stubble is its shell alone" % id)
			continue
		var strands: HumanAssetData = made[1]
		var guides: int = HairStrands.guide_count(strands)
		assert_gt(guides, 500, "%s: guides" % id)
		var inside: int = 0
		var worst: float = 0.0
		for k in range(0, strands.strand_points.size(), 7):
			var d: float = head.surface(strands.strand_points[k])[0]
			worst = minf(worst, d)
			inside += 1 if d < -0.002 else 0
		var share: float = float(inside) / (strands.strand_points.size() / 7.0)
		assert_lt(share, 0.01, "%s: hair stays out of the head (worst %.1f mm)" % [id, worst * 1000.0])
		gut.p("%s: %d guides x %d points, %d ms" % [id, guides, strands.strand_size, ms])


func test_a_cut_is_the_same_hair_every_time() -> void:
	var head: HairHead = HairHead.shared()
	var a: Array[HumanAssetData] = HairGroom.new(head).grow(HairCut.preset("medium_wavy"))
	var b: Array[HumanAssetData] = HairGroom.new(head).grow(HairCut.preset("medium_wavy"))
	assert_eq(a[1].strand_points, b[1].strand_points)
	assert_same(HairGroom.assets_for(HairCut.preset("bun")), HairGroom.assets_for(HairCut.preset("bun")), "cached")


func test_the_csharp_twin_grows_the_same_hair() -> void:
	HumanBuilder.prepare()  # makes the C# twin on this (main) thread
	assert_true(HairGroom.native_instance() != null, "HairGroomNative.cs must load, or this tests nothing (rebuild the C#)")
	var head: HairHead = HairHead.shared()
	for id in ["short_crop", "medium_wavy", "afro", "ponytail", "bun", "crest", "quiff", "top_bun", "flyaways"]:
		var cut := HairCut.preset({"quiff": "short_crop", "top_bun": "bun", "flyaways": "medium_wavy"}.get(id, id))
		if id == "quiff":
			cut.part = HairCut.Part.UP
			cut.volume = 0.8
		elif id == "top_bun":
			cut.tie = HairCut.Tie.TOP_BUN
			cut.flyaways = 0.7
		elif id == "flyaways":
			cut.flyaways = 1.0
		var started: int = Time.get_ticks_usec()
		var fast: Array[HumanAssetData] = HairGroom.new(head).grow(cut, true)
		var fast_ms: float = (Time.get_ticks_usec() - started) / 1000.0
		var slow: Array[HumanAssetData] = HairGroom.new(head).grow(cut, false)
		var a: PackedVector3Array = fast[1].strand_points
		var b: PackedVector3Array = slow[1].strand_points
		assert_eq(a.size(), b.size(), "%s: as many points" % id)
		var off: int = 0
		var n: int = fast[1].strand_size
		for s in mini(a.size(), b.size()) / n:
			for k in n:
				if a[s * n + k].distance_to(b[s * n + k]) > 1e-5:
					off += 1
					break
		assert_lt(float(off) / maxf(a.size() / n, 1), 0.005, "%s: C# and GDScript grow the same strands (%d differ)" % [id, off])
		assert_eq(fast[1].color, slow[1].color, "%s: same guides' colours" % id)
		assert_eq(fast[1].refs, slow[1].refs, "%s: same roots" % id)
		gut.p("%s: C# %.0f ms" % [id, fast_ms])


func test_every_beard_preset_grows_on_the_face() -> void:
	var head: HairHead = HairHead.shared()
	for id: String in BeardCut.PRESETS:
		var cut := BeardCut.preset(id)
		var made: Array[HumanAssetData] = BeardGroom.new(head).grow(cut)
		# First the skin seen through the beard (one layer), then its stubble or its hairs.
		assert_eq(made[0].style, &"scalp", "%s: the skin's shade first" % id)
		assert_gt(made[0].index.size(), 0, "%s: the shade has triangles" % id)
		assert_eq(made[0].vertex.size(), head.beard_shell_vertex.size(), "%s: one layer of shade" % id)
		if cut.shell_only():
			assert_eq(made.size(), 2, "%s: a stubble is its shade and its shell" % id)
			assert_eq(made[1].style, &"shell", "%s: the stubble's shell" % id)
			assert_eq(made[1].vertex.size(), head.beard_shell_vertex.size() * 3, "%s: its cap and two layers" % id)
			continue
		var hairs: HumanAssetData = made[1]
		assert_eq(hairs.style, &"hairs")
		assert_eq(hairs.refs.size(), hairs.vertex.size() * 3, "%s: every vertex rides the skin" % id)
		assert_eq(hairs.color.size(), hairs.vertex.size())
		assert_gt(hairs.index.size(), 600, "%s: hairs" % id)
	var moustache: HumanAssetData = BeardGroom.new(head).grow(BeardCut.preset("moustache"))[1]
	var full: HumanAssetData = BeardGroom.new(head).grow(BeardCut.preset("full"))[1]
	assert_lt(moustache.index.size(), full.index.size(), "a moustache is less hair than a full beard")


func test_a_beard_round_trips_through_its_bytes() -> void:
	var cut := BeardCut.preset("goatee")
	cut.shape = BeardCut.Shape.POINTED
	assert_eq(BeardCut.from_bytes(cut.to_bytes()).to_bytes(), cut.to_bytes())
