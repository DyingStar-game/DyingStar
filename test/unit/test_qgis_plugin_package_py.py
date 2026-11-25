"""The DyingStar QGIS plugin as QGIS receives it: the zip package_plugin.py builds and its
plugins.xml. Python 3 stdlib only (no QGIS): run with `python3 test/unit/test_qgis_plugin_package_py.py`.

What breaks silently otherwise: a zip whose root folder is not DyingStar/ (QGIS installs it
under the wrong name and the menu never appears), a personal export_config.ini shipped to the
team, a plugins.xml QGIS cannot parse or whose version disagrees with metadata.txt (the plugin
manager then never offers the update).
"""
import os
import shutil
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

_QGIS_DIR = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                         "tools", "planettech", "qgis"))
sys.path.insert(0, _QGIS_DIR)

import package_plugin  # noqa: E402


_TMP = []


def _tmpdir():
    d = tempfile.mkdtemp(prefix="ds_plugin_pkg_")
    _TMP.append(d)
    return d


class PluginPackage(unittest.TestCase):

    @classmethod
    def tearDownClass(cls):
        for d in _TMP:
            shutil.rmtree(d, ignore_errors=True)

    @classmethod
    def setUpClass(cls):
        cls.out = _tmpdir()
        cls.zip_path = package_plugin.build_zip(cls.out)
        with zipfile.ZipFile(cls.zip_path) as zf:
            cls.names = zf.namelist()
        cls.meta = package_plugin.metadata()

    def test_everything_under_the_plugin_folder(self):
        self.assertTrue(self.names)
        bad = [n for n in self.names if not n.startswith("DyingStar/")]
        self.assertEqual(bad, [], "QGIS installs a plugin under its zip's root folder")

    def test_the_plugin_entry_points_are_there(self):
        for needed in ("metadata.txt", "__init__.py", "icon.svg", "ds_plugin/main.py",
                       "ds_plugin/runner.py", "ds_plugin/settings.py", "ds_project.py",
                       "link_modifiers.py", "setup_planet_project.py", "export_roads.py",
                       "export_elevation.py", "layers/core.py", "layers/dialog.py",
                       "export/planet/dsmp.py", "preview_mountain_contours.py",
                       "zone_terrain.py", "ds_plugin/roads_ui.py", "export/planet/terrain_grid.py"):
            self.assertIn("DyingStar/" + needed, self.names)

    def test_nothing_personal_or_cached(self):
        for n in self.names:
            self.assertNotIn("__pycache__", n)
            self.assertFalse(n.endswith(".pyc"), n)
            self.assertNotEqual(os.path.basename(n), "export_config.ini",
                                "a personal config must not reach the team")
            if n.startswith("DyingStar/export/"):
                self.assertFalse(os.path.basename(n).startswith("test_"), n)

    def test_metadata_says_qgis_4(self):
        self.assertEqual(self.meta["name"], "DyingStar")
        self.assertTrue(self.meta["qgisminimumversion"].startswith("4."))
        self.assertEqual(self.meta["supportsqt6"], "True")
        for key in ("description", "about", "version", "author", "repository"):
            self.assertTrue(self.meta.get(key), key)

    def test_the_zip_is_reproducible(self):
        again = package_plugin.build_zip(_tmpdir())
        with open(self.zip_path, "rb") as a, open(again, "rb") as b:
            self.assertEqual(a.read(), b.read())

    def test_plugins_xml(self):
        url = "https://example.invalid/DyingStar-x.zip"
        xml = package_plugin.plugins_xml(self.meta, os.path.basename(self.zip_path), url,
                                         date="2026-11-25")
        root = ET.fromstring(xml)
        plugin = root.find("pyqgis_plugin")
        self.assertEqual(plugin.get("name"), "DyingStar")
        self.assertEqual(plugin.get("version"), self.meta["version"])
        self.assertEqual(plugin.findtext("version"), self.meta["version"])
        self.assertEqual(plugin.findtext("download_url"), url)
        self.assertEqual(plugin.findtext("file_name"), os.path.basename(self.zip_path))
        self.assertTrue(plugin.findtext("qgis_minimum_version").startswith("4."))

    def test_the_tag_must_match_the_version(self):
        out = _tmpdir()
        self.assertEqual(package_plugin.main(["--out", out, "--tag", "qgis-plugin-v0.0.0-nope"]), 1)
        self.assertEqual(package_plugin.main(
            ["--out", out, "--tag", package_plugin.TAG_PREFIX + self.meta["version"]]), 0)
        self.assertTrue(os.path.exists(os.path.join(out, "plugins.xml")))

    def test_every_shipped_python_file_compiles(self):
        with zipfile.ZipFile(self.zip_path) as zf:
            for n in self.names:
                if n.endswith(".py"):
                    compile(zf.read(n).decode("utf-8"), n, "exec")


if __name__ == "__main__":
    unittest.main()
