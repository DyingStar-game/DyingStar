# StarGrotte 0.9 — atelier de grottes pour Dying Star

## Livraison avec 200 grottes sur Tarsis III

Le module et l’atelier sont livrés avec le catalogue `levels/stargrot/catalogs/tarsis_3_200_grottes.tres`, déjà affecté à la scène normale de Tarsis III. Il contient 105 entrées en rampe, 89 dolines et 6 entrées de type hangar. Le chargement client/serveur utilise les secteurs du terrain ; l’atelier n’apparaît pas en jeu. Voir [le dossier de PR](STARGROT-PR-2026-10-28.md) pour l’intégration courante et les essais.

## Revue du porche — 28 octobre 2026

Le seuil est fermé sur les pentes croisées. Le terrain percé attend sa cavité avant affichage, et le paquet exige des preuves de validation. Voir [la correction et la revue du module](STARGROT-REVUE-2026-10-28.md) pour le périmètre testé et les réserves.

## Intégration sur develop — 28 octobre 2026

Base : `b4f834df9142f9af7ed92174d8c8ab23431fe64e`. Voir [le bilan de fusion](STARGROT-INTEGRATION-2026-10-28.md) et [le guide actualisé](STARGROT-LIVRAISON-DEVELOP.md). Le module réutilise le garde Windows natif, réserve les lampes de démonstration à l’atelier et contrôle la signature complète du relief avant de charger un site. Les collections anciennes doivent être recalées avant livraison. Les rapports des dates précédentes restent historiques.

## Bibliothèque extérieure — 27 octobre 2026

Les palettes **Roche sculptée** utilisent maintenant une bibliothèque extérieure indépendante : douze nouveaux modèles, répartis entre blocs fracturés, dalles, éclats en coin, rochers allongés, blocs arrondis et affleurements stratifiés. Les six modèles intérieurs restent dédiés aux salles et galeries. Le placement extérieur varie aussi les proportions, l’inclinaison, la taille et l’ordre des formes ; des portions du pourtour restent nues. Gros blocs avec collisions, passages et descentes dégagés, budget borné, placement reproductible en GDScript.

Relancer l’atelier. Les sites qui utilisent déjà les palettes sculptées en bénéficient au rechargement. Pour une ancienne palette, choisir **Roche sculptée — bouche ouverte**, puis **Habiller** le site ou la famille. Les collections personnelles ne sont pas réécrites.

La ressource `scenes/planet/cave/libraries/cave_rock_exterior.tres` est reliée au champ **Entrance Library** des palettes complètes ; elle peut être remplacée indépendamment. Les modèles sont dans `scenes/planet/cave/assets/rock_exterior/`, leur source Blender dans `assets_blender/stargrot/exterior/`. Voir le README de ce dossier d’assets pour reconstruire la bibliothèque. La scène `test/stargrot/test_entrance_rocks.tscn` produit les captures de contrôle. Les réserves visuelles du bilan du 24 octobre restent distinctes de cet habillage.

Mise à jour du 24 octobre 2026 : intégration sur `develop` à la révision `509148dc81a54061ec1422dbe78d03af4ac8648b`. Voir `STARGROT-RELEASE-2026-10-24.md` pour les preuves de compatibilité et les limites.

Lancer localement `Lancer-StarGrotte-Atelier.cmd` depuis le dossier outputs. Dans Godot, ouvrir `levels/stargrot/stargrot_explorer.tscn` avec les arguments utilisateur `--stargrot-explorer --stargrot-workbench`.

L’atelier est un outil de développement : il n’est pas exporté avec le jeu (`exclude_filter` des presets d’export). Les grottes livrées (catalogues) et le module qui les construit (`scenes/planet/cave/`) le sont.

## Placer comme dans un STR

