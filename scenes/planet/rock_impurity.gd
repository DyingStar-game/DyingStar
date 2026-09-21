@tool
class_name RockImpurity
## How much of its colouring elements a rock carries at a point of the
## surface — and so which shade, between the rock's light and dark tints, the
## ground bakes there and how rich the ore a miner gets is.
##
## One rule for every corundum (and any catalogue rock): the rock declares its
## impurities in rocks.py (element, ppm range, optional), and the shade is the
## rock's own combination of ONE CONCENTRATION FIELD PER ELEMENT, evaluated
## here. What varies between a red, a blue and a yellow corundum is only which
## elements it reads and how it mixes them (see [method concentration]) —
## there is no per-rock table.
##
## The geology, in short — the rock's colour tells where it came from:
##   · Cr, Ti, V are SOURCE-BOUND: they came with the deep mafic / ultramafic
##     rock. A massif is that rock lifted and exposed by erosion, so their
##     concentration follows the mountain core (crests darkest, foothills
##     pale); Fe is everywhere, and rises only mildly with the core.
##   · A CREVASSE, a canyon, a road cutting expose deeper rock too: the carve
##     depth adds to the same "provenance depth" — the floor of a 150 m crack
##     on the plain is as rich as a high flank.
##   · VEINS: hot fluids carried the mobile elements (Cr, V, Fe — not Ti)
##     along the fractures: a halo of a few tens of metres around a crack
##     wall is richer than the block it cuts.
##   · STRATA: the elements were laid in beds, tilted by the uplift. Every
##     element is multiplied by the band it sits in — near-horizontal stripes
##     of alternating richness, the same on every element.
##   · IRON VALENCE: deep rock formed reduced, iron as Fe²⁺ (the blue of a
##     sapphire, the blue side of a green); near the surface it is oxidised,
##     Fe³⁺ (yellow). A rock that declares `core_colors` slides from its
##     shallow hue to its deep hue with the provenance depth — a green massif
##     is blue-green on the crest, yellow-green on the flanks.
##   · DUST: not an impurity. Flats inside a massif collect debris, which pales
##     the rock; steep faces are fresh rock, fully saturated. Colour only.
##
## Contract: every function is PURE (direction, height, the mountain core and
## carve depth the caller measured, constants) — integer-hash noise for the
## strata, SurfaceNoise.mottle for the fine mottling — so the client's baked
## colours and the server's mining yield agree on one lattice. No engine state.

# ── Tuning ──────────────────────────────────────────────────────────
## Thickness of one stratum (m) and the share of it blended into the next.
const STRATA_THICKNESS_M := 70.0
const STRATA_BLEND := 0.2
## Richness swing of the strata: every element × [1 − amp, 1 + amp].
const STRATA_AMP := 0.3
## Dip (°) of the beds, min and max, drawn per STRATA_CELL_M cell.
const STRATA_DIP_MIN_DEG := 4.0
const STRATA_DIP_MAX_DEG := 22.0
const STRATA_CELL_M := 150000.0
const STRATA_SEED := 7919

## Carve depth (m) at which a crevasse floor counts as fully deep.
const CARVE_REF_M := 150.0
## Width of the vein halo outward from a crack wall (m), and its gain on
## the fluid-mobile elements.
const VEIN_HALO_M := 40.0
const VEIN_GAIN := 0.35
const FLUID_MOBILE := {"Cr": true, "V": true, "Fe": true}
## Provenance depth at which the iron is fully reduced (core_colors reached).
const VALENCE_DEPTH := 1.0
## Ore richness of a mined rock (MiningZone): how much the provenance under
## it lifts the zone's own target.
const ORE_CORE_GAIN := 0.35
const ORE_CARVE_GAIN := 0.35

## Element fields: the plain's share of the mottling, the core gain, the carve
## gain — source-bound elements versus the ubiquitous iron.
const SRC_BASE := 0.55
const SRC_CORE := 0.7
const SRC_CARVE := 0.5
const FE_BASE := 0.75
const FE_CORE := 0.25
const FE_CARVE := 0.3
## A rock with no impurity at all (white corundum): strata over this.
const PURE_BASE := 0.5

