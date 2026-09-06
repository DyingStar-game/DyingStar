#!/usr/bin/env python3
"""Fail the build when an Area3D monitors the world without saying so.

An Area3D with `monitoring` on runs a broadphase query on EVERY physics step,
whether or not anything moved. Left at the engine defaults it also keeps
`collision_mask = 1`, the `world` layer -- planet terrain, ~4800 collision
shapes. Measured on this game (2026-09-06): 150 such areas cost ~930 ms per
wall second, i.e. 2.2 FPS with physics starved to 17/60 Hz. A controlled probe
isolated the shape of the cost -- 17 areas cost 0.31 ms/tick at the world
origin, 2.93 ms/tick at 8e10 m with a narrow mask, and 10.78 ms/tick with the
default `world` mask. Distance multiplies an area query by ~10x; a `world` mask
by ~3.7x more. Bodies alone cost nothing at distance (0.034 ms/tick either way).

The bug is silent: a new prop scene authored without `monitoring = false` shows
no symptom at all until the framerate collapses. Six scenes had it; their
sibling scenes did not. That is an omission bug, which is exactly what a linter
catches and a human review does not.

A node passes when ANY of these holds:
  (a) its own property block writes `monitoring = false`;
  (b) its `script` resolves to a .gd that assigns `monitoring = false` anywhere
      in the file (file-scoped on purpose -- mining_zone.gd sets it from
      enable_server_detection(), not from _ready);
  (c) its node header carries the group `active_monitor`, the deliberate opt-in
      for an area that really must detect.

Usage:
    python3 tools/check_area_monitoring.py                 # whole repo
    python3 tools/check_area_monitoring.py scenes/ levels/ # some paths
    python3 tools/check_area_monitoring.py --strict        # warnings are errors
    python3 tools/check_area_monitoring.py --json          # machine-readable

Exit code is 1 when at least one error is found, 2 when the check cannot run
(unreadable file). Warnings never block unless --strict.

Dependencies: none -- Python 3 standard library only, so CI needs no pip step.

KNOWN LIMITATIONS, stated rather than papered over:
  * Type resolution follows `instance=` chains to a scene's root node, but a
    script that extends a `class_name` which itself extends Area3D is not
    recognised. No such node exists today.
  * Rule (b) is file-scoped: a script that disables monitoring on some OTHER
    node still satisfies the rule for its own. The alternative is a GDScript
    interpreter.
  * A `collision_mask` assigned from a PARENT's script is invisible here
    (player.gd sets $AreaDetector.collision_mask). This is why the mask rule
    warns instead of failing.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Vendored engine code and build output are not ours to lint.
EXCLUDED_DIRS = {".git", ".godot", ".venv", "addons", "build", "assets_blender"}

# The deliberate opt-in. A group, not an allowlist file, because globals.gd
# already legislates it ("Variants of one layer are told apart by GROUP
# (is_in_group), never by a dedicated layer"), because it survives renames and
# reparenting where a path-keyed list does not, and because it is queryable at
# RUNTIME -- client_perf.gd's area census uses the same predicate, which is how
# code-created areas (invisible here) still get covered.
MONITOR_GROUP = "active_monitor"

# Writing down WHY an area needs its mask is the only way to silence the mask
# warnings. That asymmetry is deliberate: the escape hatch produces documentation.
REASON_KEY = "metadata/monitor_reason"

# Godot layer 1 = `world` (project.godot [layer_names]): planet terrain and every
# static hull. An area scanning it is handed thousands of candidates per step.
WORLD_BIT = 1

# Areas that override space gravity must detect bodies to apply it to them, so
# they legitimately carry a wide mask.
GRAVITY_GROUP = "gravity"


# --------------------------------------------------------------------------
# .tscn parsing
# --------------------------------------------------------------------------

class Section:
    """One `[kind ...]` block of a .tscn plus the properties that follow it."""

    def __init__(self, kind: str, attrs: dict, line: int) -> None:
        self.kind = kind
        self.attrs = attrs
        self.line = line
        self.props: dict[str, str] = {}


def _tokenize_attrs(text: str) -> dict:
    """Split `key=value key=value` from a section header.

    Written as a scanner rather than one regex per attribute because two values
    break naive patterns, and both bit me before this file existed:
      * `groups=["a","b"]` CONTAINS a `]`, so `[^\\]]*\\]` stops at the wrong one;
      * `uid="uid://x"` contains the substring `id="`, so a loose `id="([^"]+)"`
        captures the uid and every script resolves to nothing -- a SILENT
        false-negative generator, which is worse than a crash.
    """
    attrs: dict = {}
    i, n = 0, len(text)
    while i < n:
        while i < n and text[i].isspace():
            i += 1
        start = i
        while i < n and (text[i].isalnum() or text[i] in "_-/."):
            i += 1
        key = text[start:i]
        if not key or i >= n or text[i] != "=":
            # A bare token (the section kind, or something unparsed): skip it.
            while i < n and not text[i].isspace():
                i += 1
            continue
        i += 1  # consume '='
        value, i = _read_value(text, i)
        attrs[key] = value
    return attrs


def _read_value(text: str, i: int) -> tuple[str, int]:
    """Read one attribute value starting at `i`; return it and the new index."""
    n = len(text)
    if i >= n:
        return "", i
    ch = text[i]
    if ch == '"':
        i += 1
        start = i
        while i < n and text[i] != '"':
            if text[i] == "\\":
                i += 1
            i += 1
        return text[start:i], min(i + 1, n)
    if ch == "[":
        depth, start = 0, i
        while i < n:
            if text[i] == "[":
                depth += 1
            elif text[i] == "]":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
        return text[start:i], i
    # Bare token, possibly a call like ExtResource("x") -- read through parens.
    start, depth = i, 0
    while i < n:
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
        elif depth == 0 and text[i].isspace():
            break
        i += 1
    return text[start:i], i


def parse_scene(text: str) -> list[Section]:
    """Split a .tscn into sections.

    A section's properties run until the NEXT line starting with `[`, not until
    a blank line: Godot separates blocks with blank lines but a property list may
    contain them too.
    """
    sections: list[Section] = []
    current: Section | None = None
    for lineno, line in enumerate(text.splitlines(), start=1):
        if line.startswith("["):
            body = line[1:]
            if body.endswith("]"):
                body = body[:-1]
            kind = body.split(" ", 1)[0].strip()
            current = Section(kind, _tokenize_attrs(body), lineno)
            sections.append(current)
            continue
        if current is None or "=" not in line:
            continue
        key, _, value = line.partition("=")
        current.props[key.strip()] = value.strip()
    return sections


def _groups_of(section: Section) -> set[str]:
    raw = section.attrs.get("groups", "")
    return set(re.findall(r'"([^"]*)"', raw))


def _int_prop(section: Section, key: str) -> int | None:
    raw = section.props.get(key)
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Resolution across files
# --------------------------------------------------------------------------

class Resolver:
    """Resolves res:// paths, scene root types and script contents, memoized."""

    def __init__(self) -> None:
        self._scenes: dict[Path, list[Section]] = {}
        self._root_type: dict[Path, str] = {}
        self._script_disables: dict[Path, bool] = {}
        self.errors: list[str] = []

    def path_of(self, res_path: str) -> Path | None:
        if not res_path.startswith("res://"):
            return None
        return REPO_ROOT / res_path[len("res://"):]

    def sections(self, path: Path) -> list[Section]:
        if path not in self._scenes:
            try:
                self._scenes[path] = parse_scene(path.read_text(encoding="utf-8"))
            except UnicodeDecodeError:
                # An `instance=` can point at an imported .glb/.scn, which is binary.
                # Nothing to read, and nothing to report: the node is defined there,
                # not here, and a mesh import has no Area3D.
                self._scenes[path] = []
            except OSError as exc:
                self.errors.append(f"cannot read {path}: {exc}")
                self._scenes[path] = []
        return self._scenes[path]

    def ext_resources(self, sections: list[Section]) -> dict[str, str]:
        return {
            s.attrs["id"]: s.attrs.get("path", "")
            for s in sections
            if s.kind == "ext_resource" and "id" in s.attrs
        }

    def root_type(self, path: Path, seen: frozenset = frozenset()) -> str:
        """Type of a scene's root node, following instance= chains."""
        if path in self._root_type:
            return self._root_type[path]
        if path in seen:  # a scene cannot instance itself, but never loop
            return ""
        sections = self.sections(path)
        ext = self.ext_resources(sections)
        result = ""
        for s in sections:
            if s.kind != "node" or "parent" in s.attrs:
                continue
            result = self.node_type(s, ext, seen | {path})
            break
        self._root_type[path] = result
        return result

    def node_type(self, section: Section, ext: dict[str, str], seen: frozenset) -> str:
        if "type" in section.attrs:
            return section.attrs["type"]
        inst = section.attrs.get("instance", "")
        m = re.match(r'ExtResource\("([^"]+)"\)', inst)
        if not m:
            return ""
        target = self.path_of(ext.get(m.group(1), ""))
        if target is None or target.suffix != ".tscn" or not target.exists():
            return ""  # imported binary scene, or a path we cannot follow
        return self.root_type(target, seen)

    def script_disables_monitoring(self, path: Path) -> bool:
        """True when a .gd assigns `monitoring = false` anywhere in the file."""
        if path not in self._script_disables:
            try:
                text = path.read_text(encoding="utf-8")
            except OSError:
                self._script_disables[path] = False
                return False
            self._script_disables[path] = bool(
                re.search(r"(?:^|[^\w])monitoring\s*=\s*false", text)
            )
        return self._script_disables[path]


