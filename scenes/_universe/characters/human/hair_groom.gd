class_name HairGroom
extends RefCounted

## Grows a head of hair from its settings (HairCut) on the neutral head (HairHead), in the game: guide
## strands and the shell of hair under them, as the HumanAssetData that HumanBuilder and HairStrands take.
## The rules are tools/character/hair_groom/groom.py's (which made the fixed styles before): roots drawn on
## the scalp where hair grows, strands leaving it combed along a flow, pulled down by gravity, kept out of
## the head and the shoulders, curled, drawn aside off the face; a tail or a bun past a tie.
##
## Deterministic -- its own random numbers, seeded by the cut -- so a cut is the same hair everywhere. One
## set of assets per distinct cut, cached (CAPACITY); safe from the bake workers.

## Guide strands of a head of hair at density 0.5 (the game makes HairStrands' hairs around each).
const GUIDES: int = 2400
const CAPACITY: int = 24
## The hairline fades in over this width (m) across it: a gradient of thinning hairs, not a line.
const HAIRLINE_WIDTH: float = 0.02
## Metres on the scalp per unit of elevation (its sine, seen from the skull's centre) at the forehead.
const METRES_PER_ELEVATION: float = 0.12
## Where a raised hairline's fade starts under its raised line (m): its middle where groom.HAIRLINE_FADE put it.
const RAISED_LINE_LEAD: float = 0.004
## What hangs in front of the face is kept this far from the middle (m) and under FACE_TOP (groom.py).
const FACE_HALF_WIDTH: float = 0.072
const FACE_TOP_FROM_CENTRE: float = 0.0306  # above the brows, from the skull's centre (groom FACE_TOP)
const FRINGE_TOP_FROM_CENTRE: float = 0.0166  # just above the eyes, under a fringe (groom FACE_TOP_FRINGE)
const TIE_PONYTAIL := Vector3(0.0, 0.035, -0.105)  # from the skull's centre
## The front hairline (sine of the elevation from the skull's centre): level across the forehead at FRONT_LINE
## (groom.HAIRLINE_FRONT 0.50 raised 0.28 for FFHQ's foreheads) out to FRONT_LINE_FLAT (azimuth, rad), then down
## the temples by FRONT_LINE_DROP at FRONT_LINE_SIDE, where the bank's own line (nape, behind the ears) takes over.
## The bank's line alone is a round arch: raised more in the middle, it drew a pointed one (temples 0.30-0.40 IOD
## under the middle, FFHQ's are 0.05-0.09 for men, 0.18 for women: hair_measure.py "temples").
const FRONT_LINE: float = 0.78
## Where the level part ends (azimuth, rad): a man's line (x), a rounder one (y, HairCut.round_line).
const FRONT_LINE_FLAT := Vector2(1.1, 0.8)
const FRONT_LINE_SIDE: float = 1.9
const FRONT_LINE_DROP: float = 1.15
## How far a low hairline (HairCut.low_line 1) brings the front line down (sine of the elevation): ~3 cm, short
## of the bank's own line (FRONT_LINE - groom.HAIRLINE_FRONT = 0.28), where the scalp ends.
const LOW_LINE_DROP: float = 0.25
## The temples' corners of a man's line, a little higher than the forehead: height, azimuth (rad), half-width (rad).
const TEMPLE_CORNER := Vector3(0.06, 1.15, 0.15)
const TIE_BUN := Vector3(0.0, 0.075, -0.085)
## The ears kept bare: the scalp (hair_head.res, groom.py's EAR_BOX left bare) still holds the top of each ear
## and the front of its hollow, where short hair's shell drew a dark patch inside the ear. Their vertices are those
## the bank's ear targets move: per target, full hair under the first share of its largest move, none past the
## second -- the ear's top drawn out (Fantasy_Ear, which also stretches the scalp above it a little), its hollow
## and its front (canal, tragus: inside the ear, bare from the least move).
const EAR_TARGETS: Dictionary = {
	"Fantasy_Ear": Vector2(0.15, 0.4), "Ears_Canal_Size": Vector2(0.05, 0.15), "Ears_Canal_Depth": Vector2(0.05, 0.15),
	"Ears_Tragus_Portrusion": Vector2(0.05, 0.15),
}
## And no hair under the ear's overhang: the shell, lifted a few mm off the scalp, came out through the front of the
## ear where it hangs close over the head. A scalp vertex is bare when a vertex of the ear (off the scalp, moved by
## Ears_Rot past EAR_PINNA of its largest move) lies above it within EAR_OVERHANG.x along its normal and
## EAR_OVERHANG.y across.
const EAR_PINNA: float = 0.2
const EAR_OVERHANG := Vector2(0.012, 0.005)
## A top bun's tie: on top of the head (the scalp's highest point is 0.115 m above the skull's centre).
const TIE_TOP_BUN := Vector3(0.0, 0.112, -0.005)
## A top bun is a twisted coil: its hairs spiral round a flattened ring sitting on the tie -- the ring's radius and
## the coil's thickness, as shares of the bun's size, and how flat it is (its height over its width).
const TOP_BUN_RING: float = 0.42
const TOP_BUN_COIL: float = 0.58
const TOP_BUN_FLAT: float = 1.0
## Hairs wound in a top bun (a coil is more surface than a low bun's ball: twice its hairs).
const TOP_BUN_HAIRS: int = 800
## A quiff (HairCut.Part.UP): its front hairs' lift off the scalp and stiffness at full quiff, and how much of
## their weight it holds up (style "quiff": 0 = none).
const QUIFF_LIFT: float = 0.95
const QUIFF_STIFF: float = 0.95
const QUIFF_HOLD: float = 1.0
## Where a quiff stands: from this far in front of the skull's centre (m), whole past the second.
const QUIFF_Z := Vector2(-0.01, 0.035)
## Flyaways (HairCut.flyaways 1): the share of hairs that escape the cut, plus this times how far the root is into
## the hairline's fade (1 at its edge); their lift, weight, comb, stiffness and added frizz.
const FLYAWAY_SHARE: float = 0.015
const FLYAWAY_EDGE: float = 0.25
const FLYAWAY_LIFT: float = 0.2
const FLYAWAY_GRAVITY: float = 0.9
const FLYAWAY_COMB: float = 0.15
const FLYAWAY_STIFF: float = 0.3
const FLYAWAY_FRIZZ: float = 0.35
## A flyaway's length, as a share of the cut's (drawn between the two).
const FLYAWAY_LENGTH := Vector2(0.25, 0.8)
## How much of the comb a quiff's hairs are spared at the root (none at the tip): they stand, then lie back.
const QUIFF_COMB_DELAY: float = 1.0
## How hairs gather around their guide (HairStrands): clump (m), clump_tip, frizz (m), per kind of hair.
const KINDS: Array = [[0.004, 0.92, 0.0008], [0.005, 0.75, 0.002], [0.003, 0.7, 0.001], [0.006, 1.0, 0.004]]