## Colouring power of one ppm of each element, relative to iron: what makes a
## 4 500 ppm Cr ruby a chromium colour and not an iron one.
const CHROMOPHORE := {"Cr": 10.0, "V": 8.0, "Fe": 1.0, "Ti": 1.0}
const SOURCE_BOUND := {"Cr": true, "Ti": true, "V": true}
## Weight of an optional impurity in the mix.
const OPTIONAL_WEIGHT := 0.5

## Dust on the flats of a massif: strength, the slope band it fades over
## (slope = 1 − n·up: 0.04 ≈ 16°, 0.25 ≈ 41°) and the core it needs.
const DUST_MAX := 0.45
const DUST_SLOPE_LO := 0.04
const DUST_SLOPE_HI := 0.25
const DUST_CORE_LO := 0.05
const DUST_CORE_HI := 0.4
const DUST_TONE := Color(0.86, 0.82, 0.74)
const DUST_MIX := 0.6

## Per-slug mixing rule, built once from the catalogue:
## {"pair": bool, "elements": PackedStringArray, "weights": PackedFloat64Array}.
static var _rules: Dictionary = {}
static var _rules_mutex := Mutex.new()


# ── Provenance ──────────────────────────────────────────────────────

## Depth-of-origin of the rock exposed at a point, from the mountain core
## (PlanetData.mountain_core) and the carve depth (m) below the sampled
## surface — the two ways deep rock reaches the surface, added.
static func provenance(core: float, carve_m: float) -> float:
	return maxf(core, 0.0) + clampf(carve_m / CARVE_REF_M, 0.0, 1.0)


## Concentration of [param element] in [0, 1]: its plain share of the
## mottling [param mottle], plus the core, the carve and the vein halo
## ([param vein_n], see [method vein_weight]), by its kind.
static func element_field(element: String, mottle: float, core: float, carve_n: float,
		vein_n: float = 0.0) -> float:
	var c := clampf(core, 0.0, 1.5)
	var v := VEIN_GAIN * vein_n if FLUID_MOBILE.has(element) else 0.0
	if SOURCE_BOUND.has(element):
		return clampf(SRC_BASE * mottle + SRC_CORE * c + SRC_CARVE * carve_n + v, 0.0, 1.0)
	return clampf(FE_BASE * mottle + FE_CORE * c + FE_CARVE * carve_n + v, 0.0, 1.0)


## Vein halo weight in [0, 1] at [param wall_m] metres outward from the
## nearest crack wall (≤ 0 on the wall or inside the crack; INF = no crack
## network here, the plain's zero).
static func vein_weight(wall_m: float) -> float:
	if is_inf(wall_m):
		return 0.0
	return 1.0 - smoothstep(0.0, VEIN_HALO_M, maxf(wall_m, 0.0))


## Ore richness target of a mining rock sitting on the ground: the zone's own
## [param base] lifted by the provenance there — a crest or a crevasse floor
## yields richer rocks than the plain, whatever the mineral.
static func ore_richness(base: float, core: float, carve_m: float) -> float:
	return clampf(base + ORE_CORE_GAIN * clampf(core, 0.0, 1.5)
			+ ORE_CARVE_GAIN * clampf(carve_m / CARVE_REF_M, 0.0, 1.0), 0.0, 1.0)


