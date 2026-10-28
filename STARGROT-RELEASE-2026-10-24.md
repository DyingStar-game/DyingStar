# StarGrotte — préparation de la première release

## Base Dying Star

Révision intégrée : `509148dc81a54061ec1422dbe78d03af4ac8648b`, branche `develop`, 24 octobre 2026. Ancienne base : `7f15361081c8022d8d4d3258f07184be4d99aab4`. Les 808 fichiers modifiés en amont ont été intégrés. Un conflit dans PlanetTerrain a été résolu en conservant le préchargement des modules de rails et l’attachement du registre des grottes.

Les modifications locales v9 et les corrections des raccords du 19 octobre sont conservées. Sauvegarde complète des 203 fichiers locaux présents avant la mise à jour : `../stargrot-before-update-20261024.zip` (manifeste SHA-256 inclus). L’autostash Git est également conservé. Aucun commit, push, tag ou publication effectué.

## Texture native retrouvée et réutilisée

Le matériau natif `assets/_universe/environment/terrain/rocks/rock_material.tres` utilise Rock029. La couleur, la normale OpenGL et la rugosité sont présentes sous `assets/textures/grounds/rock/` dans le dépôt et dans la révision intégrée.

Les parois de grotte utilisaient déjà cette couleur et cette normale. Les trois blocs sculptés, l’éboulis, la stalagmite et la stalactite utilisaient seulement des teintes de sommets. Leur matériau partagé utilise maintenant les trois textures natives, conserve les teintes et la projection triplanaire. La réimportation des modèles charge ce matériau existant au lieu de le remplacer par un matériau sans texture. Aucun nouveau fichier image ni dépendance externe ajouté.

## Adaptation au contrôleur natif

Le contrôleur récent exige le repère du joueur dans chaque commande. Les commandes de mouvement et d’arrêt de l’atelier transmettent désormais `PropSpawn.parent_frame_uuid(player)`. La scène de placement vérifie les deux chemins. Cette adaptation est entièrement en GDScript.

## Vérification

Compilation réussie, zéro erreur ; import sans erreur de script. Contrôle de style : 55 scripts, zéro problème.

- 109 tests unitaires, 3 265 assertions, zéro échec (grottes, résidence des chunks, vol libre, récupération sous le terrain et rails).
- 200 sites générés, 36 contrôles réussis ; catalogue client/serveur : 20 contrôles.
- Scènes graphiques : ciel du système 15, création/export/recalage/suppression/annulation 40, placement à la souris 23, porches/doline/puits de lumière 33 contrôles. Total hors tests unitaires : 167 contrôles.
- Décors : six modèles, 105 occurrences, poses/collisions/séparation validées. Captures rapprochées inspectées ; Rock029 est bien appliquée.
- Atelier : ouverture indépendante et fermeture réussies, zéro tâche de profilage restante. Scène des raccords : sortie normale, captures inspectées.

Toutes les scènes finales se terminent avec le code 0 et sans erreur de script. Les trois scènes sans rendu ont passé avant la correction du contrat d’entrée ; les sept scènes graphiques ont été rejouées après cette correction. Les preuves sont dans `.stargrot-validation/`, dont `release-results-20261024.json`.

**Réserve visuelle avant release publique :** les raccords internes de la scène contrôlée ne montrent plus les grands jours des captures initiales. La capture planétaire `portal-porch.png` montre néanmoins des zones non jointives au sol autour du porche et une forte surexposition du terrain. Les avertissements natifs de tuiles ancêtres indiquent une divergence possible entre relief affiché et collisions ; la cause exacte de ces défauts visuels n’est pas établie par les tests. Les essais automatisés réussis ne suffisent donc pas à certifier une finition visuelle complète. Le paquet est un candidat d’intégration, pas une release publique validée.

## Intégration

Le paquet reste identifié StarGrotte 0.9, candidat à la première release. Appliquer son patch sur la révision de base indiquée dans le manifeste, puis suivre `STARGROT-LIVRAISON-DEVELOP.md`. La présence du module ne place pas automatiquement des grottes dans toutes les planètes : affecter le catalogue livré au champ PlanetData.cave_catalog pour la planète voulue.

Les collections locales personnelles ne sont pas réécrites. Si le relief d’un ancien site a changé, utiliser le recalage explicite de l’atelier avant export. Le moteur reste Godot 4.7 Mono double précision avec .NET 9 ; le noyau géométrique et le garde Windows restent en C#.

## Limites de cette validation

Essais locaux Windows, avec le moteur Dying Star fourni. Ils ne certifient pas Mac/Linux, une session multijoueur distante ni les performances de centaines de grottes simultanément visibles. Le jeu charge des tuiles distantes lorsque les packs de hauteur locaux sont absents ; le journal du catalogue isolé signale une résolution hors canal, tandis que le démarrage complet résout le canal `dev`. Client et serveur déployés doivent utiliser le même canal et les mêmes données de relief.

La compilation conserve l’avertissement NU1902 de la dépendance native OpenTelemetry 1.12.0. Les journaux peuvent aussi contenir des diagnostics natifs de LOD terrain, de shaders et d’objets résiduels à la fermeture ; ils ne sont pas présentés comme corrigés par ce portage.
