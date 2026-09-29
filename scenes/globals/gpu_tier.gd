class_name GpuTier
extends RefCounted
## Which graphics preset a machine should start on, guessed from its GPU.
##
## Used ONCE, on the very first launch (no settings file yet), and to fill the "Recommended for"
## line of the Graphics page. A player who already has settings is never moved by it.
##
## classify() is pure — adapter name, device type, renderer and screen in, tier out — so the whole
## table is unit-tested without a GPU. Guessing wrong costs one menu visit; guessing HIGH on a weak
## card costs a first impression, so every unknown lands on MEDIUM and every doubt rounds down.

const LOW : String = "low"
const MEDIUM : String = "medium"
const HIGH : String = "high"
const ULTRA : String = "ultra"
## Cheapest first: a tier's index is how far it is from LOW, which is what _down() walks.
const ORDER : Array[String] = [LOW, MEDIUM, HIGH, ULTRA]

## The integrated Radeons that genuinely play 3D at 1080p. Every other integrated GPU is LOW.
const _STRONG_IGPU : String = "radeon\\s*(760m|780m|880m|890m)"
const _SOFTWARE : String = "llvmpipe|swiftshader|basic render"
## A laptop chip is a desktop name with a fraction of the power budget: one tier down.
const _LAPTOP : String = "laptop|max-q|mobile|rx\\s*\\d{4}m\\b"
## 3840 x 2160: from there the pixel count, not the settings, is what the GPU pays for.
const _UHD_PIXELS : int = 3840 * 2160


## The tier for THIS machine, read from the live renderer.
static func detect() -> String:
	var screen : Vector2i = DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	return classify(RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_type(),
		RenderingServer.get_current_rendering_method(), screen)


## `device_type` is a RenderingDevice.DeviceType; `method` is get_current_rendering_method().
static func classify(adapter: String, device_type: int, method: String, screen: Vector2i) -> String:
	var name : String = adapter.to_lower()
	var tier : String = _base(name, device_type, method)
	if _has(_LAPTOP, name):
		tier = _down(tier)
	if screen.x * screen.y >= _UHD_PIXELS:
		tier = _down(tier)
	return tier


static func _base(name: String, device_type: int, method: String) -> String:
	# Mobile / Compatibility are the fallbacks of a machine that could not start Forward+.
	if method != "forward_plus":
		return LOW
	if device_type in [RenderingDevice.DEVICE_TYPE_CPU, RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU] \
			or _has(_SOFTWARE, name):
		return LOW
	if device_type == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU:
		return MEDIUM if _has(_STRONG_IGPU, name) else LOW
	var nvidia : String = _nvidia(name)
	if nvidia != "":
		return nvidia
	var amd : String = _amd(name)
	if amd != "":
		return amd
	var intel : String = _intel(name)
	if intel != "":
		return intel
	return MEDIUM


## "" when the name is not an NVIDIA GeForce we can place.
static func _nvidia(name: String) -> String:
	var rtx : RegExMatch = _match("rtx\\s*(\\d{2})(\\d{2})", name)
	if rtx != null:
		var gen : int = int(rtx.get_string(1))
		var model : int = int(rtx.get_string(2))
		if gen >= 30:
			return ULTRA if model >= 70 else (HIGH if model == 60 else MEDIUM)
		return HIGH if model >= 70 else MEDIUM
	if _has("gtx\\s*16|gtx\\s*10[78]0", name):
		return MEDIUM
	if _has("gtx", name):
		return LOW
	return ""


## "" when the name is not a Radeon RX we can place. The four digits are series + class: 6800 is
## series 6, class 8. RDNA 4 renumbered (9070 / 9060), so its class is the last two digits there.
static func _amd(name: String) -> String:
	var rx : RegExMatch = _match("rx\\s*(\\d)(\\d)(\\d)\\d", name)
	if rx != null:
		var series : int = int(rx.get_string(1))
		var klass : int = int(rx.get_string(2))
		match series:
			9:
				return ULTRA if int(rx.get_string(3)) >= 7 else HIGH
			7:
				return ULTRA if klass >= 8 else HIGH
			6:
				return [LOW, LOW, LOW, LOW, LOW, LOW, MEDIUM, HIGH, ULTRA, ULTRA][klass]
			5:
				return MEDIUM if klass >= 6 else LOW
		return LOW
	# Polaris (RX 480 / 580) and Vega: three digits or a name, all well below the game's needs.
	if _has("rx\\s*\\d{3}\\b|vega", name):
		return LOW
	return ""


## "" when the name is not an Intel Arc. Integrated Intel never gets here (device type above).
static func _intel(name: String) -> String:
	if not _has("arc", name):
		return ""
	return MEDIUM if _has("\\b(a7\\d\\d|b5\\d\\d)\\b", name) else LOW


static func _down(tier: String) -> String:
	return ORDER[maxi(0, ORDER.find(tier) - 1)]


static func _has(pattern: String, text: String) -> bool:
	return _match(pattern, text) != null


static func _match(pattern: String, text: String) -> RegExMatch:
	var re := RegEx.new()
	re.compile(pattern)
	return re.search(text)
