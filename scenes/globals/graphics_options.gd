class_name GraphicsOptions
extends RefCounted
## Every rendering option the player can change, as DATA: one entry per option.
##
## This table is the single place an option is described. RenderSettings validates and stores from
## it, RenderApplier hands it to the engine, and GraphicsOptionsView builds the same rows from it in
## the Graphics page AND in the in-game overlay. Adding an option is one entry here, its keys in
## localisation.csv and — only if it is not a plain Viewport property — one branch in RenderApplier.
##
## The translation keys are written out in full on purpose: test_localisation_keys.gd proves every
## key is used by finding it LITERALLY in the sources, so a key assembled at runtime would fail it.
##
## Entry fields:
##   key       the [video] key in user://settings.ini
##   section   the heading it is listed under (a SEC_* key)
##   label     translation key of the row
##   kind      TOGGLE, CHOICE or SLIDER
##   choices   CHOICE only: [value, text, renderers?] — text is a key or a literal ("4x", "FXAA");
##             renderers, when present, limits THAT value to those rendering methods
##   min/max/step/format   SLIDER only; format picks how the value label reads
##   default   what the game rendered before these options existed: a key missing from an old
##             settings file must not change the picture
##   presets   the value for each of PRESETS, in that order
##   off       the value forced when the option cannot apply (default: first choice / false)
##   renderers the rendering methods the option works on (absent = all)
##   blocked_by  {key, values, why, force}: greyed while `key` is in `values`; `force` also applies
##             `off` (the stored choice is kept and comes back when the block lifts)
##   client_ini  client.ini debug keys that override this option (they win, the row is greyed)
##   viewport  the root Viewport property it sets as-is (otherwise RenderApplier maps it)
##   environment  true when it lives on the world Environment (applied when one is attached)
##   commit_on_release  SLIDER only: apply when the drag ends, not on every step (buffer realloc)

const SECTION : String = "video"
## Preset names, cheapest first. Index i of an option's "presets" is the value for PRESETS[i].
const PRESETS : Array[String] = [GpuTier.LOW, GpuTier.MEDIUM, GpuTier.HIGH, GpuTier.ULTRA]
const CUSTOM : String = "custom"
## What each preset name reads as. CUSTOM is shown but never picked: it is where you land.
const PRESET_LABELS : Dictionary = {
	GpuTier.LOW: "%%MENU_GFX_LOW", GpuTier.MEDIUM: "%%MENU_GFX_MEDIUM", GpuTier.HIGH: "%%MENU_GFX_HIGH",
	GpuTier.ULTRA: "%%MENU_GFX_ULTRA", CUSTOM: "%%MENU_GFX_CUSTOM",
}

const TOGGLE : String = "toggle"
const CHOICE : String = "choice"
const SLIDER : String = "slider"

const FORMAT_PERCENT : String = "percent"
const FORMAT_MULTIPLIER : String = "multiplier"
const FORMAT_METERS : String = "meters"

const SEC_AA : String = "%%MENU_GFX_SECTION_AA"
const SEC_SHADOWS : String = "%%MENU_GFX_SECTION_SHADOWS"
const SEC_EFFECTS : String = "%%MENU_GFX_SECTION_EFFECTS"
const SEC_WORLD : String = "%%MENU_GFX_SECTION_WORLD"
const SECTIONS : Array[String] = [SEC_AA, SEC_SHADOWS, SEC_EFFECTS, SEC_WORLD]

const WHY_RENDERER : String = "%%MENU_GFX_WHY_RENDERER"
const WHY_CLIENT_INI : String = "%%MENU_GFX_WHY_CLIENT_INI"

const FORWARD_PLUS : Array[String] = ["forward_plus"]
## RenderingDevice renderers: everything but Compatibility (OpenGL).
const RD_RENDERERS : Array[String] = ["forward_plus", "mobile"]

## atmosphere_quality -> (view steps, light steps) of AtmosphereRenderer's two raymarches. HIGH is
## the 32 x 8 the game always rendered with.
const ATMOSPHERE_STEPS : Array[Vector2i] = [Vector2i(16, 4), Vector2i(24, 6), Vector2i(32, 8), Vector2i(48, 12)]

## The shared wording of a four-step quality ladder, and of "off + that ladder".
const _QUALITY : Array = [[0, "%%MENU_GFX_LOW"], [1, "%%MENU_GFX_MEDIUM"], [2, "%%MENU_GFX_HIGH"], [3, "%%MENU_GFX_ULTRA"]]
const _OFF_QUALITY : Array = [[0, "%%MENU_OFF"], [1, "%%MENU_GFX_LOW"], [2, "%%MENU_GFX_MEDIUM"],
	[3, "%%MENU_GFX_HIGH"], [4, "%%MENU_GFX_ULTRA"]]