1. Dans **Création**, choisir une famille et un gabarit, puis **Nouvelle grotte aléatoire**. Préparer la forme pour le placement.
2. Dans **Placer**, choisir la planète et cliquer **Placer sur le terrain**. La fenêtre du terrain passe en vue surélevée.
3. Survoler le sol chargé : le trait turquoise montre le seuil d’un porche (ou le contour d’une doline). Molette : orientation, utile seulement sur terrain plat ; sur une pente, le porche s’oriente seul vers l’amont. ZQSD / WASD : déplacement de la vue ; Espace / Ctrl : monter / descendre.
4. Cliquer pour créer et sauvegarder la grotte. Clic droit ou Échap annule le mode de placement. La caméra reste au-dessus du résultat. Le bouton **Placer une grotte** permet de recommencer.

La navigation de l’atelier utilise uniquement les touches clavier configurées dans le jeu. Les axes d’une manette ou d’un joystick branché ne pilotent pas cette caméra. Relâcher la touche arrête le déplacement ; quitter la fenêtre, ouvrir l’atelier ou lancer un placement efface les commandes retenues. Après un changement de fenêtre, appuyer à nouveau sur la touche pour repartir.

Le site choisi est maintenu par les secteurs épinglés natifs pendant le placement, puis libéré à l’exploration ou en orbite. Le clic porte sur le véritable terrain physique de la planète sélectionnée, jusqu’à 6 km de la caméra. Les bâtiments, les parois des grottes et le ciel ne sont pas des supports. Approcher une région et attendre son chargement avant de la sélectionner. Un éclairage d’atelier aide le placement de nuit ; reprendre l’exploration retrouve l’éclairage normal.

**Peupler** génère un lot selon les biomes disponibles et le relief mesuré : porches sur les versants et pieds de pente, dolines ou porches plongeants sur terrains plats, dolines sur terrains volcaniques. Jusqu’à 512 sites par planète. Il s’agit de règles de plausibilité, pas d’une simulation géologique. Les sites non compatibles avec le terrain ou trop proches sont refusés avec un bilan.

**Placer** conserve les corrections précises, la navigation, la suppression unitaire ou par planète et l’annulation de la dernière suppression / du dernier remplacement.

**Livrer** exporte les sites validés vers le jeu. Le catalogue ne dépend pas de l’interface de l’atelier. Voir [le guide d’intégration](STARGROT-LIVRAISON-DEVELOP.md).

## Décors roche sculptée

Les nouveaux brouillons **Roche** utilisent le premier lot artistique : trois blocs, un éboulis, une stalagmite et une stalactite. Dans **Création**, les palettes **Roche sculptée — salles et profondeur** et **Roche sculptée — bouche ouverte** sont disponibles. Les anciennes grottes conservent leur bibliothèque.

Les six décors sculptés utilisent maintenant **Rock029**, la texture déjà employée par les rochers natifs de Dying Star : couleur, normales et rugosité dans `assets/textures/grounds/rock/`. Leur matériau partagé conserve les teintes des sommets et emploie une projection triplanaire, sans copier les images ni modifier les rochers du jeu de base. Réimporter les modèles conserve ce matériau.

Source Blender : `assets_blender/stargrot/stargrot_rock_pilot.blend`. Voir `assets_blender/stargrot/README.md` pour les retouches. Le jeu charge les ressources natives et réutilise ses secteurs ; Blender n’est pas nécessaire pour jouer. Les blocs ont des collisions simples, les petites formations restent visuelles.

## Habillage procédural et anciennes grottes

Les lots rocheux utilisent désormais la palette sculptée. Les palettes personnelles restent conservées quand elles correspondent au biome. Les anciens sites gardent leur bibliothèque jusqu’à une action explicite.

Pour les habiller : sélectionner la grotte, choisir la bibliothèque dans **Création**, puis utiliser dans **Placer** **Habiller cette grotte avec la bibliothèque choisie** ou **Habiller les grottes de cette famille sur la planète**. L’action est sauvegardée et annulable ; elle conserve formes, graines, coordonnées et ajustements au relief. Une palette Roche ne remplace pas les palettes Glace ou Sable.

