@tool
class_name CaveMineral
extends RefCounted
## The rock a cave is dug in, as the cave shows it: walls tinted toward the rock's colour, clear crystals of
## its habit (rocks.py crystal_habit) and the fluorescence they glow with (rocks.py fluorescence), faintly
## all the time and brightly under a UV torch (Globals.RENDER_MASK_FLUORESCENT).
##
## The rock comes from the planet's own QGIS data at the cave's site (PlanetData.rock_at), on the client,
## when the cave is assembled: nothing is networked or persisted. The crystals' placements are planned
## with the other decorations (CaveDecorationRule.mineral_crystal), the same on every machine; only their
## look depends on the rock, and a cave in a rock without a habit simply does not draw them.

const GlobalsDefs := preload("res://scenes/globals/globals.gd")

## Seed of each baked crystal cluster (tools/stargrot/bake_crystal_assets.gd, CaveCrystalMesh).
const CRYSTAL_SEEDS := {"floor": 7101, "wall": 7102, "ceiling": 7103}
## Group of every crystal MultiMesh drawn, so a change of the ground quality setting swaps their material live.
const CRYSTAL_GROUP := &"cave_mineral_crystals"
## Wall tint when the catalogue has no colour for the rock.
const FALLBACK_TINT := Color(0.72, 0.66, 0.58)

## The rock's catalogue slug (rocks.json).
var slug := ""
## Colour the cave walls are tinted toward (the rock's deep shade at the site).
var wall_tint := FALLBACK_TINT
## Colour the clear crystal lets through (full brightness, the rock's hue).
var crystal_color := Color(1, 1, 1)
## Fluorescence colour, and its strength 0..1 (0: the rock does not glow).
var glow_color := Color(0, 0, 0)
var glow_strength := 0.0
## Does the rock grow free crystals (a crystal habit)?
var crystals := false

# One tinted copy per (shared material, rock), never per cave.
static var _tinted := {}
# The crystal rock of each override (crystal_mineral), by slug.
static var _crystal_rocks := {}
static var _watching_quality := false


## The mineral of the cave at [param placement] on the planet [param data], or null where no catalogue
## rock applies (a cave in a biome without rock keeps its authored look). Main thread only.
static func at(data: PlanetData, placement: CavePlacement) -> CaveMineral:
    if data == null or placement == null:
        return null
    var dir := placement.surface_direction()
    return for_slug(data.rock_at(dir), dir, data.radius)


## The mineral of the rock [param rock] at [param dir] on a sphere of [param radius] (the tint is mottled
## by position, RockCatalogue.tint), or null for an unknown rock.
static func for_slug(rock: String, dir: Vector3 = Vector3.UP, radius: float = 1.0) -> CaveMineral:
    if rock.is_empty() or not RockCatalogue.has(rock):
        return null
    var mineral := CaveMineral.new()
    mineral.slug = rock
    var core := RockCatalogue.core_colors_of(rock)
    if core.size() == 2:
        # A cave is deep rock: the reduced-iron hue of the blue and green corundums (RockImpurity.valence).
        mineral.wall_tint = (core[0] as Color).lerp(core[1] as Color, 0.5)
    else:
        mineral.wall_tint = RockCatalogue.tint(dir, radius, rock, FALLBACK_TINT)
    var pair := RockCatalogue.colors_of(rock)
    var hue: Color = (pair[0] as Color).lerp(pair[1] as Color, 0.6) if pair.size() == 2 else Color(1, 1, 1)
    # A clear crystal passes its hue at full brightness; the shader's absorption makes the depth.
    var peak := maxf(hue.r, maxf(hue.g, hue.b))
    mineral.crystal_color = Color(hue.r / peak, hue.g / peak, hue.b / peak) if peak > 0.0 else Color(1, 1, 1)
    var fluo := RockCatalogue.fluorescence_of(rock)
    if not fluo.is_empty():
        mineral.glow_color = fluo["color"]
        mineral.glow_strength = float(fluo["strength"])
    mineral.crystals = not RockCatalogue.crystal_habit_of(rock).is_empty()
    return mineral


## [param base] tinted toward this rock by [param style] (cached per material and rock), or [param base]
## itself when there is nothing to tint. The shared resource is never modified.
func tinted(base: Material, style: CaveMineralStyle) -> Material:
    var standard := base as BaseMaterial3D
    if standard == null or style == null or style.wall_tint_strength <= 0.0:
        return base
    var key := [standard, slug]
    if _tinted.has(key):
        return _tinted[key]
    var copy := standard.duplicate() as BaseMaterial3D
    copy.resource_name = "%s_%s" % [standard.resource_name, slug]
    copy.albedo_color = standard.albedo_color.lerp(wall_tint, style.wall_tint_strength)
    # Light wraps around the relief like it does in a translucent stone, at no cost.
    copy.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
    if style.wall_subsurface > 0.0:
        copy.subsurf_scatter_enabled = true
        copy.subsurf_scatter_strength = style.wall_subsurface
    _tinted[key] = copy
    return copy


## The material of [param key] ("wall", "floor" or "decor": the cave's rocks): the style's milky corundum
## when it has one, else [param base] tinted toward this rock ([method tinted]).
func surface_material(key: String, base: Material, style: CaveMineralStyle) -> Material:
    if style != null:
        var translucent: Material = {"wall": style.translucent_wall_material,
            "floor": style.translucent_floor_material, "decor": style.translucent_decor_material}.get(key)
        if translucent != null:
            return translucent
    return tinted(base, style)


