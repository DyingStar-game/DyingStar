# Dying Star — lave déterministe v6

Branche `rnd/viscous-lava-20261105`, depuis le build `0.1.0-dev.202611042208`.

## En jeu

La lave simulée est le comportement par défaut. Les éruptions suivent le calendrier des volcans
(`VolcanoActivityProfile`) :

- un créneau commence en moyenne **10 minutes** après la fin du précédent (±2 min 30) ;
- 55 % des créneaux sont des **éruptions de 40 minutes** (`eruption_duration_s`) : panache, pierres et lave ;
- les autres sont une fumée seule de 90 s, sans lave.

Le serveur de jeu (`server/lava_eruptions.gd`) simule l’éruption des volcans proches d’un joueur
(50 km, `[lava]` de `server.ini`). Il échantillonne le cratère une fois, quelques anneaux par image, puis
publie un prop `lava_flow` (`scenes/planet/lava/lava_flow.gd`) :

- le **plan entier** de l’éruption, la description du champ et sa **grille** (cellules et sol, ~20 Ko,
  zone 6) ;
- un **résumé** de la lave toutes les 3 s (~3 Ko, zone 2) : masque exact des cellules mouillées et germes de
  Voronoï portant épaisseur, chaleur et écoulement (`LavaSummary`).

Les clients à moins de 25 km ne simulent pas : ils reconstruisent la lave depuis le dernier résumé, sur un
travailleur, et l’affichent avec le même rendu (voir [NETWORK](NETWORK.md)). Le prop est supprimé quand le
dépôt a disparu.
Pas encore de collision ni de dégâts : la lave est visuelle.

`--authored-lava` rétablit les coulées QGIS, leur nivellement et les lacs statiques (comparaison, debug).

## Essayer sur les volcans

Double-cliquer sur **`test/volcano/launch_lava.cmd`**. La vue emploie le vrai
terrain de Tarsis III, le joueur, le ciel et les effets volcaniques du jeu.
Une éruption de **40 minutes** commence dans le cratère vide, le remplit,
déborde et alimente les versants sur **360°**. Le relief détermine les chemins.

**L** : vue du cratère ; **V** : volcan suivant ; **K** : nouvelle éruption ;
**J** : couper/reprendre l’apport ; **Y** : temps ×1 / ×4 / ×12 ; **M** : fumée ;
**F2** : panneau volcan. Clic : souris, ZQSD : vol, Espace/Ctrl : altitude,
molette : vitesse, Échap : libérer la souris.

Après l’arrêt de l’apport, la lave refroidit jusqu’au noir. Après environ deux
minutes simulées, le dépôt s’amincit et sa couverture se retire progressivement
pendant trois minutes. Au terme du nettoyage, maillage, textures, fumée et
passages de terrain sont libérés. Une autre éruption peut réutiliser la zone.

La grille polaire contient **96 secteurs × 96 anneaux**, dont 24 à l’intérieur
du cratère. Les cellules s’élargissent sur les flancs : le volcan testé couvre
un disque de **7,22 km de rayon**, avec seulement 9 216 cellules. Les sources
restent dans le cratère. La viscosité de référence est **400 Pa·s** à 1 150 °C,
avec une source à **1 200 °C** et un seuil de **30 Pa**. La gravité vient de la
planète.

Débit (`LavaPlanetPatch.eruption_volume_q`, entiers) : rampe de 45 s, plein débit
dimensionné au volume du cratère jusqu’à 120 s, descente jusqu’à 240 s, puis
**5 %** du débit maximal jusqu’à la fin (`TAIL_PERMILLE`). Jamais nul pendant
l’éruption : une coupure de 2 s lancerait le nettoyage. Chaque commande est bornée
à la place restante de sa cellule. Une hauteur de pression éruptive de 64 m aide le
magma à franchir les lèvres irrégulières ; elle disparaît après la coupure.
Le volume transporté provient toujours des seuls apports comptabilisés.

Voir [l’intégration volcans](../volcano/LAVA.md) pour les mesures et les limites.

## Dépôts au repos et éruptions longues

Les cellules noires et solidifiées (≤850 °C) quittent la liste active. Leur
volume reste présent et bloque toujours le relief. Le refroidissement froid
emploie une loi linéaire quantifiée d’environ 0,1 °C/s ; énergie et âge sont
calculés en une seule opération à la lecture ou au réveil. La partie chaude
conserve son bilan thermique détaillé. Cette loi froide fait partie du modèle
**v6** ; elle est identique avec ou sans mise au repos.

Une commande ou un flux entrant réveille uniquement les cellules touchées.
Le nettoyage de fin d’éruption réveille les dépôts pour faire progresser leur
retrait. L’affichage et la fumée parcourent aussi les seules cellules concernées ;
un champ entièrement au repos n’envoie plus de textures identiques au GPU.

Le calcul de cycle de vie et les paramètres sont partagés par les noyaux
GDScript/C#. Le jumeau C# reste nécessaire pour accélérer les équations ; les
tests exigent son égalité avec la référence. Aucun générateur ou système de
cache supplémentaire n’a été ajouté.

