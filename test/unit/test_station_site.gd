extends GutTest
## StationSite / StationOrbit: a station orbits its body for real, as a pure function of time — the
## same way a moon does, in the same parent frame.

const SANDBOX := {
	"map_radius_km": 6356.0,
	"orbit_mass_earths": 0.788,
	"rotation_period_hours": 25.0,
	"axial_tilt_deg": 15.0,
}

var _site: StationSite = null


func before_each() -> void:
	_site = StationSite.new()
	_site.id = "tarsis_3/test"
	_site.body_key = "tarsis_3"
	_site.proper_name = "Test"
	_site.altitude_m = 400000.0
	_site.inclination_deg = 51.6


func test_400_km_takes_an_hour_and_44() -> void:
	var orbit: StationOrbit = _site.orbit(SANDBOX)
	assert_almost_eq(orbit.radius_m, 6756000.0, 0.01, "reference radius + altitude")
	assert_almost_eq(orbit.period_seconds(), 6225.8, 5.0, "Kepler: 2π·sqrt(r³/GM)")


func test_the_altitude_holds_all_the_way_round() -> void:
	var orbit: StationOrbit = _site.orbit(SANDBOX)
	for i in 12:
		var t: float = orbit.period_seconds() * i / 12.0
		assert_almost_eq(orbit.position_at(t).length(), 6756000.0, 0.5, "circular at t=%.0f" % t)


func test_it_comes_back_after_one_period() -> void:
	var orbit: StationOrbit = _site.orbit(SANDBOX)
	var start: Vector3 = orbit.position_at(1000.0)
	assert_lt(start.distance_to(orbit.position_at(1000.0 + orbit.period_seconds())), 1.0, "one lap")


func test_the_orbit_is_inclined_against_the_equator_not_the_ecliptic() -> void:
	var orbit: StationOrbit = _site.orbit(SANDBOX)
	var quarter: float = orbit.period_seconds() / 4.0
	var normal: Vector3 = orbit.position_at(0.0).cross(orbit.position_at(quarter)).normalized()
	# The body's spin axis in the same parent frame: Planet._place_at_time tips it by the axial tilt.
	var spin_axis: Vector3 = Basis(Vector3.BACK, deg_to_rad(15.0)) * Vector3.UP
	assert_almost_eq(rad_to_deg(normal.angle_to(spin_axis)), 51.6, 0.01, "51.6° from the pole")


func test_it_orbits_the_way_the_body_spins() -> void:
	# Prograde, like a real station: its angular momentum points along the spin axis, not against it.
	var orbit: StationOrbit = _site.orbit(SANDBOX)
	var p0: Vector3 = orbit.position_at(0.0)
	var momentum: Vector3 = p0.cross(orbit.position_at(10.0) - p0)
	var spin_axis: Vector3 = Basis(Vector3.BACK, deg_to_rad(15.0)) * Vector3.UP
	assert_gt(momentum.dot(spin_axis), 0.0, "same sense as the planet's rotation")


func test_the_ascending_node_turns_about_the_spin_axis() -> void:
	var a: StationOrbit = _site.orbit(SANDBOX)
	_site.ascending_node_deg = 90.0
	var b: StationOrbit = _site.orbit(SANDBOX)
	var spin_axis: Vector3 = Basis(Vector3.BACK, deg_to_rad(15.0)) * Vector3.UP
	var quarter: float = a.period_seconds() / 4.0
	var na: Vector3 = a.position_at(0.0).cross(a.position_at(quarter)).normalized()
	var nb: Vector3 = b.position_at(0.0).cross(b.position_at(quarter)).normalized()
	assert_almost_eq(rad_to_deg(nb.angle_to(spin_axis)), 51.6, 0.01, "same inclination")
	assert_gt(rad_to_deg(na.angle_to(nb)), 1.0, "a different plane")


func test_synchronous_radius_matches_known_orbits() -> void:
	assert_almost_eq(StationOrbit.synchronous_radius(3.986004e14, 86164.09) / 1000.0, 42164.0, 1.0, "Earth GEO")
	_site.altitude_mode = StationSite.AltitudeMode.SYNCHRONOUS
	var orbit: StationOrbit = _site.orbit(SANDBOX)
	assert_almost_eq(orbit.radius_m / 1000.0, 40092.0, 5.0, "Sandbox: 25 h day, 0.788 Earth masses")
	assert_almost_eq(orbit.period_seconds(), 90000.0, 1.0, "one orbit per day")


func test_the_floor_faces_the_body() -> void:
	var orbit: StationOrbit = _site.orbit(SANDBOX)
	for t: float in [0.0, 1500.0, 4000.0]:
		var attitude: Basis = orbit.attitude_at(t)
		var radial: Vector3 = orbit.position_at(t).normalized()
		assert_almost_eq(attitude.y.dot(radial), 1.0, 1e-6, "+Y away from the planet at t=%.0f" % t)
		var motion: Vector3 = (orbit.position_at(t + 1.0) - orbit.position_at(t)).normalized()
		assert_gt((-attitude.z).dot(motion), 0.999, "-Z along the motion")
		assert_almost_eq(attitude.determinant(), 1.0, 1e-6, "a proper rotation")


func test_uuid_is_stable_and_per_station() -> void:
	var same := StationSite.new()
	same.id = _site.id
	var other := StationSite.new()
	other.id = "tarsis_3/other"
	assert_eq(_site.uuid(), same.uuid(), "same id, same uuid, on every machine")
	assert_ne(_site.uuid(), other.uuid(), "one uuid per station")
	assert_eq(_site.uuid().length(), 36, "uuid format")


func test_the_palaka_pital_station_is_listed() -> void:
	var sites: Array[StationSite] = StationSites.for_body("tarsis", "tarsis_3")
	assert_eq(sites.size(), 1, "one station around Sandbox")
	assert_eq(sites[0].proper_name, "Palaka-Pital")
	assert_eq(StationSites.by_uuid("tarsis", sites[0].uuid()), sites[0], "found back by uuid")
	# Sandbox's figures, not its scene: loading tarsis_3.tscn drags in every dependency and their load
	# errors, which GUT counts against whichever test happens to run.
	assert_almost_eq(sites[0].altitude_above(SANDBOX), 400000.0, 0.01, "400 km")
	assert_almost_eq(sites[0].inclination_deg, 51.6, 1e-6, "like the ISS")


func test_a_station_wears_the_orbital_icon_not_the_capitals() -> void:
	# The chart asks the icon table with the station's id; a proper name starting "Palaka-Pital" would
	# match the capital's rule, which comes first.
	var icons: PoiIconSet = load("res://assets/textures/poi/poi_icons.tres")
	var poi := {"kind": StarMap.STATION_POI_KIND, "name": "tarsis_3/palaka_pital"}
	assert_eq(icons.icon_for(poi).resource_path, "res://assets/textures/poi/orbital_station.png")
	assert_eq(icons.kind_label(poi), tr("%%POI_KIND_ORBITAL"), "and reads as an orbital station")
