# Volcans de Tarsis III

La revue de structure, les optimisations et les mesures reproductibles sont
detaillees dans [PERFORMANCE.md](PERFORMANCE.md).

Scène autonome : `res://test/volcano/volcano_view.tscn`.
Elle charge les scènes du système Tarsis et le manifeste livré avec le jeu,
sans charger l'explorateur Stargrotte ni créer de collection de grottes.
Les panaches, projections et lacs sont créés par le `PlanetTerrain` du jeu,
via `VolcanoFeatures`, sur les volcans existants. Les volcans dormants ne fument
pas spontanément ; un événement explicite peut les réveiller temporairement.

Sous Windows, le lanceur versionné est `test/volcano/launch.cmd`. Il utilise
`GODOT_EXE`, ou `godot.exe` dans le PATH, et reconnaît aussi le runtime local
placé à côté du dépôt. Il ne contient aucun chemin personnel ni nom imposé
pour le dossier du projet. Exemple depuis la racine du dépôt :

```bat
set "GODOT_EXE=C:\Godot\godot_console.exe"
test\volcano\launch.cmd
```

Choisir le binaire Godot **4.7 .NET double précision** utilisé par le jeu,
avec le runtime .NET 9 et l'assembly C# construit. Les données de terrain
complètes améliorent la validation visuelle ; le pack des volcans de Tarsis III
est celui du dépôt. Aucun exécutable Godot n'est ajouté à cette contribution.

Avec la version Godot .NET double précision du projet :

```text
godot --path . res://test/volcano/volcano_view.tscn -- --volcano-view
```

Clic pour capturer la souris, déplacement avec les touches configurées du jeu,
Espace/Ctrl pour monter/descendre en vol, Maj pour accélérer, molette pour la vitesse.
T : marcher/voler ; V : stratovolcan actif suivant ; N : prochaine éruption ;
B : salve de test ; +/- : heure ; Échap : libérer la souris ; H : masquer les indications.
`--capture` ajoute la série de captures automatique dans le dossier utilisateur Godot.
La navigation de test sélectionne les stratovolcans actifs ; le jeu applique aussi
les VFX aux autres types de volcans non dormants via le même système.

Vérification des données réelles et de la fabrique de VFX :

```text
godot --headless --path . res://test/volcano/test_tarsis_volcano_vfx.tscn -- --volcano-view
```

Le lancement de `volcano_view.tscn` avec `--volcano-view --smoke-test` vérifie
aussi la création du panache par le registre de terrain et son traitement par
le moteur de rendu, enregistre `user://volcano_smoke_test.png`, puis ferme la scène.

La feature repose sur `scenes/planet/volcano/volcano_features.gd`,
`volcano_plume.gd`, `volcano_plume_model.gd`, `volcano_stone_field.gd` et
`assets/_universe/environment/terrain/volcano/`. Elle ne requiert aucune
modification de la scène Tarsis III ou de ses volcans exportés.

## Regression des decoupes de fumee

Lancer `res://test/volcano/test_plume_closeup.tscn` avec `--volcano-view`
et le rendu 3D actif. Le test couvre les vues exterieure, de bord et interieure
avec plus de 32 bouffees superposees. Il compare aussi le rendu apres inversion
de leur ordre pour detecter les suppressions arbitraires de volumes. Les
captures `user://plume_closeup_*.png` permettent une inspection visuelle.

## Reglages et evenements (F2)

### Valeurs par défaut et fréquence

Choisir la planète dans **F2**. La vue 3D reste sur Tarsis III ; la liste
permet aussi d'enregistrer les profils des autres corps du système.

| Réglage | Valeur par défaut | Effet |
|---|---:|---|
| Activités aléatoires | Activées | Une activité possible par cycle et par volcan non dormant |
| Intervalle moyen | 10 min | Durée moyenne entre deux débuts d'activité |
| Variation | 25 % | Décale chaque départ de ±25 % de la durée du cycle |
| Durée d'activité | 90 s | Formation, phase d'activité puis arrêt de l'émission |
| Chance d'éruption | 55 % | Les autres activités produisent seulement un panache |
| Force minimale / maximale | 0,8 / 1,6 | Intensité tirée pour chaque activité |
| Fumée au repos | 0 | Aucune fumée entre les activités, après dissipation |
| Formation / arrêt | 45 s / 30 s | Montée et diminution progressives de l'émission |
| Dissipation | 120 s | Effacement des bouffées après la fin de l'activité |
| Graine | 1 | Suite reproductible, différente pour chaque volcan |
| Influence du vent | 1,6 | Multiplicateur du vent fourni par la météo |
| Diversité des panaches | 1 | Variations maximales de hauteur, longueur, largeur et teinte |

Le pourcentage décale les départs, plutôt que de tirer directement une attente.
Avec un cycle de 10 min et une variation de 25 %, l'écart entre deux départs
peut donc aller de **5 à 15 min**. La durée d'activité ne doit pas dépasser
l'écart minimal ; le panneau refuse les valeurs incompatibles.
La chance d'éruption s'applique à chaque activité, pas à chaque image.

Exemples : pour des panaches fréquents sans projections, choisir un intervalle
de 5 min et une chance d'éruption de 0 %. Pour des éruptions plus rares, choisir
30 min et 20 %. Pour un volcan entièrement éteint hors événements, désactiver
les activités aléatoires et conserver la fumée au repos à 0.

### Eteint, panache seul et eruption

