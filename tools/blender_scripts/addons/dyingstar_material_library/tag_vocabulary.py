"""Tag vocabulary access for the addon.

Single responsibility: read the project's tags.json and expose it in the shapes
Blender needs. Knows nothing about node trees, panels or file export.

The vocabulary is the same file validate.py checks against, so the addon can
never offer a tag the validator would reject. Its location comes from the addon
preferences, since the addon is installed outside the repository.
"""

from __future__ import annotations

import json

from . import preferences

# Catalogs are built from this category, so it drives the Asset Browser tree.
FAMILY_CATEGORY = "family"

# Cached per resolved path: changing the repository root must reload.
_cache: dict[str, dict] = {}


class VocabularyError(RuntimeError):
    """Raised when tags.json is missing, unreachable or malformed."""


def load(force_reload: bool = False) -> dict:
    """Return the parsed vocabulary, cached per repository path."""
    path = preferences.tags_path()
    if path is None:
        raise VocabularyError(
            "Repository root not set (Preferences > Add-ons > Dying Star)"
        )

    key = str(path)
    if key in _cache and not force_reload:
        return _cache[key]

    try:
        with path.open(encoding="utf-8") as handle:
            categories = json.load(handle)["categories"]
    except (OSError, json.JSONDecodeError, KeyError) as error:
        raise VocabularyError(f"Cannot read {path}: {error}") from error

    _cache[key] = categories
    return categories


def all_tags() -> list[str]:
    """Every valid tag, flattened and sorted."""
    return sorted({tag for tags in load().values() for tag in tags})


def family_tags() -> set[str]:
    """Tags that determine which Asset Browser catalog a material lands in."""
    return set(load().get(FAMILY_CATEGORY, []))


def check_family(material_id: str) -> tuple[str | None, str | None]:
    """Validate the family segment of a shared material id.

    A runtime script reads this segment to pick footstep sounds, so an unknown
    family fails silently in game. Returns the family and an error message,
    either of which may be None.
    """
    prefix = "mat_"
    if not material_id.startswith(prefix):
        return None, None

    parts = material_id[len(prefix):].split("_")
    if len(parts) < 2 or not parts[0]:
        return None, "Name must be mat_<family>_<descriptor>"

    family = parts[0]
    try:
        known = family_tags()
    except VocabularyError as error:
        return family, str(error)

    if family not in known:
        return family, f"'{family}' is not a known family: {', '.join(sorted(known))}"

    return family, None


def enum_items(self, context) -> list[tuple[str, str, str]]:
    """Enum items callback for the tag dropdown.

    Grouped by category so the artist sees the structure of the vocabulary
    rather than a flat alphabetical list. Signature is imposed by Blender, and
    it must never raise: an exception here breaks the whole panel.
    """
    try:
        categories = load()
    except VocabularyError as error:
        return [("", str(error)[:60], "")]

    items: list[tuple[str, str, str]] = []
    for category, tags in categories.items():
        for tag in tags:
            items.append((tag, tag, f"{category}: {tag}"))

    return items or [("", "Vocabulary is empty", "")]
