"""Access to the shared validation rules from inside Blender.

Single responsibility: locate and load tools/map_rules.py at runtime.

The addon cannot import it normally: it lives in Blender's script directories,
outside the repository's import path, and the repository location is only known
once the artist has set it in the preferences. Loading by file path keeps the
rules in one place rather than duplicating them here.
"""

from __future__ import annotations

import importlib.util
import sys
from types import ModuleType

from . import preferences

RULES_MODULE_NAME = "dyingstar_map_rules"
RULES_RELATIVE_PATH = ("tools", "map_rules.py")

# Cached per resolved path, so changing the repository root reloads the rules.
_cache: dict[str, ModuleType] = {}


class RulesUnavailable(RuntimeError):
    """Raised when map_rules.py cannot be found or loaded."""


def load() -> ModuleType:
    """Return the shared rules module.

    Raises:
        RulesUnavailable: when the repository root is unset or the file is
            missing, so callers can degrade instead of crashing the panel.
    """
    root = preferences.resolve_root()
    if root is None:
        raise RulesUnavailable(
            "Repository root not set (Preferences > Add-ons > Dying Star)"
        )

    path = root.joinpath(*RULES_RELATIVE_PATH)
    key = str(path)
    if key in _cache:
        return _cache[key]

    if not path.is_file():
        raise RulesUnavailable(f"Not found: {path}")

    spec = importlib.util.spec_from_file_location(RULES_MODULE_NAME, path)
    if spec is None or spec.loader is None:
        raise RulesUnavailable(f"Cannot load {path}")

    module = importlib.util.module_from_spec(spec)

    # Register before executing: dataclasses resolve their field types through
    # sys.modules[cls.__module__].__dict__, which is None for a module that was
    # created but never registered.
    sys.modules[RULES_MODULE_NAME] = module

    try:
        spec.loader.exec_module(module)
    except Exception as error:  # noqa: BLE001 - surface any import-time failure
        sys.modules.pop(RULES_MODULE_NAME, None)
        raise RulesUnavailable(f"Cannot load {path}: {error}") from error

    _cache[key] = module
    return module
