class_name CaveNativeLifetime
extends RefCounted
## Reuse the game's Windows lifetime guard during explicit offline authoring and editor imports.

static var _prepared: bool = false


static func prepare(offline_authoring: bool) -> bool:
    if _prepared or OS.get_name() != "Windows":
        return true
    if not offline_authoring:
        return false
    var script := NativeScript.load_usable("res://tools/native/NativeLibraryPin.cs", ["Pin"])
    if script == null:
        push_error("StarGrotte : compiler le module de durée de vie natif avant le lancement.")
        return false
    var guard: RefCounted = script.new()
    _prepared = bool(guard.call("Pin", "livekit_ffi.dll"))
    print("STARGROT NATIVE LIFETIME pinned=", _prepared)
    return _prepared