const NATIVE_PATH: String = "res://scenes/_universe/characters/human/native/HairGroomNative.cs"
## The style's knobs handed to the C# twin, in its order (HairGroomNative's constants).
const NATIVE_STYLE: Array[String] = ["top", "side", "strand_seg", "lift", "gravity", "comb", "comb_reach", "stiff", "volume",
		"frizz", "curl", "pitch", "front", "fringe", "tail", "bun", "guides", "clump", "clump_tip", "kind_frizz", "quiff",
		"flyaways", "loose_len"]
const FLOWS: Array[String] = ["crown", "part_centre", "part_left", "part_right", "back", "tie"]

static var _native: Object = null  # HairGroomNative, made on the main thread (adopt_native), configured on first use
static var _native_ready: bool = false
static var _cache: Dictionary = {}  # cut key -> Array[HumanAssetData]
static var _order: Array[String] = []  # least recently used first
static var _mutex := Mutex.new()
static var _ears := PackedFloat32Array()  # _off_ears(), per scalp vertex

var _head: HairHead
var _state: int = 0
var _use_native: bool = true


## A fresh C# twin when DyingStar.dll carries it, else null. Main thread (C# objects are made there).
static func native_instance() -> Object:
	var script: Script = NativeScript.load_usable(NATIVE_PATH, ["Configure", "Strands"])
	return script.new() if script != null else null


## Keep [param native] (native_instance(), main thread) for the bake workers.
static func adopt_native(native: Object) -> void:
	_mutex.lock()
	if _native == null:
		_native = native
	_mutex.unlock()


## The C# twin as it is (made by adopt_native), for loops that need no head (HairStrands); null without one.
static func native_twin() -> Object:
	_mutex.lock()
	var out: Object = _native
	_mutex.unlock()
	return out


## The C# twin, configured with [param head] on first use; null without one.
static func _configured_native(head: HairHead) -> Object:
	_mutex.lock()
	if _native != null and not _native_ready:
		_native.call("Configure", head.scalp_vertex, head.scalp_position, head.scalp_normal, head.scalp_triangles,
				head.centre, head.crown, head.sdf, head.sdf_origin, head.sdf_cell, head.sdf_size)
		_native_ready = true
	var out: Object = _native
	_mutex.unlock()
	return out


## The assets of [param cut]: [shell, strands] (strands absent under HairCut.SHELL_ONLY_BELOW), made on
## first use (any thread) and kept while used.
static func assets_for(cut: HairCut) -> Array[HumanAssetData]:
	var key: String = cut.key()
	_mutex.lock()
	var found: Variant = _cache.get(key)
	if found != null:
		_order.erase(key)
		_order.append(key)
		_mutex.unlock()
		return found
	_mutex.unlock()
	var made: Array[HumanAssetData] = HairGroom.new(HairHead.shared()).grow(cut)
	var dropped: Array = []
	_mutex.lock()
	if _cache.has(key):  # another worker made it meanwhile: keep one
		made = _cache[key]
	else:
		_cache[key] = made
		_order.append(key)
		while _order.size() > CAPACITY:
			var old: String = _order.pop_front()
			dropped.append_array(_cache[old])
			_cache.erase(old)
	_mutex.unlock()
	# Outside the mutex: HairStrands holds its lock while it builds, and asks for the C# twin (this mutex)
	# meanwhile -- forgetting under this one deadlocked a worker against another.
	for asset: HumanAssetData in dropped:
		HairStrands.forget(asset)
	return made


func _init(head: HairHead) -> void:
	_head = head


# --- random numbers: the same on every machine and in the C# twin ---------------------------------------

func _seed(bytes: PackedByteArray) -> void:
	var h: int = 2166136261  # FNV-1a
	for b in bytes:
		h = ((h ^ b) * 16777619) & 0xFFFFFFFF
	_state = h


func _uniform() -> float:
	_state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF
	return float(_state) / 4294967296.0


func _range(a: float, b: float) -> float:
	return a + (b - a) * _uniform()


func _normal() -> float:
	return (_uniform() + _uniform() + _uniform() + _uniform() - 2.0) * 1.7320508


func _normal3() -> Vector3:
	return Vector3(_normal(), _normal(), _normal())


# --- the style: the settings turned into groom.py's knobs ------------------------------------------------

