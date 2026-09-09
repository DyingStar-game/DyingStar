# Streaming des tuiles d'élévation — étude de conception

**Statut :** étude / non implémenté. Rédigé le 2026-09-07.

## Vocabulaire (à lire en premier)

Deux mots que le code distingue et qu'il est facile de confondre. Il y a
**16 384 chunks pour une tuile** — toute cette étude repose sur ce rapport.

| terme | c'est quoi | taille | fichier |
|---|---|---|---|
| **tuile** | une case de `heights.pack` : `tile_res²` altitudes brutes | 4 Ko | ce qui pèse les Go de `assets/qgis/export/` |
| **chunk** | un morceau de terrain triangulé à l'écran | 12-18 Ko | `hp_n8192_p…_lod0_mesh.res`, généré à l'exécution |

Dans ce document, « streaming » désigne toujours le streaming des **tuiles**.

## Résumé

Remplacer les 3,9 Go de données d'élévation embarqués aujourd'hui dans chaque
build client et serveur par un flux HTTP à la demande : `heights.pack` éclaté en
un fichier par tuile, versionné et immuable, servi par un simple nginx. Le joueur
télécharge les tuiles autour de lui (LOD0 au plus près, LOD1-4 au loin) et les
garde dans un cache disque plafonné.

Deux décisions structurantes, argumentées plus bas :

- **on streame les tuiles (l'entrée de l'exporteur), pas les meshes** (la sortie
  du runtime) — l'inventaire à héberger passe de ~14,5 To à ~69 Go par planète ;
- **résolution par corps** : tarsis_3 passe à **198 m** (`n1024 × tr32`), les
  19 autres planètes et lunes restent à **4 065 m** (`n64 × tr25`) ;
- **adressage par chemin**, pas par contenu : la dédup mesurée sur le dataset ne vaut
  que 1 %, et l'ensemble de travail d'un joueur (~580 Ko) ne justifie aucun index.

Résultat attendu : **build de 3,9 Go → ~26 Mo**, **73,8 Go hébergés** pour les 20 corps,
et **moins d'un mégaoctet téléchargé** pour qu'un joueur voie tout le terrain autour de
lui — à une résolution 10× meilleure sur tarsis_3.

Le streaming ne réduit **pas** le coût CPU de génération d'un chunk — c'est un
chantier distinct (voir Phase 0).

---

## 1. État actuel (mesuré le 2026-09-07)

| | valeur |
|---|---|
| total `assets/qgis/export/` | **3,9 Go** (18 planètes à 157 Mio + tarsis_3 et tarsis_5 à 655 Mo) |
| embarqué dans le build ? | oui — `export_presets.cfg` `include_filter="*.json, *.planetpack, *.pack"`, client **et** serveur dédié |
| résolution | tarsis_3 : nside 64 × tile_res 50 → **2033 m** ; autres planètes tile_res 25 → **4064 m** |
| taille d'une tuile | `tile_res² × 4` = **10 Ko** (float32 brut) |
| mesh de chunk en cache (`.res`) | médiane **12 Ko**, moyenne 18 Ko, max 43 Ko |
| shape de collision en cache | moyenne **49 Ko** (serveur uniquement) |
| profondeur du quadtree | `max_quadtree_depth = 14` (nside 16384) |
| hébergement web existant | `exportplanets.dyingstar-game.space/export.tar.gz` |
| client HTTP dans le jeu | **aucun** — pas un `HTTPRequest` / `HTTPClient` hors addons |

### Formules de dimensionnement

```
espacement au sol   s  = 6 504 266 / (nside × tile_res)      mètres
taille du pack         = 16 × nside² × tile_res² × 4         octets
                       = 64 × (nside × tile_res)²
nombre de tuiles       = 16 × nside²
```

(`6 504 266 = R × √(π/3)` pour `R = 6 356 000`. Le `16 × nside²` est la pyramide
complète : `Σ 12 × nside² = 12 × nside² × 4/3`.)

Vérifié : n64 × tr50 → 655 Mo (fichier réel : 655 320 464 o).

---

## 2. Tuile vs mesh : pourquoi on streame l'entrée

### La tuile — l'entrée

Une grille d'altitudes, rien d'autre. Produite par
`tools/qgis/export_elevation.py` à partir des contours QGIS. Aucune notion de
triangle, de LOD, de couleur, de route ni de biome.

### Le mesh — la sortie

Ce que `PlanetChunk.generate_mesh()` construit pour **un** chunk à **un** LOD. À
`chunk_resolution = 32` : 33×33 = 1089 sommets portant
(`planet_chunk.gd:1196-1203`) `ARRAY_VERTEX` (12 o) + `ARRAY_NORMAL` (12 o) +
`ARRAY_TANGENT` (16 o) + `ARRAY_TEX_UV` (8 o) + `ARRAY_TEX_UV2` (8 o) +
`ARRAY_COLOR` (16 o) + `ARRAY_CUSTOM0` jupes (12 o) ≈ 84 o/sommet, plus
32×32×6 = 6144 indices. ~116 Ko brut, 12-18 Ko compressé.

La génération ne fait pas que trianguler — elle **ajoute** :

```
  tuile 4 Ko
     |
     |  échantillonnage bilinéaire à la direction de chaque sommet
     |  + cratères / rivières / canyons / volcans (zones)
     |  + cracks corundum, jupes anti-fissures
     |  + routes, exclusions de ponts
     |  + couleurs de biome, layer de texture de détail, tangentes
     |  + correction de winding, normales analytiques
     v
  mesh 12-18 Ko   ×  un par (chunk, LOD)
```

### La comparaison qui décide

| | tuile | mesh |
|---|---|---|
| variantes par LOD | **aucune** — une par (nside, ipix) | **une par lod** (le cache contient `n4096_lod0` *et* `n4096_lod1`) |
| dépend du code du jeu | non | oui — `v27`, `_brg`, `_cor` sont dans la clé (`planet_terrain.gd:330`) |
| invalidée par | un ré-export QGIS (`data_version`) | un ré-export **ou** n'importe quel patch de gameplay |
| inventaire, planète entière | 16,8 M tuiles = **69 Go** | 12 × 8192² = 805 M meshes = **14,5 To** |

`PlanetData.sample_nside_for()` clampe l'échantillonnage à `nside_max`
(`planet_data.gd:590`) : une tuile alimente `(16384/1024)² = 256` chunks au
niveau le plus fin du quadtree — et 16 384 avec le `nside_max = 64` actuel. La
génération est un **amplificateur**. Streamer la sortie, c'est transporter
l'amplification ; streamer l'entrée, c'est transporter la source et laisser le
client amplifier, ce qu'il fait déjà et qu'il cache déjà sur disque.

Corollaire : au niveau le plus fin, un chunk fait 397 m de large alors que la
tuile n'a un échantillon que tous les 198 m. Le mesh fin **ne lit presque aucune
nouvelle donnée** — tout ce qui est visible à cette échelle (cracks, lits de
rivière, talus de route, cratères) est ajouté procéduralement.

### Pourquoi un CDN de meshes ne marche pas

La bande passante par joueur conviendrait (20 Mo/session). Le blocage est ce qui
doit **exister** sur le serveur pour que n'importe quel joueur soit n'importe où :
14,5 To par planète. Et si on n'en pré-calcule qu'une partie, il faut un plan B :

- « le client le génère » → il lui faut les hauteurs en local → le problème de
  disque n'est pas résolu ;
- « le client attend » → un trou dans le monde à chaque miss ;
- « le serveur bake à la demande » → ce n'est plus nginx mais une ferme de
  workers Godot headless, et n'importe quel patch de gameplay invalide 100 % du
  bake.

Argument pratique complémentaire — la **marge de prefetch** :

| | taille d'une unité | à 100 m/s (véhicule) |
|---|---|---|
| chunk au niveau fin | 397 m | on en franchit un toutes les **4 s** |
| tuile n1024 | 6,35 km | une toutes les **64 s** |
| tuile n64 | 101,6 km | une toutes les **17 min** |

Une tuile débloque des centaines de chunks ; un mesh n'en débloque qu'un.

---

## 3. Empreinte instantanée d'un joueur (simulé)

`PlanetTerrain._traverse` a été rejoué à l'identique (mêmes constantes :
`SUBDIVIDE_FACTOR 1.5`, `BACKFACE_DOT -0.3`, `HORIZON_MARGIN_RAD 0.02`,
`max_quadtree_depth 14`) avec la vraie géométrie HEALPix de
`tools/qgis/healpix_utils.py`.

**Combien un joueur doit-il télécharger à l'instant T, sans bouger ?**

| situation | chunks actifs | tuiles | float32 | uint16 |
|---|---|---|---|---|
| debout au sol, **format retenu n1024×tr32** | 411 | **273** | **1,07 MiB** | **0,53 MiB** |
| orbite 200 km, n1024×tr32 | 160 | 160 | 0,62 MiB | 0,31 MiB |
| *(pour mémoire : format actuel n64×tr50)* | 411 | 138 | 1,32 MiB | 0,66 MiB |

Détail par niveau, joueur debout (format actuel, `nside_max = 64`) :

```
chunks :  n4:3  n8:20  n16:35  n32:32  n64:37 | n128:33  n256:32  n512:37
          n1024:32  n2048:37  n4096:32  n8192:37  n16384:44
tuiles :  n4:3  n8:20  n16:35  n32:32  n64:48
```

Tout ce qui est à droite de la barre — 284 chunks, **69 % du total** — s'effondre
dans 11 tuiles supplémentaires, parce que `sample_nside_for` clampe à
`nside_max`. Les niveaux les plus fins du quadtree sont gratuits en réseau.

**Validation** : les niveaux grossiers bougent à peine quand le joueur marche,
donc leur compte instantané doit égaler ce qu'un vrai cache accumule. C'est le
cas (cache mesuré de tarsis_3, 1154 meshes) :

