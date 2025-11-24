@tool
extends Control

@export_tool_button("generate") var gen = generate_color

@export var n2 = 0.7
@export var o2 = 0.21
@export var co2 = 0.01
@export var ch4 = 0.0
@export var so2 = 0.0
@export var h2 = 0.0
@export var he = 0.0

func generate_color():
	$ColorRect.color = get_atmosphere_color({
		"N2": n2,
		"O2": o2,
		"CO2": co2,
		"CH4": ch4,
		"SO2": so2,
		"H2": h2,
		"He": he,
	})

# Atmospheric color generator
# composition is a dictionary of gas -> percentage (0.0–1.0)
# Example: {"N2": 0.78, "O2": 0.21, "CO2": 0.01}
func get_atmosphere_color(composition: Dictionary) -> Color:
	var colors := {
		"N2": Color(0.5, 0.7, 1.0),   # Nitrogen → blue sky
		"O2": Color(0.4, 0.6, 1.0),   # Oxygen → enhances blueness
		"CO2": Color(0.9, 0.5, 0.3),  # CO2 → reddish tint
		"CH4": Color(0.6, 0.8, 0.7),  # Methane → cyan tint
		"SO2": Color(1.0, 0.9, 0.6),  # Sulfur dioxide → yellowish haze
		"H2": Color(0.7, 0.9, 1.0),   # Hydrogen → pale blue
		"He": Color(0.8, 0.9, 1.0)    # Helium → very light tint
	}

	var result := Color(0, 0, 0)
	var total := 0.0

	for gas in composition.keys():
		if gas in colors:
			var amount = composition[gas]
			result += colors[gas] * amount
			total += amount

	if total > 0:
		result /= total  # normalize

	# Clamp to valid range
	return Color(
		clamp(result.r, 0, 1),
		clamp(result.g, 0, 1),
		clamp(result.b, 0, 1),
		1.0
	)
