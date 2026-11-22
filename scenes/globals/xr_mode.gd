class_name XRMode
extends RefCounted
## Is the game running in VR? Asked by any script, autoloads included (it names no gameplay class).
##
## VR is OpenXR only, never a given headset: the game talks to whatever OpenXR runtime is active (SteamVR,
## Meta Quest Link, Virtual Desktop, Monado / WiVRn...). It is turned on by Godot's own launch argument
## `--xr-mode on` and nothing else: OpenXR must start with the engine (it adds Vulkan extensions), and
## the project leaves `xr/openxr/enabled` off so a flat-screen player never wakes a VR runtime. Godot
## initialises the interface before the first autoload, so by then is_active() is final. When
## `--xr-mode on` finds no runtime, Godot itself warns the user (xr/openxr/startup_alert) and plays on the
## flat screen. Scripts cannot see that the argument was given: Godot takes it out of
## OS.get_cmdline_args().

## Godot's name for its OpenXR interface (XRServer.find_interface).
const INTERFACE_NAME := "OpenXR"
## Far plane (m) of every headset camera, whatever the flat camera's (1e13). In stereo Godot 4.7 builds each
## eye's projection in float and, from them, the sky's directions (it unprojects every pixel AT the far
## plane) and the culling frustum combined from both eyes (CameraData.set_multiview_camera): with far/near
## at 2e14, or even 2e12, the sky came out black and the culling failed now and then ("p_far <= p_near").
## Measured on the menu stage's planet (2026-11-22): 1e7 still failed, 5e5 drew the sky and failed never.
## The price: nothing past 500 km is drawn in VR (other bodies of the system); the star and the stars are
## the sky's own and stay.
const FAR_M := 5.0e5
## Physics steps one frame may run to catch up (the engine's default is 8). A headset frame that came late
## must not be followed by an even later one: past this the game's clock slows down instead.
const MAX_PHYSICS_STEPS := 2
## Device id of the gamepad the VR controllers play as (VrInput): a number no real pad gets. In VR it holds
## the HUD's button names from the start (InputDevice.hold_pad): the controllers are all the player has.
const PAD_DEVICE := 15


## The OpenXR interface, initialised or not; null in a build without the OpenXR module.
static func interface() -> XRInterface:
	return XRServer.find_interface(INTERFACE_NAME)


## True when the game renders to a headset: launched with `--xr-mode on` and a runtime answered.
static func is_active() -> bool:
	var xr := interface()
	return xr != null and xr.is_initialized()


## In VR the runtime paces the frames (it waits for the headset's display): the desktop window's v-sync
## or the menu's frame cap would hold the headset under its refresh rate. Called after the player's own
## choices are applied (SettingsManager), which stay saved for the flat screen. Nothing without VR.
static func pace_by_runtime() -> void:
	if not is_active():
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