|     | simulation | cache réel |
|-----|------------|----|
| n4  | 3          | 3  |
| n8  | 20         | 22 |
| n16 | 35         | 43 |
| n32 | 32         | 46 |
| n64 | 37         | 42 |

**Mesuré depuis** (phase 0, client en jeu, 2026-09-07) : **283 tuiles distinctes**,
contre 273 simulées — 3,7 % d'écart. La simulation ci-dessus est validée.

**Réserves** : terrain seul (ni props, ni végétation, ni textures) ; ±10 % selon
la position exacte (géométrie des pixels HEALPix) ; sous-estimation de 10-20 %
car un chunk à cheval sur un bord de tuile a besoin des voisines pour
l'échantillonnage bilinéaire (`sample_height_boundary`).

Le script de simulation est conservé hors dépôt (`sim_traverse.py`) ; il tient en
80 lignes et peut être rejoué pour d'autres scénarios.

---

## 4. Format d'export retenu

### La décision (actée)

| | format | espacement | fichiers | tuile uint16 | données | disque 4 Kio |
|---|---|---|---|---|---|---|
| **tarsis_3** | `n1024 × tr32` | **198 m** | 16 777 216 | 2 048 o | 34,4 Go | 68,7 Go |
| **19 autres** (planètes et lunes) | `n64 × tr25` | **4 065 m** | 1 245 184 | 1 250 o | 1,6 Go | 5,1 Go |
| **TOTAL hébergé** | | | **18,0 M** | | **35,9 Go** | **73,8 Go** |

À comparer aux **1,37 To et 335 M de fichiers** si les 20 corps passaient à 198 m. Un
seul disque suffit, `rsync` reste praticable, et le *pack creux* (phase 1) redevient une
optimisation plutôt qu'une nécessité. Sur un volume formaté en `mkfs.ext4 -b 1024`,
l'occupation tombe à 35,9 Go.

**Conséquence à noter : tarsis_5 baisse de résolution.** Elle est aujourd'hui à 2 033 m
(`tr50`, 655 Mo) et repasse à 4 065 m (`tr25`, 164 Mo) — c'est une perte visible sur une
planète qui a actuellement une meilleure donnée que les autres. Décision assumée.

**Plancher embarqué** : les niveaux n1…n8 (1 020 tuiles par corps) restent dans le
`.pck`, soit **26 Mo** au total. Le build passe donc de **3,9 Go à ~26 Mo**.

### Pourquoi ce partage nside × tile_res

Le produit `nside × tile_res` est fixé par la résolution visée. Le **partage**
entre les deux est libre — et il change tout, alors qu'il était sans importance
pour un pack monolithique.

```
empreinte réseau instantanée  ∝  tile_res²      (une grosse tuile sur-livre)
nombre de fichiers            ∝  nside²
```

### Les options à 198 m

| découpage | tuile | fichiers/planète | sol : tuiles / MiB f32 | disque réel (blocs 4 Kio) |
|---|---|---|---|---|
| n256 × tr128 | 65 536 o | 1 048 576 | 204 / 12,75 | 68,7 Go |
| n512 × tr64 | 16 384 o | 4 194 304 | 240 / 3,75 | 68,7 Go |
| **n1024 × tr32** | **4 096 o** | **16 777 216** | **273 / 1,07** | **68,7 Go** |
| n2048 × tr16 | 1 024 o | 67 108 864 | 309 / 0,30 | **274,9 Go** |

Et à 500 m, pour comparaison : n512 × tr26 donne 0,62 MiB au sol pour 4,2 M
fichiers et 11,3 Go/planète.

### Pourquoi n1024 × tr32 et pas plus fin

`n2048 × tr16` télécharge 3,5× moins (0,30 vs 1,07 MiB) mais :

- **Blocs disque.** ext4 alloue 4 096 o minimum par fichier (vérifié sur la
  machine de dev). Une tuile de 1 024 o en occupe 4 096 → **×4 de gaspillage**,
  274,9 Go sur disque pour 68,7 Go de données. En uint16 (512 o) c'est ×8. À
  `tr32` la tuile fait **exactement un bloc** : zéro gaspillage.
- **Inodes.** 67 M fichiers/planète × 20 = 1,34 milliard d'inodes. ext4 en alloue
  un tous les 16 Ko par défaut ; il faudrait `mkfs -i 1024` et la table d'inodes
  seule pèserait ~343 Go. rsync et les sauvegardes deviennent impraticables.
- **Overhead HTTP.** À 512 o de charge utile, les en-têtes HTTP/2 (~100-200 o
  après HPACK) font 20-40 % du transfert. Le gain affiché est en partie fictif.
- **`tile_res` ne doit pas descendre sous `chunk_resolution` (32).** Un
  chunk-feuille échantillonne 33 points par arête dans sa propre tuile. À `tr32`
  l'ajustement est exact ; à `tr16` le mesh génère deux fois plus de sommets que
  la tuile n'a de données.

### Déduplication : mesurée à 1 %, et ça tranche l'adressage

Hypothèse tentante : la pyramide étant sur-échantillonnée d'un facteur ~6000, des zones
entières (plaines, fonds océaniques) devraient produire des tuiles byte-identiques qu'un
stockage adressé par contenu fusionnerait gratuitement. **Mesuré sur les 65 532 tuiles du
`heights.pack` de tarsis_3, c'est faux :**

| format | tuiles uniques | dédup | tuiles constantes |
|---|---|---|---|
| float32 (actuel) | 64 910 / 65 532 | **0,9 %** | — |
| uint16 (0,16 m) | 64 849 | **1,0 %** | 1,1 % |
| uint12 (2,6 m) | 64 826 | 1,1 % | 1,1 % |
| uint10 (**10 m**) | 64 736 | **1,2 %** | 1,3 % |

655 Mo → 649 Mo. Même quantifiée à **10 mètres**, la dédup ne bouge pas : l'interpolation
TIN sphérique produit des valeurs légèrement différentes partout, et seules 1,1 % des
tuiles sont exactement constantes.

### Le point qui clôt le débat « faut-il des bundles ? »

Un bloc **2×2 de tuiles n2048×tr16** couvre exactement la surface d'une tuile
n1024 (2 × 3 176 = 6 352 m) et contient 4 × 256 = 1 024 échantillons, soit une
grille 32×32 : **c'est bit pour bit une tuile n1024×tr32**.

Donc `nside` vs `tile_res` et « faut-il regrouper en bundles ? » sont **la même
question**, déjà tranchée par le choix du format. Un fichier par tuile, pas de
couche de bundles.

Si le grain fin est un jour souhaitable pour le prefetch, la bonne façon est
l'inverse : garder n1024×tr32 sur disque et servir des **plages HTTP Range** à
l'intérieur des tuiles. On garde un fichier par bloc disque et on récupère la
granularité au niveau du transport.

### Conséquence sur le format de stockage

À `tr32`, une tuile float32 fait 4 096 o = un bloc exact. En uint16 elle fait
2 048 o et occupe **toujours un bloc** : l'uint16 **divise par deux la bande
passante mais ne gagne rien sur le disque**. Idem pour la compression.

→ **Stocker la forme la plus compressée possible** (uint16 pré-deflaté) : le
disque coûte pareil, le transfert coûte deux à quatre fois moins.
→ Option d'exploitation : formater le volume de distribution en
`mkfs.ext4 -b 1024`, ce qui ramène l'occupation totale de **73,8 Go à 35,9 Go**.

### Coût d'hébergement

Voir le tableau de la décision en tête de section : **73,8 Go et 18,0 M de fichiers**
pour l'ensemble des 20 corps, dont 68,7 Go pour tarsis_3 seule. Un volume formaté en
`mkfs.ext4 -b 1024` ramène l'occupation à 35,9 Go.

Le *pack creux* de la phase 1 reste souhaitable — les contours ne portent que
438 048 valeurs indépendantes alors qu'à 198 m on stocke 1,29 × 10¹⁰ échantillons, donc
la quasi-totalité de la pyramide fine de tarsis_3 est de l'interpolation pure — mais il
redevient une **optimisation** et non un prérequis, puisque 73,8 Go tiennent sans lui.

---

## 5. Avantages

- **Build : 3,9 Go → ~26 Mo** (les niveaux n1…n8 des 20 corps). Image Docker serveur,
  CI, dépôts Steam, installation joueur — tout maigrit d'un facteur 150.
- **Débloque une résolution 10× meilleure sur tarsis_3.** Le 198 m est impossible à
  embarquer : 68,7 Go pour cette seule planète.
- **Paiement à l'usage** : ~580 Ko pour voir tout le terrain autour de soi.
- **Découple données et livraisons de code.** Aujourd'hui, corriger un relief =
  re-tarball de 3,9 Go + rebuild. Ensuite : publier une version de planète.
- **Les serveurs de zone ne tirent que leur zone.**
- **L'éditeur** ouvre une scène de planète sans checkout de 3,9 Go.
- **Les briques existent déjà** : les offsets DSHP sont purement arithmétiques,
  `manifest.data_version` est déjà une empreinte blake2b des entrées,
  `ChunkDiskCache._validate_version` sait déjà purger, l'hôte nginx est déployé,
  et `export_elevation.py:156` a déjà un flag `WRITE_LOOSE_TILES` qui écrit
  l'arborescence `n{nside}/face_{face}/f{ipix}.r32`.

---

## 6. Inconvénients et pièges

**Le streaming ne règle pas le coût de génération des chunks.** Il déplace de la
donnée. Si « le calcul des chunks » est la vraie douleur, c'est un chantier
séparé — le chrono par chunk est commenté en `planet_terrain.gd:2819` et doit
être rallumé et décomposé avant de s'engager ici.

