#!/usr/bin/env python3
"""
Unit tests for tools/generate_credits.py -- the credit-line grammar, which file a
.txt credits, and the JSON it writes.

Pure stdlib, no Godot, so this runs anywhere and in CI next to the script itself:

    python3 test/unit/test_generate_credits_py.py

Fixtures are throwaway folders: the script's job is to pair files on disk, so a
fixture that IS a folder is the honest one.
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools"))

from generate_credits import collect, parse_line, render, uncredited  # noqa: E402

MEMBER = "Discord - Pierro - 852633379459039302"


class TestLineGrammar(unittest.TestCase):
    def test_member_line(self) -> None:
        fields = parse_line(MEMBER)
        self.assertEqual(fields["source"], "Discord")
        self.assertEqual(fields["author"], "Pierro")
        self.assertEqual(fields["id"], "852633379459039302")
        self.assertEqual(fields["license"], "CC BY-NC-SA 4.0", "a member's work is under the asset licence")

    def test_pseudo_with_a_slash_and_trailing_space(self) -> None:
        fields = parse_line("Discord - KiFouine / WarpZone_Bar - 111043432687874048 ")
        self.assertEqual(fields["author"], "KiFouine / WarpZone_Bar")

    def test_third_party_line(self) -> None:
        fields = parse_line("Freesound - RescopicSound - https://freesound.org/s/750433/ - CC BY-NC 4.0")
        self.assertEqual(fields["source"], "Freesound")
        self.assertEqual(fields["author"], "RescopicSound")
        self.assertEqual(fields["url"], "https://freesound.org/s/750433/")
        self.assertEqual(fields["license"], "CC BY-NC 4.0")

    def test_user_name_instead_of_discord_id_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            parse_line("Discord - Loic - loic06282")

    def test_old_freesound_form_is_not_a_credit_line(self) -> None:
        self.assertIsNone(parse_line("Jump by Artmasterrich -- https://freesound.org/s/345437/ -- License: CC0"))

    def test_bare_url_is_not_a_credit_line(self) -> None:
        self.assertIsNone(parse_line("https://sketchfab.com/3d-models/metal-shelf"))


class TestPairing(unittest.TestCase):
    """Which file a .txt credits, and what is reported."""

    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)

    def tearDown(self) -> None:
        self._dir.cleanup()

    def _write(self, rel: str, text: str = "") -> Path:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def _collect(self):
        files = sorted(p for p in self.root.rglob("*") if p.is_file())
        return collect(self.root, files)

    def test_music_sfx_and_models_by_folder_and_extension(self) -> None:
        self._write("assets/_universe/audio/music/tune.ogg")
        self._write("assets/_universe/audio/music/tune.txt", MEMBER)
        self._write("assets/_universe/audio/sfx/door.ogg")
        self._write("assets/_universe/audio/sfx/door.txt", MEMBER)
        self._write("assets_blender/truck.blend")
        self._write("assets_blender/truck.blend1")
        self._write("assets_blender/truck.txt", MEMBER)
        credits, errors = self._collect()
        self.assertEqual(errors, [])
        by_category = {c.category: c.asset for c in credits}
        self.assertEqual(by_category, {"music": "tune.ogg", "sfx": "door.ogg", "models": "truck.blend"},
                         "a .blend1 backup is never the credited file")
        music = [c for c in credits if c.category == "music"][0]
        self.assertEqual(music.path, "res://assets/_universe/audio/music/tune.ogg", "the page plays it from there")

    def test_a_texture_set_is_credited_by_its_prefix(self) -> None:
        self._write("assets_blender/metal_4K_Color.jpg")
        self._write("assets_blender/metal_4K_Normal.jpg")
        self._write("assets_blender/metal_4K.txt", "Site - Someone - https://example.org/a - CC0")
        credits, errors = self._collect()
        self.assertEqual(errors, [])
        self.assertEqual([c.asset for c in credits], ["metal_4K_*"])

    def test_one_line_per_author(self) -> None:
        self._write("assets_blender/valley.blend")
        self._write("assets_blender/valley.txt",
                    "Discord - A - 1\nDiscord - B - 2\n\nDiscord - C - 3\n")
        credits, errors = self._collect()
        self.assertEqual(errors, [])
        self.assertEqual(sorted(c.author for c in credits), ["A", "B", "C"])

    def test_orphan_credit_file_is_an_error(self) -> None:
        self._write("assets/sfx/gone.txt", MEMBER)
        _credits, errors = self._collect()
        self.assertEqual(len(errors), 1)
        self.assertIn("credits no file", errors[0])

    def test_sound_without_credit_file_is_an_error(self) -> None:
        self._write("assets/sfx/bang.ogg")
        _credits, errors = self._collect()
        self.assertEqual(len(errors), 1)
        self.assertIn("no credit file", errors[0])

    def test_one_discord_id_under_two_pseudos_is_an_error(self) -> None:
        self._write("assets/a.ogg")
        self._write("assets/a.txt", "Discord - WarpZone - 111")
        self._write("assets/b.ogg")
        self._write("assets/b.txt", "Discord - KiFouine - 111")
        _credits, errors = self._collect()
        self.assertEqual(len(errors), 1)
        self.assertIn("several pseudos", errors[0])

    def test_licence_files_are_not_credit_files(self) -> None:
        self._write("assets/LICENSE", "CC BY-NC-SA 4.0")
        self._write("assets/pack/License.txt", "CC0")
        self._write("assets/pack/README.txt", "notes")
        _credits, errors = self._collect()
        self.assertEqual(errors, [])

    def test_material_manifest_gives_its_author(self) -> None:
        self._write("assets/mat_rock/material.json", json.dumps(
            {"author": "Poly Haven", "license": "CC0-1.0", "notes": "https://polyhaven.com/a/rock"}))
        credits, errors = self._collect()
        self.assertEqual(errors, [])
        self.assertEqual(credits[0].asset, "mat_rock")
        self.assertEqual(credits[0].url, "https://polyhaven.com/a/rock")


class TestNewModelsAndTextures(unittest.TestCase):
    """--new-since: a model or texture added on the branch needs a credit; what was there before does not."""

    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)

    def tearDown(self) -> None:
        self._dir.cleanup()

    def _write(self, rel: str, text: str = "") -> Path:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def _uncredited(self, *added: Path) -> list:
        files = sorted(p for p in self.root.rglob("*") if p.is_file())
        return uncredited(set(added), files, self.root)

    def test_a_new_model_without_credit_is_an_error(self) -> None:
        crate = self._write("assets/props/crate.glb")
        errors = self._uncredited(crate)
        self.assertEqual(len(errors), 1)
        self.assertIn("crate.txt", errors[0])

    def test_its_own_credit_file_covers_it(self) -> None:
        crate = self._write("assets/props/crate.glb")
        self._write("assets/props/crate.txt", MEMBER)
        self.assertEqual(self._uncredited(crate), [])

    def test_the_model_s_credit_covers_the_textures_named_after_it(self) -> None:
        self._write("assets/props/crate.glb")
        self._write("assets/props/crate.txt", MEMBER)
        albedo = self._write("assets/props/crate_albedo.png")
        self.assertEqual(self._uncredited(albedo), [])

    def test_a_material_json_covers_its_folder(self) -> None:
        self._write("assets/materials/mat_rock/material.json", "{}")
        normal = self._write("assets/materials/mat_rock/rock_normal.png")
        self.assertEqual(self._uncredited(normal), [])

    def test_a_library_licence_covers_its_folder_but_not_the_project_s(self) -> None:
        self._write("assets/LICENSE", "CC BY-NC-SA 4.0")
        self._write("assets/Animation Library/License.txt", "CC0")
        anim = self._write("assets/Animation Library/Unity/anim.glb")
        loose = self._write("assets/props/loose.png")
        self.assertEqual(self._uncredited(anim), [], "the library's own licence")
        self.assertEqual(len(self._uncredited(loose)), 1, "the project's assets/LICENSE credits nobody")

    def test_sounds_and_other_files_are_left_to_the_other_checks(self) -> None:
        self.assertEqual(self._uncredited(self._write("assets/data/poi.json")), [])


class TestOutput(unittest.TestCase):
    def test_output_is_stable_and_has_every_section(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("b", "a"):
                (root / "assets").mkdir(exist_ok=True)
                (root / "assets" / (name + ".ogg")).write_text("")
                (root / "assets" / (name + ".txt")).write_text(MEMBER)
            files = sorted(p for p in root.rglob("*") if p.is_file())
            credits, _ = collect(root, files)
            first = render(credits)
            self.assertEqual(first, render(list(reversed(credits))), "the order of reading must not show")
            data = json.loads(first)
            self.assertEqual(list(data), ["music", "sfx", "models"])
            self.assertEqual([c["asset"] for c in data["sfx"]], ["a.ogg", "b.ogg"])
            self.assertTrue(first.endswith("\n") and "\r" not in first)


if __name__ == "__main__":
    unittest.main()
