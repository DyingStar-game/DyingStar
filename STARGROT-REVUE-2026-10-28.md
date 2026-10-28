# StarGrotte — correction du porche et revue du module

> Rapport de l’étape antérieure à l’ajout du catalogue des 200 grottes et à la préparation de la PR. Pour la livraison courante, voir [STARGROT-PR-2026-10-28.md](STARGROT-PR-2026-10-28.md). Les états de publication ci-dessous décrivent cette étape antérieure.

Base : `b4f834df9142f9af7ed92174d8c8ab23431fe64e`. Branche locale : `codex/stargrot-integration-20261028`. Cette revue complète le premier candidat du 28 octobre. Le paquet précédent conserve ses preuves historiques ; utiliser le candidat portant la mention « revu » pour cette correction.

## Origine du défaut et correction

Le volume qui perce le terrain commence sur un plan fixe, appelé ici le début du porche. Les parois suivent ensuite leur intersection avec le versant. Sur une pente qui monte aussi latéralement, les deux pieds de l’entrée ne rencontrent pas le relief à la même profondeur. Le sol utilisait ces deux points décalés comme première arête : il commençait donc en diagonale à l’intérieur d’une ouverture déjà découpée sur toute sa largeur. Un triangle restait sans sol devant lui.

La correction conserve le contour irrégulier des parois, mais fait commencer les deux pieds du seuil sur le plan de découpe commun. Le maillage affiché et le maillage de collision proviennent toujours des mêmes faces. Les entrées directement percées dans une falaise reçoivent aussi une petite fondation enfouie sous le seuil, pour couvrir les petits jours dus à l’interpolation du terrain affiché. Elle comprend des assises latérales qui dépassent le contour de découpe de 75 cm, placées 15 cm sous le sol, ainsi qu’un raccord court devant le seuil. Elles ferment les deux petits jours latéraux que le contrôle des 88 points intérieurs ne détectait pas. Le contour horizontal des dolines n’est pas projeté autour d’une entrée verticale : sur une falaise, cela créait des bandes de roche dressées.

Le test de régression a d’abord été exécuté sur le code précédent : six points de la zone découpée n’avaient pas de sol et un pied commençait environ 44 cm trop loin. Après correction, les dix tests de porches passent, avec 945 assertions. Un contrôle sur Tarsis 3 vérifie aussi 88 positions sur le seuil, sur le maillage affiché et sur les collisions serveur. Deux rayons supplémentaires visent les angles depuis la caméra réelle. Le diagnostic initial traversait le vide à droite et à gauche ; après correction, ces rayons rencontrent la surface rocheuse et sa collision à environ 10,9 m de la caméra.

## Constats de revue traités

| Priorité | Constat | Traitement |
| --- | --- | --- |
| P1 | Sol diagonal laissant une partie de la découpe ouverte sur une pente croisée. | Début du sol aligné sur le plan de découpe dans `CavePortal.build_porch`. Test reproduisant le défaut avant correction. |
| P2 | Petits jours sous les angles du seuil, entre le relief échantillonné et le terrain affiché. | Fondation et assises latérales enfouies ajoutées au seuil direct. Le raccord horizontal autour de toute la bouche a été rejeté par le test réel, puis remplacé. |
| P2 | Client pouvant afficher un terrain percé avant que sa cavité soit assemblée. | Assemblage du chunk reporté jusqu’à disponibilité de la grotte, avant le retrait de l’ancien chunk. Les chunks sans grotte en attente continuent à s’afficher. Un maillage en attente est abandonné si le joueur quitte le secteur. |
| P2 | Préparation du ZIP possible sans certificat de validation lorsqu’il était absent. | Le préparateur exige désormais les preuves, la bonne base et les empreintes des sources. Quatre contrôles couvrent certificat absent, sources identiques, sources modifiées et mauvaise base. |

Les deux premiers constats sont corrigés en GDScript. Aucun nouveau code C# n’est ajouté. Le changement de chargement est également en GDScript ; les scripts PowerShell et Python servent aux contrôles et à la préparation de livraison.

## Périmètre relu