1. **Latence sur le chemin critique physique.** Aujourd'hui : lecture locale (µs)
   + génération (ms). Ensuite : RTT 30-200 ms + TLS + retries. Un joueur qui
   téléporte tombe à travers le sol. Il faut un plancher toujours-local, du
   prefetch anticipé, et surtout **`read_tile` ne doit jamais bloquer** : il
   renvoie « pas résident » et le chunk est re-queué. C'est le plus gros
   changement de code — `HeightPack.read_tile` est aujourd'hui *lock-free et
   synchrone*, appelé depuis `WorkerThreadPool` ; il faut faire remonter un état
   « pending » via `PlanetData.load_chunk_heightmap` jusqu'au pipeline de tâches.
2. **Le serveur dédié est un client plus dur que le client de jeu.** Cold start
   k8s avec N joueurs dispersés = thundering herd, collision exigée
   immédiatement. Pas de lazy HTTP côté serveur : pré-pull de sa zone au boot
   (init container / PVC), lazy en filet de sécurité uniquement.
3. **Désynchro de version client/serveur = joueurs qui traversent le sol.** Le
   serveur **doit imposer** le `data_version` par planète dans le handshake ; le
   client ne demande jamais « latest ».
4. **~~Un manifeste SHA256 par tuile s'auto-détruit.~~ Tranché : pas de manifeste.**
   Celui de tarsis_3 pèserait 537 Mo (sha256 brut) ou 134 Mo (tronqué à 8 o) pour aller
   chercher ~580 Ko de données utiles. L'adressage par chemin en fait l'économie
   complète ; l'intégrité passe par un CRC32 dans l'en-tête de tuile. Voir §7.
5. **18,0 M de fichiers, dont 16,8 M pour la seule tarsis_3.** Sharding d'arborescence
   obligatoire : le layout `n{nside}/face_{face}/f{ipix}` existant ne donne que
   12 répertoires par niveau, soit 1 M de fichiers par répertoire au niveau n1024. D'où
   le `f{ipix div 4096}/f{ipix}` de §7.
6. **Range et gzip ne cohabitent pas.** nginx ne sait pas servir proprement un
   `Content-Range` gzippé → objets pré-compressés au bake, pas de compression à
   la volée.
7. **Dépendance réseau pour voir le sol.** Solo / LAN / hors ligne, coupure FAI,
   dev dans le train. Garder un mode « télécharger toute la planète ».
8. **Cache client sans limite** si on ne l'encadre pas. Voir section 8.
9. **Egress et exploitation.** Un service de plus sur le chemin critique du jeu :
   TLS, monitoring, disponibilité, DDoS.
10. **Un ré-export devient un événement de masse.** `data_version` change → tous
    les clients re-téléchargent *et* re-bakent. Argument pour le
    content-addressing (diff gratuit) et le versionnement par planète.
11. **La donnée source ne contient pas 198 m d'information.** 438 048 sommets de
    contours pour 1,29 × 10¹⁰ échantillons stockés. C'est un coût *et* une
    opportunité (pack creux, Phase 1).
12. **Intégrité / triche** : risque faible (le serveur est autoritaire sur la
    collision). Signer le manifeste, pas chaque tuile.
13. **Éditeur** : même `HeightPack`, mais il ne peut pas bloquer sur HTTP dans
    `_process`. La pièce utile est un bouton « prefetch cette région » à côté de
    `editor_goto_lon/lat`.

---

## 7. Architecture retenue

Un fichier par tuile, pré-compressé, **adressé par chemin**, version dans l'URL. La
génération de mesh reste locale, avec le cache disque existant.

```
https://export…/planets/<planet>/<version>/n<nside>/f<ipix div 4096>/f<ipix>.bin
                                                    └── sharding ──┘
Cache-Control: public, max-age=31536000, immutable
```

- **L'URL est de l'arithmétique pure** sur `(nside, ipix, version)`. Aucun manifeste,
  aucun bootstrap, aucune indirection : le client sait déjà quelle tuile il veut.
- **Sharding obligatoire** : le seul niveau n1024 de tarsis_3 compte 12,58 M de tuiles ;
  les 12 répertoires de face donneraient 1 M de fichiers par répertoire.
- **Intégrité par CRC32 dans l'en-tête de chaque tuile** (4 octets dans le fichier). Ça
  couvre exactement ce que TLS ne couvre pas — un cache disque local corrompu, un mauvais
  objet servi par le CDN — sans le moindre manifeste.
- **Changement de version : purge complète du cache.** L'ensemble de travail d'un joueur
  fait ~580 Ko (283 tuiles × 2 048 o) ; le re-télécharger coûte moins cher que toute
  machinerie incrémentale. `ChunkDiskCache._validate_version` fait déjà exactement ça.
#### Plancher servi en un objet — ✅ FAIT (`floor.bin`)

Les niveaux grossiers n1…n8 ne servent pas au sol. Mesuré sur le cache d'une session
réelle : **95 des 1 020 tuiles du plancher, soit 9 %**, et zéro en n1/n2 alors même que
`nside_min = 1`. Une tuile n8 fait 813 km de côté, l'horizon depuis le sol est à quelques
dizaines de kilomètres. Ce à quoi le plancher sert, c'est la planète vue de loin — en
orbitant, on en balaye toute la sphère aux niveaux grossiers — et la résilience
hors-réseau.

| niveau | publié | utilisé en session | côté d'une tuile |
|---|---|---|---|
| n1 | 12 | **0** | 6 504 km |
| n2 | 48 | **0** | 3 252 km |
| n4 | 192 | 20 | 1 626 km |
| n8 | 768 | 75 | 813 km |

Le coût n'est donc pas le volume mais le **nombre d'allers-retours** : 1 020 tuiles pour
1,88 Mio, soit des secondes de bande passante mais des minutes de latence sur un vrai
réseau. Le publieur émet un `floor.bin` par version — index de 16 octets par entrée, puis
les charges utiles **exactement telles qu'elles seraient servies pour une tuile isolée**,
si bien que le client les écrit sans les décoder et qu'un plancher et une tuile ne peuvent
pas diverger. `--verify` compare les deux chemins.

Récupéré **à l'approche de la planète** et non au menu : le travail est mis en file au
moment où `for_planet()` construit la source, donc sur le fil de téléchargement, une
requête, au moment où cela devient utile. Précharger les 19 corps au menu coûterait 36 Mio
et ne se justifierait que pour jouer réseau coupé.

