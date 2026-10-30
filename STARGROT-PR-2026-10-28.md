# StarGrotte 0.9 et 200 grottes sur Tarsis III

## Contenu proposé pour develop

Cette contribution réunit le module d’exécution, l’atelier de création StarGrotte, les bibliothèques de rochers, les tests et le raccordement réseau des 200 grottes créées par l’auteur. Elle cible `develop`, base `b4f834df9142f9af7ed92174d8c8ab23431fe64e`, vérifiée le 28 octobre 2026.

Les grottes de Tarsis III sont des props réseau (type Horizon `cave`, scène `scenes/planet/cave/cave_site.tscn`) stockés dans la persistance ; leurs emplacements ne sont pas dans le dépôt. Elles sont placées dans QGIS (couche `cave_site`), recalées hors ligne puis importées par le panel admin : voir « Caves pipeline » dans [tools/planettech/qgis/README.md](tools/planettech/qgis/README.md). Le catalogue de onze exemples reste une ressource de démonstration de l’atelier ; il n’est pas utilisé par le jeu.

La collection de travail de l’atelier reste locale et distincte du catalogue livré. Un poste neuf ouvre sa propre collection de travail ; il n’hérite pas de la sauvegarde personnelle de l’auteur. Le jeu normal, lui, reçoit ses grottes par le réseau. La sauvegarde personnelle et les caches de terrain ne sont pas ajoutés au dépôt.

## Comportement en jeu

Client et serveur lisent les mêmes définitions et les mêmes signatures de relief. Les ouvertures coupent le terrain ; les cavités et leurs collisions sont construites à proximité des secteurs demandés. Les 200 définitions ne conduisent pas à garder 200 maillages chargés en orbite. Le client attend qu’une cavité soit assemblée avant d’afficher sa découpe.

Les porches conservent le contour irrégulier de leurs parois, avec un sol couvrant le plan de découpe et des raccords enfouis aux angles. Six formes de rochers habillent les intérieurs ; une bibliothèque distincte de douze formes habille les entrées et les parois des dolines. Les textures Rock029 déjà présentes dans Dying Star sont réutilisées.

La création, le placement, les raccords, la gestion des secteurs et les décors sont en GDScript. Le calcul CPU du champ de densité et de sa triangulation reste en C# dans `CaveNetworkMesher.cs`. L’import Windows et l’atelier réutilisent le garde de bibliothèque native du jeu.

L’atelier reste un outil de développement, exclu des exports. Il se lance avec `--stargrot-explorer --stargrot-workbench`. Le jeu normal démarre comme auparavant et reçoit ses grottes par le réseau. Ses grottes utilisent l’éclairage normal du jeu ; les lampes de démonstration restent réservées à l’atelier.

## Fermeture de l’atelier

Les registres de grottes possèdent leurs propres tâches et leur propre callback de traitement. La fermeture arrête maintenant explicitement ces registres avant de joindre les tâches natives du terrain et de synchroniser le rendu. Cela empêche la soumission de nouveaux travaux de grottes pendant la destruction des ressources. Les scénarios de fermeture vérifient qu’aucun travail de grotte ne reste actif et que les registres ne traitent plus de nouvelles demandes.

## Vérifications

Le catalogue issu de la sauvegarde de l’atelier a passé 209 contrôles : 200 sites présents, relief courant compatible, séparation des empreintes, export et relecture préservant toutes les signatures de placement. Signature native du relief : `9ea4cee4bf5b3c8d` ; version des hauteurs : `af187a067b584b4d`.

Le premier chargement local d’une grande grotte de ce catalogue, dont une salle atteint environ 124 m de large, a pris 33,0 s côté client et 32,4 s côté serveur lors du contrôle ciblé. La préparation est effectuée en arrière-plan, mais cette latence d’arrivée reste à examiner avant fusion. Le délai du test, auparavant prévu pour le petit catalogue de démonstration, passe de 30 à 90 s et le résultat enregistre les durées réelles. La validation du toit réutilise désormais son repère et son inverse, sans supprimer de point de contrôle ni modifier la tolérance de couverture. Aucun gain global de performances n’est annoncé.

La vérification finale complète a terminé avec le code 0 après le raccord du catalogue à la scène. Les empreintes des sources et données exécutables sont identiques avant et après le passage. Les onze scènes ont toutes été rejouées :

| Contrôle | Résultat |
| --- | --- |
| Compilation et import | Réussis ; aucune erreur de script. |
| Tests unitaires | 140 tests, 3 565 assertions, zéro échec. |
| Population synthétique de 200 sites | 40 contrôles réussis. |
| Catalogue réel et terrain client/serveur | 22 contrôles réussis, 200 définitions chargées, même géométrie pour le site comparé, déchargement vérifié. |
| Ciel du système | 15 contrôles réussis. |
| Création, export, recalage, suppression et annulation | 42 contrôles réussis. |
| Placement à la souris | 23 contrôles réussis. |
| Porche, doline et puits de lumière | 36 contrôles réussis, dont 88 positions du seuil et les deux angles obliques. |
| Assets, raccords et fermeture de l’atelier | Scénarios terminés sans échec ; zéro tâche de profilage ou de grotte restante et registres arrêtés à la fermeture. |
| Style et crédits | 58 scripts sans problème ; 211 crédits bien formés. |

Les six scénarios chiffrés hors tests unitaires totalisent 178 contrôles. Le certificat local `passed.json` énumère les onze scènes et les empreintes exactes. Le changelog français/anglais est vérifié avec l’outil officiel du projet. Le test du catalogue utilise la référence de la scène normale, initialise le terrain client et serveur et compare la même grotte par son identifiant, même si plusieurs tâches finissent dans un ordre différent.

Pour reproduire les essais : Godot 4.7 Mono double précision du projet, .NET 9, puis `tools/stargrot/verify_develop.ps1 -Godot CHEMIN -Dotnet CHEMIN -WithPlanetTest`. Les preuves locales sont dans `.stargrot-validation/`, hors Git.

## Review et limites

Le [guide de livraison](STARGROT-LIVRAISON-DEVELOP.md) explique les mises à jour ultérieures des catalogues et leur recalage lorsque le relief change. La [revue des raccords](STARGROT-REVUE-2026-10-28.md) et le [bilan de portage](STARGROT-INTEGRATION-2026-10-28.md) décrivent les étapes précédentes ; leurs états de publication et leurs chiffres restent datés de ces étapes.

Les essais locaux ne sont pas une visite visuelle de chacune des 200 grottes, une mesure de performances à grande échelle ou une certification des exports Linux/macOS et des transferts entre serveurs. Le contraste entre la roche brune des grottes et le terrain bleu de Tarsis, ainsi que le fin contour clair visible sur certaines entrées en forte lumière, restent à examiner visuellement. Les contrôles du seuil ne constituent pas une vérification exhaustive de tout le contour sous chaque éclairage. Les avertissements natifs de tuiles ancêtres, de shaders/fermeture et de NuGet déjà observés restent signalés. Le spawn rare de rochers minables n’est pas implémenté.

La PR prépare la revue de l’équipe ; elle ne fusionne pas la contribution et ne publie pas de release.
