"""Keeps human_catalogue.json append-only for the tools that rewrite it (build_vitruvian_bank.py, refit_outfits.py,
hair_groom/groom.py).

A character's replicated string (CharacterAppearance.encode) and Horizon's saved players store POSITIONS in the
catalogue's lists: a slider, style, outfit, eye colour or origin that moves or disappears turns every saved character
using it into someone else. So a tool about to write the catalogue calls guard(): it stops with the list of entries
that moved or went, unless DS_CATALOGUE_REORDER=1 (then a CharacterMigrations step must carry saved documents
over, and CharacterAppearance's replicated version must change). Adding at the end is always fine.

test/unit/test_catalogue_order.gd checks the same on the catalogue in the repository.
"""
import json
import os
import sys


def _ids(entries):
    out = []
    for e in entries:
        if isinstance(e, dict):
            out.append(e.get("id", e.get("key")))
        else:
            out.append(e)
    return out


def problems(old, new, lists):
    """Entries of `old` that moved or went in `new`, for each list path in `lists` ("modifiers", "assets/hair"...)."""
    found = []
    for path in lists:
        before, after = old, new
        for part in path.split("/"):
            before = (before or {}).get(part, [])
            after = (after or {}).get(part, [])
        before, after = _ids(before), _ids(after)
        for i, name in enumerate(before):
            if i >= len(after):
                found.append(f"{path}[{i}] '{name}' removed")
            elif after[i] != name:
                found.append(f"{path}[{i}] '{name}' is now '{after[i]}'")
    return found


def guard(cat_path, new, lists):
    """Exits when writing `new` over the catalogue at `cat_path` would move or remove an entry of `lists`."""
    if not os.path.exists(cat_path) or os.environ.get("DS_CATALOGUE_REORDER") == "1":
        return
    found = problems(json.load(open(cat_path)), new, lists)
    if found:
        sys.exit("human_catalogue.json is append-only (saved characters store positions in it):\n  "
                 + "\n  ".join(found[:20]) + ("\n  ..." if len(found) > 20 else "")
                 + "\nKeep the order (add at the end), or DS_CATALOGUE_REORDER=1 with a CharacterMigrations step.")
