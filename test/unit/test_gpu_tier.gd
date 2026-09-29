extends GutTest
## GpuTier: the first-launch preset guessed from the GPU. A wrong guess upwards is the costly one,
## so the cases below pin the rounding-down rules as much as the happy path.

const DISCRETE : int = RenderingDevice.DEVICE_TYPE_DISCRETE_GPU
const INTEGRATED : int = RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU
const FHD : Vector2i = Vector2i(1920, 1080)
const UHD : Vector2i = Vector2i(3840, 2160)

## adapter, device type, renderer, screen -> expected tier.
const CASES : Array = [
	["NVIDIA GeForce RTX 3080", DISCRETE, "forward_plus", FHD, GpuTier.ULTRA],
	["NVIDIA GeForce RTX 4090", DISCRETE, "forward_plus", FHD, GpuTier.ULTRA],
	["NVIDIA GeForce RTX 3060", DISCRETE, "forward_plus", FHD, GpuTier.HIGH],
	["NVIDIA GeForce RTX 4050", DISCRETE, "forward_plus", FHD, GpuTier.MEDIUM],
	["NVIDIA GeForce RTX 2080 SUPER", DISCRETE, "forward_plus", FHD, GpuTier.HIGH],
	["NVIDIA GeForce RTX 2060", DISCRETE, "forward_plus", FHD, GpuTier.MEDIUM],
	["NVIDIA GeForce GTX 1660 Ti", DISCRETE, "forward_plus", FHD, GpuTier.MEDIUM],
	["NVIDIA GeForce GTX 1080", DISCRETE, "forward_plus", FHD, GpuTier.MEDIUM],
	["NVIDIA GeForce GTX 1050 Ti", DISCRETE, "forward_plus", FHD, GpuTier.LOW],
	["NVIDIA GeForce RTX 4060 Laptop GPU", DISCRETE, "forward_plus", FHD, GpuTier.MEDIUM],
	["AMD Radeon RX 5700 XT", DISCRETE, "forward_plus", FHD, GpuTier.MEDIUM],
	["AMD Radeon RX 5500 XT", DISCRETE, "forward_plus", FHD, GpuTier.LOW],
	["AMD Radeon RX 6600", DISCRETE, "forward_plus", FHD, GpuTier.MEDIUM],
	["AMD Radeon RX 6700 XT", DISCRETE, "forward_plus", FHD, GpuTier.HIGH],
	["AMD Radeon RX 6800M", DISCRETE, "forward_plus", FHD, GpuTier.HIGH],
	["AMD Radeon RX 7900 XTX", DISCRETE, "forward_plus", FHD, GpuTier.ULTRA],
	["AMD Radeon RX 7600", DISCRETE, "forward_plus", FHD, GpuTier.HIGH],
	["AMD Radeon RX 9070 XT", DISCRETE, "forward_plus", FHD, GpuTier.ULTRA],
	["AMD Radeon RX 9060 XT", DISCRETE, "forward_plus", FHD, GpuTier.HIGH],
	["Radeon RX 580 Series", DISCRETE, "forward_plus", FHD, GpuTier.LOW],
	["Intel(R) Arc(TM) A770 Graphics", DISCRETE, "forward_plus", FHD, GpuTier.MEDIUM],
	["Intel(R) Arc(TM) A380 Graphics", DISCRETE, "forward_plus", FHD, GpuTier.LOW],
	["Intel(R) UHD Graphics 630", INTEGRATED, "forward_plus", FHD, GpuTier.LOW],
	["AMD Radeon 780M Graphics", INTEGRATED, "forward_plus", FHD, GpuTier.MEDIUM],
	["llvmpipe (LLVM 15.0.7, 256 bits)", RenderingDevice.DEVICE_TYPE_CPU, "forward_plus", FHD, GpuTier.LOW],
	["Mystery GPU 9000", DISCRETE, "forward_plus", FHD, GpuTier.MEDIUM],
	["NVIDIA GeForce RTX 3080", DISCRETE, "gl_compatibility", FHD, GpuTier.LOW],
	["NVIDIA GeForce RTX 3080", DISCRETE, "mobile", FHD, GpuTier.LOW],
	["NVIDIA GeForce RTX 3060", DISCRETE, "forward_plus", UHD, GpuTier.MEDIUM],
	["NVIDIA GeForce RTX 3080", DISCRETE, "forward_plus", UHD, GpuTier.HIGH],
]


func test_every_case_lands_on_its_tier() -> void:
	for c in CASES:
		assert_eq(GpuTier.classify(c[0], c[1], c[2], c[3]), c[4], "%s on %s at %s" % [c[0], c[2], c[3]])


func test_rounding_down_never_goes_below_low() -> void:
	assert_eq(GpuTier.classify("NVIDIA GeForce GTX 1050 Laptop", DISCRETE, "forward_plus", UHD), GpuTier.LOW,
		"laptop + 4K on an already-low card stays low")


func test_every_answer_is_a_known_tier() -> void:
	for c in CASES:
		assert_has(GpuTier.ORDER, GpuTier.classify(c[0], c[1], c[2], c[3]), c[0])