## groom.py's style knobs for [param cut].
static func style_of(cut: HairCut) -> Dictionary:
	var top: float = cut.top_length()
	var c: float = cut.curl
	var coily: float = smoothstep(0.75, 1.0, c)
	var curly: float = smoothstep(0.15, 0.7, c)
	var long_hair: float = smoothstep(0.03, 0.25, top)
	var s := {}
	s["top"] = top
	s["side"] = cut.side_length()
	s["seg"] = clampi(int(top / 0.03) + 3, 4, 12)
	s["strand_seg"] = mini(int(s["seg"]) + 2 + roundi(c * 8.0), 18)
	s["lift"] = lerpf(0.25, 0.12, smoothstep(0.03, 0.2, top)) + 0.1 * curly + 0.45 * coily
	s["gravity"] = lerpf(0.35, 1.1, long_hair) * (1.0 - 0.95 * coily)
	s["comb"] = lerpf(0.7, 1.0, smoothstep(0.03, 0.12, top)) * (1.0 - 0.9 * coily)
	s["comb_reach"] = 0.3 if top > 0.18 else 2.0
	s["stiff"] = 0.5 - 0.2 * coily
	s["volume"] = lerpf(0.007, 0.016, cut.volume) + 0.03 * coily
	s["frizz"] = 0.03 + 0.04 * c + 0.85 * coily
	s["curl"] = 0.0 if c < 0.15 else lerpf(0.004, 0.009, curly) * (1.0 - 0.7 * coily)
	s["pitch"] = lerpf(0.08, 0.045, curly) * (1.0 - 0.6 * coily)
	s["front"] = (lerpf(1.0, 0.75, smoothstep(0.1, 0.3, top)) if cut.fringe < 0.02 else 1.0) * (1.0 - 0.45 * curly)
	s["fringe"] = lerpf(0.02, 0.07, cut.fringe) if cut.fringe >= 0.02 else 0.0
	s["flow"] = ["crown", "part_centre", "part_left", "part_right", "back", "back", "back"][cut.part]
	s["quiff"] = 0.0
	if cut.part == HairCut.Part.UP:  # the front swept up off the forehead, then back
		s["quiff"] = lerpf(0.5, 1.0, cut.volume)
		s["front"] = 1.3
		s["fringe"] = 0.0
	if cut.part == HairCut.Part.CREST:  # a strip along the middle, standing
		s["lift"] = 0.75
		s["gravity"] = 0.1
		s["comb"] = 0.5
		s["stiff"] = 0.7
	s["tie"] = cut.tie
	s["flyaways"] = cut.flyaways
	s["loose_len"] = maxf(top, 0.06)  # a loose hair keeps the cut's length, even from a tied head
	if cut.tie != HairCut.Tie.LOOSE:
		s["flow"] = "tie"
		s["top"] = 0.13
		s["side"] = 0.13
		s["seg"] = 5
		s["strand_seg"] = 7
		s["lift"] = 0.1
		s["gravity"] = 0.0
		s["comb"] = 1.6
		s["comb_reach"] = 2.0
		s["stiff"] = 0.3
		s["front"] = 1.0
		s["fringe"] = 0.0
		s["tail"] = maxf(top * 0.9, 0.12)
		s["bun"] = 0.03 + 0.015 * smoothstep(0.1, 0.5, top)
		if cut.tie == HairCut.Tie.TOP_BUN:  # a top knot: larger, the more so with the volume
			s["bun"] = (0.028 + 0.012 * smoothstep(0.1, 0.5, top)) * lerpf(0.9, 1.3, cut.volume)
	# How hairs gather round a guide: straight -> wavy -> curly -> coily.
	var k: float = c * 3.0
	var i: int = mini(int(k), 2)
	var f: float = k - i
	s["clump"] = lerpf(KINDS[i][0], KINDS[i + 1][0], f)
	s["clump_tip"] = lerpf(KINDS[i][1], KINDS[i + 1][1], f)
	s["kind_frizz"] = lerpf(KINDS[i][2], KINDS[i + 1][2], f)
	s["guides"] = roundi(GUIDES * lerpf(0.6, 1.4, cut.density))
	s["shell_height"] = clampf(cut.side_length(), 0.0015, 0.0045)
	# Under short hair (or shaved sides) the shell is the hair itself, seen end-on: many layers.
	s["shell_layers"] = 8 if cut.side_length() < HairCut.SHELL_ONLY_BELOW else 2
	return s


# --- growing --------------------------------------------------------------------------------------------

## [shell, strands]: the assets of [param cut]. [param native]: the strands in C# when it is there (the
## GDScript below is its reference: tests compare them).
func grow(cut: HairCut, native: bool = true) -> Array[HumanAssetData]:
	_use_native = native
	_seed(cut.to_bytes())
	var style: Dictionary = style_of(cut)
	var density: PackedFloat32Array = _scalp_density(cut)
	var out: Array[HumanAssetData] = [_shell(cut, style, density)]
	if not cut.shell_only():
		var strands: HumanAssetData = _strands(cut, style, density)
		if strands != null:
			out.append(strands)
	return out


## How much hair grows at each scalp vertex for this cut: the hairline raised by its recession (more at the
## temples), the crown thinned.
func _scalp_density(cut: HairCut) -> PackedFloat32Array:
	var ears: PackedFloat32Array = _off_ears(_head)
	var out := PackedFloat32Array()
	out.resize(_head.scalp_vertex.size())
	for v in out.size():
		var p: Vector3 = _head.scalp_position[v]
		var rel: Vector3 = (p - _head.centre).normalized()
		var temples: float = smoothstep(0.25, 0.75, absf(rel.x)) * smoothstep(-0.2, 0.4, rel.z)
		# The bank's hairline sits ~3 cm low at the front for FFHQ's (a bare forehead of 0.94 eye distances
		# under hair worn without a fringe): the front line, level, replaces it there.
		var azimuth: float = absf(atan2(rel.x, rel.z))
		var flat: float = FRONT_LINE_FLAT.y if cut.round_line else FRONT_LINE_FLAT.x
		var corner: float = 0.0 if cut.round_line else TEMPLE_CORNER.x
		var front: float = FRONT_LINE - LOW_LINE_DROP * cut.low_line - FRONT_LINE_DROP * smoothstep(flat, FRONT_LINE_SIDE, azimuth) \
				+ corner * exp(-pow((azimuth - TEMPLE_CORNER.y) / TEMPLE_CORNER.z, 2.0))
		var bank_line: float = rel.y - _head.scalp_above[v]
		var line: float = maxf(bank_line, front) + cut.recession * (0.12 + 0.22 * temples)
		# How far inside the hairline (m): from the scalp's edge, or under the raised line. Measured across the
		# line, so the hair thins out as gradually down the temples as on the forehead.
		var inside: float = minf(_head.scalp_edge[v], (rel.y - line) * METRES_PER_ELEVATION + RAISED_LINE_LEAD)
		var d: float = smoothstep(0.0, HAIRLINE_WIDTH, inside)
		var bald: float = cut.crown_bald * 0.085
		d *= smoothstep(bald, bald + 0.025, p.distance_to(_head.crown)) if bald > 0.0 else 1.0
		d *= ears[v]
		out[v] = d
	return out


