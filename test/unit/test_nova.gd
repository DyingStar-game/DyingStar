extends GutTest
## Nova: live inheritance, variant discovery from the QGIS export, the vertex palette and the
## scatter's determinism (docs/NOVA.md).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_nova.gd

const BODY := "test_body_nova"


func _body_with(variants: Array) -> NovaBody:
	var b := NovaBody.new()
	b.planet_name = BODY
	var vs: Array[Dictionary] = [NovaBody._variant(1, NovaBody.DEFAULT_KEY, {})]
	for z: Dictionary in variants:
		vs.append(NovaBody._variant(vs.size() + 1, NovaBody.zone_key(z), z))
	b.variants = vs
	for v in vs:
		b._id_by_key[v.key] = v.id
	return b


# ---------------------------------------------------------------------------
# Variants
# ---------------------------------------------------------------------------

func test_zone_key_keeps_text_attributes_only_sorted() -> void:
	var zone := {"biome_type": "outcrop-plateau", "rock_type": "corundum_red", "clarity": "milky",
			"density": 0.4, "name": "plateau_a", "color_hex": "#8a7080", "coverage": "full"}
	assert_eq(NovaBody.zone_key(zone), "outcrop-plateau|clarity=milky|rock_type=corundum_red")
	assert_eq(NovaBody.slug_of(NovaBody.attrs_of(zone)), "clarity-milky__rock_type-corundum_red")
	assert_eq(NovaBody.zone_key({}), NovaBody.DEFAULT_KEY, "no zone = the body's ground")


func test_a_numeric_attribute_never_splits_a_variant() -> void:
	var a := {"biome_type": "forest-boreal_forest", "density": 0.2}
	var b := {"biome_type": "forest-boreal_forest", "density": 0.9}
	assert_eq(NovaBody.zone_key(a), NovaBody.zone_key(b))


func test_tarsis_3_variants_are_its_corundum_rocks() -> void:
	if NovaBody.pack_for("tarsis_3") == null:
		pending("no tile service serves tarsis_3's modifiers")
		return
	var body := NovaBody.open_body("tarsis_3")
	assert_gt(body.variants.size(), 5, "the plateau zones carry several rocks")
	assert_eq(body.variants[0].key, NovaBody.DEFAULT_KEY)
	var rocks := {}
	for v in body.variants.slice(1):
		if v.attrs.has("rock_type"):
			assert_eq(v.biome_type, "outcrop-plateau", "Tarsis 3's rocks are its plateaus: %s" % v.key)
		rocks[v.attrs.get("rock_type", "")] = true
	assert_true(rocks.has("corundum_red"), "corundum_red is a variant")
	assert_true(rocks.has("corundum_blue"), "corundum_blue is a variant")
	assert_true(rocks.has("emery"), "emery is a variant: its two zones are missing from the coarsest pack level")
	var again := NovaBody.open_body("tarsis_3")
	assert_eq(again.fingerprint(), body.fingerprint(), "ids are stable for one export")


func test_an_unknown_zone_falls_back_to_the_body_ground() -> void:
	var body := _body_with([{"biome_type": "outcrop-plateau", "rock_type": "emery"}])
	assert_eq(body.variant_id_for_zone({"biome_type": "outcrop-plateau", "rock_type": "emery"}), 2)
	assert_eq(body.variant_id_for_zone({"biome_type": "icy-glacier"}), 1)
	assert_eq(body.variant_id_for_zone({}), 1)


# ---------------------------------------------------------------------------
# Live inheritance
# ---------------------------------------------------------------------------

func test_the_most_specific_level_wins_and_reverting_falls_back() -> void:
	var body := _body_with([{"biome_type": "test-nova_biome", "rock_type": "corundum_red"}])
	var v := body.variant(2)
	var arch := body.profile_for_edit(NovaBody.archetype_path("test-nova_biome"))
	var biome := body.profile_for_edit(NovaBody.body_biome_path(BODY, "test-nova_biome"))
	var own := body.profile_for_edit(NovaBody.variant_path(BODY, v))
	assert_eq(body.resolve(2, "ground/tile_m"), NovaSchema.default_of("ground/tile_m"), "default first")
	arch.set_own("ground/tile_m", 12.0)
	assert_eq(body.resolve(2, "ground/tile_m"), 12.0, "archetype")
	biome.set_own("ground/tile_m", 20.0)
	assert_eq(body.resolve(2, "ground/tile_m"), 20.0, "body biome over archetype")
	own.set_own("ground/tile_m", 30.0)
	assert_eq(body.resolve(2, "ground/tile_m"), 30.0, "variant over body biome")
	assert_eq(body.origin_of(2, "ground/tile_m"), NovaBody.variant_path(BODY, v))
	own.revert("ground/tile_m")
	assert_eq(body.resolve(2, "ground/tile_m"), 20.0, "revert: the body biome again")
	arch.set_own("ground/roughness", 0.5)
	assert_eq(body.resolve(2, "ground/roughness"), 0.5, "a key nobody below sets comes from the archetype, live")