Vérifié bout en bout depuis un cache vide, contre l'arbre publié : **plancher complet en
624 ms, 1,88 Mio, 2 requêtes** (le pointeur de version puis l'objet), aucune tuile
illisible.

Cette vérification a coûté un plantage, qui vaut d'être noté : sonder le plancher depuis le
thread principal pendant que le fil téléchargeait des tuiles a donné un **signal 11** dans
les entrailles de `HTTPClient`. La connexion conservée était partagée, et un commentaire
affirmait qu'elle n'appartenait qu'au fil sans que rien ne le garantisse. `_reuses_connection()`
le vérifie désormais : tout appelant qui n'est pas le fil de téléchargement reçoit une
connexion jetable, c'est-à-dire le comportement d'origine. En pratique cela ne concerne que
`open_planet`, une requête par planète. Le témoin `floor.done` n'est posé qu'une fois tout écrit, si
bien qu'un arrêt en cours se retraduit par un nouveau téléchargement et non par un
plancher à trous.

- **Plancher local** : les niveaux n1…n8 (1 020 tuiles par corps) restent embarqués dans
  le `.pck`, **26 Mo au total**. La planète est toujours visible sans réseau et une vue
  orbitale n'émet que ~120 requêtes.
- **Couverture totale garantie** : jamais de trou, quelle que soit la position.

### Pourquoi pas l'adressage par contenu

L'alternative — nommer les objets par le hash de leur contenu, avec un manifeste
`(nside, ipix) → hash` — apporte trois choses, et les trois s'effondrent à la mesure.

**Déduplication : 1 %.** Mesurée sur les 65 532 tuiles de tarsis_3, y compris quantifiée
à 10 m (voir §4). L'argument principal du contenu-adressage n'existe pas sur ce dataset.

**Mises à jour incrémentales : sans objet.** Elles économiseraient au mieux les ~580 Ko
d'un working set. La complexité ne se rentabilise pas.

**Intégrité : obtenue plus simplement** par un CRC32 dans l'en-tête de tuile.

Et le coût est réel : le manifeste de tarsis_3 pèserait **537 Mo** en sha256 brut,
134 Mo tronqué à 8 octets — pour aller chercher 580 Ko de données.

**La variante « pointeur »** (une URL par chemin qui renvoie le hash, puis une seconde
requête vers le blob adressé par contenu) résout bien ce bootstrap : c'est un manifeste
shardé à une entrée par fichier, récupéré paresseusement. Mais elle double le nombre
d'objets (33,5 M pour tarsis_3), et un fichier-pointeur de 64 octets occupe un bloc de
4 Kio — soit **68,7 Go rien qu'en pointeurs**, autant que les données (atténuable par
`mkfs.ext4 -O inline_data`, qui loge ces fichiers dans l'inode). Le tout pour récupérer
la dédup à 1 %.

**Le fond du problème est l'éparpillement.** 283 tuiles utiles sur 16,78 M, c'est
0,0017 % de la pyramide. Un index à granularité région (4 096 hashes par fichier, 32 Ko)
obligerait à en chercher 20 à 50, soit 640 Ko à 1,6 Mo — **plus que les données
indexées**. Toute granularité d'index sur-livre. L'adressage par contenu est le bon
outil quand les blobs sont gros, redondants et rarement modifiés en bloc ; ici ils sont
minuscules, uniques à 99 % et l'ensemble de travail est infime.

### Couche optionnelle : meshes bakés

À n'envisager **qu'après** stabilisation de la clé de cache mesh (`v27`, `_brg`,
`_cor`), sinon chaque patch client la purge intégralement. Toujours avec fallback
sur les tuiles :

- niveaux grossiers globalement (n1…n64 = 65 536 objets, ~1,2 Go/planète) ;
- zones chaudes désignées en LOD0 (spawn, villes) : un carré de 20×20 km à n8192
  ≈ 634 chunks = 11,4 Mo ; vingt zones ≈ 230 Mo.

---

## 8. Cache client — ✅ FAIT (`TileCacheLru`, budget 128 Mio)

Le budget de 400 Mio initialement retenu ici supposait deux tiers, tuiles **et** meshes, et
disait explicitement que « en pratique les 400 Mio serviront aux meshes générés ». Le
streaming de meshes ayant été écarté (§3, 14,5 To d'inventaire), ce tier n'existe pas et
personne ne consomme ce budget. Les chiffres ci-dessous sont mesurés sur l'export
tarsis_3 n256 publié et sur une session de jeu réelle.

### Le budget se compte en fichiers, pas en octets

| | |
|---|---|
| tuiles publiées (tarsis_3, n1…n256) | 674 884 |
| données | 849 Mio |
| **sur disque** | **2,6 Gio** |
| taille d'une tuile | médiane 1383 o, max **2060 o** |

Aucune tuile n'atteint 4 Kio, donc chacune occupe exactement un bloc de système de
fichiers : l'écart données/disque est de ×3,1, uniforme. Un budget exprimé en octets de
données consommerait trois fois ce qu'il annonce. `TileCacheLru` convertit une fois
(`BLOCK_BYTES = 4096`) et raisonne ensuite en **nombre de fichiers**.

### Pourquoi 128 Mio

| niveau | cumul tuiles | Mio disque | côté d'une tuile | par échantillon |
|---|---|---|---|---|
| n8 | 1 024 | 4 | 813 km | 25,3 km |
| **n16** | **4 095** | **16** | **407 km** | **12,7 km** |
| n32 | 16 304 | 64 | 203 km | 6,3 km |
| n64 | 62 345 | 244 | 102 km | 3,2 km |
| n256 | 674 884 | 2 636 | 25 km | 0,79 km |

Une tuile couvre `tile_res` = 32 échantillons de côté : les deux colonnes de droite
diffèrent d'un facteur 32, et c'est la première qui dit combien de tuiles une traversée
consomme.

**C'est un plafond, pas une cible.** Occupation réelle mesurée après une session de jeu,
par niveau :

    n4:20  n8:75  n16:91  n32:94  n64:91  n128:86  n256:78   = 535 tuiles, 2,2 Mio

La répartition est plate — c'est la signature de la pyramide de LOD : le joueur voit un
nombre à peu près constant de chunks, réparti sur les niveaux. Le cache ne croît donc pas
avec le niveau le plus fin, mais avec la surface distincte visitée.

- La même session à la résolution visée n1024 demanderait **2 095 tuiles, 8,2 Mio** (les
  niveaux n512 et n1024 s'ajoutent, ×4 et ×16 sur la surface déjà couverte en n256).
- 128 Mio vaut donc **seize fois** la session la plus lourde qu'on ait mesurée. Le budget
  n'est jamais réservé : il ne coûte rien tant qu'il n'est pas atteint, et n'existe que
  pour le cas pathologique du joueur qui survole la planète des heures durant.
- Il reste sous un vingtième de la planète complète en n1024 : le cache ne peut pas
  dégénérer en « télécharger la planète », ce qu'un budget de 400 Mio autorisait déjà à
  n256 (la moitié des données de la planète).

Le budget s'exprime en **mébioctets** — les chiffres ci-dessus viennent de `du` et de
divisions par 1048576, tout est binaire. Réglable par `--tile-cache-mb=`, `DS_TILE_CACHE_MB`, ou `[stream] tile_cache_mb` du
`.ini` — la cascade habituelle. `0` désactive l'éviction.

### Niveaux épinglés plutôt que LRU

**n1…n16 n'est jamais évincé** : 4 095 tuiles, 16 Mio, la planète entière à 12,7 km par
échantillon. Une
tuile n16 sert des milliers de chunks ; la laisser évincer par un déplacement au sol
rendrait la vue orbitale à nouveau payante. Ces tuiles ne sont même pas suivies par
l'index, donc ne consomment pas le budget — plafond réel ~144 Mio.

C'est aussi moins cher que prévu : ce plancher était estimé à 26 Mio pour n1…n8 seulement,
alors qu'il coûte 4 Mio mesurés et peut donc descendre deux niveaux plus bas.

### Index d'usage

Godot n'expose pas d'atime (`FileAccess.get_modified_time` rend le mtime, et lire ne le
met pas à jour). `index.bin` est maintenu dans le répertoire de version et écrit à
l'arrêt de la source. Quand il manque — premier lancement, ou arrêt brutal — on parcourt
le répertoire : l'ordre est alors inconnu et la première éviction arbitraire, mais **le
budget reste tenu**, ce qui est la propriété qui compte. Ce parcours porte sur l'occupation
réelle — quelques centaines à quelques milliers de fichiers — et non sur le plafond. L'éviction purge jusqu'à 90 % du
budget pour ne pas se relancer à chaque tuile écrite ensuite.

### Obsolescence

Version dans le *chemin* (`user://tile_cache/<planet>/<data_version>/`). Au chargement de
planète, `purge_other_versions()` supprime tout répertoire dont la version diffère de
celle annoncée par le serveur. O(1), et c'est déjà le pattern de `chunk_disk_cache.gd:51`.

---

## 9. Phases d'implémentation

### Phase 0 — mesurer avant d'écrire du code — ✅ FAITE

Le rig est implémenté (`scenes/planet/terrain_profiler.gd`, suite GUT
`test/unit/test_terrain_profiler.gd`, 13/13). **Il reste à le faire tourner sur une
vraie session et à lire les chiffres** — c'est ça, la sortie de la phase 0.

**S'armer** comme les autres compteurs manuels du projet : `--perf` en ligne de
commande, `DS_PERF=1` dans l'environnement, ou `[debug] perf` dans l'ini. Éteint, le
coût est d'un test booléen par section instrumentée. Une ligne toutes les 10 s, jamais
une par chunk.

**Ce que le rig produit**, trois lignes `[TerrainProf]` :

```
meshes=N mean=X.XXms | prepare=% verts=% index=% normals=% skirt=% overlay=% surface=%
tuiles=Y% du temps mesh (Z.ZZms/mesh) | asm=n×ms col=n×ms | cache save=n×ms load=n×ms
tuiles distinctes=D (R demandes, L lectures disque) | n1:3 n8:20 n16:35 …
```

- Les phases suivent les sections `# --- ... ---` de `PlanetChunk.generate_mesh`.
- **`tuiles=Y%` est la ligne qui décide de la phase 3** : c'est exactement la part du
  coût qu'un passage en streaming déplacerait sur le réseau. Le reste ne bougerait pas.
  Si Y est marginal, le streaming ne touchera jamais au coût CPU et il faut chercher
  ailleurs.
- **`tuiles distinctes=D` avec sa ventilation par niveau** est la mesure directe de ce
  que la section 3 n'estime que par simulation (273 tuiles / 1,07 MiB). C'est ce
  chiffre qui dimensionne le cache client, le prefetch et l'egress.

**Où c'est branché** (tout est inerte hors `PropNet.prof_on`) :

| point de mesure | fichier |
|---|---|
| 7 bornes de phase dans `generate_mesh` | `planet_chunk.gd` |
| recensement + chrono des tuiles | `planet_data.gd` (`load_chunk_heightmap`, mutex dédié) |
| assemblage main-thread, collision serveur | `planet_terrain.gd` |
| `ResourceSaver` / `ResourceLoader` du cache | `chunk_disk_cache.gd` |
| compteurs partagés | `prop_net.gd` (`prof_chunk_*`, `prof_asm_*`, `prof_col_*`, `prof_cache_*`) |

**Modèle de threads** : `generate_mesh` tourne sur `WorkerThreadPool` et n'écrit dans
aucun compteur partagé — il remplit un `Dictionary` local à l'appel, que le thread
principal reverse via `TerrainProfiler.commit_mesh()` après complétion de la tâche. Le
recensement de tuiles, lui, est écrit depuis les workers et porte son propre mutex.

**Effet de bord volontaire** : le `print` de `_create_chunk` (serveur) sortait une ligne
**par chunk**, inconditionnellement. Chaque `print` traverse CustomLogger → Obs → le pont
OpenTelemetry C# et coûte des millisecondes : sur le chemin de création de chunk il
mesurait surtout son propre coût, et il polluait les logs serveur en continu. Remplacé
par une accumulation dans `prof_col_*`.

#### Relevés — 2026-09-07

##### Client, joueur en jeu — le relevé qui répond

```
meshes=3 mean=28.99ms | prepare=2% verts=36% index=0% normals=61% skirt=0% overlay=1% surface=0%
tuiles=144.4% du temps mesh (41.87ms/mesh) | asm=488×2.86ms col=0 | cache save=3×1.01ms load=488×0.56ms
tuiles distinctes=283 (23 dem/s, 11597 demandes, 294 lectures disque)
    dir_chunk=4360 dir_query=895 boundary=240  2.1 tuiles/appel
    | n1:12 n4:21 n8:45 n16:67 n32:66 n64:72
```

**1. Le fait dominant : 3 meshes générés pour 488 chunks assemblés — 99,4 % viennent du
cache disque.** Le budget terrain d'un client tiède se répartit ainsi :

| poste | coût | thread |
|---|---|---|
| assemblage (`_assemble_visual_chunk`) | 488 × 2,86 ms = **1,40 s** | **principal** |
| lecture du cache disque (`ResourceLoader`) | 488 × 0,56 ms = 273 ms | principal |
| génération de mesh | 3 × 28,99 ms = 87 ms | worker |

L'assemblage coûte **16× la génération**, et il est sur le thread principal — c'est lui
qui fait les à-coups, pas la génération. Ce classement était invisible avant : le seul
chrono qui existait mesurait l'assemblage et était commenté.

**2. Quand la génération a lieu, elle est dominée par les normales (61 %), puis les
sommets (36 %).** Tout le reste — indices, jupes, overlays, surfaces — est sous 2 %. Un
cache froid paie 29 ms par chunk, et les normales analytiques en sont les deux tiers.

**3. La simulation de la section 3 est validée.** 283 tuiles distinctes mesurées contre
**273 estimées** par rejeu de `_traverse` : 3,7 % d'écart, sur des positions de caméra
différentes. À `tile_res 50`, ces 283 tuiles font **2,83 Mo** — l'ordre de grandeur du
streaming est confirmé par la mesure, pas seulement par le calcul.

**4. Le cache de tuiles est quasi parfait** : 294 lectures disque pour 283 tuiles
distinctes sur 11 597 demandes. Onze relectures seulement (évictions LRU).

**5. Troisième bug d'affichage, corrigé** : `tuiles=144.4% du temps mesh`. Le numérateur
était le compteur GLOBAL — incluant les 488 chunks servis par le cache, les requêtes de
gameplay et les spawners — pendant que le dénominateur ne couvrait que les 3 meshes
générés. Le temps de tuile est désormais mesuré **par thread, à l'intérieur de
`generate_mesh`** (`PlanetData.prof_thread_tile_usec()`), donc comparable au temps mesh.
La ligne des phases porte aussi le taux de cache, sans lequel `mean=28.99ms` se lit
comme le coût d'un chunk alors que 99,4 % des chunks ne le paient jamais.

##### Client, CACHE FROID — la réponse de la phase 0

```
meshes=293 (293 assemblés, 0.0% depuis le cache) mean=623.09ms
    | prepare=0% verts=24% index=0% normals=74% skirt=0% overlay=1% surface=0%
tuiles=9.4% du temps mesh (58.42ms/mesh) | asm=293×6.33ms | cache save=293×0.59ms load=0
tuiles distinctes=29 (34385 dem/s, 1294558 demandes, 41 lectures disque)
    dir_chunk=677462 dir_query=627 boundary=108047  1.6 tuiles/appel | n1:12 n64:17
```

**La lecture de tuiles pèse 9,4 % du temps de génération. Les normales en pèsent 74 %.**
C'est la ligne que la phase 0 devait produire, et elle tranche : **le streaming ne peut
rien gagner côté CPU.**

Et c'est encore plus net que le pourcentage ne le suggère. **1 294 558 demandes de
tuiles pour 29 tuiles distinctes** — 44 600 demandes par tuile, 41 lectures disque au
total. Ces 9,4 % ne sont donc pas de l'entrée/sortie : c'est le coût de la mécanique de
lookup (formatage de clé, mutex, parcours LRU) autour d'une `Image` **déjà en RAM**.
Changer l'origine de la tuile — disque local ou HTTP — ne toucherait que les
29 premières lectures. **L'impact CPU du streaming est mesurablement nul.**

**D'où viennent 1,29 million de demandes ?** Le calcul des normales échantillonne la
hauteur en **quatre points par sommet** (`dir_l`, `dir_r`, `dir_b`, `dir_t`, gradient
analytique, `planet_chunk.gd:845-860`), en plus de l'échantillon du sommet lui-même.
Mesuré : 785 509 échantillons pour 293 meshes = **2681 par mesh**, chacun coûtant 1,6
lookup de tuile. À `res 32` un chunk n'a que 1089 sommets.

**Le coût absolu est le vrai sujet.** 623 ms par chunk en moyenne (1408 ms sur les
premiers relevés, avant que la moyenne ne descende), soit 293 × 623 ms = **182 s de
temps worker**, ~46 s de temps réel sur 4 tâches parallèles, rien que pour le terrain
d'une première visite. C'est cohérent avec la lenteur d'entrée dans le monde.

**Comparé au cache chaud** (relevé précédent, 488 chunks) : 99,4 % de succès de cache,
génération réduite à 87 ms au total. Le cache disque est ce qui rend le jeu jouable ; il
ne supprime pas le coût, il le paie une seule fois.

**Réserve de mesure, importante ici.** L'enveloppe de profilage prend un mutex partagé et
formate une clé à chaque appel de tuile, et le compteur d'échantillonneurs en prend un
autre — soit ~2 millions de verrous depuis 4 threads workers concurrents. À 182 s de
total cela reste de l'ordre de quelques pour cent, mais **les 9,4 % sont un plafond**
(le numérateur contient cette surcharge), et le partage relatif est légèrement biaisé
vers `normals`, qui fait les quatre cinquièmes des échantillons. La conclusion —
normales ≫ tuiles — a beaucoup trop de marge pour en être affectée.

##### Suite du chantier CPU — deux correctifs mesurés, 2026-09-08

Hors périmètre du streaming, mais c'est la phase 0 qui les a désignés. Relevés à cache
froid, **497 meshes dans les deux cas** et `dir_chunk=714694` à l'identique — donc
directement comparables.

| | avant | après | |
|---|---|---|---|
| **temps par mesh** | 379,5 ms | **254,0 ms** | **−33 %** |
| normals | 281,3 ms | 162,0 ms | −42 % |
| — crack (Voronoï ×4/sommet) | 108,6 ms | **15,6 ms** | **−86 %** |
| — échantillons de hauteur | 170,4 ms | 144,8 ms | −15 % |

**Correctif 1 — saut du Voronoï de crack.** `crack_offset` scindé en distance au bord +
profil ; le gradient saute ses quatre Voronoï quand le sommet est à plus de
`demi-largeur + 2ε` d'une crack, où les offsets sont nuls par construction. Sortie
bit-identique, prouvée contre une copie figée de l'arithmétique d'origine.

**Correctif 2 — `get_pixel` remplacé par de l'indexation float.** Les tuiles étant en
`FORMAT_RF`, leurs octets SONT les float32 ; `img.get_pixel(x, y).r` ne faisait que les
relire en construisant une `Color` par texel (~17 400 par chunk). Cache
`_chunk_floats` parallèle, une seule prise de verrou comme avant.

**Attribution** : sur les 125 ms gagnées par chunk, le crack en apporte **93 ms (74 %)**
et les floats **26 ms (21 %)**. Les deux intuitions initiales étaient inversées — c'est la
mesure qui a tranché à chaque fois.

**Ce qui domine maintenant** : l'échantillonnage de hauteur pèse **144,8 ms, soit 57 % du
temps d'un chunk**. Quatre échantillons par sommet pour le gradient analytique. Les
supprimer demande de calculer le gradient par différences finies sur la grille
`_chunk_heights` déjà remplie — ce qui exige un halo d'un sommet pour l'accord aux
coutures, et **change la géométrie** (bump `v27`, re-bake). C'est désormais le seul gros
poste restant côté génération.

##### Ce que ça ouvre, hors de ce document

`_assemble_visual_chunk` (thread principal, 2,86 ms × 488 à chaud, 6,33 ms × 293 à
froid) et le calcul des normales (74 % de la génération, 4 échantillons par sommet à
travers un lookup verrouillé) sont les deux vraies cibles du « coût de calcul des
chunks ». Ni l'une ni l'autre n'est touchée par le streaming. Deux pistes visibles dans
le relevé, à instruire séparément :

- le « touch » LRU de `load_chunk_heightmap` fait un `Array.find()` linéaire sur
  `_cache_order` plus un formatage de clé `"hp_n%d_p%d"` — à 1,29 million d'appels ;
- les quatre échantillons de gradient par sommet retombent presque toujours sur la même
  tuile que le sommet lui-même : la résoudre une fois par sommet, ou calculer le
  gradient depuis la grille de hauteurs déjà chargée, supprimerait l'essentiel du
  volume.

##### Serveur — toujours aucun chunk de collision

`col=0` et `cache load=0` alors que le client construisait 488 chunks au même moment :
aucune résidence de zone n'a été demandée de tout le run. **À élucider** — soit Horizon
n'a pas envoyé l'entrée de zone, soit le joueur n'était dans aucune zone gérée par le
serveur. Le rig rend le trou visible, il ne l'explique pas.

Les 3568 `dir_chunk` du serveur au repos sont identifiés : ils viennent de
`_build_bridge_plans` (`planet_data.gd:1825`, 35 plans de ponts sur tarsis_3), pas de la
génération de terrain.

##### Ce que ces relevés changent pour la décision

Le streaming des tuiles **reste justifié** : il résout le problème de disque (3,9 Go →
~26 Mo), il débloque le 198 m sur tarsis_3, et les 283 tuiles / 2,83 Mo mesurées
confirment le dimensionnement de la section 3.

Mais **la question du coût CPU est tranchée, et la réponse est non.** À cache froid, la
lecture de tuiles pèse 9,4 % de la génération, et ces 9,4 % sont de la mécanique de
lookup sur une `Image` déjà en RAM — 1,29 million de demandes pour 29 tuiles, 41 lectures
disque. Le streaming ne déplacerait que ces 41 lectures.

Les deux problèmes posés au départ sont donc **indépendants**, et il faut les traiter
séparément : le streaming pour le disque, les normales et l'assemblage pour le CPU.

**Note de lecture** : les `5-7 µs/demande` incluent la mesure (l'enveloppe formate une
clé `"hp_n%d_p%d"` et prend un mutex à chaque appel). À prendre comme un plafond. À
surveiller aussi : le « touch » LRU de `load_chunk_heightmap` fait un `Array.find()`
linéaire sur `_cache_order` — inoffensif à 2 tuiles, à 283 il coûte déjà.

**Ce qui reste à faire dans cette phase :**

- [x] ~~Session **client** réelle avec `--perf`~~ — fait, voir ci-dessus.
- [x] ~~Comparer `tuiles distinctes` mesuré aux 273 simulés~~ — 283, écart 3,7 %.
- [x] ~~Identifier l'appelant des demandes au repos~~ — `_build_bridge_plans`.
- [x] ~~**Sonder tarsis_3** avant tout export n1024, trancher dense vs creux~~ — fait,
      et l'export l'a confirmé : creux, **69,5 % élagué** contre 65 % projeté.
- [x] ~~**Élucider `col=0` côté serveur**~~ — configuration, pas bug (§10).
- [x] ~~Relevé client **cache froid**~~ — fait : 623 ms/chunk, normales 74 %, tuiles
      9,4 %. La phase 0 a sa réponse.
- [x] ~~**Choisir la résolution cible par planète.**~~ Acté : tarsis_3 à 198 m
      (`n1024 × tr32`), les 19 autres planètes et lunes à 4 065 m (`n64 × tr25`).

### Phase 1 — réduire la donnée avant de la streamer — ✅ FAITE ET VALIDÉE EN JEU

- DSHP v2 : **uint16** au lieu de float32 (le float32 offre des pas de 0,163 m sur
  10 700 m d'amplitude — sans objet). Gain sur le transfert, pas sur le disque
  (blocs de 4 Kio).
- Deflate/zstd par tuile.
- **Pack creux** : voir ci-dessous, désormais mesurable.

#### Résultat (2026-09-08) — livré, exporté, validé en jeu

DSHP v2 : échantillons uint16 et pack creux. Lecteur bi-format (les packs v1 restent
lisibles, donc les planètes se ré-exportent une par une), écriture en deux passes avec
élagage **en cascade** — chaque tuile est comparée à la reconstruction que le client
obtiendra, pas à son parent réel, ce qui borne l'erreur visible à exactement epsilon quelle
que soit la profondeur.

**tarsis_3_2** (lune, n64 × tr25, 448 m) : 17,9 % élagué, **163,8 Mo → 64,1 Mo (2,6×)**.

**tarsis_3** (n256 × tr32, 794 m, ~30 min) : 35,7 % élagué, **1 318 Mo**, contre 655 Mo à
2 033 m auparavant — soit **2,6× plus fin pour 2× la taille**. Validé en jeu : la remontée
de niveau, les coutures et la collision se comportent correctement alors que 41,6 % des
tuiles du niveau fin sont absentes.

| niveau | n16 | n32 | n64 | n128 | n256 |
|---|---|---|---|---|---|
| élagué | 0,1 % | 0,7 % | 6,4 % | 22,1 % | **41,6 %** |

L'élagage double à chaque niveau, exactement comme le prédit la physique du problème :
l'écart à l'upsample du parent varie comme la dérivée seconde × (taille de cellule)², donc
il chute d'un facteur 4 par niveau.

**Le ratio cascade/borne est stable à 0,869** (n128 : 22,1/25,6 ; n256 : 41,6/47,6). C'est
lui qui rend la projection fiable, puisque le sondage ne mesure que la borne :

| | n512 | n1024 | total |
|---|---|---|---|
| cascade projetée | 55 % | 70 % | **65 % élagué** |
| **cascade MESURÉE** | **58,4 %** | **75,2 %** | **69,5 % élagué** |
| pack à 198 m, projeté | | | ~12 Go, 5,8 M fichiers, ~7 h |
| **pack à 198 m, MESURÉ** | | | **9,75 Gio, 5 109 933 fichiers** |

L'export a été fait : la projection était **conservatrice de 4,5 points**, et le pack pèse
un cinquième de moins qu'annoncé. Le ratio cascade/borne de 0,869 a donc bien tenu deux
niveaux plus bas que là où il avait été mesuré, ce qui était tout le pari de la méthode.

**Correction d'estimation à retenir** : la durée annoncée était d'abord de 35 h, calée sur
un export n64 complet. Faux d'un facteur 5 — à n64 l'échantillonnage est minoritaire devant
les coûts fixes (extraction des contours, décimation, construction du TIN, raster de repli).
Recalibré sur un run réellement dominé par l'échantillonnage.

#### Le pack creux, et comment décider

Au bake, une tuile fine n'est pas stockée si l'upsample bilinéaire de son parent la
reproduit à moins d'epsilon près ; à la lecture le client remonte d'un niveau, ce que
`PlanetData.sample_nside_for()` sait déjà faire.

Le taux d'élagage dépend entièrement du relief et change à chaque ré-export. D'où
**`tools/analyze_pack_sparsity.py`** : il mesure, sur n'importe quel `heights.pack`,
l'écart entre chaque tuile et la prédiction depuis son parent, et projette le gain par
seuil. À rejouer par planète et après toute modification de terrain — c'est l'outil qui
permet de basculer dense ↔ creux avec un chiffre plutôt qu'une intuition.

```
python3 tools/analyze_pack_sparsity.py <pack> [--sample N] [--json rapport.json]
```

Tests : `python3 test/unit/test_pack_sparsity_py.py` (6 tests). Le plus important couvre
le **mapping de quadrant NESTED** : si l'enfant `k` était rattaché au mauvais quadrant du
parent, l'outil rapporterait des erreurs énormes partout et on conclurait à tort « pack
creux inutile ». Un faux négatif silencieux sur une décision d'architecture.

#### Mesure sur tarsis_3 (n64 × tr50, 65 520 comparaisons)

| niveau | tuiles | err. max médiane | ≤ 1 m | ≤ 5 m | ≤ 10 m | ≤ 25 m |
|---|---|---|---|---|---|---|
| n8 | 768 | 292,9 m | 0,0 % | 0,4 % | 4,4 % | 16,7 % |
| n16 | 3 072 | 68,4 m | 0,1 % | 9,0 % | 23,4 % | 36,4 % |
| n32 | 12 288 | 21,2 m | 1,9 % | 27,6 % | 39,9 % | 52,1 % |
| **n64** | **49 152** | **8,8 m** | 13,6 % | **42,5 %** | **51,7 %** | 63,0 % |

La colonne « ≤ 10 m » croît de 4 % à 52 % en descendant : plus la pyramide s'affine, plus
elle est prédictible — exactement ce que le sur-échantillonnage annonce. **tarsis_3 part
à n1024, quatre niveaux plus bas**, donc l'élagage devrait y être bien supérieur. C'est
une extrapolation, pas une mesure : seul un export dense n1024 permettra de trancher.

**epsilon est un compromis de qualité, pas un gain gratuit.** À 10 m on élague la moitié
des tuiles, mais 10 m de relief disparaissent. L'erreur est lisse (écart à une
interpolation, pas une marche) et render comme collision passent tous deux par
`sample_nside_for`, donc **ils ne peuvent pas diverger** — le terrain est simplement
aplani d'epsilon. À 1 m l'élagage tombe à 13,6 % et ne justifie plus la complexité.

**L'index de présence.** Les offsets arithmétiques meurent avec les trous. Un bitmap
(2,1 Mo pour tarsis_3) est plus gros que les 580 Ko de working set — même piège que le
manifeste. Le 404-et-remonter coûterait 2 RTT sur 80 % des requêtes. La réponse propre :
**4 bits dans l'en-tête de chaque tuile disant lesquels de ses enfants existent**, coût
nul, aucun index. À vérifier : un chunk à n8192 échantillonne directement n1024 sans
passer par n512, donc le prefetch doit garantir la résidence du parent.

#### Décider sans payer 34 heures d'export

Passer tarsis_3 de `n64 × tr50` à `n1024 × tr32` représente **1,72 × 10¹⁰ évaluations du
TIN** contre 1,64 × 10⁸ aujourd'hui — un facteur **105**. L'export actuel prenant ~20 min,
l'export dense correspondant demanderait **~34 heures** et 68,7 Go écrits, pour répondre
à une question binaire.

Cette question n'a pas besoin de toute la planète. **`tools/qgis/probe_pack_sparsity.py`**
construit le même TIN que l'exporteur (mêmes contours, même décimation, même
interpolateur), tire quelques centaines de pixels parents au hasard à chaque transition
de niveau n64→n128 … n512→n1024, échantillonne parents et enfants, et projette le taux
d'élagage. **~44 s d'échantillonnage** au lieu de 34 h, à quelques points de pourcentage
près.

```
# console Python de QGIS, projet de la planète ouvert
exec(open('.../tools/qgis/probe_pack_sparsity.py').read())
```

Il réutilise `_upsampler` de `tools/analyze_pack_sparsity.py` : le mapping de quadrant
NESTED est la seule partie délicate, elle est testée, et elle ne doit exister qu'à un
seul endroit.

**Ordre des opérations recommandé** : sonder d'abord, décider dense ou creux, puis lancer
l'export une seule fois dans le bon mode — plutôt qu'un export dense de 34 h suivi d'un
second export si la mesure conclut au creux.

#### Ce que la mesure a révélé sur l'ensemble des exports

Passé sur les 19 packs, l'outil a sorti autre chose que des taux d'élagage.

**14 corps sur 19 partagent un seul et même blob d'élévation, entièrement plat.**
Hachage des blobs (en-tête exclu) :

| blob | corps | relief réel |
|---|---|---|
| `f943725f` | tarsis_2, tarsis_3_1, tarsis_4_1, tarsis_4, tarsis_5_2…5_6, tarsis_6_1, tarsis_6_2, tarsis_6, tarsis_7, tarsis_8 | **0 m** |
| `4af4a744` | tarsis_3_2, tarsis_5_1 | 929 m |
| `904b5cc3` | tarsis_1 | 6 236 m |
| `a95c524e` | tarsis_3 | 7 147 m |
| `c489de25` | tarsis_5 | 7 147 m |

Ces 14 corps déclarent `elev_min 0 / elev_max 1000` — le gabarit par défaut — et 100 %
de leurs tuiles échantillonnées sont constantes. **Ils stockent 14 fois le même vide :
917 504 fichiers et 3,8 Go de disque pour une donnée qui tient en un nombre.**

Conséquence directe sur la décision « 19 autres corps à 4 065 m » : elle porte en réalité
sur **quatre jeux de données distincts**, pas dix-neuf. Avant d'investir dans un pack
creux, le gain le moins cher est de ne pas exporter de pyramide pour un corps sans
relief — le runtime retombe déjà sur une surface lisse quand le pack est absent.

**Bug latent trouvé au passage : le nom de planète de l'en-tête de pack n'est pas mis à
jour par le swap.** `tools/qgis/swap_sandbox_gaea_export.py` (échange des créneaux
Sandbox/Gaea) réécrit `manifest.json` mais jamais le JSON embarqué dans l'en-tête de
`heights.pack`. Résultat : le pack de `tarsis_3_chunks/` s'annonce `tarsis_4`, celui de
`tarsis_4_chunks/` s'annonce `tarsis_3`, idem pour les lunes `_1` et `_2`. Inoffensif
aujourd'hui — `PlanetData` lit le `manifest.json`, qui fait autorité — mais son **repli
sur l'en-tête quand le fichier manque donnerait le mauvais `planet_name`, donc la
mauvaise clé de `ChunkDiskCache`**, et croiserait les caches de deux planètes. Le
correctif est un patch en place : les deux noms ont la même longueur, `json_len` ne
bouge pas. `analyze_pack_sparsity.py` signale désormais le désaccord.

### Phase 2 — bake et publication — ✅ FAITE, CHAÎNE HTTP VÉRIFIÉE

`tools/publish_tiles.py` éclate un `heights.pack` en arborescence servable. Outil séparé
de l'exporteur : il se rejoue sans ré-exporter, marche sur v1 comme sur v2 (les planètes
encore en float32 dense se publient sans être ré-exportées), et se teste sur des packs
synthétiques.

```
dist/<planet>/latest.json                              pointeur de version, no-cache
dist/<planet>/<version>/manifest.json
dist/<planet>/<version>/n<nside>/f<shard>/f<ipix>.bin  une tuile
dist/<planet>/<version>/n<nside>/f<shard>/present.bin  présence du shard
```

**La version est dans le chemin**, donc chaque objet est immuable : publier n'invalide
rien, on écrit un nouvel arbre et on bascule le pointeur. Retour arrière trivial, clients
en vol non perturbés.

**Carte de présence par shard.** Sur un pack creux 35 à 65 % des tuiles n'existent pas.
Sans indication le client le découvrirait par un 404 — deux allers-retours sur la majorité
des requêtes. 512 octets renseignent sur 4096 tuiles voisines d'un coup. C'est
l'alternative bon marché au manifeste global (537 Mo pour tarsis_3, contre 580 Ko de
working set).

