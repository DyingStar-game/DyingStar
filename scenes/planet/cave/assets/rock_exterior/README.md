# Rochers extérieurs StarGrotte

Douze modèles originaux, six familles avec deux variantes : blocs fracturés, dalles, éclats en coin, fractures allongées, blocs arrondis et affleurements stratifiés. Aucun des six modèles de la grotte intérieure n’est réutilisé. Les textures Rock029 restent celles de Dying Star.

Chaque modèle a son GLB, un maillage natif et une collision convexe partagés par ses règles de placement au sol et dans les parois. Les collisions convexes simplifient les petites concavités des affleurements stratifiés. `manifest.json` conserve les dimensions, les graines et le nombre de triangles. Les attributions sont dans les fichiers `.txt` associés.

La bibliothèque `scenes/planet/cave/libraries/cave_rock_exterior.tres` se branche dans **Entrance Library** d’une palette complète. Elle n’est pas une palette de murs et de sols à sélectionner seule. Cette ressource suppose la version courante du module StarGrotte et ses scripts `CaveAssetLibrary` et `CaveDecorationRule`.

Source éditable : `assets_blender/stargrot/exterior/exterior_rocks.blend`. Reconstruction :

1. Exécuter Blender en arrière-plan avec `--factory-startup --python tools/stargrot/build_exterior_rocks.py` depuis la racine du projet.
2. Importer le projet dans Godot 4.7 Mono double précision.
3. Exécuter `tools/stargrot/import_exterior_rocks.tscn` avec l’argument utilisateur `--stargrot-explorer` pour reconstruire les ressources et les collisions natives.

Les modèles intérieurs ont leur propre source et leur propre importeur. Les ressources de palette conservent leur référence à cette bibliothèque extérieure lorsqu’elles sont réimportées.