## Gives the cave surface or rocks [param instance] this rock's colour and fluorescence (instance uniforms of
## the milky corundum), on the fluorescent layer too so the UV torch makes its clouds glow. [param open_air_source]
## says where its share of open sky is read (cave_corundum_rock.gdshader): 0 none (underground), 1 its vertex
## colour (an entrance's ground cover), 2 its MultiMesh custom data (rocks around and before the mouth).
func dress_surface(instance: GeometryInstance3D, style: CaveMineralStyle, open_air_source: int = 0) -> void:
    if style == null:
        return
    instance.set_instance_shader_parameter(&"open_air_source", float(open_air_source))
    instance.set_instance_shader_parameter(&"wall_tint", Vector3(wall_tint.r, wall_tint.g, wall_tint.b))
    instance.set_instance_shader_parameter(&"tint_strength", style.wall_tint_strength)
    instance.set_instance_shader_parameter(&"glow", Vector4(glow_color.r, glow_color.g, glow_color.b, glow_strength))
    instance.layers |= GlobalsDefs.RENDER_MASK_FLUORESCENT


## The mineral the crystals of this cave are made of: the rock [member CaveMineralStyle.crystal_rock_overrides]
## gives this one (rubies in a colourless corundum), else this very rock.
func crystal_mineral(style: CaveMineralStyle) -> CaveMineral:
    if style == null or not style.crystal_rock_overrides.has(slug):
        return self
    var rock: String = style.crystal_rock_overrides[slug]
    if not _crystal_rocks.has(rock):
        _crystal_rocks[rock] = for_slug(rock)
    var crystal: CaveMineral = _crystal_rocks[rock]
    return self if crystal == null else crystal


## The crystal material for this machine's ground quality: the refracting one, or the opaque one on
## medium quality (no screen copy).
static func crystal_material(style: CaveMineralStyle) -> Material:
    if style == null:
        return null
    if style.crystal_material_low != null and _ground_quality() < 2:
        return style.crystal_material_low
    return style.crystal_material


static func _watch_quality() -> void:
    if _watching_quality:
        return
    var tree := Engine.get_main_loop() as SceneTree
    var settings := tree.root.get_node_or_null("SettingsManager") if tree else null
    if settings == null or settings.get("render") == null:
        return
    settings.render.changed.connect(_on_render_changed)
    _watching_quality = true


static func _on_render_changed(keys: PackedStringArray) -> void:
    if not keys.has("ground_quality"):
        return
    var tree := Engine.get_main_loop() as SceneTree
    for node in tree.get_nodes_in_group(CRYSTAL_GROUP):
        var instance := node as GeometryInstance3D
        if instance != null and instance.has_meta(&"mineral_style"):
            instance.material_override = crystal_material(instance.get_meta(&"mineral_style"))


static func _ground_quality() -> int:
    var tree := Engine.get_main_loop() as SceneTree
    var settings := tree.root.get_node_or_null("SettingsManager") if tree else null
    if settings == null or settings.get("render") == null:
        return 2
    return int(settings.render.effective("ground_quality"))


## Paints a crystal MultiMesh with this cave's crystal rock ([method crystal_mineral]): its hue and glow ride
## instance uniforms, the material is shared.
func dress_crystals(instance: GeometryInstance3D, style: CaveMineralStyle) -> void:
    var crystal := crystal_mineral(style)
    instance.material_override = crystal_material(style)
    # The material follows the ground quality setting, also for the caves already built when it changes.
    instance.set_meta(&"mineral_style", style)
    instance.add_to_group(CRYSTAL_GROUP)
    _watch_quality()
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    # Their own layer only: the UV beam reaches them, the glow lights (RENDER_MASK_LOCAL_LIT) do not — set in
    # the cluster, those would light the crystals from inside and turn them milky. The torch, whose mask is
    # every layer, still lights them.
    instance.layers = GlobalsDefs.RENDER_MASK_FLUORESCENT
    instance.set_instance_shader_parameter(&"crystal_color",
        Vector3(crystal.crystal_color.r, crystal.crystal_color.g, crystal.crystal_color.b))
    instance.set_instance_shader_parameter(&"glow",
        Vector4(crystal.glow_color.r, crystal.glow_color.g, crystal.glow_color.b, crystal.glow_strength))


## Soft lights in the crystals' fluorescence colour ([method crystal_mineral]) over the crystal clusters at
## [param transforms] (cave-local), spread at least [member CaveMineralStyle.glow_light_spacing_m] apart, in their
## seeded order. None for crystals glowing weaker than the style's threshold.
func add_glow_lights(root: Node3D, transforms: Array, style: CaveMineralStyle) -> int:
    if style == null:
        return 0
    var crystal := crystal_mineral(style)
    if crystal.glow_strength < style.glow_light_min_strength or style.glow_light_count <= 0:
        return 0
    var kept: Array[Vector3] = []
    for transform: Transform3D in transforms:
        if kept.size() >= style.glow_light_count:
            break
        # Off the support along the cluster's axis, so the light falls on the crystals and around them.
        var point := transform.origin + transform.basis.y.normalized() * 0.8
        var near := false
        for other in kept:
            if other.distance_to(point) < style.glow_light_spacing_m:
                near = true
                break
        if near:
            continue
        kept.append(point)
        var light := OmniLight3D.new()
        light.name = "CrystalGlow%d" % (kept.size() - 1)
        light.position = point
        light.light_color = crystal.glow_color
        light.light_energy = style.glow_light_energy * crystal.glow_strength
        light.light_specular = 0.25
        light.omni_range = style.glow_light_range_m
        light.shadow_enabled = false
        light.light_cull_mask = GlobalsDefs.RENDER_MASK_LOCAL_LIT
        light.distance_fade_enabled = true
        light.distance_fade_begin = style.glow_light_fade_begin_m
        light.distance_fade_length = 10.0
        root.add_child(light)
    return kept.size()

