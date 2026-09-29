class_name RenderApplier
extends RefCounted
## Hands the effective rendering options to the engine. The ONLY place that does.
##
## Three destinations:
##   - the root Viewport (the game view). Never the settings page's own viewport: that page lives in
##     a SubViewport, and an option applied there would change nothing the player looks at;
##   - RenderingServer globals (shadow atlas and filter, SSAO/SSIL quality, SSR size, glow upscale, the
##     planet_hex_quality shader global) — process-wide despite some of their names;
##   - the world Environment, which AtmosphereRenderer rebuilds on every spawn and attaches here.
##
## Options that someone else consumes (shadows, shadow distance, atmosphere quality, the two
## distances) have no branch: their consumers read RenderSettings and listen to its `changed`.

## Index = the ssao / ssil option value (0 = off).
const _SSAO_QUALITY : Array[int] = [
	RenderingServer.ENV_SSAO_QUALITY_VERY_LOW, RenderingServer.ENV_SSAO_QUALITY_LOW,
	RenderingServer.ENV_SSAO_QUALITY_MEDIUM, RenderingServer.ENV_SSAO_QUALITY_HIGH,
	RenderingServer.ENV_SSAO_QUALITY_ULTRA]
const _SSIL_QUALITY : Array[int] = [
	RenderingServer.ENV_SSIL_QUALITY_VERY_LOW, RenderingServer.ENV_SSIL_QUALITY_LOW,
	RenderingServer.ENV_SSIL_QUALITY_MEDIUM, RenderingServer.ENV_SSIL_QUALITY_HIGH,
	RenderingServer.ENV_SSIL_QUALITY_ULTRA]
## Index = the ssr option value (0 = off). The engine's roughness-quality knob is deprecated in 4.7 and
## does nothing any more: steps and half/full resolution are what SSR quality is now.
const _SSR_STEPS : Array[int] = [0, 32, 64, 96]
## The engine's own defaults for the knobs we do not expose (adaptive target, fade-out range): kept,
## so turning an effect on gives the stock look rather than a tuning of ours.
const _ADAPTIVE_TARGET : float = 0.5
const _FADE_FROM_M : float = 50.0
const _FADE_TO_M : float = 300.0

var _settings : RenderSettings
var _viewport : Viewport
## Weak: the Environment belongs to the world, and a respawn replaces it. We must not keep the old
## one alive, nor write into it.
var _environment : WeakRef = null


func _init(settings: RenderSettings, viewport: Viewport) -> void:
	_settings = settings
	_viewport = viewport
	_settings.changed.connect(_on_changed)


## Every option, once — at boot, before the first 3D frame, so pipelines compile for the final setup.
func apply_all() -> void:
	for option in GraphicsOptions.OPTIONS:
		_apply(option)


## The world's Environment is new: give it the environment options now, and on every change after.
func attach_environment(environment: Environment) -> void:
	_environment = weakref(environment)
	for option in GraphicsOptions.OPTIONS:
		if option.get("environment", false):
			_apply(option)


func _on_changed(keys: PackedStringArray) -> void:
	for key in keys:
		_apply(GraphicsOptions.find(key))


func _apply(option: Dictionary) -> void:
	var key : String = option["key"]
	# A client.ini debug key owns it: whoever reads that key applies it (ClientPerf, AtmosphereRenderer).
	if _settings.is_overridden(key):
		return
	var value : Variant = _settings.effective(key)
	if option.has("viewport"):
		_viewport.set(option["viewport"], value)
		return
	match key:
		"fsr_sharpness":
			_viewport.fsr_sharpness = (1.0 - float(value)) * 2.0
		"shadow_sun_res":
			RenderingServer.directional_shadow_atlas_set_size(int(value), true)
		"shadow_filter":
			RenderingServer.directional_soft_shadow_filter_set_quality(int(value))
			RenderingServer.positional_soft_shadow_filter_set_quality(int(value))
		"ground_quality":
			RenderingServer.global_shader_parameter_set("planet_hex_quality", int(value))
		"ssao":
			_apply_ssao(int(value))
		"ssil":
			_apply_ssil(int(value))
		"ssr":
			_apply_ssr(int(value))
		"glow":
			RenderingServer.environment_glow_set_use_bicubic_upscale(int(value) == 2)
			var env : Environment = _env()
			if env != null:
				env.glow_enabled = int(value) > 0


# Low and medium render at half resolution, the engine's cheap path; high and ultra at full.
func _apply_ssao(level: int) -> void:
	RenderingServer.environment_set_ssao_quality(_SSAO_QUALITY[level], level <= 2, _ADAPTIVE_TARGET,
		3 if level == 4 else 2, _FADE_FROM_M, _FADE_TO_M)
	var env : Environment = _env()
	if env != null:
		env.ssao_enabled = level > 0


func _apply_ssil(level: int) -> void:
	RenderingServer.environment_set_ssil_quality(_SSIL_QUALITY[level], level <= 2, _ADAPTIVE_TARGET, 4,
		_FADE_FROM_M, _FADE_TO_M)
	var env : Environment = _env()
	if env != null:
		env.ssil_enabled = level > 0


func _apply_ssr(level: int) -> void:
	RenderingServer.environment_set_ssr_half_size(level < 3)
	var env : Environment = _env()
	if env != null:
		env.ssr_enabled = level > 0
		env.ssr_max_steps = maxi(1, _SSR_STEPS[level])


func _env() -> Environment:
	return null if _environment == null else _environment.get_ref() as Environment