**Enveloppe de 12 octets par tuile** : magie, CRC32, flags. TLS couvre le transport, pas
un cache disque corrompu ni un mauvais objet servi par un CDN — et la magie attrape la
page d'erreur HTML mise en cache à la place d'une tuile. 0,9 % de surcoût.

#### Mesures réelles

| | tuiles | durée | données | disque (blocs 4 Kio) |
|---|---|---|---|---|
| tarsis_3_2 | 53 794 | 9 s | 44 Mo | **211 Mo** |
| tarsis_3 (n256) | 674 624 | 2 min 08 | 849 Mo | **2,6 Go** |

Le deflate ramène les charges utiles à **64 %** du brut. Mais **849 Mo de données occupent
2,6 Go sur disque** : la tuile médiane fait 1 384 o et un bloc ext4 en fait 4 096. Comme
pour l'uint16, la compression divise la bande passante par deux et ne gagne rien sur le
disque — seul un volume en blocs de 1 Kio le fait.

| tarsis_3 à 198 m (projeté) | données | disque |
|---|---|---|
| blocs 4 Kio (défaut) | 7 Go | 23,8 Go |
| **blocs 1 Kio** (`mkfs.ext4 -b 1024`) | 7 Go | **11,9 Go** |

#### Vérification

`--verify` relit l'arborescence écrite et la compare au pack. `--verify-http <URL>` fait
la même comparaison contre l'arbre **servi** : chemins, en-têtes, enveloppe, contenu, et
le fait qu'une tuile absente réponde bien 404 plutôt qu'une page d'erreur en 200.

