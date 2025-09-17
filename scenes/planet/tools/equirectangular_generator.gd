@tool
extends Node

@export var width := 1024
@export var height := 1024
@export var scale := 1

@export var seed := 1337

@export var planet_distance = 1.0 # AU
@export var planet_lum = 1.0 # fraction of sun luminosity

@export var water_lvl = 0.2
@export var greenhouse_factor = 0.7 # portion of CO2 in atmo
@export var ocean_frac = 0.6
@export var atmo_pressure = 1.0

# Elevation noise
@export var continent_frequency := 2.4
@export var mountain_frequency := 1.7

# Climate noise
@export var temp_frequency := 0.3
@export var humid_frequency := 0.6

@export_tool_button("Generate") var gen = generate_maps

var noise_plaque := FastNoiseLite.new()
var noise_continent := FastNoiseLite.new()
var noise_mountain := FastNoiseLite.new()
var noise_temp := FastNoiseLite.new()
var noise_humid := FastNoiseLite.new()


@export var noise: FastNoiseLite

func generate_maps():
	
	
	noise_plaque.seed = seed
	noise_plaque.frequency = 0.14
	noise_plaque.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise_plaque.fractal_type = FastNoiseLite.FRACTAL_NONE
	noise_plaque.cellular_distance_function = FastNoiseLite.DISTANCE_HYBRID
	noise_plaque.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	noise_plaque.cellular_jitter = 1.15
	noise_plaque.domain_warp_enabled = true
	noise_plaque.domain_warp_amplitude = 2.0
	
	
	# Continent noise (broad shapes)
	noise_continent.seed = seed + 11
	noise_continent.frequency = continent_frequency
	noise_continent.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_continent.fractal_type = FastNoiseLite.FRACTAL_NONE
	noise_continent.fractal_octaves = 3

	# Mountain noise (high frequency ridges)
	noise_mountain.seed = seed + 101
	noise_mountain.frequency = mountain_frequency
	noise_mountain.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_mountain.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	noise_mountain.fractal_octaves = 3

	# Temperature noise
	noise_temp.seed = seed + 202
	noise_temp.frequency = temp_frequency
	noise_temp.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_temp.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_temp.fractal_octaves = 4

	# Humidity noise
	noise_humid.seed = seed + 303
	noise_humid.frequency = humid_frequency
	noise_humid.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_humid.fractal_type = FastNoiseLite.FRACTAL_NONE

	var image = Image.create_empty(width, height, false, Image.FORMAT_RGB8)

	for y in range(height):
		var v = float(y) / height
		var latitude = (v - 0.5) * PI  # -π/2 = south pole, +π/2 = north pole
		
		for x in range(width):
			var u = float(x) / float(width)
			var phi = u * TAU

			# Spherical to Cartesian for noise sampling
			var nx = cos(latitude) * cos(phi)
			var ny = sin(latitude)
			var nz = cos(latitude) * sin(phi)
			var nvec = Vector3(nx, ny, nz)

			var plaque = normalize_noise(noise_plaque.get_noise_3dv(nvec * scale * 10))
			plaque = 0.0 if plaque < ocean_frac else water_lvl
			
			# ---------- ELEVATION (RED) ----------
			var cont = normalize_noise(noise_continent.get_noise_3dv(nvec * scale))
			
			var mount = normalize_noise(noise_mountain.get_noise_3dv(nvec * scale * 3.0))
			mount *= cont
			
			#mount = 0.3 + mount * 0.7

			# continents + mountain detail
			#var elevation = (0.2 + plaque * 0.8) * mount
			var elevation = 2.0 * mount * plaque + 0.2 * mount
			#if plaque > 0.5:
				#elevation = clamp(elevation, 0.2, 1.0)
			
			elevation = clamp(elevation, 0.0, 1.0)

			# ---------- TEMPERATURE (GREEN) ----------
			#var lat_temp = cos(latitude)
			#lat_temp = clamp(lat_temp, 0.0, 1.0)
#
			#var t_noise = normalize_noise(noise_temp.get_noise_3dv(nvec * scale * 2.0))
#
			#var temperature = clamp(lat_temp * 0.7 + t_noise * 0.3, 0.0, 1.0)
			#
#
			## ---------- HUMIDITY (BLUE) ----------
			#var circulation = sin(latitude * 3.0) * 0.5 + 0.5
