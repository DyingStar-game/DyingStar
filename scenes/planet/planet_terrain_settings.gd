class_name  PlanetTerrainSettings

extends Resource

## Global scale of the terrain elevation
@export var elev_scale: float = 1.0

## Global noise scale value
@export var noise_scale: float = 1.0

## Macro Noise Generator
@export var noise: FastNoiseLite
## Micro Noise Generator
@export var noise_micro: FastNoiseLite

## List of noise modifiers to generate the terrain
@export var noise_params: Array[NoiseParam]