Relevé sur un nginx local : **311 tuiles vérifiées, 21 absences confirmées en 404,
0 désaccord**.

#### Configuration nginx

La vérification HTTP a trouvé deux en-têtes manquants. nginx sert des ETag, donc sans eux
un client revalide chaque tuile à chaque session — un aller-retour par tuile, pour un
objet qui ne peut pas changer.

```nginx
location ~ ^/dist/[^/]+/latest\.json$ {
    add_header Cache-Control "no-cache";      # le pointeur DOIT être relu
}
location ~ ^/dist/[^/]+/[0-9a-f]+/ {
    add_header Cache-Control "public, max-age=31536000, immutable";
    types { }  default_type application/octet-stream;
}
```

Deux remarques :
- **Pas de `gzip` côté nginx** : les tuiles sont déjà deflatées dans leur charge utile.
  Le compresser une seconde fois coûterait du CPU pour rien.
- **HTTP/2 ou 3 en production** : une session ouvre des centaines de petites requêtes, et
  le multiplexage change tout. Le relevé ci-dessus était en HTTP/1.1 local.

### Phase 3 — fetcher runtime — 🟢 FONCTIONNEL EN JEU, RESTE LE CONFORT

**`scenes/planet/remote_tile_source.gd`** — la moitié cliente du format publié. URL,
enveloppe de 12 octets, cartes de présence par shard, cache disque cloisonné par version,
et un fil de téléchargement à file dédupliquée.

