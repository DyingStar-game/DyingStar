#!/usr/bin/env python3
"""
Unit tests for tools/check_area_monitoring.py — the .tscn parser and the rules.

Pure stdlib, no Godot, so this runs anywhere and in CI next to the check itself:

    python3 test/unit/test_area_monitoring_py.py

Most of these are parser tests rather than rule tests, and that is deliberate:
the rules are three lines each, while the .tscn header format has two traps that
have already cost real time. Both are frozen here so they cannot come back:

  * `groups=["a","b"]` CONTAINS a `]`, so a `[^\\]]*\\]` regex stops at the wrong
    one and silently reads no groups (test_groups_attribute_contains_bracket).
  * `uid="uid://x"` contains the substring `id="`, so a loose `id="([^"]+)"`
    captures the uid instead of the resource id, and EVERY script resolves to
    nothing — a false-negative generator, which is the worse failure direction
    for a linter (test_uid_is_not_mistaken_for_id).

Fixtures are inline .tscn strings, not files on disk: the parser takes text, and
a fixture you can read next to its assertion is worth more than a tree of stubs.
"""
import os
import sys
import unittest

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools"))

from check_area_monitoring import (  # noqa: E402
    MONITOR_GROUP,
    _groups_of,
    _tokenize_attrs,
    parse_scene,
)


class TestHeaderTokenizer(unittest.TestCase):
    """The header scanner, which replaced one regex per attribute."""

    def test_groups_attribute_contains_bracket(self) -> None:
        attrs = _tokenize_attrs(
            'node name="Zone" type="Area3D" parent="." groups=["spawn", "active_monitor"]'
        )
        self.assertEqual(attrs["name"], "Zone", "name must survive a later bracketed value")
        self.assertEqual(attrs["type"], "Area3D")
        self.assertEqual(
            attrs["groups"],
            '["spawn", "active_monitor"]',
            "the whole array must be captured, brackets included",
        )

    def test_uid_is_not_mistaken_for_id(self) -> None:
        attrs = _tokenize_attrs(
            'ext_resource type="Script" uid="uid://s8pbsagvb7ix" path="res://a.gd" id="1_1t3ni"'
        )
        self.assertEqual(attrs["id"], "1_1t3ni", "id must not be captured from inside uid")
        self.assertEqual(attrs["uid"], "uid://s8pbsagvb7ix")
        self.assertEqual(attrs["path"], "res://a.gd")

    def test_call_valued_attribute(self) -> None:
        attrs = _tokenize_attrs('node name="X" parent="." instance=ExtResource("2_abc")')
        self.assertEqual(attrs["instance"], 'ExtResource("2_abc")', "a call value reads to its )")

    def test_groups_of_reads_every_name(self) -> None:
        sections = parse_scene('[node name="A" type="Area3D" groups=["gravity", "%s"]]' % MONITOR_GROUP)
        self.assertEqual(_groups_of(sections[0]), {"gravity", MONITOR_GROUP})


class TestSectionSplitting(unittest.TestCase):
    def test_properties_attach_to_their_node(self) -> None:
        sections = parse_scene(
            '[node name="A" type="Area3D"]\n'
            "collision_mask = 8\n"
            "monitoring = false\n"
            "\n"
            '[node name="B" type="Area3D"]\n'
            "collision_layer = 32\n"
        )
        node_a, node_b = [s for s in sections if s.kind == "node"]
        self.assertEqual(node_a.props["monitoring"], "false")
        self.assertEqual(node_a.props["collision_mask"], "8")
        self.assertNotIn(
            "monitoring", node_b.props, "a blank line must not leak properties into the next node"
        )
        self.assertEqual(node_b.props["collision_layer"], "32")

    def test_line_numbers_point_at_the_header(self) -> None:
        sections = parse_scene(
            "[gd_scene format=3]\n"
            "\n"
            '[node name="Root" type="Node3D"]\n'
            "\n"
            '[node name="Zone" type="Area3D" parent="."]\n'
        )
        zone = [s for s in sections if s.attrs.get("name") == "Zone"][0]
        self.assertEqual(zone.line, 5, "a finding must point at the node header, not the file")