## Per scalp vertex of [param head], 1 off the ears to 0 on them (EAR_TARGETS), worked out once (any thread).
static func _off_ears(head: HairHead) -> PackedFloat32Array:
	_mutex.lock()
	if _ears.size() != head.scalp_vertex.size():
		var keep := PackedFloat32Array()
		keep.resize(head.scalp_vertex.size())
		keep.fill(1.0)
		var morph: HumanMorph = HumanMorph.shared()
		var base: PackedVector3Array = morph.bank.base
		for key: String in EAR_TARGETS:
			var slot: int = morph.bank.target_index(key)
			if slot == -1:
				continue
			var moved: PackedVector3Array = morph.with_target(base, slot, 1.0)
			var most := 0.0
			for c in base.size():  # on the ear: its largest move
				most = maxf(most, moved[c].distance_to(base[c]))
			var share: Vector2 = EAR_TARGETS[key]
			for v in head.scalp_vertex.size():
				var c: int = head.scalp_vertex[v]
				keep[v] *= 1.0 - smoothstep(share.x, share.y, moved[c].distance_to(base[c]) / maxf(most, 1e-9))
		var pinna := PackedVector3Array()
		var rot_slot: int = morph.bank.target_index("Ears_Rot")
		if rot_slot != -1:
			var turned: PackedVector3Array = morph.with_target(base, rot_slot, 1.0)
			var most := 0.0
			for c in base.size():
				most = maxf(most, turned[c].distance_to(base[c]))
			var scalp := {}
			for c in head.scalp_vertex:
				scalp[c] = true
			for c in base.size():
				if not scalp.has(c) and turned[c].distance_to(base[c]) > EAR_PINNA * most:
					pinna.append(base[c])
		for v in head.scalp_vertex.size():
			if keep[v] <= 0.0:
				continue
			var p: Vector3 = base[head.scalp_vertex[v]]
			var n: Vector3 = head.scalp_normal[v]
			for e in pinna:
				var d: Vector3 = e - p
				var up: float = d.dot(n)
				if up > -0.001 and up < EAR_OVERHANG.x and (d - n * up).length() < EAR_OVERHANG.y:
					keep[v] = 0.0
					break
		_ears = keep
	var out: PackedFloat32Array = _ears
	_mutex.unlock()
	return out


## The comb (unit): where hair is brushed towards at [param p] (groom.Head.flow).
func _flow(kind: String, p: Vector3, style: Dictionary) -> Vector3:
	var rel: Vector3 = p - _head.centre
	var f: Vector3
	match kind:
		"back":
			f = Vector3(0.0, -0.25, -1.0)
		"tie":
			f = _head.centre + _tie_point(style["tie"]) - p
		"part_centre", "part_left", "part_right":
			var part_x: float = {"part_centre": 0.0, "part_left": 0.028, "part_right": -0.028}[kind]
			var side: float = 1.0 if rel.x >= part_x else -1.0
			f = Vector3(side * 0.95, -0.7, -0.2)
			if style["fringe"] > 0.0:  # the front falls forward over the forehead
				var front: float = smoothstep(0.03, 0.07, rel.z) * (1.0 if absf(rel.x) < 0.06 else 0.0)
				f = f * (1.0 - front) + Vector3(0.0, -0.8, 0.75) * front
		_:  # "crown": away from the whorl, with a twist
			var away: Vector3 = (p - _head.crown).normalized()
			f = away + 0.3 * Vector3.UP.cross(away)
	if style["fringe"] <= 0.0 and kind != "back" and kind != "tie":
		# Without a fringe the front is combed back and aside, off the forehead (FFHQ: a bare forehead of
		# ~0.8 eye distances under hair worn without one).
		var front: float = smoothstep(0.02, 0.06, rel.z) * (1.0 if absf(rel.x) < 0.07 else 0.0)
		f = f * (1.0 - front) + Vector3((1.0 if rel.x >= 0.0 else -1.0) * 0.6, 0.25, -0.8) * front
	return f.normalized()


## Where a tied head of hair is gathered, from the skull's centre.
static func _tie_point(tie: int) -> Vector3:
	match tie:
		HairCut.Tie.PONYTAIL:
			return TIE_PONYTAIL
		HairCut.Tie.TOP_BUN:
			return TIE_TOP_BUN
	return TIE_BUN


## A flyaway's knobs: left to fall from its root (the natural whorl's comb, little of it), soft and frizzy, not
## drawn to the tie.
static func _loose_style(style: Dictionary) -> Dictionary:
	var s: Dictionary = style.duplicate()
	s["flow"] = "crown"
	s["lift"] = FLYAWAY_LIFT
	s["gravity"] = FLYAWAY_GRAVITY
	s["comb"] = FLYAWAY_COMB
	s["stiff"] = FLYAWAY_STIFF
	s["frizz"] = float(style["frizz"]) + FLYAWAY_FRIZZ
	s["quiff"] = 0.0
	return s


## Pushes [param p] out of the head to [param clear] (m) off its surface.
func _clear_of_head(p: Vector3, clear: float) -> Vector3:
	var s: Array = _head.surface(p)
	var d: float = s[0]
	return p + (s[1] as Vector3) * (clear - d) if d < clear else p