## Strata multiplier in [1 − STRATA_AMP, 1 + STRATA_AMP] at [param dir] /
## [param height_m]: the richness of the tilted bed the point sits in, blended
## into the next over STRATA_BLEND of a bed. The dip is drawn per
## STRATA_CELL_M cell, so a massif's beds all lean the same way.
static func strata(dir: Vector3, radius: float, height_m: float) -> float:
	var cell := (dir * (radius / STRATA_CELL_M)).floor()
	var cx := int(cell.x)
	var cy := int(cell.y)
	var cz := int(cell.z)
	var az := MountainNoise.cell(cx, cy, cz, STRATA_SEED) * TAU
	var dip := deg_to_rad(lerpf(STRATA_DIP_MIN_DEG, STRATA_DIP_MAX_DEG,
			MountainNoise.cell(cx, cy, cz, STRATA_SEED + 1)))
	var up := (cell + Vector3(0.5, 0.5, 0.5)).normalized()
	var tang := up.cross(Vector3.UP)
	if tang.length_squared() < 1e-6:
		tang = up.cross(Vector3.RIGHT)
	tang = tang.normalized()
	var bitan := up.cross(tang)
	var n := (up * cos(dip) + (tang * cos(az) + bitan * sin(az)) * sin(dip)).normalized()
	var b := dir.dot(n) * (radius + height_m) / STRATA_THICKNESS_M
	var k := floorf(b)
	var f := b - k
	var ki := int(k)
	var v0 := MountainNoise.cell(ki, cx * 31 + cy, cz, STRATA_SEED + 2)
	var v1 := MountainNoise.cell(ki + 1, cx * 31 + cy, cz, STRATA_SEED + 2)
	var t := smoothstep(1.0 - STRATA_BLEND, 1.0, f)
	return lerpf(1.0 - STRATA_AMP, 1.0 + STRATA_AMP, lerpf(v0, v1, t))


# ── Per-rock rule ───────────────────────────────────────────────────

## The mixing rule of [param slug], from its catalogue impurities:
##   · no impurity → the pure rule (strata over PURE_BASE);
##   · Fe AND Ti → the charge-transfer PAIR: c = sqrt(fe · ti) — the blue needs
##     both side by side, Ti missing leaves a grey-blue;
##   · else the chromophore-weighted mean of its elements (ppm_max ×
##     CHROMOPHORE, optional ones at OPTIONAL_WEIGHT): Cr rules a ruby, Fe an
##     orange, with no table saying so.
static func rule_of(slug: String) -> Dictionary:
	var r: Variant = _rules.get(slug)
	if r != null:
		return r
	_rules_mutex.lock()
	r = _rules.get(slug)
	if r == null:
		r = _build_rule(RockCatalogue.get_rock(slug))
		# Replace the table rather than mutate it: the lock-free read above,
		# on another worker, never sees a half-written Dictionary.
		var next := _rules.duplicate()
		next[slug] = r
		_rules = next
	_rules_mutex.unlock()
	return r


static func _build_rule(rock: Dictionary) -> Dictionary:
	var elements := PackedStringArray()
	var weights := PackedFloat64Array()
	var has_fe := false
	var has_ti := false
	for imp in rock.get("impurities", []):
		var e := str((imp as Dictionary).get("element", ""))
		if e.is_empty():
			continue
		var w := float((imp as Dictionary).get("ppm_max", 0)) * float(CHROMOPHORE.get(e, 1.0))
		if bool((imp as Dictionary).get("optional", false)):
			w *= OPTIONAL_WEIGHT
		if w <= 0.0:
			continue
		elements.append(e)
		weights.append(w)
		has_fe = has_fe or e == "Fe"
		has_ti = has_ti or e == "Ti"
	return {"pair": has_fe and has_ti, "elements": elements, "weights": weights}


## Tests / a re-exported catalogue: forget the cached rules.
static func reset() -> void:
	_rules_mutex.lock()
	_rules.clear()
	_rules_mutex.unlock()


## The shade of [param slug] at a point, in [0, 1] = light → dark tint: its
## elements' fields (from [param core], [param carve_m] and the distance
## [param wall_m] to the nearest crack wall, INF for none) mixed by its rule,
## then banded by the strata.
static func concentration(slug: String, dir: Vector3, radius: float, height_m: float,
		core: float, carve_m: float, wall_m: float = INF) -> float:
	var rule := rule_of(slug)
	var mottle := SurfaceNoise.mottle(dir, radius, RockCatalogue.BLOTCH_M, RockCatalogue.STREAK_M)
	var carve_n := clampf(carve_m / CARVE_REF_M, 0.0, 1.0)
	var vein_n := vein_weight(wall_m)
	var elements: PackedStringArray = rule["elements"]
	var c: float
	if elements.is_empty():
		c = PURE_BASE * mottle
	elif rule["pair"]:
		c = sqrt(element_field("Fe", mottle, core, carve_n, vein_n)
				* element_field("Ti", mottle, core, carve_n, vein_n))
	else:
		var weights: PackedFloat64Array = rule["weights"]
		var num := 0.0
		var den := 0.0
		for i in elements.size():
			num += weights[i] * element_field(elements[i], mottle, core, carve_n, vein_n)
			den += weights[i]
		c = num / den
	return clampf(c * strata(dir, radius, height_m), 0.0, 1.0)


