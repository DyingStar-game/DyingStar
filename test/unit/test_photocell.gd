extends GutTest
## Photocell, the twilight switch: on below on_below_deg, off above off_above_deg, each lamp after its
## own wait, the same wait on every client, at once when the clock jumps. The star's height and the
## seconds are fed by hand here (update / advance), the way _process feeds them in the game.

const PHOTOCELL := "res://scenes/common/photocell.gd"
## The scenes whose lights follow the daylight, and the node each one's Photocell sits under.
const WIRED := {
	"res://scenes/_universe/props/furniture/furn_floodlight_outdoor_lg.tscn": "SpotLight3D",
	"res://scenes/_universe/props/furniture/furn_lamppost_outdoor_2.2m.tscn": "SpotLight3D",
	"res://scenes/_universe/structures/industrial/garage.tscn": "NeonSign",
	"res://scenes/_universe/structures/industrial/cargo_depot.tscn": "NeonSign",
	"res://scenes/_universe/structures/buildings/teleporter/teleporter.tscn": "NeonSign",
}


func test_arriving_at_night_the_lamp_is_already_on() -> void:
	var night := _lamp()
	night.cell.update(_night(night.cell))
	assert_true(night.light.visible, "switched at once: no wait on the first reading")
	var day := _lamp()
	day.cell.update(_day(day.cell))
	assert_false(day.light.visible, "off in daylight")


func test_at_dusk_each_lamp_waits_its_own_delay() -> void:
	var lamp := _lamp()
	var cell: Photocell = lamp.cell
	cell.update(_day(cell))
	cell.update(_dusk(cell))
	var wait := cell.delay_s()
	assert_between(wait, 0.0, cell.max_delay_s)
	cell.advance(wait - 0.01)
	assert_false(lamp.light.visible, "still waiting its turn")
	cell.advance(0.02)
	assert_true(lamp.light.visible, "on once its wait is over")


func test_when_the_clock_jumps_the_lamp_switches_at_once() -> void:
	var lamp := _lamp()
	var cell: Photocell = lamp.cell
	cell.update(_day(cell))
	cell.update(_night(cell), true)
	assert_true(lamp.light.visible, "the hour slider, the dev clock: night fell all at once")


func test_between_the_thresholds_the_lamp_keeps_its_state() -> void:
	var lamp := _lamp()
	var cell: Photocell = lamp.cell
	cell.update(_night(cell))
	cell.update((cell.on_below_deg + cell.off_above_deg) * 0.5)
	cell.advance(1000.0)
	assert_true(lamp.light.visible, "above on_below but under off_above: no blinking")
	cell.update(_dawn(cell))
	cell.advance(cell.max_delay_s)
	assert_false(lamp.light.visible, "off at dawn")


func test_back_over_the_threshold_before_the_wait_cancels_it() -> void:
	var lamp := _lamp()
	var cell: Photocell = lamp.cell
	cell.update(_day(cell))
	cell.update(_dusk(cell))
	cell.update(_dawn(cell))
	cell.advance(1000.0)
	assert_false(lamp.light.visible)


func test_the_wait_is_the_same_on_every_client_and_differs_between_lamps() -> void:
	var waits := {}
	for uuid: String in ["5b43b0ca", "818498de", "0edd4b47", "790c8a2e", "52dccfcd", "2a1fa62e"]:
		var first := _cell_of_prop(uuid).delay_s()
		assert_eq(_cell_of_prop(uuid).delay_s(), first, "same prop, same wait: drawn from its uuid")
		waits[first] = true
	assert_gt(waits.size(), 1, "the lamps of a village do not all wait the same")


func test_it_switches_a_neon_sign_which_strikes_before_it_holds() -> void:
	var sign := NeonSign.new()
	var cell := Photocell.new()
	sign.add_child(cell)
	add_child_autofree(sign)
	cell.set_process(false)
	cell.update(_day(cell))
	assert_false(sign.lit, "off in daylight")
	cell.update(_night(cell))
	cell.advance(cell.max_delay_s)
	assert_true(sign.lit)
	assert_true(sign.is_igniting(), "the tube strikes a few times first")
	await wait_seconds(1.5)
	assert_false(sign.is_igniting(), "then it holds")


func test_the_lamps_and_signs_are_wired() -> void:
	for path: String in WIRED:
		var text := FileAccess.get_file_as_string(path).replace("\r\n", "\n")
		var ext := RegEx.create_from_string(
				"\\[ext_resource [^\\]]*path=\"%s\" id=\"([^\"]+)\"\\]" % PHOTOCELL).search(text)
		assert_not_null(ext, "%s uses a Photocell" % path)
		if ext == null:
			continue
		var under := RegEx.create_from_string("\\[node [^\\n]*parent=\"%s\"[^\\n]*\\]\\nscript = ExtResource\\(\"%s\"\\)"
				% [WIRED[path], ext.get_string(1)])
		assert_not_null(under.search(text), "%s: the Photocell drives its %s" % [path, WIRED[path]])


## Heights of the star taken from the cell's own thresholds, so the tests follow their tuning.
func _night(cell: Photocell) -> float:
	return cell.on_below_deg - 10.0


func _dusk(cell: Photocell) -> float:
	return cell.on_below_deg - 0.5


func _dawn(cell: Photocell) -> float:
	return cell.off_above_deg + 0.5


func _day(cell: Photocell) -> float:
	return cell.off_above_deg + 10.0


## A light with a Photocell under it, in the tree, its clock fed by hand.
func _lamp() -> Dictionary:
	var light := OmniLight3D.new()
	var cell := Photocell.new()
	light.add_child(cell)
	add_child_autofree(light)
	cell.set_process(false)
	return {"light": light, "cell": cell}


## A Photocell in a prop whose uuid is [param uuid], out of the tree like a freshly built prop.
func _cell_of_prop(uuid: String) -> Photocell:
	var prop := Node3D.new()
	var sync := PropSync.new()
	sync.name = "PropSync"
	sync.uuid = uuid
	prop.add_child(sync)
	var light := OmniLight3D.new()
	light.name = "SpotLight3D"  # a scene's nodes have fixed names; the wait is drawn from the path too
	prop.add_child(light)
	var cell := Photocell.new()
	cell.name = "Photocell"
	light.add_child(cell)
	autofree(prop)
	return cell
