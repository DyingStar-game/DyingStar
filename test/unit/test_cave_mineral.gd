extends GutTest
## A cave shows the rock it is dug in (CaveMineral): the rock comes from the planet's zones at the site
## (PlanetData.rock_at), tints the walls, grows clear crystals where the rock has a crystal habit (rubies in a
## colourless corundum, CaveMineralStyle.crystal_rock_overrides) and lights them in their fluorescence colour.


class ZoneAt extends PlanetData:
    var zone := {}

    func first_zone_at(_dir: Vector3) -> Dictionary:
        return zone


var _data: Dictionary
var _library: CaveAssetLibrary


func before_all() -> void:
    RockCatalogue.reload()
    CaveNetwork.warm()
    _library = CaveAssetLibrary.default_for("rock")
    var profile := CaveWorkbench.preset(1, "rock", _library)
    profile.chamber_count = 5
    profile.level_count = 1
    profile.depth_m = 0
    profile.chamber_width_m = 40
    profile.chamber_height_m = 18
    profile.network_style = "ramiform"
    _data = CaveGenerator.build(profile.snapshot(7654321))


func test_rock_at_follows_the_ground_colour_rule() -> void:
    var planet := ZoneAt.new()
    planet.zone = {"rock_type": "corundum_red"}
    assert_eq(planet.rock_at(Vector3.UP), "corundum_red", "no corundum default: the zone's rock")
    planet.zone = {}
    assert_eq(planet.rock_at(Vector3.UP), "", "no zone, no default: no rock")
    planet.corundum_default_biome = true
    planet.corundum_default_rock = "corundum_pink"
    assert_eq(planet.rock_at(Vector3.UP), "corundum_pink", "the corundum default covers an empty zone")
    planet.zone = {"rock_type": "corundum_blue"}
    assert_eq(planet.rock_at(Vector3.UP), "corundum_pink", "a zone without a known biome does not displace it")


func test_mineral_of_a_rock() -> void:
    assert_null(CaveMineral.for_slug(""))
    assert_null(CaveMineral.for_slug("kryptonite"))
    var ruby := CaveMineral.for_slug("corundum_red")
    assert_true(ruby.crystals)
    assert_gt(ruby.glow_strength, 0.0)
    assert_almost_eq(maxf(ruby.crystal_color.r, maxf(ruby.crystal_color.g, ruby.crystal_color.b)), 1.0, 1e-5,
        "a clear crystal passes its hue at full brightness")
    assert_gt(ruby.crystal_color.r, ruby.crystal_color.b, "ruby red")
    var sapphire := CaveMineral.for_slug("corundum_blue")
    assert_true(sapphire.crystals)
    assert_eq(sapphire.glow_strength, 0.0, "Fe-Ti sapphire does not fluoresce")
    assert_gt(sapphire.wall_tint.b, sapphire.wall_tint.r, "deep blue walls")
    assert_false(CaveMineral.for_slug("hercynite_oxidised").crystals, "no habit, no crystals")


func test_tinted_walls_never_touch_the_shared_material() -> void:
    var wall := _library.wall_material as BaseMaterial3D
    var before := wall.albedo_color
    var ruby := CaveMineral.for_slug("corundum_red")
    var tinted := ruby.tinted(wall, _library.mineral_style) as BaseMaterial3D
    assert_ne(tinted, wall)
    assert_eq(wall.albedo_color, before, "the shared .tres is unchanged")
    assert_ne(tinted.albedo_color, before)
    assert_eq(ruby.tinted(wall, _library.mineral_style), tinted, "one copy per material and rock")
    assert_eq(ruby.tinted(wall, null), wall, "no style, no tint")