func _strands(cut: HairCut, style: Dictionary, density: PackedFloat32Array) -> HumanAssetData:
	var twin: Object = _configured_native(_head) if _use_native else null
	if twin != null:
		var knobs := PackedFloat64Array()
		for key in NATIVE_STYLE:
			knobs.append(float(style.get(key, 0.0)))
		var got: Array = twin.call("Strands", _state, density, knobs, FLOWS.find(style["flow"]), cut.part, cut.tie)
		_state = got[5]
		if (got[1] as PackedColorArray).is_empty():
			return null
		return _wrap(cut, got[0], int(style["strand_seg"]) + 1, got[1], got[2], got[3], got[4], style)
	var tris: PackedInt32Array = _head.scalp_triangles
	var tri_count: int = tris.size() / 3
	# Roots: drawn on the scalp's triangles by area x density (groom.Head.roots).
	var cumulative := PackedFloat64Array()
	cumulative.resize(tri_count)
	var total: float = 0.0
	for t in tri_count:
		var a: Vector3 = _head.scalp_position[tris[t * 3]]
		var b: Vector3 = _head.scalp_position[tris[t * 3 + 1]]
		var c: Vector3 = _head.scalp_position[tris[t * 3 + 2]]
		var dens: float = (density[tris[t * 3]] + density[tris[t * 3 + 1]] + density[tris[t * 3 + 2]]) / 3.0
		total += (b - a).cross(c - a).length() * dens
		cumulative[t] = total
	if total <= 0.0:
		return null
	var count: int = style["guides"]
	var n: int = int(style["strand_seg"]) + 1
	var top: float = style["top"]
	var side_len: float = style["side"]
	var fringe: float = style["fringe"]
	var down := Vector3(0.0, -1.0, 0.0)
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	var refs := PackedInt32Array()
	var weights := PackedFloat32Array()
	var face_top: float = _head.centre.y + (FRINGE_TOP_FROM_CENTRE if fringe > 0.0 else FACE_TOP_FROM_CENTRE)
	for _s in count:
		var t: int = cumulative.bsearch(_uniform() * total)
		t = mini(t, tri_count - 1)
		var r1: float = sqrt(_uniform())
		var r2: float = _uniform()
		var bary := Vector3(1.0 - r1, r1 * (1.0 - r2), r1 * r2)
		var i0: int = tris[t * 3]
		var i1: int = tris[t * 3 + 1]
		var i2: int = tris[t * 3 + 2]
		var root: Vector3 = _head.scalp_position[i0] * bary.x + _head.scalp_position[i1] * bary.y + _head.scalp_position[i2] * bary.z
		var normal: Vector3 = (_head.scalp_normal[i0] * bary.x + _head.scalp_normal[i1] * bary.y + _head.scalp_normal[i2] * bary.z).normalized()
		var root_density: float = density[i0] * bary.x + density[i1] * bary.y + density[i2] * bary.z
		var rel: Vector3 = root - _head.centre
		var height: float = clampf(rel.normalized().y, 0.0, 1.0)
		var on_top: float = smoothstep(0.25, 0.85, height)
		if cut.part == HairCut.Part.CREST:  # only the middle strip is long
			on_top = smoothstep(0.66, 0.74, height) * smoothstep(0.04, 0.03, absf(rel.x))
		var length: float = (side_len + (top - side_len) * on_top) * _range(0.8, 1.1)
		length *= 1.0 + (float(style["front"]) - 1.0) * smoothstep(0.035, 0.07, rel.z) * (1.0 if absf(rel.x) < 0.07 else 0.0)
		if fringe > 0.0 and rel.z > 0.045 and absf(rel.x) < 0.06:
			length = fringe * _range(0.85, 1.1)
		var layer: float = _uniform()
		if length < HairCut.SHELL_ONLY_BELOW:
			continue  # shaved there: the shell is the hair
		# Without a fringe the front is combed back all along, or it falls over the forehead.
		var reach: float = float(style["comb_reach"])
		if fringe <= 0.0 and rel.z > 0.03 and absf(rel.x) < 0.07:
			reach = 2.0
		# A flyaway: a hair escaping the cut, more of them along the hairline (no draw at all without flyaways, so
		# every other cut keeps its hairs).
		var grow_style: Dictionary = style
		var loose: bool = false
		if float(style["flyaways"]) > 0.0 and _uniform() < float(style["flyaways"]) * (FLYAWAY_SHARE + FLYAWAY_EDGE * (1.0 - root_density)):
			loose = true
			length = float(style["loose_len"]) * _range(FLYAWAY_LENGTH.x, FLYAWAY_LENGTH.y)
			grow_style = _loose_style(style)
		var strand: PackedVector3Array = _grow_one(root, normal, length, layer, grow_style, reach)
		if style["curl"] > 0.0:
			strand = _curl(strand, style, 0.0015 + float(style["volume"]) * layer)
		# Hair frames a face, it does not hang across it: what falls in front of it is drawn aside -- or, coming
		# from its middle (a fringe), ends there: drawn aside, it would cross the eyes.
		var aside: float = (1.0 if root.x >= 0.0 else -1.0) * FACE_HALF_WIDTH * (1.0 + 0.12 * layer)
		var ended: bool = false
		for k in strand.size():
			var q: Vector3 = strand[k]
			if ended:
				strand[k] = strand[k - 1]
			elif q.z - _head.centre.z > 0.04 and q.y < face_top and absf(q.x - _head.centre.x) < FACE_HALF_WIDTH:
				if k > 0 and absf(strand[k - 1].x - _head.centre.x) < FACE_HALF_WIDTH * 0.8:
					ended = true
					strand[k] = strand[k - 1]
				else:
					strand[k] = Vector3(aside, q.y, q.z)
		points.append_array(strand)
		colours.append(Color(1.0 if loose or cut.tie == HairCut.Tie.LOOSE else 0.0, _uniform(), layer, root_density))
		refs.append_array([_head.scalp_vertex[i0], _head.scalp_vertex[i1], _head.scalp_vertex[i2]])
		weights.append_array([bary.x, bary.y, bary.z])
	var longest: float = maxf(top, side_len) * 1.1
	if float(style["flyaways"]) > 0.0:
		longest = maxf(longest, float(style["loose_len"]) * 1.05)
	if cut.tie != HairCut.Tie.LOOSE:
		var extra: Array = _gathered(style, n)
		var tie_point: Vector3 = _head.centre + _tie_point(cut.tie)
		var near: Array = _nearest_scalp(tie_point)
		for e: PackedVector3Array in extra[0]:
			points.append_array(e)
			colours.append(Color(1.0 if cut.tie == HairCut.Tie.PONYTAIL else 0.0, _uniform(), _uniform(), 1.0))
			refs.append_array(near)
			weights.append_array([1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0])
		if cut.tie == HairCut.Tie.PONYTAIL:
			longest = maxf(longest, float(style["tail"]) * 1.05)
	return _strand_asset(cut, points, n, colours, refs, weights, style, longest)


