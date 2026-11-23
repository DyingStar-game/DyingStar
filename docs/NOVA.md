# Nova

> Ce qui n'est pas dans le dépôt : les captures citées ici (`docs/nova_captures/…`) et les sources Blender des
> roches (`assets_blender/nova/…`, 217 Mo) sont restées en local chez l'auteur ; les roches livrées sont dans
> `scenes/planet/nova/assets/` et se reconstruisent avec `tools/nova/`. Les crédits des textures de sol sont
> dans le fichier `tex_<nom>.txt` de chaque dossier de matière (l'ancien `source.txt`).


Outil de l'éditeur Godot pour habiller les biomes d'une planète : le sol et ce qui est posé dessus.
Prototype, branche `feat/nova`.

## Ce qui est décidé

1. **QGIS décide *où*, Nova décide *quoi*.** Les zones, le relief, les POI et les routes restent dans
   QGIS et ses exports (`assets/qgis/export/<corps>_chunks/`). L'outil les lit, ne les modifie jamais, et ne
   touche ni aux calques (`tools/planettech/qgis/layers/`) ni aux formats d'export.
2. **Chaque corps est unique, par héritage vivant champ par champ :**
   `archétype` (catalogue, par `biome_type`) → `biome du corps` → `variante`.
   Un fichier ne contient que les champs qu'il surcharge ; « revenir à la base » efface la surcharge.
3. **Variantes découvertes dans l'export.** Une variante est un `biome_type` plus ses attributs QGIS
   *discrets* (texte : `rock_type`, `clarity`…). Les attributs numériques (`density`, `depth`…) ne créent
   pas de variante. Sur Tarsis 3 : un seul biome (`outcrop-plateau`) et une variante par corindon.
   Le sol hors zone est la variante `_default` du corps.
4. **`rocks.json` reste la vérité sur la couleur des roches** (option A). L'outil ajoute par-dessus :
   textures, relief de détail, transitions, scatter.
5. **Couches traitées en premier : le sol et le scatter.** Ambiance, gameplay, ressources : plus tard.
6. **Plugin de l'éditeur**, données en `.tres` dans git, un fichier par biome de corps et par variante.

## Exigences

- **Transitions douces** entre variantes, sans arête nette.
- **Le même rocher pour tout le monde**, serveur compris, et au même endroit quel que soit le LOD.
- **Aperçu rapide** : changer l'aspect du sol ne régénère rien ; changer le scatter ne refait que les rochers.

## Architecture

| Pièce | Fichier | Rôle |
|---|---|---|
| Schéma | `scenes/planet/nova/nova_schema.gd` | La liste des réglages (type, défaut, bornes, aide). |
| Profil | `scenes/planet/nova/nova_profile.gd` | Un fichier : les surcharges `clé → valeur`. |
| Corps | `scenes/planet/nova/nova_body.gd` | Découverte des variantes, héritage, ids, matériau, textures. |
| Scatter | `scenes/planet/nova/nova_scatter.gd` | Placement déterministe et rendu par chunk. |
| Plugin | `addons/nova/` | Le panneau « Nova ». |

Données : `res://nova/archetypes/<biome_type>.tres`, puis
`res://nova/bodies/<corps>/<biome_type>.tres` et `.../<biome_type>/<variante>.tres`.
Le corps est actif dans l'outil dès que `bodies/<corps>/_default.tres` existe.

### Sol

- Chaque sommet de chunk reçoit l'**id de sa variante** (C# `TileFrameNative.SetVertNova`, et la boucle
  GDScript pour les sommets qu'elle traite). Les ids suivent l'ordre trié des variantes découvertes : ils ne
  changent qu'avec un ré-export des zones.
- Le chunk écrit une **palette de 4 variantes** (une pour le chunk, passée au shader par instance) et le
  **poids** de chacune par sommet (`CUSTOM3` ; `CUSTOM2` porte le fondu des niveaux de détail).
  Près d'une frontière, un sommet échantillonne les zones sur trois anneaux (jusqu'à 1,6 maille) : ses
  poids sont la part de chaque variante autour de lui, et sa teinte de roche est mélangée de même
  (`PlanetChunk.nova_soft_weights`, `nova_blend_colors`). Interpolés sur les triangles, ils placent le
  fondu sur le vrai contour de la zone, pas sur l'escalier de la grille ; le shader le resserre avec la
  luminosité de la texture (« Netteté des transitions »).
- Les réglages de chaque variante sont dans une **texture de paramètres** et deux **tableaux de textures**
  posés sur un matériau propre au corps : les modifier ne reconstruit aucun chunk.
- Les zones prises par l'outil ne passent plus par une surface de mesh séparée (`terrain_material_override`).
- Cache : dossier `user://chunk_cache_nova/`, pour ne jamais vider le cache normal.

### Scatter

- Chaque couche place au plus un objet par **cellule HEALPix** d'un niveau fixe choisi d'après sa taille de
  cellule. Tout (présence, position dans la cellule, rotation, échelle, objet) est un hachage entier de
  `(graine de la couche, face, ix, iy)` : même résultat sur toute machine, sans aléatoire ni ordre.
- Les cellules d'un chunk sont exactement les sous-pixels de sa tuile : le rocher posé par un chunk fin et
  par son parent est le même. Une couche n'apparaît que sur les chunks assez fins (au plus 4⁸ cellules).
- La **direction** d'un objet est celle de sa cellule (jamais la grille, que les bords de crevasse
  déplacent) et sa **variante** est lue dans les zones à cette direction exacte (`zone_context`) : seule la
  **hauteur** vient de la grille du chunk affiché, pour qu'il repose sur le sol que le joueur voit.

### Seconde matière du sol

Une variante peut mélanger une seconde matière (sable, poussière…) à la première : sa texture, sa normal
map, sa taille de motif et son gain, la part du sol qu'elle couvre et la taille de ses plages. Un bruit lent
dit où elle se trouve, et elle prend d'abord les creux de la première (ses texels sombres) : le bord d'une
plage suit le grain de la roche au lieu d'un fondu plat. Elle est teintée par la roche comme la première.
Les roches du scatter gardent la première matière. À régler avec « Variation à grande échelle » et
« Anti-répétition », qui existaient déjà. Une texture sombre demande un gain fort : le régolithe gris du
projet (`regolith_grey`, clarté moyenne 0,16) faisait des flaques noires ; `regolith_grey_2` (0,82) convient
avec le gain par défaut.

### Occlusion, rugosité, hauteur ; matières d'ambientCG

- Une matière du sol peut porter une troisième image (« Occlusion, rugosité, hauteur », une carte par canal
  rouge / vert / bleu) : les creux s'assombrissent, la surface brille ou non point par point, et la seconde
  matière remplit les vrais creux (la hauteur) au lieu des texels sombres. Les roches du scatter s'en
  servent aussi.
- `assets/_universe/_shared/materials/mat_rock_cracked_062/` et `mat_gravel_slate_040/` viennent
  d'ambientCG (Rock062 et Gravel040, 1K, licence CC0 1.0 ; voir `source.txt` dans chaque dossier). La
  couleur est convertie en gris et étirée vers un gris moyen clair (moyenne linéaire ~0,46) : c'est la
  couleur de la roche (`rocks.json`) qui la teinte, et une texture sombre éteindrait cette teinte.
