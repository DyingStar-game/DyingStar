using System;
using System.Runtime.InteropServices;
using Godot;

/// <summary>
/// Keeps a native library loaded until the process dies, whatever unloads it before.
///
/// LiveKit's livekit_ffi.dll runs a Rust runtime (tokio, WebRTC) whose threads start with the extension
/// and are never stopped: leaving the room, and even livekit::shutdown(), leaves them parked. At exit
/// Godot unloads the extension and its libraries under them, and the first one to wake jumps into code
/// that is no longer mapped — an execute access violation in the unloaded livekit_ffi.dll (Windows
/// client crash dumps 2026-10-22 and 2026-10-25, on almost every quit). A pinned library stays mapped:
/// those threads run until ExitProcess ends them.
///
/// Windows only: elsewhere Pin answers false and does nothing.
/// </summary>
[Tool]
public partial class NativeLibraryPin : RefCounted
{
    private const uint GetModuleHandleExFlagPin = 0x1;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetModuleHandleExW(uint flags, string moduleName, out IntPtr module);

    /// <summary>
    /// Pin the already loaded library <paramref name="moduleName"/> (a file name such as
    /// "livekit_ffi.dll"). True once pinned; false off Windows, or when no such library is loaded.
    /// </summary>
    public bool Pin(string moduleName)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }
        return GetModuleHandleExW(GetModuleHandleExFlagPin, moduleName, out _);
    }
}