class TestRules(unittest.TestCase):
    """The three ways to pass, and the one way to fail, exercised end to end."""

    def _check(self, text: str):
        import check_area_monitoring as mod

        class _Stub(mod.Resolver):
            def __init__(self, source: str) -> None:
                super().__init__()
                self._source = source

            def sections(self, path):
                return mod.parse_scene(self._source)

        from pathlib import Path

        return mod.check_scene(Path(mod.REPO_ROOT) / "fixture.tscn", _Stub(text))

    def test_bare_area_is_an_error(self) -> None:
        findings, checked = self._check('[node name="Zone" type="Area3D" parent="."]\n')
        self.assertEqual(checked, 1)
        self.assertEqual(len(findings), 1, "an Area3D saying nothing must fail")
        self.assertEqual(findings[0].level, "ERROR")
        self.assertEqual(findings[0].node, "Zone")

    def test_monitoring_false_passes(self) -> None:
        findings, _ = self._check(
            '[node name="Zone" type="Area3D" parent="."]\nmonitoring = false\n'
        )
        self.assertEqual(findings, [], "the passive declaration is the normal case")

    def test_marker_passes_with_a_narrow_mask(self) -> None:
        findings, _ = self._check(
            '[node name="Det" type="Area3D" parent="." groups=["%s"]]\ncollision_mask = 8\n'
            % MONITOR_GROUP
        )
        self.assertEqual(findings, [], "a declared monitor scanning only `prop` is fine")

    def test_marker_without_explicit_mask_warns(self) -> None:
        findings, _ = self._check(
            '[node name="Det" type="Area3D" parent="." groups=["%s"]]\n' % MONITOR_GROUP
        )
        self.assertEqual([f.level for f in findings], ["WARN"], "default mask 1 is the costly one")

    def test_gravity_may_scan_the_world_layer(self) -> None:
        findings, _ = self._check(
            '[node name="G" type="Area3D" parent="." groups=["%s", "gravity"]]\n'
            "collision_mask = 15\n" % MONITOR_GROUP
        )
        self.assertEqual(findings, [], "a gravity override must reach every solid body")

    def test_gravity_space_override_also_exempts(self) -> None:
        findings, _ = self._check(
            '[node name="G" type="Area3D" parent="." groups=["%s"]]\n'
            "gravity_space_override = 1\ncollision_mask = 15\n" % MONITOR_GROUP
        )
        self.assertEqual(findings, [], "the property alone identifies a gravity area")

    def test_world_mask_warns_when_not_gravity(self) -> None:
        findings, _ = self._check(
            '[node name="Det" type="Area3D" parent="." groups=["%s"]]\ncollision_mask = 1\n'
            % MONITOR_GROUP
        )
        self.assertEqual([f.level for f in findings], ["WARN"])
        self.assertIn("world", findings[0].summary)

    def test_reason_metadata_silences_the_mask_warning(self) -> None:
        findings, _ = self._check(
            '[node name="Det" type="Area3D" parent="." groups=["%s"]]\n'
            'metadata/monitor_reason = "mask is set in player.gd"\n' % MONITOR_GROUP
        )
        self.assertEqual(findings, [], "the only way to silence it is to write down why")

    def test_explicit_true_needs_the_marker(self) -> None:
        findings, _ = self._check('[node name="Zone" parent="Inner"]\nmonitoring = true\n')
        self.assertEqual([f.level for f in findings], ["ERROR"],
                         "an outer scene re-enabling an instanced area must declare it")

    def test_instanced_node_is_not_reported_here(self) -> None:
        findings, checked = self._check(
            '[node name="Grid" parent="." instance=ExtResource("1_x")]\n'
        )
        self.assertEqual(findings, [], "the marker belongs to the scene that DEFINES the node")
        self.assertEqual(checked, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
