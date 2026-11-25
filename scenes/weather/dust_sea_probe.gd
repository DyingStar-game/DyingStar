class_name DustSeaProbe
extends RefCounted
## A one-key probe of the dust sea's render (action debug_dust_sea_probe, Alt+J, registered at run time by
## AtmosphereRenderer, debug and editor builds only; docs/WEATHER.md): what is SENT, not what the code is
## believed to send. A development tool: nothing in it is shown to a player, nothing to translate. Four rounds of tuning by eye from
## screenshots alone did not move the look (2026-11-25); this names the numbers.
##
## Writes into user://dust_sea_probe/ (the path is printed):
##   <stamp>.json  every sea and dust uniform as the aerial material holds it now, DustSea's own state, the eye,
##                 the light (the sun's energy and colour, the ambient, its sky share), the weather at the eye;
##   <stamp>.png   the screen as it is;
##   <stamp>_branch.png  the aerial pass's debug view (sea_debug 1): red where the pixel took the terrain branch
##                 (the depth buffer holds something there), blue where it took the sky branch, the brightness
##                 the sea's transmittance (black = opaque sea). A terrain drawn after the pass (transparent,
##                 a LOD cross-fade) shows blue under crisp ground: the sea never fogs it;
##   <stamp>_sea.png  the sea's light alone (sea_debug 2), over black.
## The JSON also lists every dust wall and devil drawn (WeatherPhenomena.probe): the colours sent, the ground's
## under its front.

const ACTION := &"debug_dust_sea_probe"
const DIR := "user://dust_sea_probe"
## The aerial material's uniforms read back.
const PARAMS: Array[String] = ["sea_on", "sea_beta", "sea_top", "sea_floor", "sea_ground", "sea_top_boost",
	"sea_top_scale", "sea_billow_m", "sea_sun", "sea_ambient", "sea_ms_gain", "sea_eye_gain", "sea_direct_gain",
	"sea_crease_floor", "sea_neutral", "sea_white", "sea_rock_tint", "sea_edge_tint", "sea_map_on", "sea_steps",
	"sea_rays", "sea_far", "sea_pixel_rad", "sea_cam", "sea_up", "sea_radius", "dust_veil_beta", "dust_density",
	"dust_far_density", "dust_albedo", "dust_sun", "dust_sun_free", "dust_ambient", "mie_beta", "mie_g",
	"haze_top", "haze_bottom", "haze_falloff", "rayleigh_beta", "sky_exposure", "star_irradiance", "star_color",
	"open_sky", "aerial_lut_distance", "use_transmittance_lut", "planet_radius", "to_star"]


## Register the action (Alt+J) when the project has none of that name: no project.godot edit for a debug key.
static func register_action() -> void:
	if not enabled() or InputMap.has_action(ACTION):
		return
	InputMap.add_action(ACTION)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_J
	key.alt_pressed = true
	InputMap.action_add_event(ACTION, key)


## Whether the probe is offered: debug and editor builds (a released game has no use for it).
static func enabled() -> bool:
	return OS.is_debug_build()


## Probe [param renderer] now: the JSON at once, the three pictures over the next frames.
static func run(renderer: AtmosphereRenderer) -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var base := "%s/%s" % [DIR, stamp]
	var file := FileAccess.open(base + ".json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(plain(collect(renderer)), "\t"))
		file.close()
	print("[DustSeaProbe] %s.json (+ .png, _branch.png, _sea.png)" % ProjectSettings.globalize_path(base))
	await _shot(renderer, base + ".png")
	renderer.set_dust_param(&"sea_debug", 1)
	await _shot(renderer, base + "_branch.png")
	renderer.set_dust_param(&"sea_debug", 2)
	await _shot(renderer, base + "_sea.png")
	renderer.set_dust_param(&"sea_debug", 0)


## The screen two frames from now, to [param path].
static func _shot(renderer: AtmosphereRenderer, path: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := renderer.get_viewport().get_texture().get_image()
	if image != null:
		image.save_png(path)


## Everything the probe writes, as Godot values.
static func collect(renderer: AtmosphereRenderer) -> Dictionary:
	var shader := {}
	for name: String in PARAMS:
		shader[name] = renderer.aerial_param(name)
	var out := {"sea": renderer.dust_sea.probe(), "shader": shader, "aerial_visible": renderer.is_aerial_enabled()}
	var body := renderer.current_body()
	var camera: Camera3D = renderer.player.camera if is_instance_valid(renderer.player) else null
	if body != null and camera != null:
		var altitude := body.elevation_of(camera.global_position)
		out["eye"] = {"camera_altitude_m": altitude, "player_altitude_m": renderer.altitude_above_sphere(),
			"over_ground_m": body.surface_altitude_of(camera.global_position),
			"sea_tau_above": renderer.dust_sea.sea_tau_above(altitude), "tau_above": renderer.dust_sea.tau_above(altitude),
			"under_share": renderer.dust_sea.under_share(altitude), "eye_gain": renderer.dust_sea.eye_gain(altitude)}
	if is_instance_valid(renderer.sun):
		var sin_e: float = renderer.sun.star_direction.dot(renderer.sun.stable_up())
		out["sun"] = {"sin_elevation": sin_e, "sun_energy": renderer.sun.sun_energy,
			"light_energy": renderer.sun.light_energy, "light_color": renderer.sun.light_color,
			"visible": renderer.sun.visible, "transmittance_at": renderer.transmittance_at(sin_e),
			"shadow_max_distance": renderer.sun.directional_shadow_max_distance}
	if body != null and camera != null:
		for child: Node in body.get_children():
			if child is WeatherPhenomena:
				out["phenomena"] = (child as WeatherPhenomena).probe(camera.global_position)
	var env: Environment = renderer.player.get_world_3d().environment if is_instance_valid(renderer.player) else null
	if env != null:
		out["environment"] = {"ambient_source": env.ambient_light_source, "ambient_color": env.ambient_light_color,
			"ambient_energy": env.ambient_light_energy, "ambient_sky_contribution": env.ambient_light_sky_contribution,
			"reflected_source": env.reflected_light_source}
	return out


## [param v] in JSON's terms: vectors and colours as arrays, resources by class, the rest as text.
static func plain(v: Variant) -> Variant:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_STRING_NAME:
			return str(v)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [v.x, v.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [v.x, v.y, v.z]
		TYPE_COLOR:
			return [v.r, v.g, v.b, v.a]
		TYPE_DICTIONARY:
			var d := {}
			for key: Variant in v:
				d[str(key)] = plain(v[key])
			return d
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_INT32_ARRAY:
			var a := []
			for item: Variant in v:
				a.append(plain(item))
			return a
		TYPE_OBJECT:
			return (v as Object).get_class() if v != null else null
	return var_to_str(v)
