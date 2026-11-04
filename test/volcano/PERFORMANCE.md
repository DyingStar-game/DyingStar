# Revue et mesures des VFX volcaniques

Mesure locale du 4 novembre 2026, Godot 4.7 .NET double precision, Forward+,
RTX 4080. Scene isolee `test_plume_closeup.tscn`, fenetre demandee 960 x 540,
horloge et graine fixes. Les deux executions utilisent la meme commande,
la meme camera et les memes reglages graphiques. Ces temps ne representent
pas les FPS du jeu complet.

| Mesure | Avant | Apres | Reduction |
|---|---:|---:|---:|
| CPU : mise a jour du modele eteint | 0,872 ms | 0,099 ms | 89 % |
| CPU : mise a jour du modele panache | 1,447 ms | 0,882 ms | 39 % |
| CPU : mise a jour du modele eruptif | 1,442 ms | 0,897 ms | 38 % |
| GPU : viewport, vue exterieure dense | 14,897 ms | 8,620 ms | 42 % |
| GPU : viewport, bord du panache | 4,091 ms | 1,960 ms | 52 % |
| GPU : viewport, interieur du panache | 1,957 ms | 1,407 ms | 28 % |

CPU : moyenne de 100 mises a jour apres 10 echauffements, budget de lumiere
de 12 bouffees. GPU : mediane de 40 images apres 20 images d'echauffement,
scene figee avec 118 bouffees superposees. Le viewport logique et la taille
de sa texture sont consignes dans le JSON de mesure. Le viewport diagnostic
contient le fond et un panache ; les couts du terrain, du reseau et des
autres effets du jeu ne sont pas mesures par ce benchmark.

## Pics CPU pendant une eruption (RTX 2060)

Mesure du 4 novembre 2026, RTX 2060, 16 coeurs, rendu 1839 x 994, vsync coupee,
editeur et jeu fermes, scene `volcano_view.tscn`. Meme eruption a date fixe
(environ 1230 pierres en vol, 19 bouffees) pour l'ancien et le nouveau code,
sur 25 s. Une seule execution par version. Ancien -> nouveau :

| Vue | `_process` mediane | p99 | max | Images > 33 ms |
|---|---:|---:|---:|---:|
| Colonne | 3,54 -> 2,37 ms | 42,2 -> 16,2 ms | 66,2 -> 22,5 ms | 61 -> 6 |
| Flanc | 2,90 -> 1,77 ms | 20,8 -> 9,1 ms | 37,8 -> 12,5 ms | 18 -> 18 |
| 9 km | 2,74 -> 1,29 ms | 36,0 -> 13,6 ms | 106,9 -> 17,8 ms | 49 -> 4 |

- `VolcanoPlumeModel` ne relit plus le calendrier d'une bouffee sans fumee : un
  appel a `update` passe de 2,63 a 0,92 ms en jeu.
- `VolcanoStoneField` limite a `MAX_READS_PER_FRAME` les lectures de relief par
  image pour les nouvelles pierres. Une pierre hors budget nait plus tard, au
  plus `MAX_BIRTH_LAG_S` apres sa date (0,35 s au pire mesure).

Les resultats sont identiques au bit pres sur un banc headless (empreintes des
bouffees et de 1000 vols) ; `test/unit/test_volcano_cpu_budget.gd` le verifie.
Ces gains suppriment des a-coups : le temps d'image median reste fixe par le GPU
(16 ms dans la colonne, dont environ 10 ms de fumee).

## Responsabilites et simplifications

- `VolcanoRandom` fournit uniquement les fonctions aleatoires deterministes.
  La configuration ne depend plus du modele de rendu pour calculer ses cycles.
- `VolcanoEvent` definit une seule enveloppe d'emission, utilisee aussi par
  les activites aleatoires. Les transitions ne sont pas recopiees.
- `VolcanoActivityProfile` gere les reglages, leur copie independante et
  l'evaluation de l'activite. Un seul passage fournit la force emise et
  la fumee restante ; le panneau gere les saisies et les apercus.
- `VolcanoPlumeModel` calcule les bouffees actives ; les bouffees sans emission
  ne calculent ni geometrie, ni bruit, ni lumiere. La lumiere parcourt seulement
  les bouffees actives. L'integrale actuelle du vent est partagee dans la mise a jour.
- `VolcanoPlume` gere la camera et le rendu : 30 mises a jour/s a proximite,
  15 puis 8 a distance, 5 au repos, independamment des FPS. Les uniformes de
  geometrie ne sont renvoyes que lorsque le modele ou la vue changent.
- `VolcanoStoneField` partage les formes et la texture immuables des rochers.
  Les materiaux et les donnees de projections restent propres a chaque volcan.
  Les lots vides ne sont pas dessines ; les slots deja vides ne reecrivent pas
  leur texture. La recherche du sol sous le joueur est evitee sans rocher vivant.

Les protections de despawn sont détaillees dans le README : pool de 160 rochers
incluant le fondu, plafond de durée de vie même en mouvement, retrait à distance,
suppression des objets et arrêt de la physique des champs hors budget. Les
slots expirés sont effacés et les poussières sont bornées ; un test de surcharge
et un test 3D de nettoyage vérifient ces limites. Les mesures ci-dessus ont été
prises avant ce renforcement du despawn ; elles ne quantifient pas son gain.

Le shader garde toutes les bouffees utiles avec des masques de bits : le
correctif des decoupes n'est pas remplace par une nouvelle limite arbitraire.
L'occlusion generale vient du modele ; une sonde locale conserve le relief
des lobes. Les anciennes sondes redondantes du shader sont remplacees par
une estimation locale de l'eclairage du ciel. Il s'agit d'une approximation
visuelle, controlee sur les captures, et non d'un rendu pixel-identique.

## Verifications et reproduction

```text
godot --headless --path . res://test/volcano/test_tarsis_volcano_vfx.tscn -- --volcano-view
godot --path . res://test/volcano/test_plume_closeup.tscn --resolution 960x540 -- --volcano-view
godot --path . res://test/volcano/test_plume_closeup.tscn --resolution 960x540 -- --volcano-view --benchmark
godot --path . res://test/volcano/volcano_view.tscn -- --volcano-view --smoke-test
```

Les tests couvrent les etats et transitions, les evenements UTC, le vent,
la reproductibilite, les copies de profils, les ressources partagees et
l'absence de requetes de terrain pour des projections inactives. Le test
rapproche compare le rendu apres inversion de l'ordre des 118 bouffees :
aucun ecart significatif constate dans les trois vues. La scene Tarsis III
verifie aussi les apercus et le retour au brouillon du panneau.

Le benchmark ecrit `user://volcano_benchmark.json`. Les mesures absolues
dependent du materiel, de la resolution et du contenu visible. Une session
multijoueur chargee reste a mesurer separement.