Les blocs occupent les côtés des salles et galeries ; les éboulis forment des amas localisés ; les stalagmites demandent un sol peu incliné ; les stalactites nécessitent un vrai plafond. Les limites de pente, les supports réels et les volumes disponibles sont vérifiés. Les bords des passages restent dégagés. La répartition dépend de la graine et n’est plus un anneau régulier autour des salles. Les porches disposent de leur propre habillage sur leur sol réel et leur voûte.

L’aperçu affiche la bibliothèque active, le nombre de décors placés et de modèles utilisés. Le bouton **Décors** place la caméra dans une salle avec un éclairage d’inspection pour voir les modèles de près. Le calcul des positions utilise les workers existants avec des données simples ; l’assemblage réutilise le résultat et les MultiMesh. Le budget reste de 120 occurrences par assemblage, avec résidence native.

## Bruit des formes

**Relief bruité des sols et galeries** règle le bruit volumétrique déjà partagé par le visuel et la collision du réseau v8. **Érosion des galeries** (version 9) déforme les galeries elles-mêmes (voir plus bas). **Érosion bruitée de l’entrée** ajoute un champ cohérent à plusieurs échelles aux contours et au relief intérieur du porche, et varie la doline. Ce sont des déformations de géométrie, pas seulement un effet de matériau. Les contours érodés sont découpés exactement en morceaux convexes ; le bruit s’annule sur les raccords.

Les anciennes définitions v8 ont une érosion d’entrée à zéro et conservent leur forme. Les nouveaux brouillons l’activent à 0,55. Modifier la géométrie d’un ancien site demande de la régénérer / la replacer ou de la recaler ; **Habiller** ne change que ses assets.

## Lumière

Dans l’atelier, **+ / −** (pavé numérique, ou la touche `=` / `-`) avancent ou reculent l’horloge d’une heure, comme dans le jeu de base ; maintenir la touche fait défiler le ciel. La hauteur du soleil s’affiche en haut à gauche. L’horloge revient à l’heure normale à la fermeture de l’atelier.

## Versions 8 et 9 : salles

Chaque grotte suit un **type de réseau** inspiré des grottes réelles (classification de Palmer), choisi dans **Création** ou tiré par la graine (« automatique ») :

- **Ramifié** : un tronc et ses affluents, galeries principales plus larges, une grande salle de temps en temps ;
- **Labyrinthe de fissures** : failles et petits carrefours sur une grille de fractures, un seul niveau ;
- **Anastomosé** : tubes bas tressés sur un plan de strate, beaucoup de passages où ramper ;
- **Éponge** : de nombreuses petites cavités reliées, de toutes tailles ;
- **Ramiforme** : de grandes salles d’où rayonnent des branches et des culs-de-sac ;
- **Gouffres en cascade** : cheminées et puits successifs vers la profondeur.

Le type fixe le nombre de salles, leur distribution de tailles (log-normale autour d’une part de la « taille des grandes salles », avec une salle repère et parfois une salle géante au-delà), les familles, les embranchements, les boucles et les sections des galeries : tube, canyon, trou de serrure (tube perché sur un canyon), passage bas. Les galeries méandrent.

Treize familles de salles en version 9 (sept en version 8) : cathédrale, niche, faille, salle basse, salle d’effondrement au sol chaotique, cheminée, salle à lobes, et désormais :

- **Dôme** : plan rond, coupole qui monte plus haut que le rayon de la salle ;
- **Grande galerie** : salle très allongée et rectiligne, au sol en légère pente ;
- **Salle en gradins** : sur un sol en pente, des paliers plats séparés par des ressauts, dont certains restent des rampes praticables ; le pourtour reste une pente continue ;
- **Forêt de colonnes** : salle large et basse dont le plafond plat repose sur 5 à 18 colonnes, espacées pour passer entre elles et à l’écart des arrivées de galeries ;
- **Salle à vasque** : une cuvette au milieu du sol, à pente praticable, prévue pour un futur lac ; la voûte ne suit pas la cuvette ;
- **Salle à balcon** : salle haute avec une corniche perchée dans sa paroi.

Orientation, forme de voûte, pente et relief du sol propres à chaque salle. Le relief des parois est un bruit de gradient différent pour chaque grotte.