#
			#var h_noise = normalize_noise(noise_humid.get_noise_3dv(nvec * scale * 2.0))
#
			#var humidity = 1.0 - clamp(circulation * 0.6 + h_noise * 0.4, 0.0, 1.0)
			#humidity *= plaque
#
			#temperature = plaque * (temperature - (elevation * 0.3))
			# Final color: R=elevation, G=temp, B=humidity
			
			var temp_hum = get_climate(latitude, elevation, planet_distance, planet_lum, greenhouse_factor, ocean_frac, atmo_pressure)
			
			var color = Color(elevation, temp_hum.x, temp_hum.y)
			#var color = Color(0, temp_hum.x, 0)
			image.set_pixel(x, y, color)
	
	#generate_rivers(image)
	
	print("saving texture..")
	image.save_png("res://scenes/planet/terrain_map.png")
	#var tex = ImageTexture.create_from_image(image)
	#var mat = $Planet.material_override as ShaderMaterial
	#mat.set_shader_parameter("water_lvl", water_lvl)
	#$TextureRect.texture = tex

func get_climate(
	latitude: float, # -π/2 .. π/2
	elevation: float,           # 0.0 = ocean floor, 1.0 = mountain peak
	planet_dist: float,         # distance from star
	star_luminosity: float,     # star output
	greenhouse: float,          # 0 = no greenhouse, >0 = more
	ocean_fraction: float,      # fraction of planet covered by ocean (0..1)
	atmosphere_pressure: float  # 0 = no atmosphere, 1 = Earth, >1 = dense
) -> Vector2:

	# --- LAT & SOLAR ---
	var solar_input = star_luminosity / pow(planet_dist, 2.0)
	var lat_factor = pow(cos(latitude), 1.5)  # equator hot, poles cold

	# --- TEMPERATURE ---
	var temp = solar_input * lat_factor
	temp *= (1.0 + greenhouse)

	# Elevation cooling, scaled by pressure (thin atmospheres cool faster)
	var lapse_rate = 0.1 / max(atmosphere_pressure, 0.1)
	temp *= (1.0 - elevation * lapse_rate)

	# Ocean moderates extremes: interpolate toward mid-temp near sea level
	if elevation < 0.1: # lowlands
		temp = lerp(temp, 0.5, ocean_fraction * 0.3)

	temp = clamp(temp, 0.0, 1.0)

	# --- HUMIDITY ---
	var ocean_moisture = clamp(1.0 - elevation * 2.0, 0.0, 1.0)
	ocean_moisture *= ocean_fraction

	var hadley = sin(3.0 * latitude) * 0.5 + 0.5

	# Atmosphere pressure increases capacity to hold water
	var humidity = (ocean_moisture * 0.6 + hadley * 0.4) * (0.5 + atmosphere_pressure * 0.5)
	humidity = clamp(humidity, 0.0, 1.0)

	return Vector2(temp, humidity)

func generate_rivers(image: Image):
	var peaks = []
	for y in range(height):
		for x in range(width):
			var col = image.get_pixel(x, y)
			if col.r > 0.6:
				peaks.push_back(Vector2(x,y))
	peaks.shuffle()
	peaks.resize(2000)
	
	for p in peaks:
		if p == null: continue
		
		var curr_p = p
		for i in 3000:
			var new_p = find_slope(image, curr_p)
			if new_p != Vector2.ZERO:
				var pv = image.get_pixelv(new_p)
				if pv.r < 0.2:
					break
				image.set_pixelv(new_p, pv - Color(0.2, 0.0, 0) + Color(0.0, 0.0, 0.1))
				curr_p = new_p
			else:
				break

func find_slope(image: Image, p: Vector2) -> Vector2:
	var lowest_val = 10
	var lowest_pos = Vector2.ZERO
	var current_val = image.get_pixelv(p)
	for i in 8:
		var offset = p + Vector2(
			cos(i * 2 * PI / 8),
			sin(i * 2 * PI / 8)
		)
		
		var candidate = image.get_pixelv(offset)
		if candidate.r < current_val.r and candidate.r < lowest_val:
			lowest_val = candidate.r
			lowest_pos = offset
			
	return lowest_pos
		

func normalize_noise(val: float) -> float:
	return (val + 1.0) * 0.5
