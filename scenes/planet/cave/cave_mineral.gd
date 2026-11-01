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
## Surface vertices sampled per surface to find the inclusions worth a light (add_inclusion_lights).
const INCLUSION_SAMPLES := 6000
## cave_corundum_rock.gdshader's INCLUSION_*: inclusions reach deep into the rock, lobes and glow around them.
const INCLUSION_FLATTEN := 0.4
const INCLUSION_EXTENT := 1.6
const INCLUSION_GLOW_REACH := 1.15
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
## the milky corundum), on the fluorescent layer too so the UV torch makes its clouds glow.
func dress_surface(instance: GeometryInstance3D, style: CaveMineralStyle) -> void:
    if style == null:
        return
    instance.set_instance_shader_parameter(&"wall_tint", Vector3(wall_tint.r, wall_tint.g, wall_tint.b))
    instance.set_instance_shader_parameter(&"tint_strength", style.wall_tint_strength)
    instance.set_instance_shader_parameter(&"glow", Vector4(glow_color.r, glow_color.g, glow_color.b, glow_strength))
    instance.layers |= GlobalsDefs.RENDER_MASK_FLUORESCENT


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


## Paints a crystal MultiMesh with this rock: its hue and glow ride instance uniforms, the material is shared.
func dress_crystals(instance: GeometryInstance3D, style: CaveMineralStyle) -> void:
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
        Vector3(crystal_color.r, crystal_color.g, crystal_color.b))
    instance.set_instance_shader_parameter(&"glow",
        Vector4(glow_color.r, glow_color.g, glow_color.b, glow_strength))


## Soft lights in the fluorescence colour over the crystal clusters at [param transforms] (cave-local),
## spread at least [member CaveMineralStyle.glow_light_spacing_m] apart, in their seeded order. None for a
## rock glowing weaker than the style's threshold.
func add_glow_lights(root: Node3D, transforms: Array, style: CaveMineralStyle) -> int:
    if style == null or glow_strength < style.glow_light_min_strength or style.glow_light_count <= 0:
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
        light.light_color = glow_color
        light.light_energy = style.glow_light_energy * glow_strength
        light.light_specular = 0.25
        light.omni_range = style.glow_light_range_m
        light.shadow_enabled = false
        light.light_cull_mask = GlobalsDefs.RENDER_MASK_LOCAL_LIT
        light.distance_fade_enabled = true
        light.distance_fade_begin = style.glow_light_fade_begin_m
        light.distance_fade_length = 10.0
        root.add_child(light)
    return kept.size()


