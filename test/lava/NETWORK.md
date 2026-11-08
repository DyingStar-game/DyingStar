# Contrat déterministe — lave v6

## État et calcul

Le cœur GDScript et son accélérateur C# emploient uniquement des entiers signés
64 bits. Aucun nombre flottant, trigonométrie, hasard, caméra, GPU ou horloge
n’entre dans les décisions physiques. Le pas est fixé à 100 ms.

- `terrain_q` : hauteur en mm, quantifiée une seule fois par l’autorité.
- `volume_q` : litres, soit 1/1 000 m³.
- `energy_q` : volume × température excédant 20 °C, en dixièmes de degré.
- `exposure_q` : volume × ticks d’exposition, bornés à 10 000 000 ticks.
- `vx_q`, `vz_q` : vitesse de transport en µm/s, directions locales de la grille.
- `fade_ticks_q`, `fade_start_q` : durée restante et volume initial de retrait.
- Tick, paramètres, dernier apport, volumes injecté/retiré/échappé, géométrie et
  pression éruptive font partie de l’état canonique.

Les flux sont simultanés. Les donneurs cèdent au plus 45 % de leur volume par
tick ; les capacités des receveurs sont respectées. Les divisions entières ont
le même ordre dans les deux implémentations. `mul_div` décompose les produits
larges pour éviter les dépassements. Le bilan exact est :
`sum(volume_q) + removed_q + escaped_q == injected_q`.
Les frontières sont fermées ; `escaped_q` reste nul actuellement.

La grille cartésienne accepte 3–256 cellules par axe et une maille de 1–64 m.
La grille polaire accepte 16–256 secteurs et 3–256 anneaux ; rayon ≤16 384 m,
largeur d’anneau 1–128 m (premier anneau ≤64 m). Les surfaces, longueurs de
faces et distances sont calculées en entiers avec π = 355/113. Les secteurs
bouclent sur eux-mêmes. Les centres trigonométriques flottants servent au rendu.

Autres bornes : terrain absolu ±10 km, variation locale ≤8 192 m, épaisseur
≤512 m, cellule ≤4 milliards de litres, apport cumulé ≤1 000 milliards de m³,
source 20–1 400 °C, gravité 1–50 000 mm/s². Les bornes et les opérations de
limitation font partie du modèle. Ne pas modifier directement les tableaux à
partir de données réseau : les entrées et restaurations sont validées.

## Commandes et reprise

1. Le serveur définit modèle, géométrie, terrain quantifié et paramètres, puis
   transmet `checkpoint()`. Chaque client installe ces données ; il ne les
   recalcule pas à partir de son relief visuel ou de nombres flottants.
2. `advance_tick(n, data)` exige `n == tick + 1`. `data` contient des triplets
   entiers `[indice_cellule, litres, température_dixième_°C]`, triés par indice
   strictement croissant, sans doublon. Les paramètres changent au même tick
   sur tous les pairs. `disc_commands` produit une distribution déterministe
   d’aire uniforme ; sa source polaire doit être centrée dans le cratère.
3. Un pair attend les commandes manquantes ou demande une reprise ; il ne saute
   aucun tick et ne change jamais son pas selon ses FPS. L’accélération de
   l’aperçu calcule tous les ticks. La cadence peut être limitée par le CPU.
4. Comparer périodiquement `state_digest()` et le tick ; en cas de divergence,
   reprendre le checkpoint de l’autorité et les commandes suivantes.
   `restore()` valide tailles, bornes, version et bilan avant toute mutation.

Les checkpoints servent à l’arrivée, à la reprise et à la réparation. Les
messages courants sont commandes et empreintes, pas un champ complet par image.
Fréquence, distribution et réparation Horizon/GORC restent à implémenter.

## Checkpoint binaire