# --------------------------------------------------------------------------
# Rules
# --------------------------------------------------------------------------

ERROR = "ERROR"
WARN = "WARN"


class Finding:
    def __init__(self, level: str, path: Path, line: int, node: str, summary: str, detail: str) -> None:
        self.level = level
        self.path = path
        self.line = line
        self.node = node
        self.summary = summary
        self.detail = detail

    def as_dict(self) -> dict:
        return {
            "level": self.level,
            "file": str(self.path.relative_to(REPO_ROOT)),
            "line": self.line,
            "node": self.node,
            "summary": self.summary,
        }


REMEDY = """    Fix ONE of:
      * passive zone (detected, never detects) -- add to the node block:
            monitoring = false
      * this area really must detect -- add to the node header:
            groups=["%s"]
        and set collision_mask explicitly to the narrowest layer set.""" % MONITOR_GROUP

WHY = """    An Area3D with monitoring on runs a broadphase query every physics step,
    even when nothing moves. With the default collision_mask = 1 it scans the
    `world` layer (planet terrain, ~4800 shapes) -- measured at ~6 ms/tick per
    area far from the world origin."""


def check_scene(path: Path, resolver: Resolver) -> tuple[list[Finding], int]:
    sections = resolver.sections(path)
    ext = resolver.ext_resources(sections)
    findings: list[Finding] = []
    checked = 0

    for section in sections:
        if section.kind != "node":
            continue
        name = section.attrs.get("name", "?")
        groups = _groups_of(section)
        monitoring = section.props.get("monitoring")
        marked = MONITOR_GROUP in groups

        node_type = resolver.node_type(section, ext, frozenset({path}))
        # An instanced node inherits everything from the scene that DEFINES it,
        # including its groups, and that scene is checked on its own. Reporting
        # here too would demand the marker in every instancing scene and would
        # double-count physics_grid.tscn (instanced by pads.tscn and
        # test_spaceship.tscn). Only an explicit re-enable below concerns us.
        is_area = node_type == "Area3D" and "instance" not in section.attrs

        # An override block in an outer scene has no type and no instance. We
        # cannot know what it overrides, but re-enabling monitoring there is
        # always a declaration that needs the marker.
        if not is_area:
            if monitoring == "true" and not marked:
                findings.append(Finding(
                    ERROR, path, section.line, name,
                    "monitoring is switched back on without the %s marker" % MONITOR_GROUP,
                    WHY + "\n" + REMEDY,
                ))
            continue

        checked += 1

        if monitoring == "false":
            continue

        script_ok = False
        m = re.match(r'ExtResource\("([^"]+)"\)', section.props.get("script", ""))
        if m:
            script_path = resolver.path_of(ext.get(m.group(1), ""))
            if script_path is not None and script_path.exists():
                script_ok = resolver.script_disables_monitoring(script_path)

        if script_ok:
            continue

        if not marked:
            findings.append(Finding(
                ERROR, path, section.line, name,
                'Area3D "%s" monitors every physics step.' % name,
                WHY + "\n" + REMEDY,
            ))
            continue

        # Marked as a deliberate monitor: check that its mask is deliberate too.
        if REASON_KEY in section.props:
            continue
        gravity = GRAVITY_GROUP in groups or _int_prop(section, "gravity_space_override") not in (None, 0)
        mask = _int_prop(section, "collision_mask")
        if mask is None:
            findings.append(Finding(
                WARN, path, section.line, name,
                "declared monitor with no explicit collision_mask (inherits 1 = `world`)",
                "    Set collision_mask to the narrowest layer set it really needs, or\n"
                '    document the choice with %s = "..."' % REASON_KEY,
            ))
        elif mask & WORLD_BIT and not gravity:
            findings.append(Finding(
                WARN, path, section.line, name,
                "declared monitor scans the `world` layer (collision_mask = %d)" % mask,
                "    The `world` layer holds the planet terrain (~4800 shapes); scanning it\n"
                "    costs ~3.7x a narrow mask. Narrow it, or document why with\n"
                '    %s = "..."' % REASON_KEY,
            ))

    return findings, checked


