# Lave sur les volcans — essai v6

Branche `rnd/viscous-lava-20261105`, build de départ `0.1.0-dev.202611042208`.
**Lanceur : `test/volcano/launch_lava.cmd`.** Le raccourci du dossier `outputs`
ouvre cette même vue. Le jeu charge les tuiles officielles de Tarsis III si
nécessaire ; les caches de cet essai restent sous `.godot/`.

## Comportement

L’éruption de 10 minutes commence sans dépôt. L’apport est réparti dans le
cratère, qui se remplit, déborde et alimente les flancs sur 360°. La grille
polaire de **96 secteurs × 96 anneaux** couvre **7,22 km de rayon** sur le site
testé. Les 24 anneaux intérieurs décrivent le cratère ; les anneaux extérieurs
s’élargissent pour limiter le coût sur les flancs. La lèvre réelle est
échantillonnée aux faces. Le repère suit la verticale sphérique et la gravité
locale est **7,77 m/s²**.

La viscosité de référence passe à **400 Pa·s**, le seuil à **30 Pa** et l’apport
à **1 200 °C**. Le test commence par un apport fort dimensionné au cratère,
puis le réduit. Une hauteur de pression de 64 m aide le magma disponible à
franchir les lèvres irrégulières ; elle s’éteint après la coupure. Aucun apport
n’est placé sur les pentes et aucun chemin prédéfini ne dirige la lave.

Après la fin de l’apport, le dépôt refroidit et devient noir. Le retrait débute
après environ **deux minutes simulées** et dure **trois minutes**. Épaisseur et
couverture diminuent ensemble, avec comptabilité exacte du volume retiré.
Les cellules quittent l’index actif à zéro. À la fin, surface, textures, fumée
et raccords au terrain sont libérés ; une nouvelle éruption peut les recréer.
Le lac incandescent statique et son halo sont désactivés pour accompagner ce cycle.

**L** : vue du cratère ; **V** : volcan suivant ; **K** : nouvelle éruption ;
**J** : couper/reprendre l’apport ; **Y** : temps ×1 / ×4 / ×12 ; **M** : fumée ;
**F2** : panneau volcan ; clic : souris ; ZQSD : vol ; Espace/Ctrl : altitude ;
molette : vitesse ; Échap : libérer la souris ; H : HUD volcan classique.
L’événement d’essai est retiré au changement de volcan ou à la fermeture.
Aucun profil volcanique n’est enregistré automatiquement.

## Intégration et optimisation

`PlanetTerrain` expose le runtime sur client et serveur. Le serveur local
échantillonne le terrain une fois et transmet le checkpoint canonique ; les
deux pairs reçoivent ensuite les mêmes commandes entières à **10 Hz**.
L’accélérateur C# utilise les mêmes opérations que le cœur de référence
GDScript. Les deux tâches de calcul de l’aperçu sont exécutées sur des
travailleurs, sans accès au rendu ou à l’arbre de scène. Le thread principal
publie les textures après leur jonction. Les images sont interpolées ; aucun
tick n’est sauté, même pendant une accélération. La cadence accélérée reste
limitée par le CPU disponible.

Au plus deux zones par planète ; aucun rendu côté serveur ; maillage fixe,
deux états GPU, 96 bouffées de fumée au maximum. Le raccord aux mailles du
terrain partage ces textures et suit la convention double face HEALPix.
Les références de chunks sont faibles et retirées à leur sortie.

Dans l’aperçu lancé avec `--viscous-lava`, `authored_flows_enabled = false` désactive les rubans QGIS, leur nivellement et
le déversoir artificiel. Les sources exportées sont conservées. La politique
`simulated_lava_4` reste la clé du terrain sans anciens chemins : le schéma
physique v6 est distinct. Les profils de routes inchangées sont réutilisés
uniquement si leur ancienne clé diffère de cette seule politique lave ; les
profils proches des volcans sont invalidés. Sur cet export : 134 profils
réutilisés, une route et un plan de pont recalculés localement.

## Validation reproductible