| Zone | Sources principales | Points examinés |
| --- | --- | --- |
| Entrées et raccords | `cave_portal.gd`, `cave_approach.gd`, `cave_porch_seam.gd`, `cave_natural_opening.gd`, `cave_entrance.gd` | Début de découpe, contour, fermeture du seuil, jonction des anneaux, orientation des faces, raccord au terrain. |
| Terrain et physique | `cave_terrain_cut.gd`, `planet_chunk.gd`, `planet_terrain.gd`, `player_server.gd` | Même découpe pour maillage et collisions, conservation des attributs natifs, attente des cavités, exemptions de récupération limitées à l’air des grottes. |
| Chargement et fermeture | `cave_planet_registry.gd`, `cave_resident_set.gd` | Deux tâches au maximum, un assemblage de cavité par image, déchargement par secteurs, attente des tâches avant destruction. |
| Définitions et décors | `cave_placement.gd`, `cave_profile.gd`, `cave_asset_library.gd`, `cave_preview_builder.gd` | Versions, valeurs finies, signatures et relief, snapshots de travail, budgets et poses partagés entre présentation et collisions. |
| Création et livraison | `cave_population.gd`, `cave_authoring_file.gd`, `cave_site_collection.gd`, `stargrot_explorer.gd`, `package_develop.py` | Travail sur copies, publication après validation, sauvegarde temporaire puis remplacement, catalogue séparé de la collection locale, correspondance des preuves avec les sources. |

Il s’agit d’une relecture manuelle de l’auteur de la correction, accompagnée de tests. Ce n’est pas une revue indépendante par une deuxième personne. Le tableau indique le périmètre examiné ; il ne constitue pas une preuve exhaustive de toutes les combinaisons de graines, de reliefs et de LOD.

Points de lecture directs dans ce checkout :

- [Seuil et début du sol](scenes/planet/cave/cave_portal.gd#L299).
- [Attente de la cavité avant affichage](scenes/planet/planet_terrain.gd#L4071).
- [Exigence de preuves avant préparation du paquet](tools/stargrot/package_develop.py#L43).
- [Régression sur pente croisée](test/unit/test_stargrot_portal.gd#L127).
- [Chargement différé et départ du secteur](test/unit/test_stargrot_develop.gd#L24).

## Validation de cette révision

Le passage final ciblé a terminé avec le code 0 et des empreintes de sources identiques au début et à la fin, sans amendement après les tests :

| Contrôle | Résultat |
| --- | --- |
| Compilation et import | Réussis ; zéro erreur de script. |
| Tests unitaires | 140 tests, 3 564 assertions, zéro échec. |
| Lot de 200 sites sur terrain synthétique | 40 contrôles réussis. |
| Catalogue client/serveur | 20 contrôles réussis. |
| Placement à la souris | 23 contrôles réussis. |
| Porche, doline et puits de lumière | 36 contrôles réussis, dont le contrôle des 88 positions du seuil et des deux angles obliques sans manque. |
| Décors, raccords synthétiques, ouverture/fermeture de l’atelier | Scénarios terminés normalement, aucun échec signalé, zéro tâche de profilage du relief restante à la fermeture. |
| Style GDScript | 58 scripts, zéro problème. |
| Crédits | 211 crédits bien formés ; nouveaux modèles compris. |
| Préparateur de paquet | Quatre contrôles réussis : preuves absentes, sources identiques, sources modifiées, mauvaise base. |

Neuf scènes ont été exécutées dans ce dernier passage. Les quatre scénarios donnant un nombre de contrôles hors tests unitaires totalisent 119 contrôles (40 + 20 + 23 + 36), en complément des contrôles de décors et de fermeture. Les journaux finaux ne contiennent aucune erreur de script. Les empreintes exactes et la liste des scènes figurent dans `passed.json` et dans le manifeste livré.

Le passage complet antérieur du 28 octobre avait également vérifié le ciel et le long scénario de création/recalage/annulation. Ces deux scénarios ne sont pas présentés comme rejoués après la présente correction. Le certificat courant énumère explicitement les scènes réellement exécutées. L’option `-Scenes` du vérificateur permet de reproduire ce périmètre ; sans cette option, son fonctionnement habituel est conservé.

## Livraison et réserves

Les catalogues stockent des définitions : la correction du maillage est appliquée à leur chargement avec cette version du module. Elle n’exige pas de déplacer les sites ni de réécrire les collections personnelles. Le contrôle de signature du relief ajouté lors de la mise à jour reste applicable : les anciens sites qui ne correspondent plus au relief doivent toujours être recalés avant export.

Le contraste de teinte entre le terrain bleu de Tarsis et la roche de grotte relève encore d’une vérification artistique dans les conditions d’éclairage normales du jeu. Les avertissements natifs de tuiles ancêtres, les diagnostics de shaders/fermeture et l’avertissement NuGet déjà signalés restent consignés. Les essais locaux Windows ne certifient pas les exports Linux/macOS, le multijoueur distant ni les transferts entre serveurs. Le spawn de rochers minables reste hors de cette livraison.

Le candidat peut être transmis à l’équipe pour revue. Aucun push ni fusion distante n’est réalisé. Le commit local reste en attente du nom et de l’adresse Git à utiliser, demandés précédemment ; les changements sont conservés sur la branche de préparation.
