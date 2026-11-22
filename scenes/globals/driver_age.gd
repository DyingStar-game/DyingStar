class_name DriverAge
extends RefCounted
## Is this machine's graphics driver too old to trust, and where does the player get a newer one?
##
## A GT 710 on NVIDIA 456.71 (October 2020, Vulkan 1.2.142) passed the menu and crashed in game, inside
## the driver, while it compiled a 3D pipeline (vkCreateGraphicsPipelines, null read in nvoglv64.dll).
## Its owner believed the driver up to date: Windows Update and the Device Manager say "the best driver
## is already installed" with a 2020 one. The latest driver (474.x) fixed it.
##
## The driver's age is read from the Vulkan version it reports: the last number grows with each
## release. Godot gives scripts no driver version on Windows when the adapter's Vulkan name differs
## from its registry name — old NVIDIA drivers say "GeForce GT 710", the registry "NVIDIA GeForce
## GT 710" — so OS.get_video_adapter_driver_info() came back empty on that very machine.
##
## Only vendors where EVERY card the game can run on has a newer driver to download are judged:
## a warning the player cannot act on is noise. NVIDIA: every Vulkan card (Kepler and up) gets at least
## the R470 branch (471.11 = Vulkan 1.2.175; Kepler's 474.x security drivers come from it). AMD and
## Intel leave older GPUs on old drivers for good, so they are not judged here.
##
## outdated() is pure — renderer, vendor and version in — so the table is unit-tested without a GPU.

## Per vendor (lower case, matched inside the adapter's vendor name): the oldest Vulkan version a
## current driver reports, and the page that gives the right driver for the player's card.
const _MINIMUM : Dictionary = {
	"nvidia": {"vulkan": "1.2.175", "url": "https://www.nvidia.com/drivers/", "name": "NVIDIA"},
}


## The finding for THIS machine, read from the live renderer: {} when the driver is fine or cannot be
## judged, else {vendor, found, needed, url}.
static func detect() -> Dictionary:
	return outdated(RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_video_adapter_vendor(),
		RenderingServer.get_video_adapter_api_version())


## `driver` is get_current_rendering_driver_name(): on OpenGL or D3D12 the version string is not a
## Vulkan one, so nothing is judged.
static func outdated(driver: String, vendor: String, api_version: String) -> Dictionary:
	if driver != "vulkan":
		return {}
	var low : String = vendor.to_lower()
	for key: String in _MINIMUM:
		if not low.contains(key):
			continue
		var rule : Dictionary = _MINIMUM[key]
		var found : PackedInt32Array = _parse(api_version)
		if found.is_empty() or _compare(found, _parse(rule["vulkan"])) >= 0:
			return {}
		return {"vendor": rule["name"], "found": api_version.strip_edges(), "needed": rule["vulkan"], "url": rule["url"]}
	return {}


## "1.2.142" -> [1, 2, 142]; anything else (empty, "1.2", text) -> [].
static func _parse(version: String) -> PackedInt32Array:
	var parts : PackedStringArray = version.strip_edges().split(".")
	var out := PackedInt32Array()
	if parts.size() < 3:
		return out
	for i in 3:
		if not parts[i].is_valid_int():
			return PackedInt32Array()
		out.append(int(parts[i]))
	return out


## -1, 0 or 1, as a is older, the same or newer than b.
static func _compare(a: PackedInt32Array, b: PackedInt32Array) -> int:
	for i in 3:
		if a[i] != b[i]:
			return -1 if a[i] < b[i] else 1
	return 0