def check_scripts(paths: list[Path], resolver: Resolver) -> list[Finding]:
    """Every .gd that creates an Area3D must say what monitoring should be.

    File-scoped on purpose. Scoping this to the enclosing function needs a real
    GDScript block parser, and a false positive from a heuristic one would block
    a PR on an argument nobody can win -- a bad trade for five call sites.
    """
    findings: list[Finding] = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            resolver.errors.append(f"cannot read {path}: {exc}")
            continue
        if "Area3D.new()" not in text:
            continue
        if re.search(r"(?:^|[^\w])monitoring\s*=", text):
            continue
        line = next(
            (i for i, l in enumerate(text.splitlines(), start=1) if "Area3D.new()" in l), 1
        )
        findings.append(Finding(
            WARN, path, line, "Area3D.new()",
            "creates an Area3D but never assigns `monitoring`",
            "    The engine default is true, so this area queries the broadphase every\n"
            "    physics step. Say which you mean:\n"
            "      monitoring = false   # passive: detected, never detects\n"
            "      monitoring = true    # deliberate, and add_to_group(\"%s\")" % MONITOR_GROUP,
        ))
    return findings


# --------------------------------------------------------------------------
# Driving
# --------------------------------------------------------------------------

def _iter_files(roots: list[Path], suffix: str) -> list[Path]:
    out: list[Path] = []
    for root in roots:
        if root.is_file():
            if root.suffix == suffix:
                out.append(root)
            continue
        for path in sorted(root.rglob("*" + suffix)):
            if EXCLUDED_DIRS & set(path.relative_to(REPO_ROOT).parts):
                continue
            out.append(path)
    return out