Les salles sont réparties en trois dimensions : embranchements, boucles, culs-de-sac, puits, gouffres barrant une galerie, fenêtres en hauteur, rampes en spirale. Les galeries arrivent sur le pourtour des salles ; le centre reste libre pour les gouffres et les piliers.

En version 9, les jonctions sont plus sûres :

- une galerie termine sa pente au mur de la salle, puis suit le sol de la salle jusqu’à son seuil, sans déboucher sur une corniche ;
- le relief du sol se calme sur l’anneau des seuils ;
- deux galeries ne partent plus du même seuil ;
- une galerie n’est jamais plus large que 1,2 fois la plus petite salle qu’elle relie ;
- culs-de-sac et boucles évitent les galeries déjà tracées ;
- le gouffre sous un pont rocheux laisse une corniche (55–60 % du rayon) ;
- la pente d’un passage large se prolonge sous les arrondis voisins, ce qui supprime les marches de 2 m ;
- le conduit d’une doline ne creuse plus de cuvette sous le point d’arrivée.

Sur 48 grottes de test, la part traversable mesurée passe d’une médiane de 54 % (v8) à 76 % (v9), pour une cible de 70 %.

En version 9, les obstacles ressemblent davantage à la grotte elle-même :

- pour barrer une galerie, le générateur préfère une **fenêtre en hauteur** dans la paroi de la salle. Le **gouffre en travers** du passage n’est retenu qu’en dernier recours ou pour une cible basse : sur 80 grottes de test, 12 gouffres barrants contre 35 auparavant ;
- une longue galerie sur dix croise un **gouffre franchissable** : un trou contre une paroi, en laissant un rebord praticable, ou un gouffre sous un **pont rocheux naturel** au tablier presque plat, large de 3,6 à 5,6 m. Aucun de ces gouffres n’entame une autre galerie, à côté ou en dessous ;
- plus de **passages très bas successifs** en bout de réseau : ces étroitures de 1 m menant à de petites bulles disparaissent (le réglage n’existe plus que pour les définitions version 8).

Les surfaces de la grotte et des entrées sont **lissées** : chaque sommet moyenne les faces voisines qui ne tournent pas de plus de 60°, ce qui efface les facettes du maillage sans arrondir les vraies arêtes.

En version 9, les volumes se rejoignent par une **union douce** (congé d’environ une maille, 1 à 2,5 m) au lieu d’un maximum franc : la roche laissée entre deux salles, entre une galerie et une paroi ou au pied d’une colonne est arrondie, plus d’arête en lame de couteau ni d’angle droit. Les colonnes et piliers ont au moins 1,6 maille de rayon, sans quoi la grille les maillait en prismes carrés, et portent le même relief bruité que les parois : cannelés et irréguliers, plus des cylindres tournés aux arêtes droites. Les définitions version 8 gardent le maximum exact.

Dans une grotte, le terrain ne dessine plus ses **tuiles périmées** : une tuile grossière gardée à l’écran le temps que ses remplaçantes plus fines se chargent (surtout après un saut comme **Début : entrée**) passe plusieurs mètres sous le sol fin, et son matériau double face traversait les galeries comme une dalle plate de sol. Elle est masquée tant que la caméra est dans la roche (réseau, galerie du porche, gorge d’une doline ou d’un puits), et revient en sortant.

**Part du sol traversable à pied visée** (70 % par défaut) : le générateur ajuste les obstacles vers cette cible, puis la part réelle est mesurée sur la grille de la grotte (capsule de 1,8 m, pente ~45°, petites marches). Entre deux colonnes voisines de la grille, la hauteur libre est mesurée à mi-chemin, ce qui ne pénalise plus les passages en pente. L’atelier l’affiche ; le bouton **Traversable** colore le sol (vert : atteint à pied depuis l’entrée, rouge : non).