Par defaut la fumee au repos vaut **0** : aucune emission entre les activites.
Une activite aleatoire produit soit un panache seul, soit une eruption, selon
le reglage **Chance d'eruption par activite (%)**. A 0 %, il n'y a que des
panaches ; a 100 %, toutes les activites sont eruptives. Les projections
utilisent une intensite distincte de celle de la fumee : un panache seul ne
lance jamais de rochers, meme s'il est epais.

Le panache se construit depuis le cratere avec les nouvelles bouffees emises.
Les reglages **Formation du panache**, **Arret de l'emission** et **Dissipation
apres l'arret** controlent les transitions. Les transitions trop longues sont
raccourcies pour tenir dans la duree de l'activite. Les rochers commencent
apres le debut de la formation pour les episodes eruptifs. Apres l'arret de
l'emission, la fumee existante continue sa derive et s'efface ; elle ne peut
pas reapparaitre lors du cycle suivant.

Les boutons **Apercu** testent les trois etats dans la session, sans changer
le brouillon ni les fichiers. Un apercu panache/eruption dure 5 minutes et
part d'un volcan sans fumee. **Appliquer** reprend le brouillon. Le HUD indique
ETEINT, FORMATION DU PANACHE, PANACHE SEUL, ERUPTION ou DISSIPATION.

Le lancement d'un apercu ferme le panneau et rend directement la main a la
camera. **F2** rouvre les reglages ; les touches de vol ne relancent pas
l'apercu. Son horloge continue pendant les deplacements et les rotations.
Les evenements dates proposent aussi le choix panache seul / eruption.

Lancer `test_plume_closeup.tscn` avec `--volcano-view --lifecycle` pour les
captures de regression `user://plume_lifecycle_*.png` : eteint, formation,
panache, dissipation et retour a l'etat eteint.

Le lanceur `test/volcano/launch.cmd` ouvre la scene. Appuyer sur **F2**
pour afficher l'outil. La liste des planetes permet de configurer chaque corps
du systeme Tarsis ; la vue 3D reste sur Tarsis III. Faire defiler le panneau
pour acceder aux boutons d'application et d'enregistrement.

- Intervalle moyen et variation aleatoire : une activite par cycle, decalee
  dans le cycle. Chaque volcan a sa propre suite, reproductible entre joueurs.
- Duree, force minimale/maximale et fumee au repos. La duree doit tenir dans
  le plus court intervalle possible ; les saisies incompatibles sont refusees.
- Influence du vent : multiplicateur du vent fourni par la meteo de la planete.
  Le vent est relu toutes les 0,5 secondes, transforme dans le repere du volcan,
  puis integre sur la vie de la fumee. Une planete sans atmosphere n'a pas de vent.
- Diversite des panaches : de 0 (dimensions et teinte neutres) a 1 (variation
  complete). Chaque volcan garde sa propre hauteur, sa duree de vie de fumee
  (donc sa longueur sous le vent), sa largeur, sa densite et sa teinte. Ces
  dimensions varient independamment, avec une identite stable entre lancements.
  L'enveloppe de rendu suit les bouffees pour ne pas couper les longues trainees.
- Evenement : nom, date **UTC**, cible (planete ou volcan), duree et force.
  Format `AAAA-MM-JJTHH:MM:SS`. En France metropolitaine, soustraire une heure
  en hiver ou deux heures en ete a l'heure locale. Un evenement peut reveiller
  un volcan dormant. Plusieurs eruptions simultanees prennent la force maximale.
  La montee et la fin utilisent les durées de transition choisies lors de
  l'ajout de l'événement, réduites si nécessaire pour tenir dans sa durée.

### Programmer un événement

1. Choisir la planète et les durées de transition souhaitées.
2. Donner un nom à l'événement et saisir sa date **UTC**, au format
   `AAAA-MM-JJTHH:MM:SS`. Par exemple, le 1er décembre 2026 à 20 h à Paris
   correspond à `2026-12-01T19:00:00` UTC.
3. Choisir tous les volcans de la planète ou un volcan précis dans la liste.
4. Choisir la durée et la force. Cocher **Éruption avec projections** ou
   décocher pour un panache seul.
5. Cliquer **Ajouter l'événement au brouillon**, puis **Enregistrer dans le
   projet et appliquer** pour conserver la programmation.
6. Versionner le profil `.tres` modifié et le livrer à tous les clients avant
   la date prévue. Un joueur qui arrive pendant l'événement voit son état courant.

L'enregistrement modifie les fichiers du projet local. Il ne met pas à jour
les clients déjà distribués ni un serveur à distance. L'horloge UTC partagée
par le jeu donne le déclenchement ; il n'y a aucune minuterie à garder ouverte
dans l'éditeur. Les aperçus sont temporaires et ne programment pas un événement
dans le brouillon.

**Ajouter l'evenement** modifie le brouillon. **Appliquer** modifie seulement
la session de test. **Enregistrer dans le projet et appliquer** ecrit le profil
`res://scenes/planet/volcano/profiles/<planete>.tres`, a versionner et livrer
avec le jeu a tous les clients avant l'evenement. La fermeture puis la reouverture
de l'outil recharge ce profil. Changer de planete abandonne le brouillon non applique.

L'heure des eruptions utilise l'horloge commune en secondes UTC, independante
de l'acceleration du ciel. Les joueurs rejoignant pendant un evenement voient
son etat courant. Aucun serveur ne doit rester connecte pour declencher le VFX.
Il s'agit d'une configuration livree avec le jeu, pas d'une commande a distance
ni d'un systeme de degats serveur.

**N** decale uniquement l'horloge de demonstration. Appliquer un profil la remet
a l'heure reelle pour tester les dates d'evenement. La scene ne saute plus
automatiquement a une eruption au demarrage.
