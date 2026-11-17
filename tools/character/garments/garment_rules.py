"""The GDD's equipment rules (technical-docs: project/3_GDD/5_personnage/4_personnage_équipement.md).

Python twin of scenes/_universe/characters/human/garment_rules.gd: both are checked against the same cases,
test/data/character/garment_rules_cases.json. Keep them alike.

An item is worn on zones: 1 head, 2 neck, 3 torso, 4 arms, 5 hands, 6 wrists, 7 fingers, 8 legs, 9 feet, 0 the
whole body; a zone code may name a side (G left, D right) and a finger (1 thumb .. 5): "5G4" = left ring finger.
Its GDD code is zone - support - layer - access:
  support  the highest layer it can rest on        (0 underwear, 1 clothing, 2 light jacket, 3 coat,
  layer    the layer it counts as                    4 light armour, 5 heavy armour)
  access   0: what is under it cannot be reached; 1: it can
e.g. trousers 8-0-1-0 (on underwear, clothing), holster 8D-4-3-0 (a coat-level item that sits on light armour).

Items sharing a zone are worn inside-out by (support, layer): the one that can rest on higher layers is outside.
Each inner / outer pair needs inner.layer <= outer.support; two items with the same (support, layer) on a zone
cannot both be worn (two pairs of trousers).
"""
import re

ZONES = "0123456789"
SIDED = "456789"  # arms, hands, wrists, fingers, legs, feet
FINGERED = "57"  # hands, fingers
# A zone that holds another: the whole body holds everything, hands hold fingers, wrists sit between arm and hand.
CONTAINS = {"5": "7", "4": "6"}
ALSO = {"6": "5"}
CODE = re.compile(r"^([0-9])([GD])?([1-5])?$")


def parse_zone(code):
    """'5G4' -> ('5', 'G', '4'); None when the code is not a GDD zone."""
    m = CODE.match(str(code))
    if not m:
        return None
    zone, side, finger = m.group(1), m.group(2) or "", m.group(3) or ""
    if side and zone not in SIDED:
        return None
    if finger and zone not in FINGERED:
        return None
    if zone == "0" and (side or finger):
        return None
    return zone, side, finger


def zones_overlap(a, b):
    za, zb = parse_zone(a), parse_zone(b)
    if za is None or zb is None:
        return False
    if za[0] == "0" or zb[0] == "0":
        return True
    if za[0] != zb[0]:
        related = (CONTAINS.get(za[0]) == zb[0] or CONTAINS.get(zb[0]) == za[0]
                   or ALSO.get(za[0]) == zb[0] or ALSO.get(zb[0]) == za[0])
        if not related:
            return False
        return not (za[1] and zb[1] and za[1] != zb[1])
    if za[1] and zb[1] and za[1] != zb[1]:
        return False
    return not (za[2] and zb[2] and za[2] != zb[2])


def overlap(a, b):
    return any(zones_overlap(x, y) for x in a["zones"] for y in b["zones"])


def stack_key(item):
    return (int(item["support"]), int(item["layer"]))


def conflict(a, b):
    """Why a and b cannot be worn together ('' when they can): 'same_place' or 'cannot_rest'."""
    if not overlap(a, b):
        return ""
    if stack_key(a) == stack_key(b):
        return "same_place"
    inner, outer = (a, b) if stack_key(a) < stack_key(b) else (b, a)
    if int(inner["layer"]) > int(outer["support"]):
        return "cannot_rest"
    return ""


def keep_compatible(items):
    """The items in order, each dropped when it conflicts with one already kept."""
    kept = []
    for item in items:
        if all(not conflict(item, k) for k in kept):
            kept.append(item)
    return kept


def stack_order(items):
    """Inside out, for drawing and for hiding what is under."""
    return sorted(items, key=stack_key)


def blocked(item, worn):
    """True when an item worn over this one (sharing a zone) blocks access to it."""
    return any(o is not item and overlap(item, o) and stack_key(o) > stack_key(item) and int(o["access"]) == 0
               for o in worn)


def code_of(item):
    """The GDD code, e.g. '8D-4-3-0' (first zone)."""
    return "%s-%d-%d-%d" % (item["zones"][0], int(item["support"]), int(item["layer"]), int(item["access"]))


def check_item(item):
    """What is wrong with an item's fields (empty when nothing)."""
    errors = []
    if not item.get("zones"):
        errors.append("no zone")
    for z in item.get("zones", []):
        if parse_zone(z) is None:
            errors.append("bad zone %r" % z)
    for key in ("support", "layer"):
        if not 0 <= int(item.get(key, -1)) <= 5:
            errors.append("%s outside 0..5" % key)
    if int(item.get("access", -1)) not in (0, 1):
        errors.append("access is 0 or 1")
    return errors
