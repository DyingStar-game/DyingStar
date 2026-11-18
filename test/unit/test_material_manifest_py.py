#!/usr/bin/env python3
"""Unit tests for what a shared material's material.json may leave out -- every map -- and what it may not:
a base colour, which is an albedo map, a plain albedo_color, or both.

They run the schema (tools/schema/material.schema.json) and tools/validate.py's own checks, the ones the
Blender add-on's export has to satisfy: a manifest the add-on writes for a material with no normal map, or
with no map at all, must pass here.

    python3 test/unit/test_material_manifest_py.py
"""
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools"))

try:
    import validate  # tools/validate.py: needs jsonschema, pillow and numpy
    from jsonschema import Draft202012Validator
    from PIL import Image
except ImportError as error:  # pragma: no cover
    print("SKIP test_material_manifest_py: %s" % error)
    sys.exit(0)

_VOCABULARY = json.loads(Path(validate.TAGS_PATH).read_text(encoding="utf-8"))
_VALIDATOR = Draft202012Validator(json.loads(Path(validate.SCHEMA_PATH).read_text(encoding="utf-8")))


def _manifest(maps: dict, **extra) -> dict:
    manifest = {
        "id": "mat_metal_test",
        "display_name": "test",
        "tags": ["metal"],
        "physical_size_m": [1.0, 1.0],
        "license": "CC0-1.0",
        "author": "tester",
        "ai_generated": False,
        "delivery": {"type": "hosted", "version": 1},
        "maps": maps,
    }
    manifest.update(extra)
    return manifest


def _codes(issues: list) -> list:
    return [issue.code for issue in issues]


class TestEveryMapIsOptional(unittest.TestCase):
    def test_a_material_needs_no_normal_map(self) -> None:
        manifest = _manifest({"albedo": "tex_metal_test_albedo.png"})
        self.assertEqual(validate._check_schema(manifest, _VALIDATOR), [])
        self.assertEqual(validate._check_base_color(manifest), [])

    def test_a_plain_colour_needs_no_map_at_all(self) -> None:
        manifest = _manifest({}, albedo_color=[0.2, 0.2, 0.2])
        self.assertEqual(validate._check_schema(manifest, _VALIDATOR), [])
        self.assertEqual(validate._check_base_color(manifest), [])

    def test_a_normal_map_alone_goes_with_a_plain_colour(self) -> None:
        manifest = _manifest({"normal": "tex_metal_test_normal.png"}, albedo_color=[1.0, 0.0, 0.0])
        self.assertEqual(validate._check_schema(manifest, _VALIDATOR), [])
        self.assertEqual(validate._check_base_color(manifest), [])

    def test_the_pixel_rules_take_a_material_with_no_map(self) -> None:
        self.assertEqual(validate.inspect([], validate.RulesConfig(), (1.0, 1.0)), [])


class TestSurfaceValues(unittest.TestCase):
    """roughness and metallic as numbers: what was set by hand on the Principled BSDF."""

    def test_a_value_stands_for_a_missing_map(self) -> None:
        manifest = _manifest({}, albedo_color=[0.1, 0.1, 0.1], roughness=0.077, metallic=0.0)
        self.assertEqual(validate._check_schema(manifest, _VALIDATOR), [])
        self.assertEqual(validate._check_surface_values(manifest), [])

    def test_a_value_is_from_0_to_1(self) -> None:
        for wrong in (1.5, -0.1, "shiny"):
            manifest = _manifest({}, albedo_color=[0.1, 0.1, 0.1], roughness=wrong)
            self.assertEqual(_codes(validate._check_schema(manifest, _VALIDATOR)), ["schema"], wrong)

    def test_a_value_under_its_map_is_reported(self) -> None:
        own = _manifest({"albedo": "tex_metal_test_albedo.png", "roughness": "tex_metal_test_roughness.png"}, roughness=0.3)
        packed = _manifest({"albedo": "tex_metal_test_albedo.png", "orm": "tex_metal_test_orm.png"}, metallic=1.0)
        self.assertEqual(_codes(validate._check_surface_values(own)), ["value_under_map"])
        self.assertEqual(_codes(validate._check_surface_values(packed)), ["value_under_map"])


class TestWhatStaysRequired(unittest.TestCase):
    def test_a_base_colour_is_required(self) -> None:
        for maps in ({}, {"normal": "tex_metal_test_normal.png"}):
            self.assertEqual(_codes(validate._check_base_color(_manifest(maps))), ["base_color_missing"])

    def test_the_maps_block_itself_is_required(self) -> None:
        manifest = _manifest({}, albedo_color=[0.2, 0.2, 0.2])
        del manifest["maps"]
        self.assertEqual(_codes(validate._check_schema(manifest, _VALIDATOR)), ["schema"])

    def test_an_unknown_map_is_refused(self) -> None:
        manifest = _manifest({"tint": "tex_metal_test_tint.png"}, albedo_color=[0.2, 0.2, 0.2])
        self.assertEqual(_codes(validate._check_schema(manifest, _VALIDATOR)), ["schema"])

    def test_transparency_still_reads_the_albedo_map(self) -> None:
        manifest = _manifest({}, albedo_color=[0.2, 0.2, 0.2], alpha={"mode": "scissor"})
        self.assertEqual(_codes(validate._check_alpha(manifest)), ["alpha_needs_albedo"])


class TestAPublishedFolder(unittest.TestCase):
    """The whole of validate.py on a folder as the add-on writes it for a plain colour."""

    def setUp(self) -> None:
        self.folder = Path(tempfile.mkdtemp(prefix="ds_material_")) / "mat_metal_test"
        self.folder.mkdir()

    def tearDown(self) -> None:
        shutil.rmtree(self.folder.parent, ignore_errors=True)

    def _validate(self, manifest: dict) -> list:
        (self.folder / validate.MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")
        return validate.validate_material(
            self.folder,
            _VALIDATOR,
            validate._flatten_tags(_VOCABULARY),
            validate._family_tags(_VOCABULARY),
            validate.RulesConfig(),
        )

    def test_a_plain_colour_and_its_preview_are_a_whole_material(self) -> None:
        Image.new("RGB", (64, 64), (124, 124, 124)).save(self.folder / validate.PREVIEW_NAME)
        self.assertEqual(self._validate(_manifest({}, albedo_color=[0.4845, 0.4845, 0.4845])), [])

    def test_the_preview_is_still_required(self) -> None:
        issues = self._validate(_manifest({}, albedo_color=[0.4845, 0.4845, 0.4845]))
        self.assertEqual(_codes(issues), ["preview_missing"])


if __name__ == "__main__":
    unittest.main()
