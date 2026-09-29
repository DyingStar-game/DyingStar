class_name ClientSky
extends RefCounted
## The client's sky around an observer: its sun, its atmosphere, its moons — wired to each other.
##
## One place for a wiring that has an order and a cycle: the sun first; the atmosphere reads the
## sun's star direction rather than recomputing it (that geometry is delicate at astronomic
## coordinates); the sun then asks the atmosphere how much of the star survives the air; the moons
## read both. The player gets it on spawn, the menu stage's camera rig gets the very same sky.
##
## The observer must stand under its Planet (Planet.of), expose `camera` (the aerial perspective is
## drawn in front of it) and, if it is a CharacterBody3D, keep its `up_direction` radial.


static func attach(observer: Node3D) -> PlayerSunLight:
	# A DirectionalLight aimed from the real system star toward the observer, for crisp shadows and
	# day/night. The star's OmniLight lights the system but casts no shadows (unusable at scale).
	var sun := PlayerSunLight.new()
	sun.name = "PlayerSunLight"
	sun.player = observer
	observer.add_child(sun)
	# The Environment, the sky dome and the aerial perspective pass, all driven by the current body's
	# AtmosphereProfile.
	var atmosphere := AtmosphereRenderer.new()
	atmosphere.name = "AtmosphereRenderer"
	atmosphere.player = observer
	atmosphere.sun = sun
	observer.add_child(atmosphere)
	sun.atmosphere = atmosphere
	# One directional light per moon of the body we are on, each one's brightness derived from that
	# moon's own size, distance, albedo and phase.
	var moons := MoonLights.new()
	moons.name = "MoonLights"
	moons.player = observer
	moons.sun = sun
	moons.atmosphere = atmosphere
	observer.add_child(moons)
	return sun
