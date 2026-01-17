@tool
class_name VegetationRule
extends Resource
## Maps a biome colour to a vegetation mesh with scattering parameters.
##
## The biome colour is compared against the biomemap pixel using a tolerance
## (Euclidean distance in RGB space, ignoring alpha).  When a match is found,
## instances of [member mesh] are scattered over the matching area.

## Human-readable label (e.g. "pine_forest").
@export var rule_name: String = ""

@export_group("Biome Matching")
## Biome type string from the GeoJSON (e.g. "forest", "desert").
## When set AND a biomes GeoJSON is available on PlanetData, matching uses
## polygon zones instead of biomemap colour sampling.  This is the
## preferred method — it bypasses any colour-space issues.
@export var biome_type: String = ""
## Target biome colour (compared to the biomemap).
## Used as fallback when biome_type is empty or no GeoJSON is loaded.
@export var biome_color: Color = Color.BLACK
## Maximum Euclidean distance per matched channel to consider a match (0–1).
@export_range(0.0, 1.0, 0.01) var color_tolerance: float = 0.15
## Which channels to compare. The biomemap may encode density in the G channel,
## so matching only R+B lets you target the biome type regardless of density.
## Values: "rgb" (default), "rb" (ignore green), "r" (red only).
@export_enum("rgb", "rb", "r") var match_channels: String = "rgb"

@export_group("Mesh")
## The tree/vegetation mesh to instance.  Can be loaded from a .tscn via
## [method PlanetVegetation.mesh_from_scene] or assigned directly.
@export var mesh: Mesh
## Scene to auto-merge into [member mesh] at runtime (optional).
## If set, [member mesh] is ignored and the scene's MeshInstance3D children
## are merged via SurfaceTool.
@export var mesh_scene: PackedScene

@export_group("Scattering")
## Maximum number of instances per terrain chunk.
@export var max_per_chunk: int = 200
## Minimum distance between instances (metres).  Prevents overlap.
@export var min_spacing: float = 8.0
## LOD levels at which vegetation is spawned (0 = closest).
## Vegetation is ONLY placed on chunks whose LOD is in this set.
@export var spawn_lod_levels: Array[int] = [0]

@export_group("Transform")
## Scale range — each instance picks a uniform scale in [min, max].
@export var scale_min: float = 0.8
@export var scale_max: float = 1.4
## Whether to apply a random Y-axis rotation.
@export var random_yaw: bool = true
## Maximum random tilt in degrees (simulates uneven ground).
@export var max_tilt_deg: float = 5.0


## Check whether a sampled biome colour matches this rule.
func matches_color(c: Color) -> bool:
	var dr := c.r - biome_color.r
	var db := c.b - biome_color.b
	var tol_sq := color_tolerance * color_tolerance
	match match_channels:
		"r":
			return (dr * dr) <= tol_sq
		"rb":
			return (dr * dr + db * db) <= tol_sq
		_:  # "rgb"
			var dg := c.g - biome_color.g
			return (dr * dr + dg * dg + db * db) <= tol_sq
