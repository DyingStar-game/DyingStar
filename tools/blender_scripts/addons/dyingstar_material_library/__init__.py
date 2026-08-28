"""Dying Star material library addon.

Single responsibility: register and unregister the submodules in the right
order. All behaviour lives in the modules it imports.

Install: Edit > Preferences > Add-ons > Install from Disk, pointing at a zip of
this folder. Or drop the folder in Blender's addons directory.
"""

bl_info = {
    "name": "Dying Star Material Library",
    "author": "Dying Star contributors",
    "version": (0, 1, 0),
    "blender": (4, 0, 0),
    "location": "Properties > Material > Dying Star Library",
    "description": "Publish a Blender material into the shared PBR library",
    "category": "Material",
}

from . import handlers, operators, preferences, properties, ui  # noqa: E402

# Order matters: preferences hold the repository path everything else reads,
# properties declare what the panel draws and the handler fills, operators are
# looked up by name at draw time.
_MODULES = (preferences, properties, operators, ui, handlers)


def register() -> None:
    for module in _MODULES:
        module.register()


def unregister() -> None:
    for module in reversed(_MODULES):
        module.unregister()


if __name__ == "__main__":
    register()