const _ATLAS : Array = [[1024, "1024"], [2048, "2048"], [4096, "4096"], [8192, "8192"]]

const OPTIONS : Array[Dictionary] = [
	# ── Anti-aliasing & upscaling ──
	{"key": "upscale_mode", "section": SEC_AA, "label": "%%MENU_GFX_UPSCALER", "kind": CHOICE,
		"choices": [[Viewport.SCALING_3D_MODE_BILINEAR, "%%MENU_GFX_BILINEAR"],
			[Viewport.SCALING_3D_MODE_FSR, "AMD FSR 1.0", RD_RENDERERS],
			[Viewport.SCALING_3D_MODE_FSR2, "AMD FSR 2.2", FORWARD_PLUS]],
		"default": Viewport.SCALING_3D_MODE_BILINEAR, "viewport": "scaling_3d_mode",
		"presets": [Viewport.SCALING_3D_MODE_FSR, Viewport.SCALING_3D_MODE_BILINEAR,
			Viewport.SCALING_3D_MODE_BILINEAR, Viewport.SCALING_3D_MODE_FSR2]},
	# Capped at 100 %: above it FSR falls back to bilinear, and supersampling is not what it is for.
	{"key": "render_scale", "section": SEC_AA, "label": "%%MENU_GFX_RENDER_SCALE", "kind": SLIDER,
		"min": 0.5, "max": 1.0, "step": 0.05, "format": FORMAT_PERCENT, "commit_on_release": true,
		"default": 1.0, "viewport": "scaling_3d_scale", "presets": [0.75, 1.0, 1.0, 1.0]},
	# Stored as sharpness (1 = sharpest) because that is what the slider says; the engine's
	# fsr_sharpness runs the other way, 0 = sharpest .. 2. 0.9 is the engine default 0.2.
	{"key": "fsr_sharpness", "section": SEC_AA, "label": "%%MENU_GFX_FSR_SHARPNESS", "kind": SLIDER,
		"min": 0.0, "max": 1.0, "step": 0.05, "format": FORMAT_PERCENT,
		"default": 0.9, "presets": [0.9, 0.9, 0.9, 0.9],
		"blocked_by": {"key": "upscale_mode", "values": [Viewport.SCALING_3D_MODE_BILINEAR],
			"why": "%%MENU_GFX_WHY_NO_FSR", "force": false}},
	# FSR 2.2 anti-aliases on its own: MSAA before it is wasted work, TAA is refused by the engine.
	{"key": "aa_msaa", "section": SEC_AA, "label": "%%MENU_GFX_MSAA", "kind": CHOICE,
		"choices": [[Viewport.MSAA_DISABLED, "%%MENU_OFF"], [Viewport.MSAA_2X, "2x"], [Viewport.MSAA_4X, "4x"],
			[Viewport.MSAA_8X, "8x"]],
		"default": Viewport.MSAA_DISABLED, "viewport": "msaa_3d", "presets": [0, 0, 0, 0],
		"blocked_by": {"key": "upscale_mode", "values": [Viewport.SCALING_3D_MODE_FSR2],
			"why": "%%MENU_GFX_WHY_FSR2_MSAA", "force": true}},
	{"key": "aa_screen", "section": SEC_AA, "label": "%%MENU_GFX_SCREEN_AA", "kind": CHOICE,
		"choices": [[Viewport.SCREEN_SPACE_AA_DISABLED, "%%MENU_OFF"], [Viewport.SCREEN_SPACE_AA_FXAA, "FXAA"],
			[Viewport.SCREEN_SPACE_AA_SMAA, "SMAA", RD_RENDERERS]],
		"default": Viewport.SCREEN_SPACE_AA_DISABLED, "viewport": "screen_space_aa",
		"presets": [Viewport.SCREEN_SPACE_AA_FXAA, Viewport.SCREEN_SPACE_AA_SMAA,
			Viewport.SCREEN_SPACE_AA_DISABLED, Viewport.SCREEN_SPACE_AA_DISABLED]},
	{"key": "aa_taa", "section": SEC_AA, "label": "%%MENU_GFX_TAA", "kind": TOGGLE,
		"default": false, "viewport": "use_taa", "renderers": FORWARD_PLUS, "presets": [false, false, true, false],
		"blocked_by": {"key": "upscale_mode", "values": [Viewport.SCALING_3D_MODE_FSR2],
			"why": "%%MENU_GFX_WHY_FSR2_TAA", "force": true}},
	# ── Shadows ── (the first two predate this table: same keys, same defaults, same signals)
	{"key": "shadows", "section": SEC_SHADOWS, "label": "%%MENU_SHADOWS", "kind": TOGGLE,
		"default": true, "presets": [true, true, true, true]},
	{"key": "shadow_distance", "section": SEC_SHADOWS, "label": "%%MENU_SHADOW_DISTANCE", "kind": SLIDER,
		"min": 50.0, "max": 1000.0, "step": 10.0, "format": FORMAT_METERS,
		"default": 300.0, "presets": [150.0, 250.0, 300.0, 500.0],
		"blocked_by": {"key": "shadows", "values": [false], "why": "%%MENU_GFX_WHY_SHADOWS_OFF", "force": false}},
	{"key": "shadow_sun_res", "section": SEC_SHADOWS, "label": "%%MENU_GFX_SUN_SHADOW_RES", "kind": CHOICE,
		"choices": _ATLAS, "default": 4096, "presets": [2048, 4096, 4096, 8192],
		"blocked_by": {"key": "shadows", "values": [false], "why": "%%MENU_GFX_WHY_SHADOWS_OFF", "force": false}},
	# Lamps and the torch: not gated by the Shadows toggle, which only drives the sun and the moons.
	{"key": "shadow_light_res", "section": SEC_SHADOWS, "label": "%%MENU_GFX_LIGHT_SHADOW_RES", "kind": CHOICE,
		"choices": _ATLAS, "default": 4096, "viewport": "positional_shadow_atlas_size",
		"presets": [1024, 2048, 4096, 4096]},
	{"key": "shadow_filter", "section": SEC_SHADOWS, "label": "%%MENU_GFX_SHADOW_FILTER", "kind": CHOICE,
		"choices": [[RenderingServer.SHADOW_QUALITY_HARD, "%%MENU_GFX_HARD"],
			[RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW, "%%MENU_GFX_VERY_LOW"],
			[RenderingServer.SHADOW_QUALITY_SOFT_LOW, "%%MENU_GFX_LOW"],
			[RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, "%%MENU_GFX_MEDIUM"],
			[RenderingServer.SHADOW_QUALITY_SOFT_HIGH, "%%MENU_GFX_HIGH"],
			[RenderingServer.SHADOW_QUALITY_SOFT_ULTRA, "%%MENU_GFX_ULTRA"]],
		"default": RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		"presets": [RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW, RenderingServer.SHADOW_QUALITY_SOFT_LOW,
			RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, RenderingServer.SHADOW_QUALITY_SOFT_HIGH]},
	# ── Effects ── (no volumetric fog, deliberately: see PlayerSunLight — it flickers black here)
	{"key": "ssao", "section": SEC_EFFECTS, "label": "%%MENU_GFX_SSAO", "kind": CHOICE, "choices": _OFF_QUALITY,
		"default": 0, "environment": true, "renderers": ["forward_plus", "gl_compatibility"],
		"presets": [0, 0, 2, 3]},
	{"key": "ssil", "section": SEC_EFFECTS, "label": "%%MENU_GFX_SSIL", "kind": CHOICE, "choices": _OFF_QUALITY,
		"default": 0, "environment": true, "renderers": FORWARD_PLUS, "presets": [0, 0, 0, 2]},
	{"key": "ssr", "section": SEC_EFFECTS, "label": "%%MENU_GFX_SSR", "kind": CHOICE,
		"choices": [[0, "%%MENU_OFF"], [1, "%%MENU_GFX_LOW"], [2, "%%MENU_GFX_MEDIUM"], [3, "%%MENU_GFX_HIGH"]],
		"default": 0, "environment": true, "renderers": FORWARD_PLUS, "presets": [0, 0, 1, 2]},
	# 2 = bicubic upscale, the engine's desktop default and so what the game always rendered.
	{"key": "glow", "section": SEC_EFFECTS, "label": "%%MENU_GFX_GLOW", "kind": CHOICE,
		"choices": [[0, "%%MENU_OFF"], [1, "%%MENU_GFX_LOW"], [2, "%%MENU_GFX_HIGH"]],
		"default": 2, "environment": true, "presets": [1, 2, 2, 2]},
	# project.godot sets 4 = 16x on the root viewport; that is the default kept here.
	{"key": "anisotropic", "section": SEC_EFFECTS, "label": "%%MENU_GFX_ANISOTROPIC", "kind": CHOICE,
		"choices": [[Viewport.ANISOTROPY_DISABLED, "%%MENU_OFF"], [Viewport.ANISOTROPY_2X, "2x"],
			[Viewport.ANISOTROPY_4X, "4x"], [Viewport.ANISOTROPY_8X, "8x"], [Viewport.ANISOTROPY_16X, "16x"]],
		"default": Viewport.ANISOTROPY_16X, "viewport": "anisotropic_filtering_level",
		"presets": [Viewport.ANISOTROPY_4X, Viewport.ANISOTROPY_8X, Viewport.ANISOTROPY_16X, Viewport.ANISOTROPY_16X]},
	{"key": "debanding", "section": SEC_EFFECTS, "label": "%%MENU_GFX_DEBANDING", "kind": TOGGLE,
		"default": false, "viewport": "use_debanding", "presets": [false, true, true, true]},
	# ── World quality ──
	{"key": "atmosphere_quality", "section": SEC_WORLD, "label": "%%MENU_GFX_ATMOSPHERE", "kind": CHOICE,
		"choices": _QUALITY, "default": 2, "presets": [0, 1, 2, 3],
		"client_ini": ["debug_atmo_view_steps", "debug_atmo_light_steps"]},
	# planet_surface.gdshader's cost dial: 2 = full hex tiling, 1 = hex albedo only, 0 = plain.
	{"key": "ground_quality", "section": SEC_WORLD, "label": "%%MENU_GFX_GROUND", "kind": CHOICE,
		"choices": [[0, "%%MENU_GFX_LOW"], [1, "%%MENU_GFX_MEDIUM"], [2, "%%MENU_GFX_HIGH"]],
		"default": 2, "presets": [0, 1, 2, 2], "client_ini": ["debug_hex_quality"]},
	# Higher threshold = coarser mesh LODs sooner. 1.0 is the engine default.
	{"key": "mesh_lod", "section": SEC_WORLD, "label": "%%MENU_GFX_MESH_LOD", "kind": CHOICE,
		"choices": [[4.0, "%%MENU_GFX_LOW"], [2.0, "%%MENU_GFX_MEDIUM"], [1.0, "%%MENU_GFX_HIGH"],
			[0.5, "%%MENU_GFX_ULTRA"]],
		"default": 1.0, "viewport": "mesh_lod_threshold", "presets": [4.0, 2.0, 1.0, 0.5]},
	# Client-side multipliers read by PlanetTerrain. They never touch what the server streams or
	# collides with: only how far the client DRAWS what it already has.
	{"key": "view_distance", "section": SEC_WORLD, "label": "%%MENU_GFX_VIEW_DISTANCE", "kind": SLIDER,
		"min": 0.5, "max": 2.0, "step": 0.05, "format": FORMAT_MULTIPLIER,
		"default": 1.0, "presets": [0.6, 0.8, 1.0, 1.5]},
	{"key": "foliage_distance", "section": SEC_WORLD, "label": "%%MENU_GFX_FOLIAGE_DISTANCE", "kind": SLIDER,
		"min": 0.5, "max": 2.0, "step": 0.05, "format": FORMAT_MULTIPLIER,
		"default": 1.0, "presets": [0.5, 0.75, 1.0, 1.5]},
]


## The entry for `key`, or {} for a key this table does not know.
static func find(key: String) -> Dictionary:
	for option in OPTIONS:
		if option["key"] == key:
			return option
	return {}


## The entries listed under one heading, in table order.
static func in_section(section: String) -> Array[Dictionary]:
	var out : Array[Dictionary] = []
	for option in OPTIONS:
		if option["section"] == section:
			out.append(option)
	return out


## The value an option falls back to when it cannot apply.
static func off_value(option: Dictionary) -> Variant:
	if option.has("off"):
		return option["off"]
	match option["kind"]:
		TOGGLE:
			return false
		CHOICE:
			return option["choices"][0][0]
	return option["default"]


## Two option values are the same setting. Floats compare approximately: a value that went through
## a slider and a ConfigFile round trip is not bit-identical to the table's literal.
static func same(a: Variant, b: Variant) -> bool:
	if typeof(a) == TYPE_FLOAT or typeof(b) == TYPE_FLOAT:
		if not (typeof(a) in [TYPE_FLOAT, TYPE_INT] and typeof(b) in [TYPE_FLOAT, TYPE_INT]):
			return false
		return is_equal_approx(float(a), float(b))
	if typeof(a) != typeof(b):
		return false
	return a == b
