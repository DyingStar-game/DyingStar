extends GutTest
## The vehicle lift's three kiosks (lower landing, upper landing, platform) are 3D screens of the
## ScreenTarget contract: the crosshair finds them, the client names them in its action, and the server
## finds them again. They used a ScreenZone box in front of them, which no longer exists.

const SCREENS: Array[String] = [
	"res://scenes/_universe/structures/industrial/vehicle_lift/landings/lower_landing/lower_landing.tscn",
	"res://scenes/_universe/structures/industrial/vehicle_lift/landings/upper_landing/upper_landing.tscn",
	"res://scenes/_universe/structures/industrial/vehicle_lift/platform/platform.tscn",
]


func test_each_kiosk_is_a_screen_the_crosshair_and_the_server_find() -> void:
	for path: String in SCREENS:
		var lift := Node3D.new()  # stands for the networked VehicleLift the screen sits in
		var sync := PropSync.new()
		sync.name = "PropSync"
		sync.uuid = "lift-uuid"
		lift.add_child(sync)
		var screen: Node3D = (load(path) as PackedScene).instantiate()
		lift.add_child(screen)
		add_child(lift)
		await wait_physics_frames(1)
		var name: String = path.get_file()
		var gui: Node3D = ScreenTarget.gui_of(screen)
		assert_not_null(gui, "%s: its kiosk's Gui3D is a screen of the crosshair" % name)
		if gui == null:
			continue
		assert_true(ScreenTarget.owner_of(gui) == screen, "%s: it owns its screen (update_screen)" % name)
		assert_true(screen.has_method("set_screen_actor"), "%s: it is told who pressed" % name)
		assert_not_null(gui.get("node_viewport"), "%s: the kiosk handed its interface over" % name)
		var address: Dictionary = ScreenTarget.address_of(screen)
		assert_eq(str(address.get("target_uuid", "")), str(PropSync.networked_from(screen).get_node("PropSync").uuid),
				"%s: named by its networked node" % name)
		var quad: MeshInstance3D = gui.get("node_quad")
		var eye: Vector3 = quad.global_position + quad.global_basis.z.normalized() * 1.0
		assert_not_null(gui.hit(eye, -quad.global_basis.z.normalized(), 4.0), "%s: the crosshair hits it from 1 m" % name)
		var networked: Node = PropSync.networked_from(screen)
		assert_true(ScreenTarget.resolve(networked, address, eye) == screen, "%s: the server finds it again" % name)
		assert_eq(screen.find_children("ScreenDetector", "", true, false).size(), 0, "%s: no zone left" % name)
		lift.free()
	# Headless (dummy renderer), freeing the lift's models reports "Parameter material is null": the
	# engine's, not the screens'. Those, and only those, are expected.
	for err in get_errors():
		if "material" in str(err.code) or "material" in str(err.rationale):
			err.handled = true


## Both landings run one script (LiftLanding); what tells them apart is set on each scene's root: the
## end they call the platform to, their railing layout and the screen that shows the trip.
func test_each_landing_knows_its_end_and_its_screen() -> void:
	for at: Array in [[SCREENS[0], false, "Lower Landing Interface"], [SCREENS[1], true, "Upper Landing Interface"]]:
		var landing := (load(str(at[0])) as PackedScene).instantiate() as LiftLanding
		assert_not_null(landing, "%s: a LiftLanding" % str(at[0]).get_file())
		if landing == null:
			continue
		assert_eq(landing.is_upper, at[1], "%s: its end of the lift" % landing.name)
		assert_not_null(landing.landing_interface, "%s: its screen" % landing.name)
		if landing.landing_interface != null:
			assert_eq(str(landing.landing_interface.name), str(at[2]))
		assert_true(FileAccess.file_exists(landing.railing_json_path), "%s: its railing layout" % landing.name)
		landing.free()
	# Headless (dummy renderer), freeing the models reports "Parameter material is null": the engine's,
	# not ours (see test_vehicle_lift_screens). Those, and only those, are expected.
	for err in get_errors():
		if "material" in str(err.code) or "material" in str(err.rationale):
			err.handled = true
