# StarGrotte — premier ensemble roche sculptée

Direction artistique retenue le 15 octobre 2026 : environnement stylisé, dans l'esprit de Satisfactory,
avec des formes sculptées lisibles, des cassures larges, des arêtes adoucies et peu de petits détails.
Ce sont six modèles originaux créés pour StarGrotte, sans extraction de contenu du jeu de référence.

Ouvrir **stargrot_rock_pilot.blend** dans Blender 5.1. La collection **01_ASSETS_METRES** contient les
six modèles modifiables, nommés explicitement et marqués comme assets Blender. La collection
**02_PRESENTATION_NON_EXPORT** contient les socles, textes, caméra et lumières de présentation.

Les objets sont disposés sur des socles pour la lecture. Leurs origines restent au point de support
de leur géométrie. Chaque export remet temporairement la position de l'objet à zéro.
Unité : un mètre. Blender : axe vertical Z ; export glTF : axe vertical Y pour Godot.
La stalactite est modélisée vers le haut, puis retournée par la règle de support plafond du jeu.

| Modèle | Gabarit approximatif | Usage |
|---|---|---|
| rock_boulder_01 | 1,8 × 1,25 × 1,1 m | bloc massif |
| rock_boulder_02 | 2,25 × 1,3 × 0,65 m | dalle couchée |
| rock_boulder_03 | 1,15 × 1,05 × 1,65 m | bloc dressé |
| rock_rubble_01 | 1,24 × 1,02 × 0,44 m | amas de six fragments |
| rock_stalagmite_01 | 1,1 × 0,88 × 2,6 m | formation au sol |
| rock_stalactite_01 | 0,81 × 0,69 × 2,15 m | formation suspendue |

Les teintes sont conservées dans l'attribut de couleur **RockTint**. Les six meshes utilisent un
matériau partagé, sans texture d'image supplémentaire. Trois enveloppes convexes simplifiées
assurent la collision des blocs. Éboulis et formations fines restent visuels.

## Dans l'atelier

Les nouveaux brouillons Roche utilisent **Roche sculptée — salles et profondeur**. La palette
**Roche sculptée — bouche ouverte** réserve davantage de blocs à l'approche intérieure des entrées.
Les bibliothèques historiques et les choix des grottes enregistrées sont conservés.
Le raccord extérieur sur le relief et les grandes arches ne font pas partie de ce premier lot.
Les parois et sols des grottes utilisent encore leurs matériaux antérieurs.

Le budget est de 120 occurrences par assemblage de grotte. Les modèles sont regroupés par règle
avec MultiMesh et suivent la résidence des secteurs natifs. Le placement mesure les vrais supports
des salles v8 et évite les superpositions entre règles. L'absence de place peut réduire le nombre
de décors ; chaque grotte n'est pas obligée de contenir les six modèles.

## Répartition procédurale

Les règles de la palette sculptée distribuent les objets sur les vrais supports des salles et galeries v8. Les gravats sont regroupés en amas ; les blocs peuvent suivre la pente ; les formations gardent leur axe vertical et sont refusées quand le support est trop incliné. Les porches sont habillés à partir de leurs anneaux. Le tirage est reproductible et ne force pas tous les modèles dans toutes les grottes.

Dans **Placer**, les deux commandes **Habiller** appliquent la bibliothèque choisie dans **Création** aux sites enregistrés, sans refaire leur géométrie. L’annulation existante restaure la palette précédente.

## Fabrication et retouches

Le script **tools/stargrot/build_rock_assets.py** reconstruit le pilote dans un processus Blender
séparé : il ne modifie pas une session déjà ouverte, mais **remplace le fichier source du pilote**.
Dupliquer le .blend avant une reconstruction si des retouches manuelles doivent être conservées.
Les GLB sont exportés sous **scenes/planet/cave/assets/rock_stylized/**.

Après une retouche manuelle, exporter uniquement l'objet choisi, à l'origine, avec normales et
couleurs de sommets. Importer les GLB dans Godot, puis lancer **tools/stargrot/import_rock_assets.tscn**
avec **--stargrot-explorer**. Cette scène reconstruit les meshes natifs, collisions et deux palettes.
Le jeu utilise ces ressources natives et ne nécessite pas Blender à l'exécution.

Les métriques exactes sont dans **scenes/planet/cave/assets/rock_stylized/manifest.json**.
Lancer **test/stargrot/test_rock_assets.tscn** avec **--stargrot-explorer** pour contrôler le rendu,
les poses des collisions et l'absence de superpositions. Le scénario planétaire accepte en plus
**--stargrot-styled-assets** pour exercer les nouveaux décors sur les porches et dolines.