## AreaLight3D on the ruby inclusions of the milky corundum (cave_corundum_rock.gdshader) that cut the cave's
## surface, so their red falls on the rock around them; at most
## [member CaveMineralStyle.inclusion_light_count], spread apart, none in a rock that does not fluoresce.
## [param data] is the cave (CaveGenerator), [param texture_origin] the shift its surface was drawn with
## (CavePreviewBuilder.instantiate): the shader lays the inclusions out in those shifted coordinates.
func add_inclusion_lights(root: Node3D, data: Dictionary, texture_origin: Vector3, style: CaveMineralStyle) -> int:
    if style == null or glow_strength <= 0.0 or style.inclusion_light_count <= 0:
        return 0
    # Nearest surface vertex of every inclusion that a vertex comes within its size of (measured as the shader
    # does, depth flattened along the surface normal). Only the vertex's own cell is looked at: that misses the
    # inclusions centred in a neighbour cell, but a sample of the vertices (a cave has ~200 000) still finds far
    # more than the few lights there are room for, and every light found lands on an inclusion drawn.
    var found: Array = []
    var colour := Color(1.0, 0.08, 0.05)
    for key in ["wall", "floor"]:
        var material := (style.translucent_wall_material if key == "wall"
            else style.translucent_floor_material) as ShaderMaterial
        if material == null:
            continue
        var spacing := float(_shader_value(material, &"spot_spacing_m", 4.0))
        var chance := float(_shader_value(material, &"spot_chance", 0.6))
        var reach := INCLUSION_EXTENT * (1.0 + 0.5 * float(_shader_value(material, &"spot_raggedness", 0.4))) \
            * INCLUSION_GLOW_REACH
        var size_max := minf(float(_shader_value(material, &"spot_size_m", 1.0)),
            spacing * (1.0 - INCLUSION_FLATTEN) / reach)
        if key == "wall":
            colour = _shader_value(material, &"spot_color", colour)
        var layout := {}
        var nearest := {}
        var surface: Dictionary = data[key]
        var vertices: PackedVector3Array = surface.vertices
        var normals: PackedVector3Array = surface.normals
        var stride := maxi(1, ceili(vertices.size() / float(INCLUSION_SAMPLES)))
        for index in range(0, vertices.size(), stride):
            var point: Vector3 = vertices[index] + texture_origin
            var cell := Vector3i((point / spacing).floor())
            if not layout.has(cell):
                layout[cell] = _inclusion(Vector3(cell), chance, spacing, size_max)
            var inclusion: Variant = layout[cell]
            if inclusion == null:
                continue
            var normal: Vector3 = normals[index]
            var offset: Vector3 = point - inclusion[0]
            var distance := (offset - normal * offset.dot(normal) * INCLUSION_FLATTEN).length()
            if distance > inclusion[1]:
                continue
            var best: Variant = nearest.get(cell)
            if best == null or distance < best[0]:
                nearest[cell] = [distance, vertices[index], normals[index], inclusion[1]]
        found.append_array(nearest.values())
    found.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
    var kept: Array[Vector3] = []
    for entry: Array in found:
        if kept.size() >= style.inclusion_light_count:
            break
        var at: Vector3 = entry[1]
        var near := false
        for other in kept:
            if other.distance_to(at) < style.inclusion_light_spacing_m:
                near = true
                break
        if near:
            continue
        kept.append(at)
        var normal: Vector3 = (entry[2] as Vector3).normalized()
        var light := AreaLight3D.new()
        light.name = "InclusionLight%d" % (kept.size() - 1)
        # Just off the rock, shining out of it (a light shines along its -Z).
        light.position = at + normal * 0.03
        var up := Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT
        light.basis = Basis.looking_at(normal, up)
        light.area_size = Vector2.ONE * float(entry[3])
        light.area_range = style.inclusion_light_range_m
        light.light_color = colour
        light.light_energy = style.inclusion_light_energy
        light.light_specular = 0.6
        light.shadow_enabled = false
        light.light_cull_mask = GlobalsDefs.RENDER_MASK_LOCAL_LIT
        light.distance_fade_enabled = true
        light.distance_fade_begin = style.inclusion_light_fade_begin_m
        light.distance_fade_length = 10.0
        root.add_child(light)
    return kept.size()


## The inclusion of grid [param cell] as the shader lays it out ([centre, size]), or null if the cell has none.
static func _inclusion(cell: Vector3, chance: float, spacing: float, size_max: float) -> Variant:
    if _hash13(cell + Vector3.ONE * 13.7) > chance:
        return null
    var centre := cell + Vector3(_hash13(cell + Vector3.ONE * 3.1), _hash13(cell + Vector3.ONE * 7.9),
        _hash13(cell + Vector3.ONE * 11.3))
    return [centre * spacing, size_max * (0.5 + 0.5 * _hash13(cell + Vector3.ONE * 29.3))]


## The shader's hash13 (cave_corundum_rock.gdshader), in double precision where the GPU rounds to float: they
## differ by ~1e-3 at most, so about one inclusion in a thousand gets a light it does not show (or none).
static func _hash13(p: Vector3) -> float:
    p *= 0.1031
    p -= p.floor()
    p += Vector3.ONE * p.dot(Vector3(p.z, p.y, p.x) + Vector3.ONE * 31.32)
    var h := (p.x + p.y) * p.z
    return h - floorf(h)


## A shader parameter of [param material], or [param fallback] (the shader's default) when the material does not
## set it: the renderer cannot tell the defaults when headless (dedicated server, tests), so the corundum rock
## materials set the layout parameters explicitly.
static func _shader_value(material: ShaderMaterial, param: StringName, fallback: Variant) -> Variant:
    var value: Variant = material.get_shader_parameter(param)
    return fallback if value == null else value