Entiers signés 64 bits en **big-endian**, ordre fixe, sans JSON ni dictionnaire.
En-tête de **144 octets**, 18 entiers : magic DSLV, schéma 6, largeur, hauteur,
maille, tick, volume injecté, viscosité, seuil, refroidissement, gravité,
géométrie, nettoyage, dernier apport, volume retiré, volume échappé, anneaux du
cratère, hauteur de pression. En polaire : `hauteur + 1` limites radiales ; puis,
si un cratère est déclaré, `largeur` hauteurs de lèvre.

Ensuite neuf tableaux complets par indice croissant : terrain, volume, énergie,
exposition, vx, vz, durée de retrait, volume initial de retrait, époque de repos.
Taille : `144 + 72×N + 8×(hauteur+1) + 8×largeur` pour une grille polaire avec
cratère, soit **665 240 octets** en 96×96. Les index mouillés/actifs, capacités et
connexions sont dérivés et reconstruits, jamais sérialisés.

La référence du rejeu v6 de 2 000 ticks est :

```text
743f84c5bf21667af70625e61491ba7d4355f163c4b3d5b41edd43ea8a518961
```

Toute modification des règles doit changer schéma et référence. Le test local
Windows retrouve tous les octets avec deux cadences différentes. La CI prévoit
Linux/Windows ; sa validation croisée reste nécessaire avant livraison réseau.
Le test planète exige aussi l’égalité C#/GDScript sur 5 100 ticks avec pression,
débordement, refroidissement, réchauffage et nettoyage complet.

## Cycle volcanique et affichage

Le constructeur échantillonne la sphère réelle, attend la résidence des tuiles,
conserve les autres lits du terrain et fige un champ vide. L’apport reste dans
le cratère. La lèvre est échantillonnée explicitement aux faces. Une pression
éruptive de 64 m n’agit que dans le cratère et décroît en six secondes après
une interruption de deux secondes ; elle n’ajoute aucun volume. Sur les flancs,
seuls relief, épaisseur, gravité et rhéologie gouvernent l’écoulement.

Le nettoyage commence après deux secondes sans apport. La température maximale
baisse de 0,6 °C/tick ; la lave est noire sous 850 °C. Après 120 secondes,
le volume et la couverture se retirent pendant 180 secondes. Le volume retiré
est comptabilisé et les cellules vides quittent l’index actif. Une nouvelle
éruption réchauffe les cellules alimentées ; les anciens dépôts froids continuent
leur disparition. Ce cycle est un réglage de jeu, distinct d’un modèle de
refroidissement géologique complet.

Chaque `PlanetTerrain` possède son runtime ; au plus deux zones sont installées.
L’aperçu exécute une tâche par pair, rejoint les deux avant lecture et publication
visuelle, puis vérifie périodiquement les octets. Aucun appel de scène ou de GPU
ne part du travailleur. Les textures interpolées se mettent à jour sur le thread
principal ; la fumée attend la fin des tâches pour lire le champ.

Le raccord aux seules mailles du terrain partage ces textures, accepte les deux
orientations HEALPix et respecte les objets au premier plan. La sélection en XZ
accepte les différences de LOD. Les références des chunks sont faibles. Après
nettoyage, le runtime libère surface, textures, fumée et raccord de terrain ;
l’état canonique vide reste disponible pour la prochaine éruption.

## Transport en jeu

Le serveur de jeu fait autorité (`server/lava_eruptions.gd`). Pour chaque éruption d’un volcan proche d’un
joueur, il échantillonne le champ une fois, puis fixe un **plan entier** à partir de la fenêtre d’éruption
du calendrier (`VolcanoActivityProfile.eruption_window`, flottants lus une seule fois par l’autorité) :
`start_unix_ms` (au 100 ms près), `eruption_ticks`, `strength_milli`, `ramp_up_ticks`, `ramp_down_ticks`,
`source_rate_q`, `tail_permille`.

