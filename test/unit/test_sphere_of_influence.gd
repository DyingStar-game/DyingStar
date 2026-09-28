extends GutTest
## Which body a free body belongs to: the one whose sphere of influence holds it (Laplace, a·(m/M)^(2/5)).
## The physics decides, so the numbers are checked against sources that do not share our code: the
## textbook value for the Earth, and the one the resourcesDynamic service hands Horizon for SandBox.

## Orbit elements exactly as saved in tarsis_3.tscn (SandBox) and tarsis_3_1.tscn (Korax, its moon).
## Copied rather than loaded: loading a planet scene builds its world, and its errors fail the test.
const SANDBOX := {"peri": 0.5335, "apo": 0.5665, "mass_earths": 0.788, "primary_kg": 1.5088184e30}
const KORAX := {
	"peri": 0.0007279515376150337,
	"apo": 0.0007426576292840243,
	"mass_earths": 0.007102,
	"primary_kg": 4.705936e24,
}
## What the service announces for SandBox (Horizon planet data, `soi`, at 0.55 AU, 1:1).
const SANDBOX_SOI_FROM_SERVICE_M := 516294973.0


func _body(elements: Dictionary) -> Planet:
	var p := Planet.new()
	p.orbit_periapsis_au = elements["peri"]
	p.orbit_apoapsis_au = elements["apo"]
	p.orbit_mass_earths = elements["mass_earths"]
	p.orbit_primary_mass_kg = elements["primary_kg"]
	return autofree(p)


func test_earth_sphere_of_influence_is_the_textbook_value() -> void:
	# 925 000 km in every table; the Moon, at 384 000 km, is well inside.
	var soi: float = Planet.laplace_soi(KeplerOrbit.AU_M, Planet.MASS_EARTH, KeplerOrbit.SOLAR_MASS_KG)
	assert_almost_eq(soi / 1000.0, 925000.0, 9250.0, "Earth: %.0f km" % (soi / 1000.0))


func test_sandbox_matches_what_the_service_announces() -> void:
	var soi: float = _body(SANDBOX).sphere_of_influence_m()
	assert_almost_eq(soi, SANDBOX_SOI_FROM_SERVICE_M, SANDBOX_SOI_FROM_SERVICE_M * 0.001,
			"SandBox: %.0f km, service %.0f km" % [soi / 1000.0, SANDBOX_SOI_FROM_SERVICE_M / 1000.0])


func test_a_moon_sphere_nests_inside_its_planet_sphere() -> void:
	var planet_soi: float = _body(SANDBOX).sphere_of_influence_m()
	var moon_soi: float = _body(KORAX).sphere_of_influence_m()
	var moon_far: float = KORAX["apo"] * KeplerOrbit.AU_M
	assert_between(moon_soi / 1000.0, 15000.0, 18500.0, "Korax: %.0f km" % (moon_soi / 1000.0))
	# The whole of the moon's sphere, even at its farthest from the planet, lies inside the planet's:
	# leaving the moon puts you in the planet's frame, never straight out into the star's space.
	assert_lt(moon_far + moon_soi, planet_soi)


func test_a_body_without_orbit_elements_keeps_its_own_ground_and_air() -> void:
	# No elements: the sphere is the body's own reach (0 here, with no PlanetData), never garbage.
	var bare: Planet = autofree(Planet.new())
	assert_eq(bare.sphere_of_influence_m(), bare.domain_radius_m())
	assert_eq(Planet.laplace_soi(0.0, 1.0, 1.0), 0.0)
	assert_eq(Planet.laplace_soi(1.0, 1.0, 0.0), 0.0)


func test_the_innermost_sphere_rules() -> void:
	var centres := PackedVector3Array([Vector3.ZERO, Vector3(1.1e8, 0.0, 0.0)])
	var radii := PackedFloat64Array([5.16e8, 1.67e7])
	# Beside the moon: inside both spheres, and the moon's is the smaller one.
	assert_eq(Planet.innermost_holding(Vector3(1.1e8 + 1.0e6, 0.0, 0.0), centres, radii), 1)
	# Halfway out: only the planet's.
	assert_eq(Planet.innermost_holding(Vector3(0.0, 3.0e8, 0.0), centres, radii), 0)
	# Beyond both: the star's space.
	assert_eq(Planet.innermost_holding(Vector3(0.0, 6.0e8, 0.0), centres, radii), -1)


func test_the_innermost_sphere_rules_whatever_the_order() -> void:
	var centres := PackedVector3Array([Vector3(1.1e8, 0.0, 0.0), Vector3.ZERO])
	var radii := PackedFloat64Array([1.67e7, 5.16e8])
	assert_eq(Planet.innermost_holding(Vector3(1.1e8, 1.0e6, 0.0), centres, radii), 0)


func test_a_station_holds_what_floats_within_its_eva_radius() -> void:
	var station: OrbitalStation = add_child_autofree(OrbitalStation.new())
	station.set_process(false)  # no orbit here: nothing to place
	var site := StationSite.new()
	site.eva_radius_m = 1000.0
	station._site = site  # the radius is the site's
	assert_true(station.holds(station.global_position + Vector3(0.0, 999.0, 0.0)))
	assert_false(station.holds(station.global_position + Vector3(0.0, 1001.0, 0.0)))


func test_a_station_is_found_from_anything_aboard() -> void:
	var station: OrbitalStation = add_child_autofree(OrbitalStation.new())
	station.set_process(false)
	var deck := Node3D.new()
	var body := Node3D.new()
	station.add_child(deck)
	deck.add_child(body)
	assert_eq(OrbitalStation.of(body), station)
	assert_eq(OrbitalStation.of(station), station)
	assert_null(OrbitalStation.of(self))
