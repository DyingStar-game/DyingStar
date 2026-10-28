@tool
class_name CaveAssetLibrary
extends Resource
## References shared materials and decoration meshes; does not copy their source assets.

## Stable asset library identifier included in decoration request signatures.
@export var library_id: String = ""
## Human-readable palette name displayed by the authoring interface.
@export var display_name: String = ""
## Family from tools/schema/tags.json, used by the game's surface taxonomy.
@export var surface_family: String = "rock"
## Shared material applied to generated cave walls and vaults.
@export var wall_material: Material
## Shared material applied to generated cave floors.
@export var floor_material: Material
## Ordered interior decoration rules; each competes for the shared instance budget.
@export var decorations: Array[CaveDecorationRule] = []
## Optional separate asset set for exterior ground and embedded entrance rocks; interiors keep their own meshes.
@export var entrance_library: CaveAssetLibrary
## Shared visual instance budget for every rule in a cave, independent of its length.
@export_range(0, 1000, 1) var instance_budget: int = 240


static func default_for(family: String, open_mouth: bool = false) -> CaveAssetLibrary:
    var suffix := "_open" if open_mouth else ""
    var name := "rock_sculpted" if family == "rock" else family
    return load("res://scenes/planet/cave/libraries/cave_%s%s.tres" % [name, suffix])


func decoration_rules() -> Array[CaveDecorationRule]:
    var rules: Array[CaveDecorationRule] = decorations.duplicate()
    if entrance_library != null and entrance_library != self:
        rules.append_array(entrance_library.decorations)
    return rules


func validation_error() -> String:
    if entrance_library != null and (entrance_library == self or entrance_library.entrance_library != null):
        return "La bibliothèque d’entrée doit être indépendante, sans référence récursive."
    if instance_budget < 0 or instance_budget > 1000:
        return "Budget de décors hors limites."
    var names: Dictionary = {}
    for rule in decoration_rules():
        if rule == null or rule.mesh == null:
            return "Chaque règle doit référencer un maillage."
        if rule.rule_name.is_empty() or names.has(rule.rule_name):
            return "Les règles de décor doivent avoir des noms uniques et non vides."
        names[rule.rule_name] = true
        for value in [rule.scale_min, rule.scale_max, rule.spacing_m, rule.radius_m, rule.max_slope_deg]:
            if not is_finite(value):
                return "Paramètre de décor non fini."
        if rule.scale_min <= 0.0 or rule.scale_max < rule.scale_min or rule.spacing_m < 2.0 \
                or rule.max_instances < 0 or rule.max_instances > 500 \
                or rule.support not in ["floor", "ceiling", "entrance_ground", "entrance_wall"] \
                or rule.zone not in ["all", "entrance", "chamber", "deep"]:
            return "Échelle ou espacement de décor invalide."
        if rule.distribution not in ["legacy", "scattered", "clustered"] or rule.max_slope_deg < 0 or rule.max_slope_deg > 75:
            return "Distribution ou pente de support invalide."
        var box := rule.mesh.get_aabb()
        var reach := maxf(absf(box.position.x), absf(box.end.x))
        reach = maxf(reach, maxf(absf(box.position.z), absf(box.end.z)))
        if rule.radius_m < reach:
            return "Le rayon de sécurité du décor %s est trop petit (minimum %.2f m)." % [rule.rule_name, reach]
    return ""