## One guide strand of [param n] points from its root (groom.grow, for one strand).
func _grow_one(root: Vector3, normal: Vector3, length: float, layer: float, style: Dictionary, reach: float) -> PackedVector3Array:
	var n: int = int(style["strand_seg"]) + 1
	var seg: int = n - 1
	var step: float = length / seg
	var clear: float = 0.0015 + float(style["volume"]) * layer
	var comb: Vector3 = _flow(style["flow"], root, style)
	comb -= normal * comb.dot(normal)
	# A quiff: the front's hairs stand off the forehead and hold up against their weight.
	var rel: Vector3 = root - _head.centre
	var quiff: float = float(style["quiff"]) * smoothstep(QUIFF_Z.x, QUIFF_Z.y, rel.z) * (1.0 if absf(rel.x) < 0.07 else 0.0)
	var lift: float = float(style["lift"]) + (QUIFF_LIFT - float(style["lift"])) * quiff
	var stiff: float = float(style["stiff"]) + (QUIFF_STIFF - float(style["stiff"])) * quiff
	var gravity: float = float(style["gravity"]) * (1.0 - QUIFF_HOLD * quiff)
	var direction: Vector3 = (normal * lift + comb.normalized() * (1.0 - lift)).normalized()
	var point: Vector3 = root
	var out := PackedVector3Array([root])
	var own_reach: float = float(style["comb_reach"])
	for k in seg:
		var t: float = float(k + 1) / seg
		# A front hair combed aside all along (_strands: so it does not fall over the face) is, once beside the face,
		# combed no further than the cut's: it falls with the others. Combed on, a long hair went on sideways to its
		# tip and stood out diagonally from the side of the head.
		if reach > own_reach and absf(point.x - _head.centre.x) > FACE_HALF_WIDTH:
			reach = own_reach
		var want: Vector3 = direction * stiff + Vector3.DOWN * gravity * (0.4 + 0.6 * t) \
				+ _flow(style["flow"], point, style) * float(style["comb"]) * maxf(0.0, 1.0 - t / reach) \
				* (1.0 - QUIFF_COMB_DELAY * quiff * (1.0 - t)) \
				+ _normal3() * float(style["frizz"])
		var previous: Vector3 = point
		point += want.normalized() * step
		for _pass in 2:
			point = _clear_of_head(point, clear * minf(1.0, 0.5 + 0.5 * t * seg))
		direction = (point - previous).normalized()
		out.append(point)
	return out


## A strand wound around its own path: a helix opening from the root (groom.curl).
func _curl(strand: PackedVector3Array, style: Dictionary, clear: float) -> PackedVector3Array:
	var n: int = strand.size()
	var phase: float = _range(0.0, TAU)
	var turns: float = TAU / float(style["pitch"]) * _range(0.8, 1.25)
	var radius_scale: float = float(style["curl"]) * _range(0.6, 1.3)
	var out := PackedVector3Array(strand)
	var arc: float = 0.0
	for k in range(1, n):
		arc += strand[k].distance_to(strand[k - 1])
		var tangent: Vector3 = (strand[mini(k + 1, n - 1)] - strand[k - 1]).normalized()
		var e1: Vector3 = tangent.cross(Vector3(0.001, 1.001, 0.001)).normalized()
		var e2: Vector3 = tangent.cross(e1)
		var angle: float = arc * turns + phase
		var radius: float = radius_scale * smoothstep(0.0, 0.03, arc)
		out[k] = _clear_of_head(strand[k] + e1 * cos(angle) * radius + e2 * sin(angle) * radius, clear * 0.5)
	return out


## The hair past its tie: a tail hanging from it or a bun wound around it (groom.gathered): [strands].
func _gathered(style: Dictionary, n: int) -> Array:
	var ponytail: bool = style["tie"] == HairCut.Tie.PONYTAIL
	var tie: Vector3 = _head.centre + _tie_point(style["tie"])
	var outward: Vector3 = (tie - _head.centre).normalized()
	var strands: Array = []
	if ponytail:
		for _s in 420:
			var point: Vector3 = _clear_of_head(tie + _normal3() * 0.008, 0.004)
			var direction: Vector3 = (outward * 0.9 + Vector3(0.0, 0.25, 0.0) + _normal3() * 0.12).normalized()
			var length: float = float(style["tail"]) * _range(0.75, 1.05)
			var strand := PackedVector3Array([point])
			for k in n - 1:
				var t: float = float(k + 1) / (n - 1)
				var want: Vector3 = direction * 0.55 + Vector3.DOWN * (0.35 + 0.9 * t) + _normal3() * 0.05
				var previous: Vector3 = point
				point = _clear_of_head(point + want.normalized() * length / (n - 1), 0.012)
				direction = (point - previous).normalized()
				strand.append(point)
			strands.append(strand)
		return [strands]
	if style["tie"] == HairCut.Tie.TOP_BUN:
		return [_top_bun(style, n, tie, outward)]
	var radius: float = style["bun"]
	var centre: Vector3 = tie + outward * radius * 0.6
	for _s in 400:
		var axis: Vector3 = (outward + _normal3() * 0.35).normalized()
		var e1: Vector3 = axis.cross(_normal3()).normalized()
		var e2: Vector3 = axis.cross(e1)
		var shift: float = _range(-0.75, 0.75) * radius
		var ring: float = sqrt(maxf(radius * radius - shift * shift, 1e-8)) * _range(0.95, 1.08)
		var start: float = _range(0.0, TAU)
		var sweep: float = _range(1.6, 3.2)
		var strand := PackedVector3Array()
		for k in n:
			var angle: float = start + sweep * float(k) / (n - 1)
			strand.append(_clear_of_head(centre + axis * shift + e1 * cos(angle) * ring + e2 * sin(angle) * ring, 0.003))
		strands.append(strand)
	return [strands]


