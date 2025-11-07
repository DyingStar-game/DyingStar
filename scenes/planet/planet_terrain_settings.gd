class_name  PlanetTerrainSettings

extends Resource

## Global scale of the terrain elevation
@export var elev_scale: float = 1.0

## Global noise scale value
@export var noise_scale: float = 1.0

@export var biome_noise: FastNoiseLite

## Macro Noise Generator
@export var noise: FastNoiseLite
## Micro Noise Generator
@export var noise_micro: FastNoiseLite

## Max number of lod levels for the terrain
@export var max_lod: int = 9

## List of noise modifiers to generate the terrain
@export var noise_params: Array[NoiseParam] = []

@export var terrain_map: Texture2D

@export var biomes_elevations: Array[CompressedTexture2D] = []
@export var biomes_albedo: Array[CompressedTexture2D] = []
@export var biomes_normal: Array[CompressedTexture2D] = []