```powershell
.\test\volcano\launch_lava.ps1 -Test
.\test\volcano\launch_lava.ps1 -LongTest
.\test\volcano\launch_lava.ps1 -FastForwardSeconds 300 -Capture "$PWD\lave-active.png"
.\test\volcano\launch_lava.ps1 -FastForwardSeconds 1000 -Capture "$PWD\lave-noire.png"
.\test\volcano\launch_lava.ps1 -FastForwardSeconds 1230 -Capture "$PWD\lave-disparue.png"
```

`-FastForwardSeconds` calcule tous les ticks côté autorité avant l’arrivée du
client, puis lui transmet le checkpoint actuel. `-DurationSeconds` accepte
10–604 800 s, avec 600 s par défaut. Le lanceur recompile l’accélérateur si sa
source est plus récente et les dépendances .NET sont déjà disponibles ; sinon
le cœur de référence reste utilisable.

## Mesures et limites v6

Les dépôts noirs quittent les calculs actifs tout en restant présents. Leur
refroidissement et leur âge se calculent au réveil ; un apport ou un flux chaud
les réactive. Les tableaux visuels ne sont publiés que lorsqu’ils changent.
Les règles de retrait et les constantes ont été regroupées dans le cœur
commun ; le C# conserve uniquement les boucles numériques accélérées.

```powershell
.\test\volcano\launch_lava.ps1 -WeekTest
.\test\volcano\launch_lava.ps1 -SleepBenchmark
```

Le test de repos suit **6 048 000 ticks par pair**, soit sept jours. Il conserve
1 024 dépôts, ajoute un peu de lave froide chaque jour, puis vérifie leur reprise
par lave chaude et l’arrivée tardive d’un autre pair. La comparaison utilise un
pair C# et un pair de référence GDScript. Ce scénario ne représente pas sept
jours de débit maximal du volcan. Les preuves v6 sont dans `test/lava/results/`.

Sur le benchmark synthétique 96×96 avec 8 cellules encore chaudes, seules 8
cellules sont traitées : environ **0,36 ms/tick** pour les deux pairs avec leurs
vues CPU, hors GPU et réseau. Un champ entièrement au repos est à environ
**0,005 ms/tick**. Ces mesures debug i7-13700 ne garantissent pas le budget
d’un serveur chargé. Le mode v6 sans repos retrouve les mêmes empreintes.

La durée par défaut reste **600 s**, et le lanceur accepte sept jours. La grille
bornée évite une accumulation de mémoire, mais le volume injecté peut remplir
ce domaine fermé : la mise au repos n’étend pas le terrain. À 3 000 m³/s, le
plateau d’une semaine représenterait environ **1,81 milliard de m³** ; il faudra
évaluer débit, emprise et transferts entre zones pour ce scénario continu.
Le compteur historique accepte désormais 1 000 milliards de m³, tandis que les
capacités locales et les contrôles de saturation restent inchangés.

Le test long volcanique reste un cas explicite de **15 min d’éruption puis
5 min 30 de refroidissement/nettoyage**, même si l’aperçu démarre désormais
avec 10 min. Le cycle v6 complet reste identique entre les pairs, atteint les
96 secteurs et retire l’intégralité des 7 477 500 m³. Coût mesuré sur les deux
pairs : 4,03 ms médiane / 9,94 ms P95 par tick, hors rendu. Le nettoyage demeure
une phase active pour animer et comptabiliser le retrait ; le repos vise les
dépôts stables pendant les longues éruptions. Les résultats v2/v3/v4/v5 sont
conservés comme archives.
Le contrat de checkpoint v6 et les vérifications reproductibles sont dans
[README](../lava/README.md) et [NETWORK](../lava/NETWORK.md).

Le jeu et l’éditeur sans `--viscous-lava` conservent leurs rubans QGIS, leurs
lacs et leurs clés de cache. Le lanceur active seul ce mode d’essai.

Le pont client/serveur reste local ; Horizon/GORC de production, collision,
dégâts, persistance et transferts entre zones restent à raccorder. Le raccord
visuel suit le terrain affiché mais ne répare pas ses défauts préexistants de LOD.
La CI prépare les tests Linux/Windows ; la validation locale couvre Windows.
Les diagnostics préexistants du compteur d’orphelins GUT et de quelques
références .NET à la fermeture des aperçus sont conservés dans les archives v5.
