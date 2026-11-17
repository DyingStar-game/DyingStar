extends GutTest
## WeatherPanel: a layer switched off forces its parameter on its own material only.


func after_each() -> void:
	WeatherPanel.off.clear()


func test_a_layer_switched_off_forces_its_parameter() -> void:
	assert_true(WeatherPanel.overrides(WeatherPanel.SKY).is_empty(), "all on: nothing forced")
	var veil: int = -1
	for i in WeatherPanel.LAYERS.size():
		if WeatherPanel.LAYERS[i][1] == WeatherPanel.SKY and WeatherPanel.LAYERS[i][2] == &"mie_beta":
			veil = i
	WeatherPanel.set_layer(veil, false)
	assert_eq(WeatherPanel.overrides(WeatherPanel.SKY), {&"mie_beta": Vector3.ZERO}, "the sky's veil forced to nothing")
	assert_true(WeatherPanel.overrides(WeatherPanel.AERIAL).is_empty(), "the aerial pass keeps its own")
	WeatherPanel.set_layer(veil, true)
	assert_true(WeatherPanel.overrides(WeatherPanel.SKY).is_empty(), "back on: nothing forced")
