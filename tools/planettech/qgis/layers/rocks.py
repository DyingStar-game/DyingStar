"""
Rock catalogue — the single source of truth for rock types.
============================================================

Each :class:`Rock` carries three kinds of data, consumed in three places:

  colors      the "colour range" (light → dark hex).  Far LOD / colour map use
              the middle of the range; close-up the shader lerps between the two
              bounds with noise so a zone is not one flat tint.  Chameleon rocks
              have a second range for night.
  impurities  per ELEMENT ppm ranges (with the ions responsible for the hue) —
              the mining yield: Al2O3 base plus Fe / Ti / Cr / V drawn in range.
  minerals    distinct sub-minerals trapped in the rock (emery) — mined as their
              own items, not as ppm.

``surface=False`` marks rocks that cannot exist at the surface (oxidised by
the atmosphere): they are only offered to underground biomes.

A biome opts in with ``fields=[rock_field()]`` (or ``rock_field(underground=True)``
for caves).  The setup dialog then lets the artist tick which of these rocks
exist on the planet; only the ticked ones end up in that layer's dropdown.

``catalogue()`` returns the JSON-ready dict exported for Godot.
"""

from dataclasses import dataclass, asdict
from typing import Optional

from .model import Field, ValueMap


@dataclass(frozen=True)
class Impurity:
    element: str            # "Fe", "Ti", "Cr", "V"
    ppm_min: int
    ppm_max: int
    ions: tuple = ()        # ions giving the hue: ("Fe2+", "Ti4+")
    optional: bool = False  # may be absent (pink: Fe3+ 0-1500)


@dataclass(frozen=True)
class Mineral:
    name: str               # "magnetite"
    formula: str            # "Fe3O4"


@dataclass(frozen=True)
class Rock:
    slug: str
    label: str
    formula: str                         # host crystal, e.g. "Al2O3"
    colors: Optional[tuple] = None       # (hex_light, hex_dark); None = not decided yet
    night_colors: Optional[tuple] = None # chameleon rocks only
    impurities: tuple = ()
    minerals: tuple = ()
    purity: Optional[float] = None       # host-crystal fraction when known (white: > 0.995)
    surface: bool = True                 # False → underground only
    description: str = ""


# ============================================================
# Corundum family — Al2O3 + trace impurities
# ============================================================
_AL2O3 = "Al2O3"

