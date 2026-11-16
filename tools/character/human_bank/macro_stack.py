"""Which macro targets a set of macro sliders turns on, and how strongly.

MakeHuman's macro sliders (gender, age, muscle, weight, height, proportions, cup size, firmness, and the
African/Asian/Caucasian mix) do not each own a target. macrodetails/macro.json splits every slider into
"parts": inside a part, the value blends linearly between two named levels (e.g. age 0.75 is half
"young", half "old"). The bank then holds one target per COMBINATION of levels -- a male-young-
averagemuscle-maxweight body, a female-old-minmuscle-averageweight-maxheight stature... -- and a
combination's weight is the product of its levels' weights. Five families are combined:

  macrodetails/<race>-<gender>-<age>                              x race share
  macrodetails/universal-<gender>-<age>-<muscle>-<weight>
  macrodetails/height/<gender>-<age>-<muscle>-<weight>-<height>
  macrodetails/proportions/<gender>-<age>-<muscle>-<weight>-<proportions>   (no baby targets exist)
  breast/female-<age>-<muscle>-<weight>-<cup>-<firmness>         (female only; the gender share is NOT
                                                                  applied, the average/average pair and
                                                                  baby ones do not exist)

A level whose name is empty in macro.json (height or proportions at exactly average) contributes no
target. Weights are rounded to 4 decimals per level, and combinations under CUTOFF are dropped -- both
as MakeHuman does, so a body built here matches one built in MakeHuman / MPFB.

This is the reference implementation the game's GDScript / C# port is tested against.
"""
import itertools

CUTOFF = 0.01
MACRO_ORDER = ("gender", "age", "muscle", "weight", "proportions", "height", "cupsize", "firmness")
RACES = ("african", "asian", "caucasian")


def levels(macro_config: dict, macro: str, value: float):
    """[(level name, weight)] for one slider value: the (one) part containing the value, split linearly."""
    out = []
    for part in macro_config["macrotargets"][macro]["parts"]:
        lowest, highest = part["lowest"], part["highest"]
        if lowest < value < highest:
            t = (value - lowest) / (highest - lowest)
            if part["low"]:
                out.append((part["low"], round(1.0 - t, 4)))
            if part["high"]:
                out.append((part["high"], round(t, 4)))
    return out


def target_stack(macro_config: dict, macros: dict, race: dict, cutoff: float = CUTOFF):
    """[(target path relative to targets/, weight)] for the given sliders and race mix."""
    lv = {m: levels(macro_config, m, macros[m]) for m in MACRO_ORDER}
    out = []

    for r in RACES:
        share = race.get(r, 0.0)
        if share <= 0.0001:
            continue
        for (age, wa), (gender, wg) in itertools.product(lv["age"], lv["gender"]):
            w = share * wg * wa
            if w > cutoff:
                out.append((f"macrodetails/{r}-{gender}-{age}", w))

    def combos(*names):
        return itertools.product(*(lv[n] for n in names))

    for parts in combos("gender", "age", "muscle", "weight"):
        w = _product(parts)
        if w > cutoff:
            out.append(("macrodetails/universal-" + "-".join(p[0] for p in parts), w))

    for parts in combos("gender", "age", "muscle", "weight", "height"):
        w = _product(parts)
        if w > cutoff:
            out.append(("macrodetails/height/" + "-".join(p[0] for p in parts), w))

    for (gender, _), *rest in combos("gender", "age", "muscle", "weight", "cupsize", "firmness"):
        if gender != "female":
            continue
        w = _product(rest)
        name = "breast/female-" + "-".join(p[0] for p in rest)
        if w > cutoff and "averagecup-averagefirmness" not in name and "-baby-" not in name:
            out.append((name, w))

    for parts in combos("gender", "age", "muscle", "weight", "proportions"):
        w = _product(parts)
        name = "macrodetails/proportions/" + "-".join(p[0] for p in parts)
        if w > cutoff and "-baby-" not in name:
            out.append((name, w))
    return out


def _product(parts) -> float:
    w = 1.0
    for _, weight in parts:
        w *= weight
    return w
