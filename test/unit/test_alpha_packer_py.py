#!/usr/bin/env python3
"""Unit tests for the Blender add-on's alpha_packer -- how an opacity map is folded into the
albedo's alpha at export, which is the only place Godot reads transparency from.

Only the numpy arithmetic is tested: bpy exists inside Blender alone, and alpha_packer imports it
only in the functions that touch Blender data. The module is loaded from its file, so the add-on
package (whose __init__ needs bpy) is never imported.

    python3 test/unit/test_alpha_packer_py.py
"""
import importlib.util
import os
import sys
import unittest

try:
    import numpy as np
except ImportError:  # pragma: no cover
    print("SKIP test_alpha_packer_py: numpy absent")
    sys.exit(0)

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_MODULE = os.path.join(
    _REPO, "tools", "blender_scripts", "addons", "dyingstar_material_library", "alpha_packer.py"
)
_spec = importlib.util.spec_from_file_location("alpha_packer", _MODULE)
alpha_packer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(alpha_packer)


def _rgba(*pixels: tuple) -> np.ndarray:
    return np.array(pixels, dtype=np.float32)


class TestOpacityChannel(unittest.TestCase):
    def test_a_grayscale_map_is_read_from_red(self) -> None:
        opacity = _rgba((0.0, 0.0, 0.0, 1.0), (0.4, 0.4, 0.4, 1.0))
        np.testing.assert_allclose(alpha_packer.opacity_channel(opacity), [0.0, 0.4])

    def test_a_mask_painted_in_alpha_is_read_from_alpha(self) -> None:
        # PR #409's decals: plain white RGB, the mask in alpha.
        opacity = _rgba((1.0, 1.0, 1.0, 0.0), (1.0, 1.0, 1.0, 0.35))
        np.testing.assert_allclose(alpha_packer.opacity_channel(opacity), [0.0, 0.35])


class TestAlphaPack(unittest.TestCase):
    def test_the_albedo_keeps_its_colour_and_takes_the_opacity_as_alpha(self) -> None:
        albedo = _rgba((0.1, 0.2, 0.3, 1.0), (0.5, 0.6, 0.7, 1.0))
        packed = alpha_packer.alpha_pack(albedo, np.array([0.0, 0.8], dtype=np.float32))
        np.testing.assert_allclose(packed, [[0.1, 0.2, 0.3, 0.0], [0.5, 0.6, 0.7, 0.8]])

    def test_without_an_albedo_the_colour_is_white(self) -> None:
        # albedo_color, kept in the manifest, tints it in Godot.
        packed = alpha_packer.alpha_pack(None, np.array([0.25], dtype=np.float32))
        np.testing.assert_allclose(packed, [[1.0, 1.0, 1.0, 0.25]])

    def test_sizes_must_match(self) -> None:
        with self.assertRaises(alpha_packer.PackError):
            alpha_packer.alpha_pack(_rgba((0.0, 0.0, 0.0, 1.0)), np.zeros(2, dtype=np.float32))


if __name__ == "__main__":
    unittest.main()