La grille est creuse (blocs de 16³ alloués où un volume passe) : un réseau étalé ne paie pas sa boîte englobante. Un réseau géant passe à une maille plus grossière plutôt que de produire des millions de triangles. Les blocs sont évalués et maillés en parallèle sur tous les cœurs, puis assemblés dans un ordre fixe : le résultat est identique au triangle près, 3 à 4 fois plus vite (environ 0,5 s pour une grotte moyenne).

## Version 9 : galeries érodées et puits de lumière

**Érosion des galeries** (0 à 1, 0,6 par défaut) : des champs de bruit lents, communs à tous les tronçons pour que la galerie reste d’un seul tenant, la rétrécissent et l’élargissent (±35 %), décentrent sa section (±20 %), relèvent ou abaissent sa voûte et y creusent des cloches de dissolution, avec des parois plus fouillées. Le sol garde sa pente. La largeur ne descend pas sous 3,2 m ni la hauteur sous 2,6 m, sauf si la galerie était déjà plus étroite ou plus basse. La galerie d’entrée s’érode progressivement sur ses 20 premiers mètres, pour rejoindre proprement le vestibule.

**Puits de lumière naturelle** (0 à 4, au plus) : un conduit vertical monte d’une voûte jusqu’au sol et ouvre un petit trou irrégulier dans le terrain. Le générateur choisit les voûtes assez hautes dont la colonne de roche est libre. Le conduit ne perce aucun sol situé au-dessus, aucune colonne ni aucun pont, et reste à distance de la doline et des autres puits. Il démarre au-dessus du relief du sol, donc sans trouer le plancher.

Au placement, l’ajustement au relief fixe la position et la profondeur de chaque puits, et les parois du conduit montent jusqu’au terrain réel. Une grotte recalée l’est avec ses puits. La lumière du jour entre par ces trous ; les faisceaux visibles viendront avec le travail sur l’éclairage.

Les définitions version 8 ne reçoivent ni érosion des galeries ni puits, et gardent exactement leur géométrie (empreintes vérifiées par `test_stargrot_v9.gd`).

## Entrées et sortie

- **Porche de versant ou de falaise** (et **Grand porche**) : une galerie creusée dans le relief à partir du point cliqué. Horizontale dans une falaise, en pente douce dans un versant, plongeant à 24° dans un sol plat. L’ouverture est l’intersection exacte de la galerie et du terrain. Un porche haut et étroit devient une faille pointue, un porche large une ogive. Le sol reste praticable à pied.
- **Abord du porche** (version 9) : le porche ne s’ouvre plus comme un trou dans la pente ou une tranchée droite, qui faisait carrière. Il s’ouvre au pied d’une falaise d’environ 72°, qui s’enroule autour de la bouche avec un bourrelet d’éboulis à son pied. L’ajustement garde 2,5 m de roche au-dessus de la voûte, soit une falaise plus haute que la bouche. L’abord dépend du relief :
  - **cuvette d’effondrement** en sol peu pentu : un sentier descend à la pente du porche entre des tabliers d’éboulis (18° près du sentier), avec des amas de pierres dans la partie haute. Les berges se raidissent à 30–56° jusqu’au sol, avec des baies et des éperons, un côté plus large que l’autre ;
  - **encoche** dans un versant de montagne (jusqu’à 50°) : une terrasse de niveau devant la bouche et des flancs de 50 à 78°, d’autant plus raides que le versant l’est ;
  - **falaise** au-delà de 50° : le relief est déjà la paroi, le porche y entre directement.

  L’abord est un champ de hauteur calculé à partir du profil et de l’ajustement enregistré (la pente du versant s’en déduit). Son bord est posé sur le vrai terrain, et il a sa propre découpe et sa propre présence. Le bord est scellé au terrain affiché (voir **Raccord au sol**). Les tuiles de terrain déjà découpées par une version précédente sont recalculées (étiquette de cache `_sg5_`).