func test_a_ruby_cave_grows_glowing_crystals() -> void:
    var preview := CavePreviewBuilder.instantiate(_data, _library, true, false, Vector3.ZERO,
        CaveMineral.for_slug("corundum_pink"))
    var crystals := _crystals(preview)
    assert_gt(crystals.size(), 0, "crystals in the chambers")
    for instance: MultiMeshInstance3D in crystals:
        assert_eq(instance.layers, Globals.RENDER_MASK_FLUORESCENT,
            "on the layer the UV torch reaches, out of their glow lights' reach")
        assert_eq(instance.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
    var lights := preview.find_children("CrystalGlow*", "OmniLight3D", false, false)
    assert_between(lights.size(), 1, _library.mineral_style.glow_light_count, "a few glow lights")
    for light: OmniLight3D in lights:
        assert_false(light.shadow_enabled)
    var surface := preview.get_node("CaveSurface") as MeshInstance3D
    assert_ne(surface.mesh.surface_get_material(0), _library.wall_material, "walls tinted toward the rock")
    assert_ne(surface.layers & Globals.RENDER_MASK_FLUORESCENT, 0, "the UV torch reaches the fluorescent clouds")
    assert_ne(surface.layers & Globals.RENDER_MASK_LOCAL, 0, "and every other light still lights the walls")
    assert_eq(surface.get_instance_shader_parameter(&"glow").w, 0.9, "the pink rock's fluorescence strength")
    preview.free()


func test_a_sapphire_cave_has_crystals_but_no_glow() -> void:
    var preview := CavePreviewBuilder.instantiate(_data, _library, true, false, Vector3.ZERO,
        CaveMineral.for_slug("corundum_blue"))
    assert_gt(_crystals(preview).size(), 0)
    assert_eq(preview.find_children("CrystalGlow*", "OmniLight3D", false, false).size(), 0)
    preview.free()


func test_no_rock_or_no_habit_no_crystals() -> void:
    for mineral: CaveMineral in [null, CaveMineral.for_slug("hercynite_oxidised")]:
        var preview := CavePreviewBuilder.instantiate(_data, _library, true, false, Vector3.ZERO, mineral)
        assert_eq(_crystals(preview).size(), 0)
        assert_eq(preview.find_children("CrystalGlow*", "OmniLight3D", false, false).size(), 0)
        assert_gt(preview.find_children("Decor_*", "MultiMeshInstance3D", false, false).size(), 0, "rocks stay")
        preview.free()


func test_crystals_never_thin_the_rocks() -> void:
    var without: CaveAssetLibrary = _library.duplicate()
    var kept: Array[CaveDecorationRule] = []
    for rule in _library.decorations:
        if not rule.mineral_crystal:
            kept.append(rule)
    without.decorations = kept
    var plain := CavePreviewBuilder.prepare_decorations(_data, CavePreviewBuilder.decoration_request(without))
    var full := CavePreviewBuilder.prepare_decorations(_data, CavePreviewBuilder.decoration_request(_library))
    for rule in without.decorations:
        assert_eq(full.groups.get(rule.rule_name), plain.groups.get(rule.rule_name),
            "%s placed as before the crystals" % rule.rule_name)


func test_server_builds_no_crystal() -> void:
    var server := CavePreviewBuilder.instantiate(_data, _library, false, true)
    assert_eq(server.find_children("DecorCollision_corundum*", "", false, false).size(), 0)
    server.free()


func _crystals(preview: Node) -> Array:
    return preview.find_children("Decor_corundum*", "MultiMeshInstance3D", false, false)


func test_crystals_follow_the_ground_quality_setting() -> void:
    var instance := MultiMeshInstance3D.new()
    add_child_autofree(instance)
    CaveMineral.for_slug("corundum_red").dress_crystals(instance, _library.mineral_style)
    assert_true(instance.is_in_group(CaveMineral.CRYSTAL_GROUP), "found again when the setting changes")
    instance.material_override = null
    CaveMineral._on_render_changed(PackedStringArray(["ground_quality"]))
    assert_eq(instance.material_override, CaveMineral.crystal_material(_library.mineral_style),
        "a cave already built takes the material of the new quality")


func test_a_colourless_corundum_grows_rubies() -> void:
    var milky := CaveMineral.for_slug("corundum_milky")
    var ruby := CaveMineral.for_slug("corundum_red")
    var preview := CavePreviewBuilder.instantiate(_data, _library, true, false, Vector3.ZERO, milky)
    var crystals := _crystals(preview)
    assert_gt(crystals.size(), 0, "crystals in the chambers")
    for instance: MultiMeshInstance3D in crystals:
        var hue: Vector3 = instance.get_instance_shader_parameter(&"crystal_color")
        assert_almost_eq(hue, Vector3(ruby.crystal_color.r, ruby.crystal_color.g, ruby.crystal_color.b),
            Vector3.ONE * 1e-5, "ruby crystals in the milky rock")
        assert_gt(hue.x, hue.z, "red")
        var glow: Vector4 = instance.get_instance_shader_parameter(&"glow")
        assert_almost_eq(glow.w, ruby.glow_strength, 1e-5, "the ruby's chromium fluorescence")
    var lights := preview.find_children("CrystalGlow*", "OmniLight3D", false, false)
    assert_gt(lights.size(), 0, "the rubies light the walls around them")
    for light: OmniLight3D in lights:
        assert_eq(light.light_color, ruby.glow_color, "in the ruby's red")
    var surface := preview.get_node("CaveSurface") as MeshInstance3D
    var wall_glow: Vector4 = surface.get_instance_shader_parameter(&"glow")
    assert_almost_eq(wall_glow.w, milky.glow_strength, 1e-5, "the walls keep the milky rock's own glow")
    preview.free()


func test_only_the_listed_rocks_change_their_crystals() -> void:
    var style := _library.mineral_style
    var milky := CaveMineral.for_slug("corundum_milky")
    assert_eq(milky.crystal_mineral(style).slug, "corundum_red")
    assert_eq(CaveMineral.for_slug("corundum_white").crystal_mineral(style).slug, "corundum_red")
    var sapphire := CaveMineral.for_slug("corundum_blue")
    assert_eq(sapphire.crystal_mineral(style), sapphire, "a coloured corundum keeps crystals of its colour")
    assert_eq(milky.crystal_mineral(null), milky, "no style, no override")
    assert_eq(milky.crystal_mineral(CaveMineralStyle.new()), milky, "a style without overrides changes nothing")
