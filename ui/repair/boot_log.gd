class_name BootLog
extends RefCounted

## What a repaired machine's screen scrolls while it restarts (MachineBreakdown.RESTART_S): code, green
## on black, a line every LINE_S, the last ROWS of them on screen. The code is real -- the regulators'
## own arithmetic (GaugePuzzle), as the machine's firmware would run it -- and only decoration: nothing
## reads it, and it need not follow GaugePuzzle's changes.
##
## Pure: what is on screen depends on the time elapsed alone, so every player around reads the same.

## The code's ink, and its ground.
const INK := Color(0.25, 1.0, 0.45)
const BACKGROUND := Color(0.0, 0.02, 0.0)
## A new line this often (s).
const LINE_S := 0.1
## Lines on screen at once.
const ROWS := 14

const SOURCE := """# ares-machinery/regulator.gd -- restart sequence
const COUNT := 3
const COUPLING := 0.35
const TOLERANCE := 0.04
const MARGIN := 0.1

static func values(sliders: Array) -> Array:
    var out: Array = []
    for i: int in COUNT:
        var own := clampf(float(sliders[i]), 0.0, 1.0)
        var next := clampf(float(sliders[(i + 1) % COUNT]), 0.0, 1.0)
        out.append((own + COUPLING * next) / (1.0 + COUPLING))
    return out

static func aligned(read: Array, targets: Array) -> bool:
    if read.size() != COUNT or targets.size() != COUNT:
        return false
    for i: int in COUNT:
        if absf(float(read[i]) - float(targets[i])) > TOLERANCE:
            return false
    return true

static func make(puzzle_seed: int) -> Dictionary:
    var rng := RandomNumberGenerator.new()
    rng.seed = puzzle_seed
    var targets: Array = values(_draw(rng))
    var start: Array = _draw(rng)
    while aligned(values(start), targets):
        start = start.map(func(s: float) -> float: return 0.0 if s >= 0.5 else 1.0)
    return {"targets": targets, "start": start}

static func _draw(rng: RandomNumberGenerator) -> Array:
    var out: Array = []
    for i: int in COUNT:
        out.append(rng.randf_range(MARGIN, 1.0 - MARGIN))
    return out

func restart(machine: Node3D) -> void:
    var read: Array = values(machine.regulators())
    if not aligned(read, machine.targets()):
        push_error("pressure out of line: restart refused")
        return
    for valve: Node in machine.valves():
        valve.open(read[valve.index])
        await valve.settled
    machine.screen.clear()
    machine.start()
"""

static var _lines: PackedStringArray = PackedStringArray()


## How many lines have scrolled by after [param elapsed] s.
static func lines_at(elapsed: float) -> int:
	return maxi(int(elapsed / LINE_S), 0)


## What is on screen once [param count] lines have scrolled by: the last [param rows] of them, the code
## starting over when it ends.
static func text(count: int, rows: int = ROWS) -> String:
	if _lines.is_empty():
		_lines = SOURCE.split("\n")
	var shown := PackedStringArray()
	for i: int in range(maxi(count - rows, 0), maxi(count, 0)):
		shown.append(_lines[i % _lines.size()])
	return "\n".join(shown)


## A fixed-width face for the code: the system's, whichever it has.
static func font() -> Font:
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "DejaVu Sans Mono", "Menlo", "Courier New", "monospace"])
	return mono
