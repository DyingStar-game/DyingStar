class_name ClipboardImage
extends RefCounted
## Puts a PNG file on the system clipboard as an IMAGE, so it pastes straight into Discord, Paint or
## a bug report.
##
## Godot only puts text on the clipboard (DisplayServer.clipboard_get_image exists, a setter does
## not), so each OS is handed to its own tool. Every one runs as a DETACHED process: it takes a
## moment to start, and the game must not wait for it. Returns false when no tool is available —
## the file is saved either way, only the copy is missing.


static func copy_png(path: String) -> bool:
	match OS.get_name():
		"Windows":
			return _windows(path)
		"macOS":
			return _spawn("osascript", ["-e",
				"set the clipboard to (read (POSIX file \"%s\") as «class PNGf»)" % path.replace("\"", "\\\"")])
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			return _unix(path)
	return false


## PowerShell ships with every Windows. -STA because the clipboard is a COM object; SetImage copies
## the bitmap into the clipboard, so it outlives the process that put it there.
static func _windows(path: String) -> bool:
	var quoted: String = "'%s'" % path.replace("/", "\\").replace("'", "''")
	var script: String = (
		"Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
		+ " $i = [System.Drawing.Image]::FromFile(%s);" % quoted
		+ " [System.Windows.Forms.Clipboard]::SetImage($i); $i.Dispose()"
	)
	return _spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-STA", "-WindowStyle", "Hidden",
		"-Command", script])


## Wayland first, then X11. Neither is installed everywhere, hence the probe.
static func _unix(path: String) -> bool:
	var quoted: String = "'%s'" % path.replace("'", "'\\''")
	if _has_command("wl-copy"):
		return _spawn("sh", ["-c", "wl-copy --type image/png < %s" % quoted])
	if _has_command("xclip"):
		return _spawn("sh", ["-c", "xclip -selection clipboard -t image/png -i %s" % quoted])
	return false


static func _has_command(cmd: String) -> bool:
	return OS.execute("sh", ["-c", "command -v %s" % cmd]) == 0


static func _spawn(program: String, args: PackedStringArray) -> bool:
	return OS.create_process(program, args, false) > 0