func test_values_are_coerced_to_their_schema_kind_and_bounds() -> void:
	assert_eq(NovaSchema.coerce("ground/tile_m", 1.0e9), 200.0)
	assert_eq(NovaSchema.coerce("scatter/s1/seed", 12.7), 12)
	assert_eq(NovaSchema.coerce("scatter/s3/meshes", PackedStringArray(["a", "", "b"])), ["a", "b"])
	assert_ne(NovaSchema.default_of("scatter/s1/seed"), NovaSchema.default_of("scatter/s2/seed"),
			"each layer lays its own pattern by default")


# ---------------------------------------------------------------------------
# Vertex palette
# ---------------------------------------------------------------------------

func test_palette_is_one_hot_on_the_four_most_frequent_variants() -> void:
	var vid := PackedInt32Array([3, 3, 3, 7, 7, 2, 9, 11])
	var out := PlanetChunk.nova_palette(vid)
	var w: PackedByteArray = out[0]
	var pal: PackedByteArray = out[1]
	assert_eq(w.size(), vid.size() * 4)
	assert_eq(pal, PackedByteArray([3, 7, 2, 9]), "one palette for the chunk: by frequency, then id")
	for v in vid.size():
		var s := 0
		for c in 4:
			s += w[v * 4 + c]
		assert_eq(s, 255, "one-hot at vertex %d" % v)
	assert_eq(w[0], 255, "variant 3 → slot 0")
	assert_eq(w[3 * 4 + 1], 255, "variant 7 → slot 1")
	assert_eq(w[7 * 4 + 0], 255, "a fifth variant counts as the most frequent")


func test_an_indexed_outline_answers_as_the_whole_outline() -> void:
	# nova_variant_in reads a zone's outline through its latitude bands and its tile-clip edges
	# (PlanetChunk._nova_holds): the same answer as _point_in_polygon_lonlat or _on_clip_edge on the whole
	# outline, bit for bit, on winding outlines clipped by a tile's box and on the clip edges themselves.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var mismatches := 0
	var inside := 0
	for shape in 12:
		var outline := []
		var count := 8 + shape * 40
		for k in count:
			var a := TAU * k / count
			var r := 0.6 + 0.35 * sin(a * (3 + shape % 5)) + rng.randf_range(-0.05, 0.05)
			outline.append([clampf(cos(a) * r, -0.7, 0.7), clampf(sin(a) * r * 0.4, -0.25, 0.25)])
		var e: Array = PlanetChunk.nova_entries(NovaBody.new(), [{"coverage": "polygon", "vertices": outline}])[0]
		for k in 3000:
			var lon := rng.randf_range(-0.8, 0.8)
			var lat := rng.randf_range(-0.3, 0.3)
			if k % 5 == 0:  # on a box edge, within the clip tolerance
				lon = [-0.7, 0.7][k % 2] + rng.randf_range(-1e-7, 1e-7)
			var whole := PlanetChunk._point_in_polygon_lonlat(lon, lat, outline) or PlanetChunk._on_clip_edge(lon, lat, outline)
			inside += int(whole)
			if PlanetChunk._nova_holds(e, lon, lat) != whole:
				mismatches += 1
	assert_eq(mismatches, 0, "the indexed outline answers as the whole one")
	assert_gt(inside, 3000, "and many places are inside")


# ---------------------------------------------------------------------------
# Scatter determinism
# ---------------------------------------------------------------------------

func test_hash_is_a_fixed_function() -> void:
	# Golden values: changing them moves every rock of every body for every player.
	assert_eq(NovaScatter.mix32(12345), 3431532870)
	assert_eq(NovaScatter.cell_hash(7, 3, 123456, 654321), 2595026070)


func test_a_cell_lays_the_same_object_every_time() -> void:
	var a := NovaScatter.cell_object(42, 0.9, 5, 1000, 2000)
	var b := NovaScatter.cell_object(42, 0.9, 5, 1000, 2000)
	assert_eq(a, b)
	assert_ne(NovaScatter.cell_object(43, 1.0, 5, 1000, 2000), NovaScatter.cell_object(42, 1.0, 5, 1000, 2000),
			"another seed, another pattern")


func test_a_parent_chunk_and_its_children_cover_the_same_cells() -> void:
	var sn := 1 << 14
	var parent := NovaScatter.chunk_cells(256, 1234, sn)
	assert_false(parent.is_empty())
	var cells := {}
	for c in 4:
		var child := NovaScatter.chunk_cells(512, 1234 * 4 + c, sn)
		assert_eq(child.face, parent.face)
		for y in child.r:
			for x in child.r:
				cells[Vector2i(child.x0 + x, child.y0 + y)] = true
	assert_eq(cells.size(), parent.r * parent.r, "the four children hold exactly the parent's cells")
	for y in parent.r:
		for x in parent.r:
			if not cells.has(Vector2i(parent.x0 + x, parent.y0 + y)):
				fail_test("cell %d,%d of the parent is in no child" % [x, y])
				return