def _report(findings: list[Finding], checked: int, strict: bool) -> None:
    for f in findings:
        rel = f.path.relative_to(REPO_ROOT)
        level = ERROR if (strict and f.level == WARN) else f.level
        print(f"{rel}:{f.line}")
        print(f"  {level}  {f.summary}")
        print(f.detail)
        print()
    errors = sum(1 for f in findings if f.level == ERROR or strict)
    warns = len(findings) - errors
    print(f"{checked} Area3D checked, {errors} error(s), {warns} warning(s)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("paths", nargs="*", type=Path, help="files or directories (default: whole repo)")
    parser.add_argument("--strict", action="store_true", help="treat warnings as errors")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    roots = [p.resolve() for p in args.paths] if args.paths else [REPO_ROOT]
    resolver = Resolver()

    findings: list[Finding] = []
    checked = 0
    for scene in _iter_files(roots, ".tscn"):
        scene_findings, scene_checked = check_scene(scene, resolver)
        findings.extend(scene_findings)
        checked += scene_checked
    findings.extend(check_scripts(_iter_files(roots, ".gd"), resolver))

    if resolver.errors:
        for message in resolver.errors:
            print(f"cannot run: {message}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps([f.as_dict() for f in findings], indent=2))
    else:
        _report(findings, checked, args.strict)

    blocking = [f for f in findings if f.level == ERROR or args.strict]
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