## A top bun's hairs: each spirals round a flattened ring on the tie (a twisted coil). Messy with the flyaways: a
## coil of uneven thickness, loops standing out of it, ends escaping.
func _top_bun(style: Dictionary, n: int, tie: Vector3, outward: Vector3) -> Array:
	var radius: float = style["bun"]
	var mess: float = float(style["flyaways"])
	var e1: Vector3 = outward.cross(Vector3(0.0, 0.0, 1.0)).normalized()
	var e2: Vector3 = outward.cross(e1)
	var ring: float = radius * TOP_BUN_RING
	var coil: float = radius * TOP_BUN_COIL
	var centre: Vector3 = tie + outward * coil * 0.9
	var strands: Array = []
	for _s in TOP_BUN_HAIRS:
		var u0: float = _range(0.0, TAU)
		var sweep: float = _range(1.5, 3.5)
		var v0: float = _range(0.0, TAU)
		var twist: float = _range(1.5, 3.0)
		var thick: float = _range(1.0 - 0.15 * mess, 1.0 + 0.2 * mess)
		var loop: float = _range(1.3, 1.6) if _uniform() < 0.04 + 0.08 * mess else 1.0
		var end: float = _range(0.3, 0.8) * radius if _uniform() < 0.03 + 0.1 * mess else 0.0
		var strand := PackedVector3Array()
		for k in n:
			var t: float = float(k) / (n - 1)
			var u: float = u0 + sweep * t
			var v: float = v0 + twist * sweep * t
			var r: float = coil * thick * (1.0 + (loop - 1.0) * sin(PI * t))
			var around: Vector3 = e1 * cos(u) + e2 * sin(u)
			var p: Vector3 = centre + around * (ring + r * cos(v)) + outward * (r * sin(v) * TOP_BUN_FLAT)
			if end > 0.0 and t > 0.7:
				p += (around * 0.7 + outward * 0.3).normalized() * end * ((t - 0.7) / 0.3)
			p += _normal3() * (0.0015 * mess)
			strand.append(_clear_of_head(p, 0.003))
		strands.append(strand)
	return strands


## The 3 scalp vertices (compact ids) nearest [param p].
func _nearest_scalp(p: Vector3) -> Array:
	var best: Array = [[INF, 0], [INF, 0], [INF, 0]]
	for v in _head.scalp_vertex.size():
		var d: float = p.distance_squared_to(_head.scalp_position[v])
		if d < best[2][0]:
			best[2] = [d, v]
			best.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	return [_head.scalp_vertex[best[0][1]], _head.scalp_vertex[best[1][1]], _head.scalp_vertex[best[2][1]]]


func _strand_asset(cut: HairCut, points: PackedVector3Array, n: int, colours: PackedColorArray, refs: PackedInt32Array,
		weights: PackedFloat32Array, style: Dictionary, longest: float) -> HumanAssetData:
	var count: int = colours.size()
	# Any first share of the guides is a fair sample (the hairs' levels of detail are prefixes).
	var order: Array[int] = []
	order.resize(count)
	for k in count:
		order[k] = k
	for k in range(count - 1, 0, -1):
		var j: int = int(_uniform() * (k + 1))
		var tmp: int = order[k]
		order[k] = order[j]
		order[j] = tmp
	var out_points := PackedVector3Array()
	var out_colours := PackedColorArray()
	var out_refs := PackedInt32Array()
	var out_weights := PackedFloat32Array()
	var out_offsets := PackedVector3Array()
	for k in order:
		out_points.append_array(points.slice(k * n, (k + 1) * n))
		out_colours.append(colours[k])
		out_refs.append_array(refs.slice(k * 3, k * 3 + 3))
		out_weights.append_array(weights.slice(k * 3, k * 3 + 3))
		var root: Vector3 = points[k * n]
		var bound: Vector3 = Vector3.ZERO
		for j in 3:
			bound += _bank_point(refs[k * 3 + j]) * weights[k * 3 + j]
		out_offsets.append(root - bound)
	return _wrap(cut, out_points, n, out_colours, out_refs, out_weights, out_offsets, style, longest)


## The strands' asset (guides already shuffled).
func _wrap(cut: HairCut, points: PackedVector3Array, n: int, colours: PackedColorArray, refs: PackedInt32Array,
		weights: PackedFloat32Array, offsets: PackedVector3Array, style: Dictionary, longest: float = -1.0) -> HumanAssetData:
	if longest < 0.0:
		longest = maxf(float(style["top"]), float(style["side"])) * 1.1
		if cut.tie == HairCut.Tie.PONYTAIL:
			longest = maxf(longest, float(style["tail"]) * 1.05)
		if float(style["flyaways"]) > 0.0:
			longest = maxf(longest, float(style["loose_len"]) * 1.05)
	var asset := HumanAssetData.new()
	asset.kind = &"hair"
	asset.part = 1
	asset.id = StringName("cut_" + cut.key())
	asset.gender = &"any"
	asset.style = &"strands"
	asset.strand_size = n
	asset.scale_pairs = PackedInt32Array([-1, -1, -1, -1, -1, -1])
	asset.scale_ref = PackedFloat32Array([1.0, 1.0, 1.0])
	asset.strand_points = points
	asset.color = colours
	asset.refs = refs
	asset.weights = weights
	asset.offsets = offsets
	asset.strand_params = {"children": 5, "clump": style["clump"], "clump_tip": style["clump_tip"],
			"frizz": style["kind_frizz"], "longest": longest, "centre": [_head.centre.x, _head.centre.y, _head.centre.z]}
	asset.strand_free = _free_from(cut, points, n, colours, weights)
	return asset


