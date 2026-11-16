"""The MakeHuman body, built in numpy: targets on the basemesh, joints of the game_engine rig, fitted assets.

This is the offline reference for everything the game later does at runtime (bake a body from sliders,
place the skeleton's joints, fit clothes / hair / eyebrows...). It works in MakeHuman's frame and units
(Y up, decimetres); multiply by 0.1 for glTF / Godot metres.
"""
import os

import numpy as np

import macro_stack
import mh_formats

DEFAULT_MPFB = os.path.expanduser("~/.config/blender/5.1/extensions/blender_org/mpfb/data")
DEFAULT_USER = os.path.expanduser("~/.config/blender/5.1/extensions/.user/blender_org/mpfb/data")


class HumanModel:
    def __init__(self, mpfb_data: str = DEFAULT_MPFB, user_data: str = DEFAULT_USER, rig: str = "game_engine"):
        self.mpfb_data = mpfb_data
        self.user_data = user_data
        self.base = mh_formats.load_obj(os.path.join(mpfb_data, "3dobjs", "base.obj"))
        self.macro_config = mh_formats.load_json(os.path.join(mpfb_data, "targets", "macrodetails", "macro.json"))
        self.rig = mh_formats.load_json(os.path.join(mpfb_data, "rigs", "standard", f"rig.{rig}.json"))
        self.skin_weights = mh_formats.load_json(os.path.join(mpfb_data, "rigs", "standard", f"weights.{rig}.json"))
        self.targets_dir = os.path.join(mpfb_data, "targets")
        self._paths = self._index_targets()
        self._cache: dict = {}

    # --- targets --------------------------------------------------------------------------------
    def _index_targets(self) -> dict:
        """Target key -> file. Keys are the path under targets/ without extension ("macrodetails/height/
        male-young-..."), and also the bare leaf name for modifier targets ("nose-trans-up")."""
        paths = {}
        for root, _, files in os.walk(self.targets_dir):
            for f in files:
                if not (f.endswith(".target") or f.endswith(".target.gz")):
                    continue
                full = os.path.join(root, f)
                stem = f.split(".target")[0]
                rel = os.path.relpath(os.path.join(root, stem), self.targets_dir)
                paths[rel] = full
                paths.setdefault(stem, full)
        for root, _, files in os.walk(os.path.join(self.user_data, "targets")):
            for f in files:
                if f.endswith(".target") or f.endswith(".target.gz"):
                    stem = f.split(".target")[0]
                    paths.setdefault(stem, os.path.join(root, f))
        return paths

    def target(self, key: str):
        if key not in self._cache:
            self._cache[key] = mh_formats.load_target(self._paths[key])
        return self._cache[key]

    def has_target(self, key: str) -> bool:
        return key in self._paths

    def stack(self, macros: dict, race: dict, modifiers=()):
        """[(target key, weight)]: the macro combinations plus the explicit modifier targets."""
        out = list(macro_stack.target_stack(self.macro_config, macros, race))
        for name, value in modifiers:
            resolved = mh_formats.modifier_to_target(name, value)
            if resolved is not None:
                out.append(resolved)
        return out

    def build(self, stack) -> np.ndarray:
        verts = self.base.verts.copy()
        for key, weight in stack:
            idx, delta = self.target(key)
            np.add.at(verts, idx, delta * weight)
        return verts

    # --- skeleton -------------------------------------------------------------------------------
    def _point(self, spec: dict, verts: np.ndarray) -> np.ndarray:
        if spec["strategy"] == "CUBE":
            return verts[self.base.group_verts[spec["cube_name"]]].mean(axis=0)
        if spec["strategy"] == "MEAN":
            return verts[np.array(spec["vertex_indices"], dtype=np.int64)].mean(axis=0)
        if spec["strategy"] == "VERTEX":
            return verts[int(spec["vertex_index"])]
        raise ValueError(f"unknown joint strategy {spec['strategy']}")

    def joints(self, verts: np.ndarray) -> dict:
        """bone -> (head, tail), MakeHuman frame and units."""
        return {bone: (self._point(b["head"], verts), self._point(b["tail"], verts)) for bone, b in self.rig.items()}

    def ground(self, verts: np.ndarray) -> float:
        """Height of the soles: the lowest point of the visible body, as MPFB's feet-on-ground uses."""
        return float(verts[self.base.group_verts["body"], 1].min())

    # --- fitted assets --------------------------------------------------------------------------
    @staticmethod
    def fit(mhclo: mh_formats.Mhclo, verts: np.ndarray) -> np.ndarray:
        """Asset vertices on a (morphed) basemesh: barycentric of 3 references + offset x axis sizes."""
        size = np.ones(3)
        for axis, i in (("x", 0), ("y", 1), ("z", 2)):
            if axis in mhclo.scales:
                a, b, ref = mhclo.scales[axis]
                size[i] = abs(verts[a, i] - verts[b, i]) / ref
        anchored = (verts[mhclo.refs] * mhclo.weights[:, :, None]).sum(axis=1)
        return anchored + mhclo.offsets * size
