class_name BenchmarkPlan
extends RefCounted
## What the in-game benchmark measures, in which order, and for how long. Pure data and decisions:
## no engine, no scene — the runner asks, this answers, the tests check the answers.
##
## The idea, since a script cannot read the GPU's time per render pass (only `--gpu-profile` and the
## editor's profiler can): measure the player's own settings, then turn ONE costly effect down at a
## time and measure again. The difference is what that effect costs on THIS machine — which is the
## number a player with a card we do not own can send us.

## One measuring window is exactly one full turn of the view, so every window sees every direction
## and the average does not depend on where the player happened to be looking.
const TURN_S : float = 6.0
## After each switch, at least this long is thrown away: buffers reallocate, pipelines compile, the
## draw ranges refresh.
const WARMUP_MIN_S : float = 1.5
## ...and then until nothing has compiled for this long and the ground has caught up.
const SETTLE_QUIET_S : float = 0.5
## Never wait longer than this: the step is then measured anyway and flagged `settled=no`.
const WARMUP_MAX_S : float = 8.0
## The ground counts as caught up at this share of the chunks its last LOD pass asked for.
const TERRAIN_READY : float = 0.98

const BASELINE : String = "baseline"
const BASELINE_END : String = "baseline_end"
const AERIAL : String = "aerial"

## Every step the benchmark may take, in run order. `set` is applied on top of the player's settings
## (RenderSettings.set_transient); a step runs only when its option is CURRENTLY costlier than that
## (see _worth_measuring) and no client.ini key owns it. `only_if` adds conditions on effective
## values. The draw distances come last: they rebuild chunks, which is the slowest thing to settle.
const CANDIDATES : Array[Dictionary] = [
	# A probe more than a setting: a quarter of the pixels. If the frame barely gets shorter, the
	# graphics card was not what held it back.
	{"id": "render_scale", "set": {"render_scale": 0.5}},
	# FSR 2.2 is the one upscaler with a real cost of its own. MSAA and TAA are pinned off with it,
	# or the stored ones would come back the moment it lets go of them.
	{"id": "upscaler", "set": {"upscale_mode": Viewport.SCALING_3D_MODE_BILINEAR,
			"aa_msaa": Viewport.MSAA_DISABLED, "aa_taa": false},
		"only_if": {"upscale_mode": Viewport.SCALING_3D_MODE_FSR2}},
	{"id": "aa_msaa", "set": {"aa_msaa": Viewport.MSAA_DISABLED}},
	{"id": "aa_screen", "set": {"aa_screen": Viewport.SCREEN_SPACE_AA_DISABLED}},
	{"id": "aa_taa", "set": {"aa_taa": false}},
	{"id": "atmosphere_quality", "set": {"atmosphere_quality": 0}},
	# Not a setting: the full-screen haze pass itself, through the same switch as Alt+I.
	{"id": AERIAL, "set": {}, "aerial": false},
	{"id": "shadows", "set": {"shadows": false}},
	{"id": "shadow_sun_res", "set": {"shadow_sun_res": 2048}, "only_if": {"shadows": true}},
	{"id": "shadow_filter", "set": {"shadow_filter": RenderingServer.SHADOW_QUALITY_HARD}},
	{"id": "ssao", "set": {"ssao": 0}},
	{"id": "ssil", "set": {"ssil": 0}},
	{"id": "ssr", "set": {"ssr": 0}},
	{"id": "glow", "set": {"glow": 0}},
	{"id": "anisotropic", "set": {"anisotropic": Viewport.ANISOTROPY_DISABLED}},
	{"id": "ground_quality", "set": {"ground_quality": 1}},
	{"id": "mesh_lod", "set": {"mesh_lod": 4.0}},
	{"id": "foliage_distance", "set": {"foliage_distance": 0.5}},
	{"id": "structures_distance", "set": {"structures_distance": 0.5}},
	{"id": "terrain_distance", "set": {"terrain_distance": 0.5}},
]

## Options where a LOWER number is the costlier one (a lower LOD threshold keeps finer meshes).
const _LOWER_IS_COSTLIER : Array[String] = ["mesh_lod"]


## The steps to run, first and last being the player's own settings (the last one tells whether the
## machine drifted — heat, people walking by — while the benchmark ran).
## [param effective] key -> effective value of every option (RenderSettings.effective).
## [param overridden] the options a client.ini key owns: changing them would change nothing.
## [param aerial_on] whether the haze pass is on now (Alt+I or client.ini may have turned it off).
## Each step: {"id", "set": {key: value}, "aerial": bool}.
static func steps(effective: Dictionary, overridden: PackedStringArray, aerial_on: bool) -> Array[Dictionary]:
	var out : Array[Dictionary] = [{"id": BASELINE, "set": {}, "aerial": aerial_on}]
	for candidate in CANDIDATES:
		if candidate["id"] == AERIAL:
			if aerial_on:
				out.append({"id": AERIAL, "set": {}, "aerial": false})
			continue
		if not _conditions_hold(candidate.get("only_if", {}), effective):
			continue
		if not _worth_measuring(candidate["set"], effective, overridden):
			continue
		out.append({"id": candidate["id"], "set": candidate["set"], "aerial": aerial_on})
	out.append({"id": BASELINE_END, "set": {}, "aerial": aerial_on})
	return out


## Roughly how long a run of these steps takes, in seconds: the warm-up turn, then for each step its
## shortest warm-up and its measured turn. Settling can stretch it; this is what the button promises.
static func estimate_s(plan: Array[Dictionary]) -> float:
	return TURN_S + float(plan.size()) * (WARMUP_MIN_S + SETTLE_QUIET_S + TURN_S)


static func _conditions_hold(conditions: Dictionary, effective: Dictionary) -> bool:
	for key in conditions:
		if not GraphicsOptions.same(effective.get(key), conditions[key]):
			return false
	return true


## True when the step's FIRST option is currently costlier than the step would make it, and no
## option of the step is owned by client.ini. The first option is what the step is about; the others
## are only pinned along with it.
static func _worth_measuring(values: Dictionary, effective: Dictionary, overridden: PackedStringArray) -> bool:
	if values.is_empty():
		return false
	for key in values:
		if key in overridden:
			return false
	var key : String = values.keys()[0]
	var now : Variant = effective.get(key)
	var target : Variant = values[key]
	if now == null or GraphicsOptions.same(now, target):
		return false
	if typeof(now) == TYPE_BOOL:
		return now == true and target == false
	if key == "upscale_mode":
		return true  # only listed under its only_if
	if key in _LOWER_IS_COSTLIER:
		return float(now) < float(target)
	return float(now) > float(target)