func test_a_layer_is_laid_only_on_chunks_fine_enough() -> void:
	assert_true(NovaScatter.chunk_cells(1024, 0, 512).is_empty(), "coarser than the chunk")
	assert_true(NovaScatter.chunk_cells(16, 0, 16 << (NovaScatter.MAX_DEPTH + 1)).is_empty(), "too many cells")
	assert_false(NovaScatter.chunk_cells(16, 0, 16 << NovaScatter.MAX_DEPTH).is_empty())


func test_scatter_level_follows_the_spacing() -> void:
	var r := 6356000.0
	var n := NovaScatter.scatter_nside(r, 10.0)
	var side := HEALPix.pixel_side_length(n, r)
	assert_between(side, 10.0 / 1.5, 10.0 * 1.5, "cells of ~10 m (got %.1f m)" % side)


func test_the_scatter_keeps_a_small_radius_round_a_poi_clear_not_its_sphere() -> void:
	var data := PlanetData.new()
	data.radius = 6356000.0
	var poi := HEALPix.lonlat2vec(10.0, 20.0)
	data.set_crack_exclusions([{"dir": poi, "radius": 25000.0}])  # a city's sphere: 25 km
	var north: Vector3 = Planet.local_axes(poi)[1]
	var at := func(metres: float) -> Vector3: return (poi + north * (metres / data.radius)).normalized()
	var near := NovaClearance.for_chunk(data, 8192, HEALPix.vec2pix_nest(8192, poi))
	assert_not_null(near, "the chunk at the POI meets it")
	if near == null:
		return
	assert_eq(near.share_at(poi), 0.0, "nothing at the centre")
	assert_eq(near.share_at(at.call(NovaClearance.POI_CLEAR_M * 0.9)), 0.0, "nor within the small radius")
	assert_between(near.share_at(at.call(NovaClearance.POI_CLEAR_M + NovaClearance.POI_FADE_M * 0.5)), 0.2, 0.8,
			"fewer and fewer toward it")
	assert_eq(near.share_at(at.call(NovaClearance.POI_CLEAR_M + NovaClearance.POI_FADE_M + 5.0)), 1.0, "everything past it")
	# A large object must not reach into the clear ground though its middle is outside.
	var edge: Vector3 = at.call(NovaClearance.POI_CLEAR_M + NovaClearance.POI_FADE_M + 5.0)
	assert_lt(near.share_for(edge, 40.0), 1.0, "an object 40 m wide standing 5 m out reaches in")
	# 5 km from the centre, well inside the 25 km sphere: the scatter is laid as anywhere.
	var far: Vector3 = at.call(5000.0)
	assert_null(NovaClearance.for_chunk(data, 8192, HEALPix.vec2pix_nest(8192, far)), "nothing to keep clear of 5 km out")


func test_the_atlas_places_are_inside_their_variant() -> void:
	if NovaBody.pack_for("tarsis_3") == null:
		pending("no tile service serves tarsis_3's modifiers")
		return
	var body := NovaBody.open_body("tarsis_3")
	var atlas := NovaAtlas.load_or_build(body, NovaBody.pack_for("tarsis_3"), 1024)
	for v in body.variants:
		# A variant only the coarse levels of the pack hold has no place: nothing of it at ground level.
		var spots: Array = atlas.spots.get(v.id, [])
		if v.attrs.has("rock_type"):
			assert_false(spots.is_empty(), "%s has a place to go to" % v.label)
		for s: Dictionary in spots.slice(0, 5):
			assert_eq(atlas.variant_at(body, s.dir), int(v.id), "a spot of %s lies in it" % v.label)
		var edges: Array = atlas.edges.get(v.id, [])
		if not edges.is_empty():
			var e: Dictionary = edges[0]
			assert_ne(int(e.other), int(v.id), "a frontier is with another variant")
	assert_eq(atlas.map.get_size(), NovaAtlas.MAP_SIZE)
	var red: Dictionary = atlas.spots[body.variant_id_for_zone({"biome_type": "outcrop-plateau",
			"clarity": "milky", "rock_type": "corundum_red"})][0]
	assert_eq(atlas.map.get_pixelv(NovaAtlas.map_pixel(red.dir)).r8, atlas.variant_at(body, red.dir),
			"the globe's map shows the variant that is there")
	var zoned := 0
	var data := atlas.map.get_data()
	for k in range(0, data.size(), 97):
		zoned += 1 if data[k] > 1 else 0
	assert_gt(float(zoned) / (data.size() / 97.0), 0.6,
			"the map shows the zones whole, as far chunks do, not only the outlines the export level keeps")
