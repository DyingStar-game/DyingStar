class_name CaveGroundCover
extends RefCounted
## The planet's ground look laid over a cave entrance's open-air surfaces (cave_ground_cover.gdshader), so its
## rim meets the terrain without a change of material. The coverage itself is baked per vertex by
## CaveEntrance.build; this picks the look. Client-side only, read-only with respect to the terrain.

const SHADER := preload("res://scenes/planet/cave/cave_ground_cover.gdshader")
const FALLBACK := Color(0.55, 0.5, 0.45)

# One material per ground texture, never per cave: what varies per site rides an instance uniform.
static var _materials := {}
static var _noise: NoiseTexture2D


## Lays the ground of [param data] at the site [param direction] (body-fixed) over the entrance [param node].
static func apply(node: Node3D, data: PlanetData, direction: Vector3) -> void:
    var surface := node.get_node_or_null("CaveSurface") as GeometryInstance3D
    if surface == null or data == null:
        return
    var look := GroundLook.at(data, direction, FALLBACK)
    var texture: Texture2D = null
    var scale := 0.1
    var strength := 0.0
    if look.material != null and look.material.get_shader_parameter(&"blend_use_albedo") == true:
        texture = look.material.get_shader_parameter(&"blend_albedo_tex") as Texture2D
        scale = float(look.material.get_shader_parameter(&"blend_albedo_scale"))
        strength = float(look.material.get_shader_parameter(&"blend_vertex_color_strength"))
    surface.material_overlay = _material(texture, scale, strength)
    surface.set_instance_shader_parameter(&"ground_tint", Vector3(look.tint.r, look.tint.g, look.tint.b))


static func _material(texture: Texture2D, scale: float, strength: float) -> ShaderMaterial:
    var key: Variant = [texture, scale, strength] if texture != null else "flat"
    if _materials.has(key):
        return _materials[key]
    if _noise == null:
        var noise := FastNoiseLite.new()
        noise.frequency = 0.035
        noise.fractal_octaves = 3
        _noise = NoiseTexture2D.new()
        _noise.width = 256
        _noise.height = 256
        _noise.seamless = true
        _noise.noise = noise
    var material := ShaderMaterial.new()
    material.shader = SHADER
    material.set_shader_parameter(&"cover_noise", _noise)
    material.set_shader_parameter(&"ground_textured", texture != null)
    if texture != null:
        material.set_shader_parameter(&"ground_albedo", texture)
        material.set_shader_parameter(&"ground_scale", scale)
        material.set_shader_parameter(&"ground_tint_strength", strength)
    _materials[key] = material
    return material
