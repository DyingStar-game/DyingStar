class_name NoiseParam

extends Resource

@export_enum("macro", "micro") var noise_type = "macro"

## Amplitude in meters
@export_range(0.0, 4000.0, 0.1) var amplitude: float = 300.0

## Scale of the noise variation
@export_range(0.0, 4000.0, 0.1) var scale: float = 300.0

@export var clamp_min = 0.0
@export var clamp_max = 10000.0

@export_multiline var description = ""
