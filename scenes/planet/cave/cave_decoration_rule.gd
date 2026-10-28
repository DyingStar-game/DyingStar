@tool
class_name CaveDecorationRule
extends Resource
## One visual mesh and its placement rules. Geometry reserves the walking corridor first.

## Unique rule identifier within the combined library; also determines its seeded placement sequence.
@export var rule_name: String = ""
## Shared decoration geometry; its bounds determine spacing, burial and route clearance.
@export var mesh: Mesh
## Optional shared material override for every instance of this rule.
@export var material: Material
## Optional shared convex collider, authored with the mesh. Rubble and small details remain visual.
@export var collision_shape: ConvexPolygonShape3D
## Legacy palettes keep their arrangement. New art uses area scatter or localized scree clusters.
@export_enum("legacy", "scattered", "clustered") var distribution: String = "legacy"
## Steepest accepted floor support (deg, 0..75); higher values allow placement on steeper slopes.
@export_range(0.0, 75.0, 1.0) var max_slope_deg: float = 35.0
## Whether interior decoration follows its support normal instead of staying upright.
@export var align_to_surface: bool = false
## Surface carrying the asset; entrance supports only exist on fitted planetary openings.
@export_enum("floor", "ceiling", "entrance_ground", "entrance_wall") var support: String = "floor"
## Entrance is the first 15% and, when open, the last 15%; deep starts after 55%.
@export_enum("all", "entrance", "chamber", "deep") var zone: String = "all"
## Mesh origin must be on its support; local +Y points away from the support.
@export_range(0.1, 10.0, 0.1) var scale_min: float = 0.8
## Largest random size multiplier; increasing it permits larger rocks and needs more route clearance.
@export_range(0.1, 10.0, 0.1) var scale_max: float = 1.4
## Minimum spacing between instances of this rule (m, at least 2); higher values produce sparser dressing.
@export_range(2.0, 30.0, 0.5) var spacing_m: float = 7.0
## Conservative bounding radius of the unscaled mesh, used to keep the route clear.
@export_range(0.05, 10.0, 0.05) var radius_m: float = 0.5
## Per-rule instance cap (0..500), also bounded by the shared library budget; zero disables this rule.
@export_range(0, 500, 1) var max_instances: int = 120
