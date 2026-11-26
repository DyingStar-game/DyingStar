"""DyingStar — the QGIS plugin of the planet pipeline (QGIS 4).

This folder is both the plugin and the library its scripts share: the exporters import
their siblings as top-level modules (``import link_modifiers``, ``from export.planet import
dsmp``, ``from layers import …``), exactly as the unit tests under test/unit/ do, so the
folder goes on sys.path when QGIS loads the plugin. The plugin's own code is the
``ds_plugin`` sub-package.
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)


def classFactory(iface):  # noqa: N802 — the name QGIS calls
    from .ds_plugin.main import DyingStarPlugin
    return DyingStarPlugin(iface)
