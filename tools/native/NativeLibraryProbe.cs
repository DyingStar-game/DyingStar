using System;
using System.Runtime.InteropServices;
using Godot;

/// <summary>
/// Tells whether the system's loader finds a native library, before a library that needs it does.
///
/// LiveKit's liblivekit_ffi.so loads libva.so.2 and libva-drm.so.2 (VA-API video encoding) only when it
/// joins a room, through implib-gen stubs that abort the whole process when one is missing: the client
/// closed as the player entered the game on NixOS through appimage-run (2026-10-25). Asking first lets
/// the game go on without voice instead.
/// </summary>
public partial class NativeLibraryProbe : RefCounted
{
    /// <summary>
    /// True when <paramref name="libraryName"/> (a file name such as "libva.so.2", looked up as dlopen
    /// does) loads; the library is released at once.
    /// </summary>
    public bool CanLoad(string libraryName)
    {
        if (!NativeLibrary.TryLoad(libraryName, out IntPtr handle))
        {
            return false;
        }
        NativeLibrary.Free(handle);
        return true;
    }
}
