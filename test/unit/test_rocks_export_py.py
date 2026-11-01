#!/usr/bin/env python3
"""
The rock catalogue exported for Godot matches its source, and its cave data is sane.

    python3 test/unit/test_rocks_export_py.py

rocks.json is written by tools/planettech/qgis/export_rocks.py from layers/rocks.py;
a rock edited without a re-export would leave the game reading stale colours,
fluorescence or crystal habits.
"""
import json
import os
import re
import sys
import unittest

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools", "planettech", "qgis"))

import export_rocks                                               # noqa: E402
from layers import rocks                                          # noqa: E402

_HEX = re.compile(r"^#[0-9A-Fa-f]{6}$")


class RocksExportTest(unittest.TestCase):

    def test_exported_json_matches_the_source(self):
        with open(export_rocks.default_path(), encoding="utf-8") as fh:
            on_disk = json.load(fh)
        # Round-trip through JSON so tuples compare as the lists they are on disk.
        fresh = json.loads(json.dumps(export_rocks.payload()))
        self.assertEqual(on_disk, fresh,
                         "rocks.json is stale: run python3 tools/planettech/qgis/export_rocks.py")

    def test_fluorescence_is_a_hex_colour_and_a_unit_strength(self):
        for rock in rocks.ROCKS:
            if rock.fluorescence is None:
                continue
            self.assertRegex(rock.fluorescence.color, _HEX, rock.slug)
            self.assertGreater(rock.fluorescence.strength, 0.0, rock.slug)
            self.assertLessEqual(rock.fluorescence.strength, 1.0, rock.slug)

    def test_chromium_glows_and_iron_quenches(self):
        by = rocks.ROCK_BY_SLUG
        self.assertGreater(by["corundum_pink"].fluorescence.strength,
                           by["corundum_red"].fluorescence.strength, "Fe3+ dims the ruby")
        for slug in ("corundum_blue", "corundum_grey_blue", "corundum_green",
                     "corundum_black", "emery"):
            self.assertIsNone(by[slug].fluorescence, slug)

    def test_only_corundum_grows_hexagonal_crystals(self):
        for rock in rocks.ROCKS:
            if rock.slug.startswith("corundum_"):
                self.assertEqual(rock.crystal_habit, "hexagonal", rock.slug)
            else:
                self.assertIsNone(rock.crystal_habit, rock.slug)


if __name__ == "__main__":
    unittest.main()