- Le corindon rouge laiteux de Tarsis 3 les utilise : roche fissurée (motif de 13 m) et plages de gravier
  (motif de 2,5 m). À 6 m, le motif de la roche dessinait une grille visible depuis 25 m de haut.

### Motif fin de près

« Motif fin de près (m) » : près de la caméra, les textures du sol sont relues avec un motif plus petit (plein
jusqu'à 5 fois sa longueur, disparu à 18 fois : 15 m et 54 m pour 3 m), avec la même anti-répétition que le
grand motif. Le grand motif, choisi pour ne pas se répéter vu de loin, ne fait que quelques dizaines de
texels par mètre aux pieds du joueur. Les roches du scatter utilisent ce motif fin, et choisissent
nettement entre leurs trois projections : avec le grand motif (13 m) un rocher d'un mètre montrait un
treizième flou de la texture, et un mélange large des projections y laissait de longues traînées.

### Roches de corindon

- **Modèles** : `tools/nova/build_corundum_rocks.py` (Blender sans fenêtre, comme les rochers de StarGrotte)
  fabrique 11 modèles — 3 affleurements stratifiés, 3 dalles, 3 rochers, 2 éboulis, 2 492 triangles au total.
  Source et aperçus dans `assets_blender/nova/corundum/`, GLB dans `scenes/planet/nova/assets/rock_corundum/`
  (option `--export`). Géométrie seule : pas de texture ni de matière par modèle, une couleur de sommet qui
  porte l'ombrage propre de la forme, pas de dessous, pied enfoncé dans le sol.
- **Matière du sol** (réglage du scatter, coché par défaut) : l'objet porte les textures du sol de sa zone,
  posées par position, et la teinte de sa roche (`NovaScatter.ground_material`). Un même modèle sert tous les
  corindons et ne jure jamais avec le sol.
- **Amas** (« Taille des amas », « Part du sol en amas ») : un bruit lisse, fonction des seuls entiers de la
  grille de la planète comme les objets eux-mêmes, garde les objets par plages et laisse le sol dégagé
  entre elles. Même résultat sur toute machine et à tout LOD.
- **Autour de la caméra seulement** : un objet est dessiné jusqu'à 120 fois sa taille, et une couche n'est
  posée sur un chunk que si son plus gros objet peut y être vu (`PlanetTerrain._nova_layers_near`, revu tous
  les 30 m de déplacement de la caméra ; une couche posée reste jusqu'à 1,25 fois cette distance). Posé sur
  tout le terrain chargé, le scatter faisait 1,2 million d'objets dans 125 000 nœuds sur Tarsis 3 : 9 à 20
  images par seconde, des blocages de 1 à 4 s, 2,5 Go. Autour de la caméra : environ 13 000 objets dans 450
  nœuds, 111 à 119 images par seconde, pire image de 20 à 40 ms, 1,2 Go.
- Pendant qu'une vue jeu tourne, l'aperçu du corps dans l'éditeur est mis en pause.
- Réglé sur le corindon rouge laiteux de Tarsis 3
  (`nova/bodies/tarsis_3/outcrop-plateau/clarity-milky__rock_type-corundum_red.tres`) : quatre couches,
  affleurements procéduraux (amas de 500 m), gros blocs scannés (300 m), blocs moyens scannés (120 m),
  éboulis près du joueur (vus jusqu'à 160 m). Pas de collision.

### Roches scannées

- **Modèles** : 9 rochers photogrammétrés de Poly Haven, licence CC0 1.0 (auteurs et liens dans
  `scenes/planet/nova/assets/rock_scanned/SOURCES.txt`). `tools/nova/build_scanned_rocks.py` (Blender sans
  fenêtre) les allège (776 à 4 364 triangles), pose leur origine au sol, passe la couleur en gris clair,
  réduit les textures à 1 024 px et range occlusion et rugosité dans une seule texture ; un GLB par modèle.
  Sources téléchargées dans `assets_blender/nova/scanned/`.
- **Teinte de la roche** (réglage du scatter, ex-« Matière du sol ») : un modèle texturé garde ses textures
  et reçoit la teinte de la roche de sa zone par-dessus son gris (`NovaScatter.dressed`) ; un modèle sans
  texture porte en plus celles du sol. Le même rocher scanné sert donc toutes les roches du jeu.
- **Distance de vue** (réglage du scatter) : 0 = 120 fois la taille de l'objet ; une valeur courte permet une
  couche dense de petits débris autour du joueur sans coût au loin.
- Un GLB d'un seul maillage est pris tel quel (normales, tangentes, niveaux de détail) ; seules les scènes
  de plusieurs maillages sont reconstruites (`NovaScatter.load_mesh`).
- Mesuré dans la vue jeu avec quatre couches de roches scannées et procédurales : 114 à 120 images par
  seconde, pire image de 21 à 37 ms, 23 000 à 30 000 objets dans moins de 500 nœuds.

### Roches sculptées

- **Modèles** : `tools/nova/build_sculpted_rocks.py` (Blender sans fenêtre, option `--render` pour les
  aperçus, environ 6 minutes) fabrique 18 modèles : 3 grandes corniches (22 à 38 m, ~3 850 triangles),
  4 affleurements (~2 350), 4 dalles (~850), 4 blocs (~670), 3 éboulis (~480). Bancs lités découpés par deux
  familles de diaclases, sculptés en haute définition (0,2 à 2,2 M triangles) puis réduits ; normale,
  occlusion, rugosité et couleur grise cuites depuis la haute définition (1 024 px, 512 px pour blocs et
  éboulis). Source, aperçus et `manifest.json` dans `assets_blender/nova/sculpted/`, GLB dans
  `scenes/planet/nova/assets/rock_sculpted/`.
- Teintées comme les roches scannées (« Teinte de la roche »).
- Corindon rouge laiteux de Tarsis 3, quatre couches : corniches et affleurements sculptés (amas de 600 m),
  gros blocs scannés et dalles sculptées (300 m), blocs scannés et sculptés (120 m), éboulis sculptés près
  du joueur (160 m de vue). Mesuré : 120 images par seconde, pire image de 9 à 12 ms, 26 500 objets dans
  1 430 nœuds.
- Défauts connus : taches sombres dans quelques joints profonds vus de très près, blocs et cailloux un peu
  lisses, deux dalles trop peu enfoncées pour une pente de 20°.
- La vue jeu s'ouvre à 10 h : à midi rien ne porte d'ombre, et la face à l'ombre d'un gros bloc est presque
  noire (peu de lumière ambiante sur Tarsis 3) — juger une roche soleil dans le dos.

### Relief du sol

- Le jeu a déjà un relief de biome (`BiomeRelief`, réglages `relief_*` de `BiomeDefinition`) : une ondulation
  fonction de la seule position, identique dans le maillage et la collision, remise à zéro sur les routes et
  leurs abords, écrasée par les plateformes de bâtiment et les sols de village (nivelés après elle).
- Nova le règle par type de zone : « Relief : creux », « Relief : bosse », « Relief : taille des
  ondulations » (`ground/relief_*`). Vides, le biome garde le sien. `NovaBody.relief_biome` donne aux
  constructeurs de chunks une copie de la définition du biome portant ce relief
  (`PlanetData.biome_of_zone`) ; les réglages entrent dans la clé du cache de maillages, donc un changement
  demande de recharger le corps (le cache se refait).
- Limite du maillage : le relief n'existe que là où le pas des sommets est sous la moitié de l'ondulation.
  Sur Tarsis 3 le pas le plus fin est de 25 m (puis 50, 100 m en s'éloignant) : rien de plus court que
  60 m ne peut exister, et il faut 200 m et plus pour que le relief tienne au loin. Les formes à l'échelle
  du joueur (gradins, marches, blocs) restent le travail des roches posées.
- Corindon rouge laiteux de Tarsis 3 : −4 / +8 m tous les 240 m.
- Le terrain de collision (serveur, et celui de la vue jeu) lit ces mêmes réglages : `PlanetData.nova_relief`
  est ouvert aussi en mode serveur, sans matière ni scatter, et entre dans la clé de son cache. Sans cela le
  joueur à pied marchait sur l'ancien relief, plusieurs mètres sous le sol affiché. Mesuré à pied en quatre
  points du corindon rouge : pieds à moins de 0,7 m du sol calculé (l'écart est l'interpolation entre sommets).

### Troisième matière et couches d'objets

- Le sol mélange jusqu'à trois matières : la première partout, la seconde et la troisième par plages, chacune
  avec son bruit (`ground/layer3_*`, colonnes 5 et 6 de la texture de paramètres ; le shader lit seconde et
  troisième par la même boucle).
- Six couches d'objets par type de zone (`NovaSchema.SCATTER_SLOTS`).

### Roches nettes de près, gradins et graviers

- **Shader de roche** (`scenes/planet/nova/nova_rock.gdshader`, `NovaScatter.rock_material`) : les textures
  d'un modèle sont étirées sur toute sa surface (un ou deux milliers de texels pour un bloc de plusieurs
  mètres : une bavure à bout de bras). Le grain fin vient donc de la texture de roche du sol, posée par
  position dans le repère du modèle, nette à toute taille ; le modèle apporte son relief cuit (normale),
  ses creux (occlusion) et, selon « Part de la texture du modèle » (`own_texture`), ses clairs et sombres :
  1 pour une roche scannée, 0 pour les roches sculptées, dont la couleur cuite dessinait des traits.
- **Modèles ajoutés** (`build_sculpted_rocks.py`, 29 modèles) : 4 gradins de 5 à 7 m de haut (front abrupt,
  revers à 25-29° où l'on monte à pied), 3 bandes de marches de 0,7 à 0,9 m, 4 plaques de graviers de 3 m
  (33 à 55 cailloux, 270 à 350 triangles). Les blocs sculptés ne sont plus posés (les blocs scannés font mieux).
- **Corindon rouge laiteux**, cinq couches : gradins et corniches (amas de 800 m), marches, affleurements et
  dalles (350 m), blocs scannés de 0,6 à 2,4 fois leur taille (160 m), éboulis (vus à 160 m), graviers autour
  du joueur seulement (vus à 60 m, une cellule de 3 m). `MAX_DEPTH` du scatter passé à 8 : au niveau 7 une
  couche plus fine que 6 m n'était pas posée sur les chunks de 800 m de Tarsis 3.
- Mesuré : 152 000 objets en mémoire dans 4 750 nœuds, 118 à 120 images par seconde, pire image de 9 à 14 ms.
- « Aller voir » de la vue jeu pose le joueur au-dessus du sol affiché, relief de biome compris
  (`nova_world.nova_goto`) ; sans cela une arrivée basse se faisait sous une bosse.

### Avant / après

Dans la vue jeu, **B** montre le jeu tel qu'il est sans Nova, puis de nouveau avec : le monde est reconstruit
au même endroit, même regard, en 8 à 12 secondes (`nova_world.toggle_nova`, `NovaBody.disabled`). L'état est
écrit en haut à gauche (« AVANT — le jeu actuel, sans Nova » / « APRÈS — avec Nova »). En « avant », le panneau
de l'éditeur ne pilote plus la vue (le lien Nova n'existe qu'avec Nova).

### Tuilage hexagonal

- « Tuilage hexagonal » (`ground/hex_tiling`, par type de zone) : chaque projection des trois matières du
  sol est pavée de triangles, chaque coin décale la texture d'un écart au hasard, et les trois lectures sont
  fondues selon la distance aux coins et la hauteur de la texture (`nova_hex_plane`, `nova_hex_tri` dans
  `terrain_biome.gdshader`). Plus de quadrillage dans les plages de gravier et de poussière vues de haut,
  sans le flou de l'ancienne anti-répétition, qu'il remplace. Le pavage se referme là où la texture se
  referme (tous les 8 192 m), donc sans couture entre chunks.
- La hauteur ne pèse que sur la couture entre deux lectures : pesée davantage, la plus haute gagnait
  partout et les fissures sombres disparaissaient.
- Garder un grand motif : à 4 puis 9 m le sol perdait ses grandes craquelures vu de loin. Corindon rouge :
  motif de 20 m, détail fin de 3 m de près (hexagonal lui aussi).
- Mesuré au même endroit, avec et sans : 117 à 120 images par seconde dans les deux cas (plafond de l'écran).
- Une vérification lancée avec `NOVA_GAME_PROBE` ouvre une fenêtre qui ne prend pas le clavier.

### Matières de Material Maker

- Material Maker exporte en ligne de commande : `material_maker --export-material --target Godot -o <dossier>
  <fichier.ptex>` donne couleur, normale, occlusion/rugosité/métal et hauteur. `tools/nova/import_ground_material.py`
  en fait les trois images d'un sol Nova (couleur en gris calée sur les autres sols, normale, occlusion /
  rugosité / hauteur).
- « Mars rocky ground » (pixelpoops, materialmaker.org n° 474, CC0), exportée en 2 048 px :
  `assets/_universe/_shared/materials/mat_ground_mars_rocky/`, graphe dans `assets_blender/nova/materials/`.
  En essai comme troisième matière du corindon rouge (motif 3,5 m, 45 % du sol). Sans relief simulé, ses
  pierres se lisent comme des taches plates : c'est la matière qui profiterait d'un SPOM.
- Les textures du sol sont ramenées à 1 024 px dans le tableau de textures de Nova (`NovaBody.TEX_SIZE`).

### Relief simulé de près (SPOM) et projection tranchée

- « Relief simulé de près (cm) » (`ground/parallax_cm`, par type de zone) : jusqu'à 30 m de la caméra
  (plein jusqu'à 12 m), la position où les textures sont lues glisse le long du rayon de vue jusqu'à
  rencontrer la hauteur de la matière qui s'y trouve (le bleu de son image occlusion / rugosité / hauteur),
  en 12 pas plus une interpolation (`nova_parallax` dans `terrain_biome.gdshader`). Pierres et fissures se
  masquent et se découvrent quand on bouge. La silhouette du sol reste plate ; au-delà de 10 cm environ les
  objets posés semblent flotter.
- Le glissement se fait **par projection**, chacune dans son plan : sur une planète, le sol n'est face à
  aucun axe sur l'essentiel de sa surface. Un premier jet, sur la seule projection dominante, ne faisait
  rien à l'endroit du test (direction 0,66 / 0,42 / 0,62).
- **Projection tranchée** (`NOVA_TRIPLANAR_SHARPNESS`, 32) : avec la netteté d'origine (4), ces zones
  mélangeaient à 60 / 40 deux projections étirées, et chaque pierre apparaissait en double. C'est ce qui
  donnait l'effet « pastilles » de Mars rocky ground.
- Corindon rouge : 12 cm. Mesuré avec et sans : 118 à 119 images par seconde.

### Petits cailloux : variantes

- `build_sculpted_rocks.py` fabrique 47 modèles. Ajoutés : 8 pierres isolées (15 à 53 cm, 63 à 129
  triangles, 256 px), 6 plaques de petits cailloux aux caractères différents (fins et denses, épars, traînée
  de vent, couronne, plaquettes, amas ; 231 à 344 triangles) et 4 plaques d'éclats plats (290 triangles).
- Corindon rouge, six couches : les éclats rejoignent les éboulis (7 modèles), les plaques de cailloux
  rejoignent les graviers (10 modèles, densité 0,55 au lieu de 0,75) et une sixième couche pose les pierres
  isolées (échelle 0,8 à 2,6, vues à 70 m).
- Mesuré au même endroit avant / après : 152 700 → 171 600 objets en mémoire, 4 770 → 9 300 nœuds, environ
  1 250 → 1 500 appels de dessin, 113-119 → 119 images par seconde (plafond de l'écran). Chaque modèle de
  plus dans une couche ajoute un nœud par bloc de 100 m : la variété se paie en appels de dessin, pas en
  triangles.
- Le SPOM est à zéro sur le corindon rouge (retiré : l'effet se voyait trop).

### Objets posés sur le triangle affiché

- Le scatter prenait la hauteur du sol par un mélange lissé des quatre coins de la maille ; le terrain
  affiché est fait de deux triangles plats par maille (diagonale i10 - i01). Sur un sol qui ondule les deux
  diffèrent de la torsion de la maille. `NovaScatter.lay_chunk` interpole maintenant sur le triangle.
- Mesuré sur 6 862 objets du corindon rouge (rayon le long de la verticale contre les triangles du chunk) :
  avant, 427 au-dessus du sol, jusqu'à 2,14 m, et d'autres enfouis jusqu'à 2,70 m ; après, aucun au-dessus,
  tous entre 1 et 44 cm sous le sol, ce qui est l'enfoncement réglé.
- Mars rocky ground ramenée à 16 % du sol, en plages de 45 m : à 45 % les mêmes pierres incrustées se
  répétaient à vue d'œil.

### Blocs de scatter près de la caméra

- Un chunk fin (800 m) du corindon rouge porte 1 600 nœuds de scatter (25 modèles × 64 blocs de 100 m).
  Créés d'un coup à l'arrivée du chunk, ils prenaient 24 à 37 ms sur le fil principal : une image perdue à
  chaque chunk en vol. Maintenant les objets posés restent sur le chunk (`nova_laid`) et seuls les blocs
  qu'une couche à courte vue peut montrer reçoivent un nœud, 100 par image au plus
  (`PlanetTerrain._nova_show_blocks`, revu tous les 30 m de déplacement).
- Mesuré en volant 6 km à 200 m/s à 30 m du sol : images de plus de 33 ms 18 à 28 → 2, pire image 98 à
  111 ms → 39 ms, 95 à 101 → 107 images par seconde ; le jeu sans Nova fait 108 à 118, 0 à 6 images lentes,
  pire 26 à 75 ms sur le même trajet. À l'arrêt : 119 avec ou sans (plafond de l'écran, que la sonde n'a
  pas su lever), 171 600 → 23 800 objets en mémoire, 9 300 → 3 300 nœuds.

### Fondu des niveaux de détail (géomorphing)

- Repris de la branche `feat/planet-lod-horizon` (un commit, 16 fichiers), fusionnée à la main dans le code
  de travail : un chunk plus fin apparaît sur la forme de son parent et rejoint la sienne en 600 ms
  (`lod_morph`, pas vers le parent en `CUSTOM2`), les niveaux lointains ont la même grille que les proches
  (`far_tier_res`) et les normales sont sondées à 40 m (`normal_probe_m`). Actif pour tout client.
- Nova a cédé `CUSTOM2` : les poids par sommet sont en `CUSTOM3`, et la palette des types de zone, la même
  pour tout le chunk, est une donnée du chunk (`nova_palette`, méta du maillage puis uniforme d'instance 7).
  `NovaBody.BAKE_VERSION` passe à 2.
- Dans la vue jeu, **L** reconstruit le monde avec ou sans ce fondu (`PlanetTerrain.lod_morph_enabled`). Les
  maillages diffèrent : chaque bascule refait le cache du terrain (une à deux minutes de chargement).
- Tests : admission du terrain (15), vitesse (4), sol lointain (7), pas de fondu (5), chunks et Nova au vert.
- Mesuré en vol (6 km à 200 m/s), cache prêt : 95 à 97 images par seconde, aucune image de plus de 33 ms,
  pire image 28 ms, avec comme sans fondu ; 708 appels de dessin contre 505 avant (niveaux lointains plus
  denses). Cache en cours de reconstruction : 83 à 87, 7 à 19 images lentes.
- Non mesuré : le gain sur le popping. Une sonde qui compare chaque image à la précédente pendant une
  montée de 30 m à 3 km ne distingue rien (le mouvement domine), et le nombre de rochers affichés décroît
  sans creux. À juger à l'œil, en mouvement (jugé réduit par Hugo le 16/11/2026).

### Fondu d'apparition des rochers

Un rocher n'apparaît plus d'un coup à sa distance d'affichage : il **sort du sol**, de la taille 0 à sa taille
sur les derniers 20 % de cette distance (`nova_rock.gdshader`, `FADE_BAND`). Pas de transparence ni de trame :
le coût est nul, et l'ombre grandit avec lui.

- La distance est prise dans le repère de la planète, jamais en coordonnées monde (des flottants simples dans
  un shader : loin de l'origine, elles s'arrondissent de dizaines de mètres). Chaque position est coupée en
  cases entières de 1 024 m (`NovaScatter.FADE_CELL_M`) et un reste, tous deux exacts : la caméra (deux
  globales de shader `nova_cam_cell` / `nova_cam_rest`, écrites chaque image par `PlanetTerrain`), le centre
  du chunk (par nœud, `fade_cell` / `fade_rest`) et la place du rocher dans son chunk (donnée d'instance du
  MultiMesh : une ligne fait maintenant `NovaScatter.ROW` = 16 flottants).
- Une couche est posée un pas d'avance (`NOVA_RELAY_STEP_M`, 30 m) : posée juste à sa distance, elle arrivait
  jusqu'à un pas en retard, ses rochers déjà à moitié sortis.
- Conséquence : les rochers les plus lointains d'une couche sont plus petits qu'avant (à 90 % de la distance,
  demi-taille). Vérifié en capture au même endroit : de près, rien ne change.
- Mesuré en vol (6 km à 200 m/s) : 105 images par seconde, 1 à 2 images de plus de 33 ms, pire 39 à 45 ms.
- Une seule règle de distance (`NovaScatter.view_of`) pour poser une couche, couper ses nœuds et faire
  sortir ses rochers. Avant, la pose comptait l'échelle maximale et l'affichage non : des couches étaient
  posées bien au-delà de ce qui se dessinait (23 800 objets en mémoire au même endroit, 13 700 maintenant,
  même image).
- Pas couvert : les surfaces sans texture d'un modèle (matériau du sol, `ground_material`) n'ont pas ce fondu ;
  un rocher change encore de hauteur d'un coup quand le sol sous lui change de niveau de détail, alors que le
  sol, lui, glisse en 600 ms.

### Frontières douces

Avant, deux sols se rejoignaient sur environ 3 mailles (75 m de près, plus loin davantage), en simple fondu,
le long du tracé exact de la zone, et le scatter s'arrêtait net sur la ligne. Captures de la même frontière
(corindon rouge / corindon rose, vue de 400 m) : `docs/nova_captures/frontiere_avant.png` et
`frontiere_apres.png`.

- **Largeur en mètres** : réglage « Largeur des transitions (m) » (`ground/transition_m`, 150 par défaut,
  0 à 600), par variante. Chaque sommet échantillonne les zones sur trois anneaux jusqu'à cette distance
  (`PlanetChunk.nova_soft_weights`) : la bande est la même à tous les niveaux de détail, jamais plus étroite
  que 1,6 maille. Cuit dans le maillage : la valeur entre dans la clé du cache, un changement se voit après
  avoir relancé la vue.
- **Ligne cassée** : dans la bande, le poids de chaque sol est multiplié par un bruit qui lui est propre
  (plaques de 40 m, `NOVA_EDGE_*` dans `terrain_biome.gdshader`), puis le mélange par la hauteur des textures
  s'applique comme avant (« Netteté des transitions »). Les deux sols se rejoignent en langues et en îlots.
  Le bruit s'efface entre 800 m et 2,5 km de la caméra.
- **Scatter qui déborde** : un objet demande sa variante en un point tiré dans un disque de la même largeur
  autour de lui (`NovaScatter._spilled`, tiré du hachage de sa cellule). La part d'objets gardés est la part
  de leur variante autour d'eux : chaque couche s'éclaircit de l'autre côté de la frontière au lieu de s'y
  arrêter. Une seule lecture de zone par objet, comme avant, et la même réponse à tous les niveaux de détail
  (sonde de parité : 243 rochers identiques entre un chunk et son parent).
- **Chunks sans frontière** : aucun calcul quand toutes les tuiles d'export à portée sont entièrement de la
  même variante (`_nova_alone`).
- Coût : le chunk de frontière de la sonde se construit en 1,3 s au lieu de 0,6 s (une fois, puis cache).
  En vol, cache prêt : 108 images par seconde, 2 images de plus de 33 ms.
- Pas fait : le relief ne suit pas la transition (il faudrait la même lecture côté serveur pour la
  collision) ; la variante voisine non réglée garde son sol par défaut, ce qui accentue le contraste.

### Carte QGIS du 18/11/2026 (locale, temporaire)

`assets/qgis/export/tarsis_3_chunks/terrainmodifier.pack` a été remplacé par l'export de ddurieur (1,4 Go,
l'ancien de 100 Mo est dans `Documents/DyingStar-Dev/backup_qgis/`). Le fichier est suivi par git mais ne doit
pas partir dans un commit : il est marqué `git update-index --skip-worktree` (à lever avec
`--no-skip-worktree` quand la carte viendra du streaming).

Ce que la nouvelle carte change, et ce que Nova en fait :

- **13 variantes** au lieu de 11 (corindons noir, bleu, caméléon, vert, gris-bleu, orange, rose, rouge,
  blanc, jaune, émeri, et une variante `region`). Les réglages suivent sans rien faire : ils sont rangés par
  biome et attributs, pas par lieu.
- **Les zones couvrent presque toute la planète** et chaque niveau du pack porte les vraies zones (10,7
  millions de tuiles au niveau d'export). L'atlas, qui lisait toutes les tuiles d'export, ne finissait plus :
  il relève maintenant le niveau le plus fin d'au plus 250 000 tuiles (`NovaAtlas.SURVEY_MAX_TILES`, ici le
  niveau 128) et ne garde un lieu que s'il est bien dans sa variante au niveau d'export.
- **Frontières vues de haut** : l'adoucissement s'arrêtait aux chunks de plus de 4 tuiles d'export de côté
  (au-delà de quelques kilomètres d'altitude, on retrouvait l'escalier du maillage). Chaque chunk lit
  maintenant les zones de son propre niveau du pack (`PlanetChunk.nova_zone_level`), celles dont viennent
  ses sommets : la transition existe à toutes les distances, large d'au moins 2,5 mailles.
- **Liseré gris entre deux zones** : deux zones voisines ne partagent pas leur contour au mètre près, et le
  sol hors zone apparaissait dans l'interstice. Sa part autour d'un sommet ne compte plus sous 12 % et
  compte en entier à partir de 45 % (`NOVA_SLIVER_SHARES`).
- Les profils de routes et de rails cuits (`grade_profiles.pack`) datent de l'ancienne carte : le jeu les
  recalcule au lancement (plusieurs minutes en tâche de fond, avertissement dans le journal). À recuire côté
  export, hors de Nova.
- Les niveaux grossiers et le niveau d'export ne disent pas toujours la même chose (la variante `region`
  n'existe qu'aux niveaux grossiers) : une couleur vue de loin peut changer en s'approchant.

Suite du 18/11 (retours sur l'aperçu et la lenteur au lancement) :

- **Carte d'aperçu trouée** (points et lignes blanches sur le globe du panneau, absents en jeu). Trois
  causes dans `NovaAtlas` : les empreintes peintes avaient la largeur d'une tuile alors qu'une tuile HEALPix
  est un losange (maintenant 1,5 fois) ; les points d'échantillonnage tombaient exactement sur les
  parallèles où les zones sont découpées, où le test « dans le contour » répond non des deux côtés
  (décalés, `OFF_X` / `OFF_Y`) ; et l'interstice entre deux zones voisines était peint en sol nu (le sol
  hors zone n'est plus peint, et les trous d'au plus 3 pixels sont comblés, `_close_gaps`). Sol nu sur la
  carte : 28 % avant, 0,5 % après ; elle correspond à la carte QGIS.
- **Recherche de la variante à un endroit** : une seule fonction rapide pour le terrain, le scatter et
  l'atlas (`PlanetChunk.nova_entries` puis `nova_variant_in`). L'identifiant de variante d'une zone, une
  chaîne construite à partir de ses attributs, était recalculé à chaque échantillon. Poids de frontière
  d'un chunk, mesurés au même endroit : 3,9 s → 0,34 s au niveau 4, 684 → 129 ms au niveau 16, 212 → 83 ms
  au niveau 8192. Mêmes résultats, le cache du terrain reste valable.
- Ce qui reste long au premier lancement sur cette carte, hors Nova : 27 s d'échauffement du premier chunk
  (avec ou sans Nova) et le recalcul des profils de routes et de rails à chaque lancement. Côté Nova :
  l'atlas se construit en 20 s une fois par carte (puis cache), et un chunk lointain avec frontières coûte
  0,3 à 0,9 s contre 0,07 à 0,15 s sans Nova, une fois (puis cache).

### Chargement (19/11/2026)

Mesuré avec une sonde dans l'éditeur (`NOVA_PROBE`, chaque image de plus de 150 ms) à l'ouverture à froid de
`tarsis_3.tscn` : **176 s sans réponse** sur les 210 premières secondes, dont un bloc de 158 s.

- **Cause principale, hors Nova** : `grade_profiles.pack` (profils de routes et de rails, ponts) était cuit
  pour l'ancienne carte. Le jeu refaisait tout à chaque lancement : 14 107 croisements route/crevasse et 131
  profils. Recuit avec l'outil du projet :
  `godot --headless --path . res://tools/bake_grade_profiles.tscn -- --planet=tarsis_3` (7 minutes, 132
  lignes sur 132). **À refaire à chaque nouvelle carte.** L'ancien fichier est dans
  `Documents/DyingStar-Dev/backup_qgis/`, le nouveau est marqué `skip-worktree` comme la carte.
- **Part de Nova** dans les 5,5 s restantes : 2,7 s. Les variantes du pack étaient lues deux fois, par le
  panneau et par le terrain (0,45 s chacune) : `NovaBody.discover` les garde pour le processus. Les modèles
  du scatter (1 s) sont maintenant lus sur un fil de travail (`PlanetTerrain._nova_read_descs`), à
  l'ouverture comme à chaque réglage de scatter changé dans le panneau ; les chunks gardent ce qu'ils ont
  jusqu'à la réponse.
- Après : **4,9 s sans réponse**, dont un bloc de 4,1 s qui est l'ouverture de la scène par le jeu (Nova y
  garde 0,65 s pour préparer les textures du sol). Vol de 6 km : 107 images par seconde, 1 image de plus de
  33 ms (98 et 18 pendant le recalcul des routes).

### Develop du 20/11/2026 : tout le terrain vient du service de tuiles

`origin/develop` (137 commits après notre base) a été fusionnée dans `feat/nova` le 20/11. Sur develop les
éléments de terrain (routes, biomes, montagnes, volcans) ne sont plus lus dans un `terrainmodifier.pack` local :
ils sont servis tuile par tuile par le service de tuiles (`RemoteModifierPack`, corps `<planète>.mod`), avec
cache disque. Les packs locaux et `grade_profiles.pack` sont supprimés du dépôt.

- La carte posée à la main pour Tarsis 3 ne sert plus : le service publie une carte plus récente (biomes du
  18/11, 11 variantes de corindon, plus de variante « region »). Nos deux fichiers locaux sont rangés dans
  `DyingStar-Dev/backup_qgis/` (`terrainmodifier_ddurieur_2026-11-14.pack`,
  `grade_profiles_rebake_2026-11-19.pack`).
- `NovaBody.pack_for(corps)` donne le pack servi ; `NovaBody.open_body(corps)` et `NovaBody.discover(pack)` lisent
  les variantes dans les niveaux qui arrivent d'un bloc (jusqu'au niveau 16), les mêmes pour tous. Sans
  service joignable : le sol hors zone seul.
- Les zones d'une tuile sont les siennes plus celles que ses ancêtres portent pour elle
  (`PlanetData.populate_zones_at`) : `PlanetChunk.nova_zones_of` passe par là, `NovaAtlas` fait la même fusion.
- `NovaAtlas` (carte d'aperçu, « aller à ») est construit sur le niveau 16 avec jusqu'à 24 × 24 points par
  tuile : 45 s la première fois, puis cache. Ses contours sont ceux du niveau 16, plus grossiers que le
  terrain : près d'une frontière, « aller à » et « sous la caméra » peuvent se tromper de côté.
- Vue jeu : le relief (montagnes) arrive après le premier placement du joueur ; `nova_world.gd` relit le sol
  pendant 60 s et remet le joueur à sa hauteur (sinon il se retrouvait sous le terrain).
- `RemoteTileSource` : la liste des sources en marche et son verrou sont créés au premier usage (script non
  `@tool` : dans l'éditeur ses statiques ne sont pas initialisées, `start()` plantait).
- Vérifié après fusion : tests Nova (13), météo (18), `test_remote_modifier_pack` (6) ; vue jeu à 114 images
  par seconde, sol de biome, tourbillons, mur de poussière.
- Pas vérifié : le panneau dans l'éditeur ; les frontières douces quand une tuile voisine n'est pas encore
  arrivée (le poids lu serait provisoire, et pourrait être mis en cache) ; la vue jeu sans réseau ; le
  reste des tests du projet.

### Scatter sur tous les biomes, POI dégagés, passe d'optimisation (20/11/2026)

- **Tous les biomes** : les 74 réglages de scatter du corindon rouge sont passés au niveau « plateau de
  Tarsis 3 » (`nova/bodies/tarsis_3/outcrop-plateau.tres`, les 11 types de zone en héritent) et recopiés
  dans `_default.tres` (sol hors zone). Le fichier du corindon rouge ne garde que son sol. Les roches gardent
  la teinte de leur zone ; leur aspect a été réglé sur le rouge, les autres couleurs n'ont pas été revues
  (`docs/nova_captures/scatter_corindon_bleu.png`).
- **Sol construit** (`scenes/planet/nova/nova_clearance.gd`, `NovaClearance`) : le scatter est partout sauf
  là où l'on a construit, avec un fondu au lieu d'un bord net.
  - Routes et rails : leur largeur et leur accotement, avec la règle qui écarte déjà le relief de biome des
    routes (`BiomeRelief.road_weight`) ; les routes tracées dans un village aussi.
  - Bâtiments : le sol nivelé sous chacun (son pad) et 6 m autour, fondu sur 10 m.
  - Villages : leur sol commun (le lit du village), fondu sur 30 m.
  - Tout POI : 150 m autour de son centre, fondu sur 100 m. Ce n'est plus la sphère du POI (500 m pour un
    village, 25 à 40 km pour une ville), qui laissait des régions entières sans rien.
  - Un objet est testé en son milieu et en quatre points de son bord : un rocher de 15 m ne déborde pas
    sur une route.
  - Mesuré en vue jeu : autour d'un village de 500 m, 0 objet à moins de 150 m du centre, 3 284 dans les
    100 m suivants, 6 359 plus loin dans sa sphère ; sur une autoroute, 0 objet sur la chaussée et 153 sur
    l'accotement, sur 13 681 à moins de 400 m (`docs/nova_captures/scatter_route.png`).
  - Pas vérifié : les pads et les lits de village. La vue jeu de Nova est hors ligne : aucun bâtiment ni
    village n'y est posé (ils viennent du serveur), seul un test sur un POI factice couvre ce code.
- **Défaut révélé par le passage à tous les biomes** : les couches actives d'un chunk tenaient dans un masque
  de 64 bits ; avec 13 types de zone × 6 couches (78 entrées) il débordait, et des chunks à 2,5 km recevaient
  toutes les petites couches (2,2 millions d'objets calculés pour 90 chunks). C'est maintenant un tableau
  d'un octet par couche : 96 000 objets pour 200 chunks, affichés en 12 s.
- **Optimisation** (vol à 200 m/s sur 6 km, zone de corindon bleu, cache chaud) :
  - avant : 105 images par seconde, 99 % des images sous 27 ms, 12 images de plus de 33 ms ;
  - après : 113 images par seconde, 99 % sous 14 ms, aucune image de plus de 33 ms ;
  - sans Nova, même trajet : 116 images par seconde, 99 % sous 12 ms.
  Ce qui a compté : la revue des chunks après chaque déplacement de 30 m est étalée sur plusieurs images
  (1,5 ms par image, `NOVA_RELAY_MS`) au lieu d'être faite d'un coup (pics de 20 ms) ; les blocs d'une couche
  dont la distance de vue n'atteint pas le chunk ne sont plus testés un par un (`nova_by_limit`) ; les blocs
  font 200 m au lieu de 100 (quatre fois moins de nœuds pour les petites couches) ; la création des nœuds
  est bornée en temps (2 ms par image) et non plus en nombre. À l'arrêt Nova ne coûtait déjà rien.
- Pas vérifié : la mémoire ; les machines plus modestes ; le scatter près d'une ville (sphères de 25 à 40 km).

### Météo

Voir `docs/WEATHER.md` : la météo vient du service météo, le jeu la lit. La vue jeu de Nova et la carte
météo du panneau lisent le service directement (`client.ini`, `[weather] service_url`).

### Le panneau

Depuis le 19/11/2026 le panneau n'est plus une seule colonne à faire défiler (les boutons du bas étaient
hors d'atteinte). Captures : `docs/nova_captures/panneau_planete.png`, `panneau_sol.png`,
`panneau_scatter.png`.

- **Toujours visibles** : en haut le corps et la liste des types de zone ; en bas « Appliquer à » et
  « Enregistrer ».
- **Trois onglets** entre les deux, chacun avec son propre défilement : **Planète** (vue jeu, heure, globe
  qui prend la place libre, carte météo, aller à une zone / une frontière / un POI, mode vol), **Sol** et
  **Scatter**.
- **Sections repliables** dans Sol (matière principale, répétition et détail, deuxième et troisième
  matières, relief, frontières ; `GROUND_SECTIONS`) et dans Scatter (une par couche, « active » dans le
  titre). Seule la matière principale est ouverte au départ ; le panneau garde ce qui a été ouvert.
- **Un réglage par ligne** : nom, éditeur, origine de la valeur, retour à la valeur héritée (`_add_row`).
  Seule la liste des modèles d'une couche garde son éditeur sur plusieurs lignes. Deux sections du sol,
  ou une couche de scatter entière, tiennent à l'écran.
- À faire : des aperçus des modèles (les textures ont déjà leur vignette).

- La **miniature** est le corps vu de l'espace : chaque type de zone a la couleur de sa roche (`rocks.json`),
  le sol hors zone celle de la roche par défaut du corps, le relief vient de ses hauteurs (niveau 8 du pack,
  pentes exagérées 40 fois, sinon invisibles à cette échelle). Le type choisi est entouré de blanc, la mire
  blanche est la caméra. Glisser : tourner. Molette : zoom. Clic : y envoyer la caméra (et choisir le type
  cliqué). C'est un shader : tourner et zoomer ne coûtent rien. Le relief n'apparaît que scène ouverte.
- **Zone k / n ▶** amène la caméra au-dessus du type choisi, zone après zone (la plus grande d'abord).
  **Frontière k / n ▶** l'amène sur une frontière avec un autre type. La hauteur se choisit dessous.
- Les lieux et la carte des zones (4096 × 2048, ~10 km par pixel sur Tarsis 3) viennent de `NovaAtlas`, lu
  dans le **niveau d'export** du pack, celui que lisent les chunks. Les niveaux grossiers ne sont pas une
  carte : sur Tarsis 3 ils couvrent 94 % du corps, l'export 3 %. L'atlas se calcule une fois par export
  (~12 s, sur un worker), puis se relit depuis `user://nova_atlas/`.
- La découverte des variantes lit les niveaux du pack jusqu'à 4096 tuiles. Le plus grossier seul perdait
  l'émeri, dont les deux zones n'y figurent pas.

### Vue jeu

Bouton « ▶ Vue jeu » de l'étape 3. Il lance `addons/nova/nova_world.tscn` dans l'onglet « Jeu » : le corps tel
que le jeu le montre, sans serveur. C'est le monde hors ligne de la vue volcans
(`test/volcano/volcano_world.gd`), donc le code client du jeu : terrain, végétation, volcans, routes et
ponts, ciel, poussière, étoile, et le joueur avec son mode dieu.

- Touches dans le jeu : clic pour prendre la souris, Échap pour la rendre, Z Q S D, Espace et Ctrl pour monter
  et descendre, molette pour la vitesse, Maj pour aller plus vite, G pour se poser et marcher (et redécoller),
  V pour voir le personnage de dos.
- Le panneau pilote le jeu par le canal de débogage de Godot (`scenes/planet/nova/nova_link.gd` côté jeu,
  `addons/nova/nova_debugger.gd` côté éditeur) : chaque réglage modifié s'y applique sans enregistrer, les
  boutons « aller à » (zone, frontière, POI, clic sur la miniature) y envoient le joueur, et la mire de la
  miniature suit sa caméra. Ce canal n'existe que lorsqu'un éditeur lance le jeu : jamais dans un jeu
  exporté, jamais sur le serveur.
- La vue jeu s'ouvre là où l'on regardait : au même point du sol et à la même hauteur que la vue 3D de
  l'éditeur quand la scène du corps y est ouverte, sinon au dernier endroit où le panneau a envoyé la vue.
- **Heure du jour** (curseur du panneau, midi par défaut) : la vue jeu garde cette heure locale où que l'on
  aille, 12 h étant le soleil au plus haut à cet endroit. Une couleur de sol ne se juge pas au lever ni au
  coucher : la lumière rasante teinte tout (une roche bleue y paraît kaki). Les touches + et − du pavé
  numérique décalent aussi l'heure d'une heure, jusqu'au prochain « aller à ».
- La vue 3D de l'éditeur n'a ni le soleil ni l'atmosphère du jeu : au même point, ses couleurs diffèrent de
  celles de la vue jeu. C'est la vue jeu qui fait foi.
- Manquent par rapport au jeu en ligne : les villages et les villes (envoyés par le serveur), les PNJ, les
  autres joueurs. Le personnage n'est pas animé (son animation vient du client réseau).
- L'éditeur compile le C# avant de lancer le jeu, avec le `dotnet` qu'il trouve dans le PATH :
  `Ouvrir-Nova.cmd` y met le kit .NET 9 fourni à côté du projet. Sans lui, le lancement échoue.

### Mode vol et marche

Boutons « Mode vol (Z Q S D) » et « À pied (G) » de l'étape 3 (`addons/nova/nova_fly.gd`). Souris sur la vue 3D :

- **En vol** : Z Q S D déplacent la vue le long du sol dans le sens où elle regarde (ce sont les positions
  W A S D, quelle que soit la disposition du clavier), Espace monte, Ctrl ou C descend, Maj va quatre fois
  plus vite. La vitesse suit la hauteur (0,8 fois la hauteur par seconde, 4 m/s au minimum). La vue s'arrête
  à 2 m du sol et à 5 rayons du centre : une quinzaine de secondes d'Espace montrent la planète entière.
- **À pied** (touche G, ou le bouton) : la vue se pose à 1,70 m, suit le relief, avance à 5 m/s, 15 m/s avec
  Maj. Espace redécolle. Pas de physique ni de collision avec les objets : seul le sol est suivi.
- Tourner la vue reste le geste de Godot : clic droit maintenu.

Rien n'est enregistré : le corps est roulé sous la caméra (`PlanetTerrain.editor_fly`), comme pour les
boutons « aller à », et la scène n'en garde aucune trace. Tant que le mode est actif et la souris sur la vue
3D, ses touches n'atteignent plus l'éditeur : ni ses raccourcis Q, W, E, ni Ctrl+Z, Ctrl+S, Ctrl+D (Ctrl
descend). La vitesse du vol libre de Godot est mise à zéro pendant ce temps, puis remise à sa valeur.
En vol, le sol sous la caméra est mesuré quatre fois par seconde : en fonçant vers une pente raide, la vue
peut passer brièvement dessous avant d'être remontée. À pied il est mesuré à chaque image.

### Points d'intérêt

Les POI du corps (`assets/qgis/export/<corps>_poi.json`, lus par `StarMapPoi.load_for` comme la carte
stellaire du jeu) sont les points jaunes de la miniature : leur nom s'affiche au survol, un clic y envoie la
caméra. La liste « Aller à un POI… » fait la même chose, triée par type puis par nom.

### À venir

- **Pinceau d'assets** : peindre à la souris des objets (arbres, rochers…) sur le sol, pour compléter le
  scatter procédural. Demandé, pas commencé.

### La planète entière dans la vue 3D

La caméra de l'éditeur ne voit pas au-delà de 1 000 km (limite de Godot) : les chunks d'une planète de
6 356 km de rayon sont coupés bien avant qu'on la voie entière. `addons/nova/nova_far_view.gd` ajoute une
sphère qui la remplace au-delà : c'est le corps réduit vers la caméra jusqu'à tenir dans le champ (une mise à
l'échelle autour de l'œil, donc les mêmes pixels), dessinée seulement là où aucun vrai chunk ne l'est. Elle
partage la carte des zones de la miniature (`nova_planet.gdshaderinc`) mais s'éclaire comme le sol lointain
qu'elle prolonge : mêmes lumières de scène, même lumière d'étoile, et une palette calculée comme l'albédo du
terrain (teinte × texture moyenne × `albedo_multiplier`). Enfant interne du terrain : jamais enregistrée
dans la scène.

### Zones : ce que montre la miniature, ce que montre le sol

Sur Tarsis 3, l'export des zones est incomplet aux niveaux fins : `tiles_for_polygon`
(`tools/planettech/qgis/export/planet/modifier_geom.py`) n'échantillonne plus l'intérieur d'un polygone
au-delà de 4 millions de points et n'en garde que le contour. Les zones couvrent 96 % du corps jusqu'au
niveau 128, 29 % au niveau 256, 2,7 % aux niveaux 512 et 1024. Les chunks lointains (niveaux grossiers)
montrent donc les zones entières, les chunks proches (niveau d'export) seulement leurs bords. La miniature et
la sphère lointaine montrent les zones entières (niveau 128, puis le niveau d'export par-dessus pour les
bords) ; « Sous la caméra » dit ce que le sol affiche, et signale une zone prévue dont l'intérieur manque.
Correctif prêt dans `modifier_geom.py` (`polygon_interior_tiles`, descente hiérarchique, tests dans
`test_tiles_for_polygon.py`), mais aucun ré-export n'a été fait : au format actuel le pack passerait
d'environ 100 Mo à 1,1 Go, ce qui demande une décision de format avant de relancer.

### Fluidité dans l'éditeur

- La mesure du sol sous la caméra se fait sur un worker (`PlanetTerrain._editor_measure_ground`) : sur le
  thread principal elle figeait l'éditeur jusqu'à 2,9 s par appel après un déplacement.
- **Aperçu léger** (case du panneau, `PlanetTerrain.editor_bare`) : l'éditeur ne construit que le sol.
- Le fondu des frontières (`PlanetChunk.nova_soft_weights`) ne se calcule que sur les chunks couvrant au
  plus 4 tuiles d'export de côté (`NOVA_SOFT_MAX_TILES`). Sur un chunk plus grossier il lisait des milliers
  de tuiles fines : un chunk de niveau 8 prenait des minutes, occupait un des 4 emplacements de construction
  tout ce temps (file d'attente de plusieurs centaines de chunks) et empêchait l'éditeur de se fermer.
  Mesuré après : file vide, aucune image au-delà de 31 ms en déplacement, fermeture en 2 à 11 s.
- Les tâches de scatter sont attendues à la fermeture comme les autres (`_nova_scatter_tasks`).

### Éditeur qui gèle au retour de focus

Si `addons/ds_net/bin/` n'existe pas (bibliothèque construite, pas commitée), Godot retente de charger
l'extension à chaque retour sur sa fenêtre et recharge tous les scripts : 12 s de gel, puis un crash quand un
worker du terrain tourne pendant le rechargement. Remède local : construire la bibliothèque
(`tools/build_ds_net.sh`) ou poser un fichier vide `addons/ds_net/.gdignore` (non commité).
Mesure : `NOVA_PROBE=<script.gd>` lance un script de mesure dans l'éditeur (voir `addons/nova/nova_plugin.gd`).

## Vérifié

- `test/unit/test_nova.gd` : héritage, découverte des variantes de Tarsis 3 (émeri compris), palette,
  hachage figé, lieux de l'atlas dans leur variante, carte du globe.
- `test/parity/nova_probe.tscn` (headless) : un chunk de Tarsis 3 à cheval sur deux corindons reçoit sa
  palette sans surface séparée ; un chunk fin et son parent posent les mêmes 217 rochers (écart ≤ 4 mm).
- `test/parity/nova_render_probe.tscn` (ouvre une fenêtre) : compile le shader et photographie ce chunk.

## Limites de ce prototype

- Collision serveur des rochers : pas encore faite (rendu client seulement).
- Les chunks lointains (`far_ground`) gardent l'ancien rendu.
- Le filtre de pente du scatter dépend de la maille : sur une pente au seuil, un rocher peut apparaître selon le LOD.
- Coût : +15 à 60 ms par chunk fin près d'une frontière (échantillonnage en GDScript, à porter en C#).
- Le relief d'un biome (`relief_*`) ne suit pas la transition : il s'arrête à la ligne de la zone.