ROCKS = [
    Rock("corundum_white", "White corundum", _AL2O3,
         colors=("#FAFAFA", "#D9D9D9"),   # white → very light grey
         purity=0.995,
         description="Anhydrous crystallised aluminium oxide of very high purity (> 99.5 %)."),

    Rock("corundum_blue", "Blue corundum", _AL2O3,
         colors=("#82C8E5", "#0F52BA"),
         impurities=(Impurity("Ti", 50, 100, ("Ti4+",)),
                     Impurity("Fe", 100, 3000, ("Fe2+",))),
         description="Al2O3 coloured by the Fe2+/Ti4+ charge-transfer pair."),

    Rock("corundum_grey_blue", "Grey-blue corundum", _AL2O3,
         colors=("#7393B3", "#263855"),
         impurities=(Impurity("Ti", 50, 200, ("Ti4+",)),
                     Impurity("Fe", 400, 15000, ("Fe2+", "Fe3+"))),
         description="Al2O3 with Fe2+/Ti4+ plus Fe3+ — more iron, duller blue."),

    Rock("corundum_black", "Black corundum", _AL2O3,
         colors=("#082567", "#111111"),
         impurities=(Impurity("Ti", 100, 400, ("Ti4+",)),
                     Impurity("Fe", 20000, 50000, ("Fe2+", "Fe3+"))),
         description="Al2O3 saturated with iron and titanium — near-opaque."),

    Rock("corundum_yellow", "Yellow corundum", _AL2O3,
         colors=("#FCE698", "#D4AF37"),
         impurities=(Impurity("Fe", 300, 6000, ("Fe3+",)),),
         description="Al2O3 coloured by Fe3+ alone."),

    Rock("corundum_green", "Green corundum", _AL2O3,
         colors=("#A2B997", "#2E4732"),
         impurities=(Impurity("Fe", 1000, 8000, ("Fe2+", "Fe3+")),),
         description="Al2O3 with both Fe2+ and Fe3+ — mixed blue/yellow absorption reads green."),

    Rock("emery", "Emery (brown corundum)", _AL2O3,
         colors=("#654321", "#2B1B17"),
         impurities=(Impurity("Fe", 10000, 50000, ("Fe2+", "Fe3+")),),
         minerals=(Mineral("magnetite", "Fe3O4"),
                   Mineral("hematite", "Fe2O3"),
                   Mineral("hercynite", "FeAl2O4")),
         description="Corundum saturated with iron, trapping distinct iron sub-minerals."),

    Rock("corundum_pink", "Pink corundum", _AL2O3,
         colors=("#FFC0CB", "#C71585"),
         impurities=(Impurity("Cr", 100, 1000, ("Cr3+",)),
                     Impurity("Fe", 0, 1500, ("Fe3+",), optional=True)),
         description="Al2O3 lightly coloured by Cr3+, optional Fe3+."),

    Rock("corundum_red", "Red corundum", _AL2O3,
         colors=("#B84A39", "#4A1512"),
         impurities=(Impurity("Cr", 1500, 4500, ("Cr3+",)),
                     Impurity("Fe", 3000, 6000, ("Fe3+",))),
         description="Al2O3 with high Cr3+ and Fe3+ — ruby range."),

    Rock("corundum_orange", "Orange corundum", _AL2O3,
         colors=("#F4A460", "#C04000"),
         impurities=(Impurity("Cr", 50, 250, ("Cr3+",)),
                     Impurity("Fe", 2500, 5000, ("Fe3+",))),
         description="Al2O3 with a little Cr3+ over dominant Fe3+."),

    Rock("corundum_chameleon", "Chameleon corundum (grey-blue / purple)", _AL2O3,
         colors=("#B4C4D9", "#3A325E"),
         night_colors=("#D1C0D4", "#5E2750"),
         impurities=(Impurity("V", 100, 3500, ("V3+",)),),
         description="Al2O3 coloured by V3+ — grey-blue in daylight, purple-mauve at night."),

    Rock("hercynite_oxidised", "Oxidised hercynite", "FeAl2O4",
         colors=("#233D2E", "#0E1A13"),   # very dark green
         surface=False,
         description="Iron-aluminium spinel; cannot survive at the surface (oxygen) — underground only."),
]

ROCK_BY_SLUG = {r.slug: r for r in ROCKS}
if len(ROCK_BY_SLUG) != len(ROCKS):
    raise ValueError("duplicate rock slug")


def rock_choices(underground=False):
    """``[(label, slug), …]`` for a dropdown — surface rocks only unless *underground*."""
    return [(r.label, r.slug) for r in ROCKS if r.surface or underground]


#: Kept for the setup dialog / existing call sites: the surface list.
ROCK_TYPES = rock_choices()


def rock_field(name="rock_type", comment="Dominant rock type of the zone", underground=False):
    return Field(name, "string", comment, choices=rock_choices(underground))


CLARITIES = [
    ("Milky — translucent, carries the impurities (surface)", "milky"),
    ("Clear — gem grade, no impurities (caves, deep rock)", "clear"),
]


def clarity_field(default="milky"):
    """Crystal clarity of the zone's rock.  Surface rock is milky; deep or
    cave rock, sheltered from weathering, is clear."""
    return Field("clarity", "string", "Crystal clarity: milky (impurities) or clear",
                 widget=ValueMap(CLARITIES), default=f"'{default}'")


def rock_fields(underground=False):
    """The pair every rock-bearing biome declares: rock type + clarity."""
    return [rock_field(underground=underground),
            clarity_field("clear" if underground else "milky")]


def catalogue():
    """JSON-ready ``{slug: {...}}`` — what gets exported for Godot."""
    out = {}
    for r in ROCKS:
        d = asdict(r)
        d["impurities"] = [asdict(i) for i in r.impurities]
        d["minerals"] = [asdict(m) for m in r.minerals]
        out[r.slug] = d
    return out
