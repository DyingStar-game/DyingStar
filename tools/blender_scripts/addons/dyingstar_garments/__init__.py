"""Dying Star garments addon: model a garment on the game's body, check it, export it into the project.

Single responsibility: register and unregister the submodules in the right order. All behaviour lives in the
modules it imports.

Install: Edit > Preferences > Add-ons > Install from Disk, pointing at the zip that
tools/blender_scripts/build_garments_addon.py makes (it carries tools/character/garments' binding code along).
The guide for artists: tools/character/garments/README.md and the "Créer un vêtement" page of technical-docs.
"""

bl_info = {
    "name": "Dying Star Garments",
    "author": "Dying Star contributors",
    "version": (0, 1, 0),
    "blender": (4, 2, 0),
    "location": "3D View > Sidebar > DyingStar",
    "description": "Model a garment on the game's body, check it and export it for the game",
    "category": "Import-Export",
}

from . import operators, preferences, properties, ui  # noqa: E402

_MODULES = (preferences, properties, operators, ui)


def register() -> None:
    for module in _MODULES:
        module.register()


def unregister() -> None:
    for module in reversed(_MODULES):
        module.unregister()


if __name__ == "__main__":
    register()