Les commandes du tick `n` (compté depuis `start_unix_ms`) valent
`LavaPlanetPatch.eruption_commands(état, description, plan, n)` : volume entier
`eruption_volume_q(n, plan)`, réparti par `disc_commands`, chaque part bornée à la place restante de sa
cellule. Elles ne dépendent que de l’état canonique, du plan et du tick : chaque pair les calcule, aucune
commande ne circule. `inject_q` et le schéma v6 sont inchangés.

Le prop `lava_flow` (un par volcan, uuid stable) porte, par canal GORC (25 km) :

| Zone | Champs | Rythme |
|---|---|---|
| 0 | `position` (sommet), `rotation`, `parent_id` (planète) | à la création |
| 6 | description du champ (`frame` en 12 nombres, source, `patch_key`) et `plan` | à chaque éruption |
| 2 | `checkpoint` (`<taille>:<base64 deflate>`, ~100-200 Ko), `checkpoint_tick`, `schema` | 60 s |
| 1 | `tick`, `digest` (SHA-256 de l’état à un tick multiple de 50) | 5 s |

Le runtime de chaque `PlanetTerrain` avance les zones munies d’un plan sur l’horloge partagée
(`Globals.reference_time`), sur un travailleur, quelques ticks par image en rattrapage. Un client arrivé en
cours d’éruption reçoit le dernier checkpoint (≤ 60 s) et rattrape. Il compare ses empreintes à celles de
l’autorité ; un écart arrête la zone jusqu’au checkpoint suivant, qui la remplace. Le serveur supprime le
prop une fois le dépôt disparu ; un prop persisté d’une éruption finie est supprimé à l’approche d’un joueur.

L’aperçu `test/volcano/viscous_lava_preview.gd` reste une autorité locale hors ligne, avec les mêmes
commandes entières. Collision et dégâts ne sont pas raccordés.

## Repos déterministe v6

Le repos est réservé aux cellules noires, ≤850 °C. Le volume reste canonique et
présent dans les faces de relief. `sleep_epoch_q[i]` vaut -1 pour une cellule
active ; une cellule au repos conserve énergie et exposition à cette époque.
La perte froide par tick vaut `max(1, volume_litres / 10)` unités d’énergie.
Le refroidissement détaillé reste utilisé au-dessus du seuil noir.

`current_energy_q(i)` et `current_exposure_q(i)` évaluent l’état à `tick`, sans
réveiller la cellule. Les lecteurs doivent utiliser ces méthodes plutôt que
les tableaux différés. `checkpoint()` matérialise ces deux champs dans une
copie et normalise l’époque des cellules au repos à son tick, sans changer la
liste de travail. Le format restaurable est donc indépendant du nombre de
lectures ou de publications et du mode de calcul avec/sans repos.

Une injection réveille son destinataire avant mélange. Un transfert réveille
un receveur froid avant d’appliquer chaleur, âge et volume ; il peut couler au
tick suivant si le mélange est assez chaud. Les cellules qui ne reçoivent rien
ne sont pas visitées. Un changement de l’option de refroidissement matérialise
les valeurs avec l’ancien réglage avant d’appliquer le nouveau. Le nettoyage
reste commun aux deux noyaux et progresse même sur des dépôts précédemment au repos.

Le mode de diagnostic `use_sleeping=false` recalcule toutes les cellules avec
les mêmes règles v6 ; ses checkpoints doivent être identiques au mode optimisé.
Les tests couvrent ce point, les arrivées tardives, les flux entrants, le
réchauffage, la modification du refroidissement et les époques invalides.

La borne d’apport historique est maintenant 10^15 litres, sans changer la taille
d’une cellule ou du champ. Les produits différés sont bornés : pour 10^9 ticks
et 4×10^9 litres/cellule, l’exposition calculée reste sous 4,04×10^18 avant sa
saturation ; la perte froide sous 4×10^17. Le domaine reste fermé et peut se
saturer ; cette extension numérique n’ajoute aucun transfert entre zones.