## Per guide, from how far along it the hair may move (HumanAssetData.strand_free): a loose cut's hairs past the
## shaders' fixed length; a fringe's near its root (it is short); of a tied cut, the tail and the bun just past
## the tie (their guides are rooted on it, weighted a third to each of the 3 scalp vertices nearest it), its
## flyaways (R = 1, rooted on the scalp) like a loose cut's, the scalp's hairs never (gathered to the tie).
func _free_from(cut: HairCut, points: PackedVector3Array, n: int, colours: PackedColorArray,
		weights: PackedFloat32Array) -> PackedFloat32Array:
	var free := PackedFloat32Array()
	free.resize(colours.size())
	for k in free.size():
		var on_tie: bool = absf(weights[k * 3] - 1.0 / 3.0) < 1e-5 and absf(weights[k * 3 + 1] - 1.0 / 3.0) < 1e-5
		var rel: Vector3 = points[k * n] - _head.centre
		if cut.tie != HairCut.Tie.LOOSE and on_tie:
			free[k] = HairMotionBinding.TAIL_FIXED if cut.tie == HairCut.Tie.PONYTAIL else HairMotionBinding.BUN_FIXED
		elif cut.tie == HairCut.Tie.LOOSE or colours[k].r > 0.5:
			var fringe: bool = cut.fringe >= 0.02 and rel.z > 0.045 and absf(rel.x) < 0.06
			free[k] = HairMotionBinding.FRINGE_FIXED if fringe else HairMotionBinding.GLOBAL_FIXED
		else:
			free[k] = HairMotionBinding.RIGID
	return free


## A scalp vertex's neutral position by its compact id.
func _bank_point(compact: int) -> Vector3:
	var at: int = _head.scalp_vertex.bsearch(compact)
	return _head.scalp_position[at] if at < _head.scalp_vertex.size() and _head.scalp_vertex[at] == compact else Vector3.ZERO


## The shell: the scalp's triangles lifted in layers where hair grows (groom.shell), drawn as hair seen
## end-on (human_hair_shell.gdshader).
## Under a head of hair whose strands cover it all (sides not shaved), only the cap, drawn as the scalp seen
## through the hairs (style "scalp", human_hair_scalp.gdshader): a shade fading out over the whole hairline,
## where the shell's cap appeared at a density of 0.85 and drew a hard edge inside it. A buzz cut and shaved
## sides keep the shell: there it is the hair.
func _shell(cut: HairCut, style: Dictionary, density: PackedFloat32Array) -> HumanAssetData:
	var layers: int = style["shell_layers"]
	var height: float = style["shell_height"]
	var first: float = 0.0005
	var under: float = 0.0 if cut.shell_only() else 1.0  # strands over it: the hairline is theirs
	var scalp: bool = not cut.shell_only() and cut.side_length() >= HairCut.SHELL_ONLY_BELOW
	if scalp:
		layers = 1
	var render: int = _head.shell_vertex.size()
	var grain := PackedFloat32Array()
	grain.resize(render)
	for r in render:
		grain[r] = _uniform()
	# Only the triangles where some hair grows.
	var tris := PackedInt32Array()
	for t in _head.shell_index.size() / 3:
		var any: bool = false
		for j in 3:
			any = any or density[_head.shell_vertex[_head.shell_index[t * 3 + j]]] > 0.004
		if any:
			tris.append_array(_head.shell_index.slice(t * 3, t * 3 + 3))
	var asset := HumanAssetData.new()
	asset.kind = &"hair"
	asset.part = 0
	asset.id = StringName("cut_" + cut.key())
	asset.gender = &"any"
	asset.style = &"scalp" if scalp else &"shell"
	asset.albedo = load("res://assets/_universe/characters/human/hair/hair_shell.png")
	asset.scale_pairs = PackedInt32Array([-1, -1, -1, -1, -1, -1])
	asset.scale_ref = PackedFloat32Array([1.0, 1.0, 1.0])
	# The cap first, then the tips, then the layers between: from afar the first ones are enough.
	var order: Array[int] = [0]
	if layers > 1:
		order.append(layers - 1)
	if layers > 2:
		order.append(layers / 2)
	for k in layers:
		if not order.has(k):
			order.append(k)
	for layer in layers:
		var t: float = float(layer) / maxi(layers - 1, 1)
		var lift: float = first + (height - first) * t if layers > 1 else first
		for r in render:
			var v: int = _head.shell_vertex[r]
			var compact: int = _head.scalp_vertex[v]
			asset.refs.append_array([compact, compact, compact])
			asset.weights.append_array([1.0, 0.0, 0.0])
			asset.offsets.append(_head.scalp_normal[v] * lift)
			asset.vertex.append(layer * render + r)
			asset.uv.append(_head.shell_uv[r])
			asset.tangent.append_array(_head.shell_tangent.slice(r * 4, r * 4 + 4))
			asset.bones.append_array([_head.head_bone, 0, 0, 0])
			asset.bone_weights.append_array([1.0, 0.0, 0.0, 0.0])
			asset.color.append(Color(under, grain[r], t, density[v]))
	for layer in order:
		for k in tris.size():
			asset.index.append(tris[k] + layer * render)
	if layers > 3:
		asset.lods.append_array([0.003, 3.0 / layers])
	if layers > 1:
		asset.lods.append_array([0.008, 1.0 / layers])
	return asset
