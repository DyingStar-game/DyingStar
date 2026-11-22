extends GutTest
## DriverAge: the "your graphics driver is too old" warning of the main menu.

## renderer, vendor, Vulkan version -> warned?
const CASES : Array = [
	# The GT 710 that crashed in game: NVIDIA 456.71.
	["vulkan", "NVIDIA", "1.2.142", true],
	["vulkan", "NVIDIA Corporation", "1.2.142", true],
	["vulkan", "NVIDIA", "1.1.126", true],
	# 471.11 and the Kepler security drivers built on it.
	["vulkan", "NVIDIA", "1.2.175", false],
	["vulkan", "NVIDIA", "1.2.186", false],
	["vulkan", "NVIDIA", "1.3.289", false],
	["vulkan", "NVIDIA", "1.4.312", false],
	# Vendors left on old drivers for good: never judged.
	["vulkan", "AMD", "1.1.0", false],
	["vulkan", "Intel", "1.0.31", false],
	# Not Vulkan: the version is an OpenGL / D3D12 one.
	["opengl3", "NVIDIA", "3.3.0 NVIDIA 456.71", false],
	["d3d12", "NVIDIA", "12_0", false],
	# Nothing readable: no warning rather than a wrong one.
	["vulkan", "NVIDIA", "", false],
	["vulkan", "NVIDIA", "1.2", false],
	["vulkan", "NVIDIA", "unknown", false],
]


func test_cases() -> void:
	for c: Array in CASES:
		var found : Dictionary = DriverAge.outdated(c[0], c[1], c[2])
		assert_eq(not found.is_empty(), c[3], "%s / %s / %s" % [c[0], c[1], c[2]])


func test_finding_names_the_versions_and_the_download_page() -> void:
	var found : Dictionary = DriverAge.outdated("vulkan", "NVIDIA", " 1.2.142 ")
	assert_eq(found.get("vendor"), "NVIDIA")
	assert_eq(found.get("found"), "1.2.142")
	assert_eq(found.get("needed"), "1.2.175")
	assert_true(String(found.get("url", "")).begins_with("https://"))
