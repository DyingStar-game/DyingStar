"""Write the English and French names of the creator's shape sliders and origins into the localisation table.

One name per Vitruvian shape key the creator offers (human_catalogue.json: %%CHAR_MOD_<KEY>) and per
origin (%%CHAR_ORIGIN_<NAME>). The %%CHAR_MOD_ and %%CHAR_ORIGIN_ blocks of
tools/localization/localisation.csv are replaced as a whole; nothing else in the file is touched. A key
without a name here stops the script: a slider is never shown under its raw key.

usage: python3 make_slider_labels.py <project root>
"""
import csv
import io
import json
import os
import sys

NAMES = {
    "Generic_Assymetry": ("Face: asymmetry", "Visage : asymétrie"),
    "BodyType_Fat": ("Body fat", "Corpulence"), "BodyType_Emaciated": ("Thinness", "Maigreur"),
    "BodyType_Muscular": ("Muscle", "Musculature"), "BodyType_Lean": ("Lean build", "Silhouette sèche"),
    "BodyType_LongProportions": ("Long limbs", "Membres longs"),
    "Face_Maxilla": ("Upper jaw", "Mâchoire supérieure"), "Face_Zygomatic_Bone": ("Cheekbones", "Pommettes"),
    "Chin_Width": ("Chin: width", "Menton : largeur"), "Chin_Portrusion": ("Chin: projection", "Menton : avancée"),
    "Chin_ChinCleft": ("Chin: cleft", "Menton : fossette"), "Chin_PosZ": ("Chin: height", "Menton : hauteur"),
    "Ear_Length": ("Ears: length", "Oreilles : longueur"), "Ear_Height": ("Ears: height", "Oreilles : hauteur"),
    "Ears_Canal_Size": ("Ears: canal size", "Oreilles : taille du conduit"),
    "Ears_Canal_Depth": ("Ears: canal depth", "Oreilles : profondeur du conduit"),
    "Ears_Lobe": ("Ears: lobe", "Oreilles : lobe"), "Ears_Rot": ("Ears: sticking out", "Oreilles : décollement"),
    "Ears_Round": ("Ears: roundness", "Oreilles : rondeur"), "Ears_Tragus_Portrusion": ("Ears: tragus", "Oreilles : tragus"),
    "Jaw_Mandible": ("Jaw: width", "Mâchoire : largeur"), "Jaw_Mandible_GonialAngle": ("Jaw: angle", "Mâchoire : angle"),
    "Jaw_Definition": ("Jaw: definition", "Mâchoire : définition"),
    "Shoulders_ShoulderWidth": ("Shoulders: width", "Épaules : largeur"),
    "Shoulders_ShoulderBladeWidth": ("Shoulder blades: width", "Omoplates : largeur"),
    "Shoulders_ShoulderTrapeziusSize": ("Trapezius", "Trapèzes"),
    "Stomach_BellyButtonPotrusion": ("Navel: projection", "Nombril : saillie"),
    "Waist_GluteSize": ("Buttocks: size", "Fesses : volume"), "Waist_Hips_Width": ("Hips: width", "Hanches : largeur"),
    "Waist_GlutealFold": ("Buttocks: fold", "Fesses : pli"), "Waist_GlutealCleft_Width": ("Buttocks: cleft width", "Fesses : largeur du sillon"),
    "Waist_GlutealCleft_Depth": ("Buttocks: cleft depth", "Fesses : profondeur du sillon"),
    "Hands_Size": ("Hands: size", "Mains : taille"), "Hands_FingernailLength": ("Fingernails: length", "Ongles : longueur"),
    "Hands_FingernailPointiness": ("Fingernails: point", "Ongles : pointe"), "Hands_Girth": ("Hands: thickness", "Mains : épaisseur"),
    "Torso_RibWidth": ("Rib cage: width", "Cage thoracique : largeur"),
    "Face_EyeSocket_Potrusion": ("Eye sockets: depth", "Orbites : profondeur"),
    "Face_FrontalBone_BrowRidge": ("Brow ridge", "Arcade sourcilière"),
    "Face_FrontalBone_FrontalEminence": ("Forehead: bumps", "Front : bosses"), "Face_FrontalBone": ("Forehead: projection", "Front : avancée"),
    "Neck_Girth": ("Neck: thickness", "Cou : épaisseur"), "Neck_Length": ("Neck: length", "Cou : longueur"),
    "Neck_ChinConnection": ("Under the chin", "Dessous du menton"),
    "Cheeks_BoneDefinition": ("Cheeks: hollow", "Joues : creux"), "Cheeks_CheeksBonePositionZ": ("Cheekbones: height", "Pommettes : hauteur"),
    "Cheeks_UpperCheek_Bone": ("Cheekbones: prominence", "Pommettes : saillie"),
    "Eyes_EyebrowsAngle": ("Eyebrows: angle", "Sourcils : angle"), "Eyes_EyebrowsDroop": ("Eyebrows: droop", "Sourcils : tombé"),
    "Eyes_EyelidsAngle": ("Eyes: slant", "Yeux : inclinaison"), "Eye_Size": ("Eyes: size", "Yeux : taille"),
    "Eyes_EyelidsAngle2": ("Eyes: outer corner", "Yeux : coin externe"), "Eyes_EyelidsCrease": ("Eyelids: crease", "Paupières : pli"),
    "Eyes_EyeBagsProminence": ("Eye bags: prominence", "Poches : saillie"), "Eyes_EyeBagsSize": ("Eye bags: size", "Poches : taille"),
    "Eyes_Distance": ("Eyes: spacing", "Yeux : écart"), "Eyes_VerticalShift": ("Eyes: height", "Yeux : hauteur"),
    "Arms_Forearm_Girth": ("Forearms: thickness", "Avant-bras : épaisseur"), "Arms_BicepSize": ("Biceps", "Biceps"),
    "Arms_TricepSize": ("Triceps", "Triceps"), "Arms_Armpit_Loc_Z": ("Armpits: height", "Aisselles : hauteur"),
    "Chest_Breast_Size": ("Breasts: size", "Poitrine : volume"), "Chest_Areola_Radius": ("Areolas: size", "Aréoles : taille"),
    "Chest_Nipple_Potrusion": ("Nipples: projection", "Tétons : saillie"),
    "Legs_FeetSize": ("Feet: size", "Pieds : taille"), "Legs_Toenail_Length": ("Toenails: length", "Ongles des pieds : longueur"),
    "Legs_Calves_Size": ("Calves", "Mollets"), "Legs_Thigh_Size": ("Thighs", "Cuisses"), "Legs_Quad_Size": ("Quadriceps", "Quadriceps"),
    "Legs_Thigh_Gap": ("Thigh gap", "Écart des cuisses"), "Legs_Hamstring_Size": ("Hamstrings", "Ischio-jambiers"),
    "Nose_NasalBone": ("Nose: bridge", "Nez : arête"), "Nose_NasalBone_AnteriorNasalAperature": ("Nose: width at the base", "Nez : largeur à la base"),
    "Nose_NasalBone_AnteriorNasalSpine": ("Nose: under the tip", "Nez : sous la pointe"), "Nose_NoseHeight": ("Nose: length", "Nez : longueur"),
    "Nose_Potrusion": ("Nose: projection", "Nez : avancée"), "Nose_NasalAngle": ("Nose: angle", "Nez : angle"),
    "Nose_NostrilSize": ("Nostrils: size", "Narines : taille"), "Nose_Tip_Potrusion": ("Nose: tip", "Nez : pointe"),
    "Nose_BottomFlatness": ("Nose: flat base", "Nez : base plate"), "Nose_BridgeProminence": ("Nose: bridge height", "Nez : hauteur de l'arête"),
    "Nose_Dorsum_Hump": ("Nose: bridge hump", "Nez : bosse de l'arête"),  # tools/character/face_survey/ava/ava_dorsum.py
    "Nose_Dorsum_Curve": ("Nose: bridge, full top / full bottom", "Nez : arête pleine en haut / en bas"),
    "Mouth_Lips_Length": ("Mouth: width", "Bouche : largeur"), "Mouth_Lips_Height": ("Lips: thickness", "Lèvres : épaisseur"),
    "Mouth_Lips_BottomLipDepth": ("Lower lip: fullness", "Lèvre inférieure : volume"),
    "Mouth_Lips_UpperLipDepth": ("Upper lip: fullness", "Lèvre supérieure : volume"),
    "Mouth_Lips_UpperLipArch": ("Upper lip: arch", "Lèvre supérieure : arc"), "Mouth_Lips_UpperAngle": ("Upper lip: angle", "Lèvre supérieure : angle"),
    "Mouth_Lips_LowerAngle": ("Lower lip: angle", "Lèvre inférieure : angle"),
    "Head_TopScalpPotrusion": ("Skull: top", "Crâne : dessus"), "Head_SideScalpPotrusion": ("Skull: sides", "Crâne : côtés"),
    "Head_BackScalpPotrusion": ("Skull: back", "Crâne : arrière"), "Head_SphenoidBone": ("Temples", "Tempes"),
    "Head_TemporalLines": ("Temporal lines", "Lignes temporales"), "Head_ParietalFlatness": ("Skull: flat top", "Crâne : dessus plat"),
    "Head_FrontalBoneFlatness": ("Forehead: flatness", "Front : aplat"),
}
ORIGINS = {
    "Race_African": ("African", "Africaine"), "Race_EastAsian": ("East Asian", "Est-asiatique"), "Race_White": ("European", "Européenne"),
    "Race_Hispanic": ("Hispanic", "Hispanique"), "Race_MiddleEastern": ("Middle Eastern", "Moyen-orientale"),
    "Race_Bengali": ("Bengali", "Bengalie"), "Race_Tamil": ("Tamil", "Tamoule"), "Race_Punjabi": ("Punjabi", "Pendjabie"),
    "Race_Marathi": ("Marathi", "Marathe"), "Race_Telegu": ("Telugu", "Télougoue"), "Race_Sinhalese": ("Sinhalese", "Cingalaise"),
    "Race_Kannada": ("Kannada", "Kannada"),
}


def main():
    root = sys.argv[1]
    catalogue = json.load(open(os.path.join(root, "assets/_universe/characters/human/human_catalogue.json")))
    csv_path = os.path.join(root, "tools/localization/localisation.csv")
    with open(csv_path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    columns = len(next(csv.reader([lines[0]])))
    kept = [line for line in lines if not line.startswith(("%%CHAR_MOD_", "%%CHAR_ORIGIN_"))]
    rows = []
    for entry in catalogue["modifiers"]:
        if entry["key"] not in NAMES:
            sys.exit(f"no name for the slider {entry['key']}")
        rows.append([entry["label"], *NAMES[entry["key"]]] + [""] * (columns - 3))
    for key, label in zip(catalogue["origins"], catalogue["origin_labels"]):
        rows.append([label, *ORIGINS[key]] + [""] * (columns - 3))
    out = io.StringIO()
    csv.writer(out, lineterminator="\n").writerows(rows)
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(kept) + "\n" + out.getvalue())
    print(f"{len(rows)} names written to {csv_path}")


if __name__ == "__main__":
    main()