- **Raccord au sol** (toutes les entrées) : le sol de la planète recouvre les surfaces à l’air libre (bord de l’abord, lèvre des dolines et des puits, cuvette de sortie), avec sa propre texture et sa teinte. La couverture est pleine au niveau du terrain et disparaît 1,5 m plus bas sur la roche raide, 6 m plus bas sur les replats où neige et sable s’accumulent. Sa lisière est irrégulière. C’est une passe superposée, comme la frange de sol des bâtiments : les matériaux de la grotte ne changent pas.
  Le terrain affiché est un maillage d’environ 25 m de maille posé sur un relief plus fin : au bord d’une découpe, il passe jusqu’à ~0,6 m au-dessus ou au-dessous du bord de la grotte, ce qui laissait une fente noire entre le sol et la grotte. Chaque bord à l’air libre (abord du porche, doline, puits de lumière, sortie) est maintenant **scellé** : une lèvre étroite monte de 0,6 m juste à l’extérieur de la découpe et replonge sous le sol à 1 m, une collerette repart jusqu’à 3 m (1 m sous le relief à son bord) et un rideau de 2 m pend sous elle. La lèvre disparaît là où le sentier de l’abord entre au niveau du sol. Le tout reçoit la couverture de sol.
- **Doline** : un grand trou irrégulier ouvert dans le sol au-dessus d’une salle en cloche. Lèvre rocheuse à parois raides, chute verticale jusqu’au sol de la salle. L’ajustement garde au-dessus du réseau une croûte proportionnée à l’ouverture : 2 m + 0,3 × le rayon de l’oculus (au plus 30 m), soit ~18 m pour une doline de 100 m, au lieu des 3 m de couverture qui en faisaient une feuille de papier. Une doline déjà placée garde son ancien ajustement jusqu’à **Peupler → Recaler les grottes sur le relief actuel**.
- **Sortie** (optionnelle) : une cuvette altérée au bout du réseau. **Avancée de la bouche de sortie** règle sa portée.

**Érosion bruitée de l’entrée** (0 à 1, 0,55 pour les nouvelles définitions) : un bruit cohérent et seedé creuse ou repousse le contour depuis son centre — encoches, becs rocheux, fissures asymétriques, bords de doline festonnés — sur deux échelles de détail. Le seuil d’un porche reste plat. Le contour concave est découpé dans le terrain en morceaux convexes qui le pavent exactement ; parois, découpe et présence suivent la même forme. Dans une doline, les parois de l’entonnoir prennent des corniches et des surplombs. À 0, le contour lisse historique est conservé.

L’ajustement au relief est enregistré dans le placement (décalage du réseau, pente et longueur du porche, profondeur, puits de lumière) : la découpe du terrain n’interroge jamais le relief en jeu. Un site sans ajustement est refusé avec « Entrée non ajustée au relief » : **Peupler → Recaler les grottes sur le relief actuel** le remet à jour.

## Qualité et compatibilité

Seules les versions 8 et 9 du générateur sont prises en charge. Les versions 1 à 7 (galeries balayées, entrées rectangulaires), leurs réglages (style de section, expansion des salles) et la scène de démonstration ont été retirés ; une définition plus ancienne est refusée avec un message explicite et doit être régénérée. La grotte initiale et le catalogue d’exemple de Tarsis 3 sont en version 9.

Base : `develop`, `b4f834df9142f9af7ed92174d8c8ab23431fe64e`. Tests unitaires : `test/unit/test_stargrot_*.gd` (dont `test_stargrot_v8.gd`, `test_stargrot_v9.gd` et `test_stargrot_portal.gd`), avec des sites synthétiques communs dans `test/unit/stargrot_fixture.gd`. Scénarios sur Tarsis dans `test/stargrot/` : population de 200 sites, catalogue livré, placement créatif et au clic, porche au pied d’une falaise, doline et puits de lumière (rayons physiques, captures dans `.stargrot-validation/`). Le script `tools/stargrot/verify_develop.ps1` rejoue les contrôles après une évolution de develop.

SOLID / DRY / KISS : contrôleur de curseur séparé de l’interface, préparation et validation communes pour clic / coordonnées / lots / recalage, sauvegarde atomique commune, chargement par la résidence native des secteurs. Aucun atelier au démarrage normal du jeu.
