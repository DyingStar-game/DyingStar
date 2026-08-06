class_name MineralDef
extends Resource

## Visual identity of a mineral shown inside a mining rock (gold, cryptonite, ...).
##
## SRP: this describes only how the ore LOOKS. The ore FIELD — how much ore and where it
## sits in the rock volume (amount, dispersion, persistence across fractures) — stays on the
## rock (`rock_mining.gd`), so swapping minerals never changes the fracture/purity behaviour.
## One `.tres` per mineral; rocks reference one. Adding a new mineral = drop a texture + a
## new `.tres`, no shader or code change (the shader is parameterised — see rock_vein.gdshader).

## Identifier (e.g. &"gold"), handy for attribution/replication later.
@export var id: StringName = &""

@export_group("Albedo")
## When true the ore is drawn with `albedo_tex` (triplanar, local space) instead of a flat color.
@export var use_texture: bool = false
@export var albedo_tex: Texture2D = null
## Tints the texture, or IS the ore color when `use_texture` is false.
@export var color: Color = Color(0.1, 0.8, 0.2)

@export_group("Surface")
@export var normal_tex: Texture2D = null
## Strength of the ore normal-map relief (0 = flat). Ignored when no `normal_tex`.
@export_range(0.0, 2.0) var normal_strength: float = 1.0
## Triplanar tiling of the ore textures (local space).
@export var tex_scale: float = 1.0

@export_group("Material")
@export_range(0.0, 1.0) var metallic: float = 1.0
@export_range(0.0, 1.0) var roughness: float = 0.14
## Self-illumination. 0 = realistic metal; >0 = glows (the old cryptonite preset used ~9).
@export var emission: float = 0.0
