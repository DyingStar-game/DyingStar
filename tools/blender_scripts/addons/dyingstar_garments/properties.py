"""What the artist fills in for a garment: its id and names, its place in the GDD's equipment rules, its credit.

Single responsibility: declare the properties (on the garment object, and the body chosen on the scene). The
GDD code (zone - support - layer - access) is built from them; see garment_rules.py.
"""

from __future__ import annotations

import bpy

ZONES = [
    ("1", "1 Head", "Tête: hats, helmets"),
    ("2", "2 Neck", "Cou: scarves, collars"),
    ("3", "3 Torso", "Torse: tops, jackets, coats (add 4 when it has sleeves)"),
    ("4", "4 Arms", "Bras: sleeves, bracers"),
    ("5", "5 Hands", "Mains: gloves (a side, and a finger for a ring)"),
    ("6", "6 Wrists", "Poignets: watches, bracelets"),
    ("7", "7 Fingers", "Doigts: rings"),
    ("8", "8 Legs", "Jambes: trousers, skirts, underpants"),
    ("9", "9 Feet", "Pied: shoes, boots, socks"),
    ("0", "0 Whole body", "Tout le corps: overalls, suits, spacesuits"),
]
SIDES = [("", "Both", "Not one side"), ("G", "Left (G)", "Gauche"), ("D", "Right (D)", "Droite")]
FINGERS = [("", "None", "")] + [(str(k), str(k), "Finger %d (1 = thumb)" % k) for k in range(1, 6)]
LAYERS = [
    ("0", "0 Underwear", "Sous-vêtement"),
    ("1", "1 Clothing", "Vêtement"),
    ("2", "2 Light jacket", "Veste légère"),
    ("3", "3 Coat", "Manteau"),
    ("4", "4 Light armour", "Armure légère"),
    ("5", "5 Heavy armour", "Armure lourde"),
]
MATERIALS = [
    ("cloth", "Cloth", "Matte fabric"),
    ("leather", "Leather", "Shoes, belts, a little shine"),
    ("hard", "Hard", "A helmet's shell, armour plates"),
    ("glass", "Glass", "A visor: see-through"),
]
GENDERS = [("any", "Anyone", ""), ("male", "Men", "Drawn for men's random looks"),
           ("female", "Women", "Drawn for women's random looks")]
BODIES = [("neutral", "Neutral", "The base body, between a man and a woman"),
          ("male", "Man", "The man's body (shape key Gender_Male)"),
          ("female", "Woman", "The woman's body (shape key Gender_Female)")]
BINDINGS = [("skin", "Skin", "Hangs on the skin under it, follows every shape (clothes)"),
            ("skull", "Skull", "Hangs on the skull and neck only, grows with the head (helmets, hats)")]
CREDITS = [("discord", "Me (Discord)", "Made by you: your Discord pseudo and id (Preferences)"),
           ("third", "Third party", "From a site: author, URL and licence")]


class DYINGSTAR_GarmentProps(bpy.types.PropertyGroup):
    garment_id: bpy.props.StringProperty(
        name="Id", description="Stable name, lowercase and underscores (e.g. leather_jacket_01): the file and the "
        "catalogue key. Never rename a garment once shipped")
    name_en: bpy.props.StringProperty(name="Name (en)", description="Shown in the character creator")
    name_fr: bpy.props.StringProperty(name="Nom (fr)", description="Affiché dans le créateur de personnage")
    zone: bpy.props.EnumProperty(name="Zone", items=ZONES, default="3", description="GDD zone: the first figure of "
                                 "the code")
    side: bpy.props.EnumProperty(name="Side", items=SIDES, default="")
    finger: bpy.props.EnumProperty(name="Finger", items=FINGERS, default="")
    extra_zones: bpy.props.StringProperty(
        name="Also covers", description="Other GDD zones it covers, comma-separated (a top with sleeves: 4; "
        "a coat down to the knees: 4, 8)")
    support: bpy.props.EnumProperty(
        name="Rests on", items=LAYERS, default="0",
        description="The highest layer it can be worn over (2nd figure). Trousers: 0 (on underwear)")
    layer: bpy.props.EnumProperty(
        name="Layer", items=LAYERS, default="1", description="The layer it counts as (3rd figure)")
    blocks: bpy.props.BoolProperty(
        name="Blocks access", default=False,
        description="What is under it cannot be reached while it is worn (4th figure: 0 when ticked)")
    hides_hair: bpy.props.BoolProperty(name="Hides hair", description="A hat, a helmet: no hair grows")
    hides_beard: bpy.props.BoolProperty(name="Hides beard", description="A mask, a closed helmet")
    hides_face: bpy.props.BoolProperty(name="Hides face", description="A closed helmet: no brows, lashes or beard")
    material: bpy.props.EnumProperty(name="Material", items=MATERIALS, default="cloth")
    gender: bpy.props.EnumProperty(name="Random looks", items=GENDERS, default="any",
                                   description="Who random characters (NPCs) wear it on; anyone can choose it")
    binding: bpy.props.EnumProperty(name="Hangs on", items=BINDINGS, default="skin")
    credit: bpy.props.EnumProperty(name="Credit", items=CREDITS, default="discord")
    credit_site: bpy.props.StringProperty(name="Site", description="e.g. Sketchfab")
    credit_author: bpy.props.StringProperty(name="Author")
    credit_url: bpy.props.StringProperty(name="URL")
    credit_licence: bpy.props.StringProperty(name="Licence", description="e.g. CC0, CC BY 4.0")
    # last check, shown in the panel
    checked: bpy.props.BoolProperty(default=False)
    poke_share: bpy.props.FloatProperty(name="Inside the skin", subtype="PERCENTAGE", min=0.0, max=100.0)
    close_share: bpy.props.FloatProperty(name="Too close for its layer", subtype="PERCENTAGE", min=0.0, max=100.0)
    hidden_skin: bpy.props.IntProperty(name="Skin hidden under it")
    triangles: bpy.props.IntProperty(name="Triangles")

    def zone_code(self) -> str:
        return self.zone + (self.side if self.zone in "456789" else "") + (self.finger if self.zone in "57" else "")

    def zones(self) -> list:
        out = [self.zone_code()]
        for z in self.extra_zones.replace(";", ",").split(","):
            z = z.strip().upper()
            if z and z not in out:
                out.append(z)
        return out

    def hides(self) -> list:
        return [k for k, on in (("hair", self.hides_hair), ("beard", self.hides_beard), ("face", self.hides_face)) if on]

    def item(self) -> dict:
        """The garment as the GDD rules see it (garment_rules.py)."""
        return {"id": self.garment_id, "zones": self.zones(), "support": int(self.support), "layer": int(self.layer),
                "access": 0 if self.blocks else 1}


def register() -> None:
    bpy.utils.register_class(DYINGSTAR_GarmentProps)
    bpy.types.Object.ds_garment = bpy.props.PointerProperty(type=DYINGSTAR_GarmentProps)
    bpy.types.Scene.ds_garment_body = bpy.props.EnumProperty(
        name="Model on", items=BODIES, default="neutral",
        description="The body the garment is modelled on and bound to")


def unregister() -> None:
    del bpy.types.Scene.ds_garment_body
    del bpy.types.Object.ds_garment
    bpy.utils.unregister_class(DYINGSTAR_GarmentProps)
