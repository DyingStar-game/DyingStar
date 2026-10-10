@tool
class_name WeatherSource
extends Resource
## Where a planet's weather comes from: the ONE place the dust effects (and anything else that reads
## the weather) are fed from, through Planet.weather_at / Planet.wind_world_at. Swap the source and
## every consumer follows, without a line changed in any of them.
##
## Today a planet uses UniformWeather (the same wind everywhere, client side). The weather service
## (a sampled climate plus the storms Horizon relays) is meant to plug in here as another subclass
## returning the same keys.
##
## The contract, every key optional (a missing key reads as calm, clear air):
## - "wind_east_m_s", "wind_north_m_s": the wind along the ground, in the local east / north axes
##   (Planet.local_axes), m/s.
## - "wind_speed_m_s": their length; "wind_from_deg": where it blows FROM, clockwise from north.
## - "dust_tau": the dust's optical depth over the place (0 = clear air, 2 = a storm).
## - "lift_threshold_m_s": the wind speed at which the ground's grains start to move (DustLift).
## - "air_density_kg_m3": the air's density (what the wind's sound carries). Planet.weather_at fills it
##   from the planet's atmosphere when the source leaves it out.
##
## @tool: a Resource script without it is a placeholder in the editor, and every call on it fails.


## The weather at [param local_dir] (unit vector from [param planet]'s centre, in its own frame), as
## the keys above. The base class has no weather: calm, clear air.
func sample(_planet: Planet, _local_dir: Vector3) -> Dictionary:
	return {}