## Parts per million of [param element] in [param slug] at a point — the
## element's field placed in the rock's declared ppm range (0 for an element
## the rock does not carry). What a mined sample yields.
static func ppm(slug: String, element: String, dir: Vector3, radius: float,
		core: float, carve_m: float, wall_m: float = INF) -> float:
	var rock := RockCatalogue.get_rock(slug)
	for imp in rock.get("impurities", []):
		if str((imp as Dictionary).get("element", "")) != element:
			continue
		var mottle := SurfaceNoise.mottle(dir, radius, RockCatalogue.BLOTCH_M, RockCatalogue.STREAK_M)
		var f := element_field(element, mottle, core, clampf(carve_m / CARVE_REF_M, 0.0, 1.0),
				vein_weight(wall_m))
		return lerpf(float((imp as Dictionary).get("ppm_min", 0)),
				float((imp as Dictionary).get("ppm_max", 0)), f)
	return 0.0


# ── Colour ──────────────────────────────────────────────────────────

## Reduced-iron share in [0, 1] at a provenance depth: 0 on the plain (all
## Fe³⁺), 1 from VALENCE_DEPTH on — how far a rock with core_colors has slid
## to its deep hue.
static func valence(core: float, carve_m: float) -> float:
	return clampf(provenance(core, carve_m) / VALENCE_DEPTH, 0.0, 1.0)


## The ground colour of [param slug] at a point: light tint → dark tint by
## [method concentration] — the tints themselves slid toward the rock's
## core_colors by [method valence] when it has them — then paled by the dust
## of a flat inside a massif ([param slope] = 1 − normal·up, 0 flat; pass 0
## when unknown). Returns [param fallback] for a rock without colours.
static func tint(slug: String, dir: Vector3, radius: float, height_m: float,
		core: float, carve_m: float, slope: float,
		fallback: Color = Color(0.5, 0.5, 0.5), wall_m: float = INF) -> Color:
	var pair := RockCatalogue.colors_of(slug)
	if pair.is_empty():
		return fallback
	var light: Color = pair[0]
	var dark: Color = pair[1]
	var deep := RockCatalogue.core_colors_of(slug)
	if not deep.is_empty():
		var v := valence(core, carve_m)
		if v > 0.0:
			light = light.lerp(deep[0] as Color, v)
			dark = dark.lerp(deep[1] as Color, v)
	var col := light.lerp(dark,
			concentration(slug, dir, radius, height_m, core, carve_m, wall_m))
	var dust := dust_weight(core, slope)
	if dust > 0.0:
		col = col.lerp(light.lerp(DUST_TONE, DUST_MIX), dust)
	return col


## Share of dust cover on a surface of [param slope] inside a massif of
## [param core]: full on the flats of a crest, none on a face or on the plain.
static func dust_weight(core: float, slope: float) -> float:
	var flat := 1.0 - smoothstep(DUST_SLOPE_LO, DUST_SLOPE_HI, slope)
	return DUST_MAX * flat * smoothstep(DUST_CORE_LO, DUST_CORE_HI, core)


## The colour of the ground at [param dir] for a caller that has no chunk
## vertex — a road slab, a query: the rock's tint at the surface (no carve,
## level) inside whatever massif is there. [param height_m] is the surface
## height when the caller knows it (the strata need it); NAN samples it.
static func ground_tint(data: PlanetData, dir: Vector3, slug: String, fallback: Color,
		height_m: float = NAN) -> Color:
	var h := height_m if not is_nan(height_m) else data.sample_height_for_direction(dir)
	return tint(slug, dir, data.radius, h, data.mountain_core(dir), 0.0, 0.0, fallback)
