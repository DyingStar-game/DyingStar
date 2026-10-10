@tool
class_name UniformWeather
extends WeatherSource
## The same wind everywhere on the planet: one speed, one bearing (each place along its own local
## east / north, so the wind keeps its compass heading all round the sphere), clear air. Client side,
## no service: enough to make the wind's dust live until the weather service is plugged in (see
## WeatherSource).

## Wind speed along the ground (m/s). Over lift_threshold_m_s the wind lifts the ground's dust.
@export_range(0.0, 60.0, 0.5) var wind_speed_m_s: float = 12.0
## Where the wind blows FROM, in degrees clockwise from north: 270 = a west wind, blowing east.
@export_range(0.0, 360.0, 1.0) var wind_from_deg: float = 270.0
## Wind speed (m/s) at which the ground's grains start to move. 5.96 is Tarsis 3's corundum plains.
@export_range(0.0, 30.0, 0.01) var lift_threshold_m_s: float = 5.96


func sample(_planet: Planet, _local_dir: Vector3) -> Dictionary:
	var parts: Vector2 = wind_parts(wind_speed_m_s, wind_from_deg)
	return {
		"wind_east_m_s": parts.x,
		"wind_north_m_s": parts.y,
		"wind_speed_m_s": wind_speed_m_s,
		"wind_from_deg": wind_from_deg,
		"dust_tau": 0.0,
		"lift_threshold_m_s": lift_threshold_m_s,
	}


## The (east, north) parts (m/s) of a wind of [param speed_m_s] blowing FROM [param from_deg]
## (clockwise from north): a wind from the west (270) blows toward the east, (+speed, 0).
static func wind_parts(speed_m_s: float, from_deg: float) -> Vector2:
	var to: float = deg_to_rad(from_deg + 180.0)
	return Vector2(sin(to), cos(to)) * speed_m_s