- **Il ne bloque jamais.** `take()` lit le cache disque et rend vide plutôt qu'attendre ;
  `fetch_now()` est réservé au préchargement. Le chemin d'échantillonnage tourne sur
  `WorkerThreadPool` et ne doit sous aucun prétexte attendre une socket.
- **`has_tile()` répond depuis la carte de présence**, jamais d'un 404 — 512 octets
  couvrent 4096 tuiles voisines, récupérés une fois par shard.
- **Le CRC32 est réimplémenté** (Godot n'en expose aucun) et doit rendre exactement ce que
  `zlib.crc32` rend, sinon toute tuile est rejetée. Figé par des vecteurs de référence
  produits par le publieur Python, un compressé et un non compressé — ce qui prouve aussi
  que `decompress_dynamic` lit le deflate de zlib.

**`scenes/planet/tile_residency.gd`** — le garde. Plutôt que de propager un état
« pending » à travers l'échantillonneur, appelé des milliers de fois par chunk depuis un
thread worker, on garantit la résidence AVANT de soumettre la tâche de mesh et on diffère
le chunk sinon. La tâche ne rencontre alors jamais de tuile manquante.

Deux subtilités que les tests verrouillent :

- **Le jeu de tuiles couvre les voisines**, pas seulement celle du chunk : le sampler
  mélange dans une marge de `BLEND_PIXELS` autour de chaque bord et le noyau bilinéaire
  déborde d'un texel. Ne précharger que la tuile centrale laisserait les bords se rabattre
  sur la carte équirectangulaire — la surface plate à l'origine du terrain « des
  kilomètres sous les props ».
- **Le drainage du backlog est borné** à son contenu initial. Sans cela, un chunk que
  `_queue_mesh_task` y remet faute de tuiles téléchargées serait repris aussitôt, et la
  boucle tournerait sans fin dès que tous les chunks en attente le sont pour cette raison.

**Sans source distante, `request_chunk_tiles` rend toujours true** : les planètes qui ne
streament pas ne paient rien et ne changent pas de comportement. C'est testé explicitement.

#### Vérifié bout à bout

Contre un nginx local servant l'arbre tarsis_3 n256, depuis Godot : **55 tuiles récupérées
en HTTP décodées en octets identiques au pack local, 5 absences concordant avec les cartes
de présence, 0 désaccord.** La chaîne QGIS → exporteur → pack creux → publieur → nginx →
client est close.

#### Validé en jeu, 2026-09-08

Câblé (`--tile-stream=` / `DS_TILE_STREAM` / `[stream] tiles_url`), et **testé en retirant
le pack local** : le client rend tarsis_3 entièrement depuis les tuiles téléchargées, et le
serveur construit sa collision de la même façon. Le volume descendu est reporté par le
profilage (`réseau: N tuiles (X Kio) + M cartes (Y Kio)`).

Deux erreurs corrigées en route, toutes deux trouvées par l'instrumentation et non par
raisonnement :

- Le garde interrogeait la présence par `has_tile()`, qui va chercher la carte d'un shard
  en **HTTP synchrone**. Appelé pour chaque chunk en attente à chaque frame : **0,2 FPS**.
  `presence_of()` ne consulte que ce qui est arrivé et met la carte en file.
- `_read_r32_tile` sortait avant le repli distant quand le pack local manquait, si bien
  qu'une planète entièrement streamée ne pouvait lire aucune tuile.

#### Prefetch en anneau — ✅ FAIT (`TileResidency.prefetch`)

C'était le manque le plus visible : une tuile n'était demandée qu'au moment où un chunk en
avait besoin, donc chaque zone nouvelle coûtait au moins un aller-retour avant d'apparaître.

`prefetch()` demande maintenant, à chaque mise à jour du terrain, la tuile sous le joueur
et ses huit voisines HEALPix **à tous les niveaux de la pyramide**. Quand l'historique
caméra montre un déplacement, l'anneau est répété autour d'un point situé en avant du
joueur (`PREFETCH_LEAD = 8` fois la course récente) — c'est ce qui fait arriver le terrain
avant lui.

Le travail se fait sur les **tuiles** et non sur les chunks : évaluer la résidence de
chaque chunk désiré coûterait neuf tuiles et une marche d'ancêtres par chunk, pour les
centaines de chunks visibles, alors qu'une direction donne directement son ipix à chaque
niveau. Comme le garde, le prefetch tourne sur le thread principal et ne consulte donc que
`presence_of()`, jamais `has_tile()` ; un test verrouille qu'aucune requête n'en part.

Deux corrections que le prefetch rend nécessaires, puisqu'il redemande volontiers ce qu'il
a déjà :

- `fetch_now()` sort immédiatement quand la tuile est déjà en cache disque — sans quoi
  chaque redemande la re-téléchargerait.
- le mémo des travaux en file est vidé une fois le travail traité. Il ne sert qu'à ne pas
  mettre deux fois la même chose en attente ; le garder indéfiniment en ferait un index de
  toutes les tuiles jamais demandées, plus d'un million sur tarsis_3.

#### Cache LRU — ✅ FAIT (`TileCacheLru`)

Le cache de tuiles grossissait sans limite, et le prefetch en anneau le remplit bien plus
vite que les demandes à la carte qu'il a remplacées. Budget ramené de 400 à **128 Mo**,
compté en fichiers et non en octets, niveaux n1…n16 épinglés hors budget. Le détail et
les mesures qui justifient ces chiffres sont en §8.

#### Ce qui reste — du confort, pas de la correction

- **Jouer réseau coupé** : il faudrait alors précharger les planchers des 19 corps au
  menu (36 Mio, 19 requêtes). Écarté pour l'instant — le plancher à l'approche donne la
  même garantie en jeu pour 1,88 Mio.

### Phase 4 — serveur

#### Canaux et poignée de main de version — ✅ FAIT

Un canal est un manifeste `corps → version`, servi en un objet :

    <dist>/channels/<canal>.json

Les arborescences vivent en `<dist>/<corps>/<version>/` et sont **immuables** : elles ne
portent pas le nom du canal. Promouvoir fait donc monter le manifeste d'un cran **sans
recopier un octet**, et la version servie en dev est littéralement la même que celle qui
passe en preprod — un octet ne peut pas changer entre deux canaux.

C'est là toute la poignée de main. Client et serveur ne négocient rien : ils résolvent le
même nom de canal, lisent le même manifeste et obtiennent les mêmes versions **par
construction**. Un seul manifeste fixe les dix-neuf corps à la fois, si bien qu'une
promotion en cours de partie ne peut pas livrer tarsis_3 dans une version et sa lune dans
une autre. Et il n'a fallu ajouter aucun message réseau, ce qui compte : le protocole
client/serveur vit dans `../horizonserver`, hors de ce dépôt.

    unstable  →  dev  →  preprod  →  prod

| canal | pour qui |
|---|---|
| `unstable` | ce que quelqu'un vient d'exporter, testé en local par lui seul |
| `dev` | ce que tous les développeurs partagent |
| `preprod` | client et serveur construits ensemble ; le canal est figé dans le build |
| `prod` | les joueurs |

**Une publication n'alimente que le premier cran.** Les suivants ne se remplissent que par
promotion, donc aucune version n'atteint les joueurs sans avoir traversé les crans
intermédiaires.

Trois garanties tenues par la promotion, chacune couverte par un test :

- **On ne promeut pas un pointeur en l'air.** L'arborescence visée doit exister, avec son
  `manifest.json`, son `floor.bin` s'il est annoncé et son niveau le plus fin. Sans ce
  contrôle, le canal supérieur casse sans que rien ne le dise et le premier à s'en
  apercevoir est un joueur devant un terrain absent.
- **Tout ou rien.** Un canal à moitié promu mêle deux exports en silence — pire que pas
  promu du tout.
- **Corps par corps.** `--planet tarsis_3` ne fait monter que lui : ré-exporter un corps
  ne doit pas embarquer dix-huit autres qui n'ont pas été retestés.

Résolution du canal côté processus, même cascade que le reste du streaming :
`--tile-channel=`, puis `DS_TILE_CHANNEL`, puis `[stream] channel` du `.ini`, puis
**l'estampille de build** `res://stream_channel.json`, puis `dev`. L'estampille est la
réponse au cas preprod : client et serveur y sont construits ensemble, donc écrire le
canal dans le build les lie sans qu'aucun des deux n'ait à être configuré au déploiement.
Un nom hors de la liste est traité comme une faute de frappe et retombe sur `dev` avec un
avertissement, plutôt que de demander un manifeste inexistant en silence.

Le seul écart que les canaux ne peuvent pas empêcher, c'est deux processus sur des canaux
**différents**. `StreamChannel.fingerprint()` l'imprime au démarrage — `canal=preprod
corps=19 empreinte=ec05a72a` — la même ligne dans les deux journaux valant mêmes versions
partout. Une planète résolue par `latest.json`, hors canal, émet un avertissement : ce
repli n'a aucune garantie de cohérence.

Vérifié bout en bout sur l'arborescence publiée : promotion des quatre crans, résolution
des trois canaux depuis le client, repli sur `dev` pour un nom fautif, et refus de
promouvoir une version non publiée sans toucher au canal cible.

#### Ce qui reste

- Mode `--prefetch-zone` du même fetcher, lancé au boot / en init container, vers
  un PVC.

### Phase 5 — éditeur — ✅ FAITE

L'éditeur n'a plus d'aperçu à lui. Il fait tourner le **même quadtree, les mêmes LOD, le
même pipeline asynchrone et le même streaming** que le client, simplement autour de la
caméra d'édition au lieu du joueur. `editor_preview_depth`, `editor_preview_rings` et
`editor_preview_vegetation` ont disparu, avec leur générateur : une profondeur et un
nombre d'anneaux fixés à la main ne montraient pas ce que le joueur verrait, et les
construire sur le fil de l'éditeur est ce qui le gelait dès que les tuiles devaient être
téléchargées. Les 38 valeurs stockées dans 19 scènes ont été retirées.

Aucun bouton « prefetch région » n'a été nécessaire : le prefetch en anneau s'en charge,
puisque c'est le même code.

Trois bugs découverts par cette bascule, tous réels au-delà de l'éditeur :

- `_crc32` lisait une table statique dont l'initialiseur n'avait pas tourné dans ce
  contexte. Chaque index sortait des bornes, le CRC était faux, la tuile était rejetée —
  et l'absence de terrain ne désignait rien. Table construite à la demande.
- Les boucles d'attente de `HTTPClient` n'avaient **aucune échéance**. Un service qui
  accepte la connexion puis se tait les faisait tourner indéfiniment, et `open_planet`
  part du thread principal : un serveur de tuiles en panne gelait l'éditeur à l'ouverture
  d'une scène. Vérifié contre un écouteur muet — 2001 ms pour une échéance de 2000.
- Les autoloads ne sont pas `@tool` : leurs membres, constantes comprises, ne sont pas
  atteignables depuis le nœud dans l'éditeur. Quatre sites tombaient dessus une fois le
  pipeline actif. Les constantes se lisent désormais sur le **script**.

### Phase 6 (optionnelle, plus tard) — CDN de meshes borné

Voir section 7. Seulement une fois `v27` / `_brg` / `_cor` stabilisés.

---

## 10. Points de décision

### Tranchés

- **Streamer les tuiles, pas les meshes** (§2) — inventaire 73,8 Go contre ~14,5 To.
- **Résolution par corps** : tarsis_3 à 198 m (`n1024 × tr32`), les 19 autres planètes
  et lunes à 4 065 m (`n64 × tr25`). tarsis_5 baisse donc de 2 033 m à 4 065 m.
- **Un fichier par tuile pour les niveaux fins** (§4) — `nside` et `tile_res` sont déjà
  le même bouton que la granularité de bundle. **Révisé pour les niveaux grossiers** : le
  plancher n1…n8 est servi en un `floor.bin` unique, parce que ces 1 020 tuiles ne pèsent
  que 1,88 Mio mais coûtent 1 020 allers-retours — des secondes de bande passante contre
  des minutes de latence. Le critère n'est donc pas la taille mais le rapport
  volume/allers-retours, et il ne bascule qu'aux niveaux grossiers.
- **Adressage par chemin, pas par contenu** (§7) — dédup mesurée à 1 %, working set de
  580 Ko, manifeste de 537 Mo : les trois arguments du contenu-adressage tombent.
- **Le streaming n'apporte rien au CPU** (phase 0) — lecture de tuiles à 9,4 % de la
  génération, contre 74 % pour les normales. Chantier séparé.
- **Phase 1 livrée et validée en jeu** (§ ci-dessus) : uint16 + pack creux, 2,6× sur une
  lune, 35,7 % d'élagage sur tarsis_3 à 794 m, projection ~12 Go à 198 m.

### Encore ouverts

- ~~Le *pack creux* vaut-il sa complexité ?~~ **Oui, et l'export à 198 m l'a confirmé** :
  **69,5 % élagué** contre 65 % projeté, soit 34,4 Go → **9,75 Gio** et 16,8 M →
  **5 109 933** fichiers, sans perte de relief.
- **Volume de distribution** : `-b 1024` ou blocs standard ? La question n'est plus
  théorique. Aucune tuile n'atteint 4 Kio (médiane 1383 o), donc en blocs de 4 Kio les
  5,1 M fichiers occupent **19,5 Gio** pour 6,7 Gio de données. En blocs de 1 Kio, environ
  la moitié.
- **Combien de versions garder en ligne** : ce sont les **inodes** qui tranchent, pas les
  octets. 5,1 M fichiers par version contre 16,7 M libres sur le volume de test, soit
  **trois versions de tarsis_3 au maximum**. Les canaux donnent le critère de suppression —
  une version qu'aucun canal ne cite est morte — mais le ramasse-miettes reste à écrire, et
  il devient nécessaire plutôt que confortable.
- ~~**`col=0` côté serveur**~~ **Élucidé** : configuration, pas bug. Le serveur n'avait ni
  pack local (renommé pour le test) ni section `[stream]` dans `server.ini` — donc aucune
  élévation, donc aucune collision. Avec l'une ou l'autre, il construit normalement.

---

*Décisions actées : streaming des tuiles et non des meshes (§2) ; tarsis_3 à 198 m et
les 19 autres corps à 4 065 m (§4) ; un fichier par tuile aux niveaux fins, un objet
unique pour le plancher (§4) ; adressage par chemin (§7).*