La durée par défaut est **2 400 s** (40 min). Le lanceur accepte jusqu’à **604 800 s**
(sept jours). La mémoire reste bornée par la grille, mais le domaine fermé peut
se remplir à fort débit : la mise au repos économise du CPU, elle n’élimine pas
le volume. Le test d’une semaine couvre les dépôts stables et leur réactivation,
pas une décharge continue du volcan pendant sept jours.

```powershell
.\test\volcano\launch_lava.ps1 -SleepBenchmark
.\test\volcano\launch_lava.ps1 -WeekTest
```

Mesure debug i7-13700, deux pairs dont l’adaptateur d’affichage, hors GPU/réseau :
9 216 cellules déposées dont 8 encore chaudes coûtent environ **0,36 ms par tick** ;
seules ces 8 cellules sont traitées. Un champ entièrement au repos coûte environ
**0,005 ms** pour les deux pairs. Le benchmark compare aussi les mêmes états au
mode v6 sans mise au repos et exige les mêmes empreintes.

## Déterminisme et coût

Le cœur `lava_fixed_core.gd` calcule en **entiers signés 64 bits à 10 Hz**.
Terrain en millimètres, volume en litres, température en dixièmes de degré.
`LavaStepNative.cs` accélère les boucles avec les mêmes opérations entières.
Le test d’intégration exige son égalité octet par octet avec la référence
GDScript, y compris pression, refroidissement, réchauffage et disparition.
Une assembly absente ou incompatible laisse fonctionner la référence.

Le serveur n’a aucun rendu. Le client utilise des tableaux d’affichage séparés,
un maillage fixe, deux états GPU interpolés et au plus 96 bouffées de fumée.
L’essai local exécute les deux calculs sur des travailleurs ; l’affichage
continue entre les ticks. Aucun tick n’est sauté pour rattraper le temps.
La limite est de deux zones par planète. Les zones vides n’exécutent plus les
boucles de fluide et ne conservent que leur état canonique réutilisable.

L’égalité exige les mêmes checkpoints, version, paramètres et commandes au même
tick. Le client ne reconstruit pas son propre relief physique depuis son LOD.
Le transport passe par le prop `lava_flow` (Horizon/GORC). Collision et dégâts
restent à raccorder. Voir [NETWORK.md](NETWORK.md).

## Modèle

Fluide de Bingham à profondeur moyenne : pente de surface libre, contrainte
seuil, viscosité croissante au refroidissement, transferts simultanés de volume,
chaleur et âge d’exposition. Les faces bloquent le relief et la véritable lèvre
échantillonnée. Les bords externes sont fermés. Sous 950 °C, la lave s’immobilise.
Le refroidissement inclut rayonnement, convection et conduction simplifiés ;
une loi de refroidissement de fin d’éruption et une disparition progressive
répondent au cycle demandé pour le jeu. Le volume retiré est comptabilisé
séparément : actif + retiré + échappé = injecté, exactement.

Ce modèle de jeu n’est pas une prévision volcanologique calibrée. Pas d’inertie,
tunnels, projections fluides ou mécanique de plaques. La pression éruptive et
la vitesse de disparition sont des paramètres de jeu. Les références de
principe restent [USGS Lava2d](https://www.usgs.gov/publications/toward-next-generation-lava-flow-forecasting-development-a-fast-physics-based-lava)
et [Costa et Macedonio](https://arxiv.org/abs/physics/0504049).

## Laboratoire et vérifications

`test/lava/launch.cmd` ouvre aussi le laboratoire synthétique, sans services du
jeu ni compilation C#. Vallée, bassin, barrage ; grilles communes 32×48, 48×72,
64×96 ; préréglages, source, débit, température et fumée ajustables. Glisser :
orbite ; molette : zoom ; Espace : pause ; R : repartir ; L : source.
Le nettoyage de fin d’éruption est réservé à la vue planète par défaut.

```powershell
.\test\lava\launch.ps1 -Test
.\test\lava\launch.ps1 -SmokeTest
.\test\volcano\launch_lava.ps1 -Test
.\test\volcano\launch_lava.ps1 -LongTest
python test/lava/check_replay.py --godot CHEMIN_GODOT --project .godot/lava-replay --output .godot/lava-evidence
```

Les **51 tests numériques** couvrent conservation, reprise atomique, commandes
invalides, bornes, grilles polaires, symétrie, couture, vieillissement, reprise
d’éruption et calcul sur travailleurs. Les **40 contrôles graphiques** couvrent
interpolation, fumée, terrain double face, coordonnées astronomiques, occlusion,
couture polaire, lave noire, retrait progressif et suppression des anciens texels.
Le rejeu lance deux processus indépendants : **20 empreintes sur 2 000 ticks**,
états binaires identiques et référence v6 figée.

Le test long suit **40 minutes d’éruption à force 1,6 puis 5 min 30 de
refroidissement et nettoyage**, sur deux pairs. Il exige l’atteinte des 96 secteurs,
aucune lave dans l’anneau extérieur, le noir avant la disparition, le bilan exact et
la suppression complète. Mesures dans [LAVA.md](../volcano/LAVA.md). Les résultats
v2/v3/v4/v5 sont conservés comme archives ; leurs unités, dimensions et coûts ne
décrivent pas le modèle v6.
