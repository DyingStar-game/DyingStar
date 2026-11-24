# Météo

La météo d'un corps est décidée par **le service météo** (`services/weather`, Rust). Le jeu ne fabrique rien :
il lit ce que le service publie, et ne calcule que le relevé en un point, avec `WeatherSampler`, la jumelle
voulue de `sampler.rs` du service.

## D'où vient la météo

1. Le service calcule les systèmes (dépressions, anticyclones, tempêtes de poussière, fronts de pluie) et les
   pousse à Horizon toutes les 30 s, comme objets `weather_system`.
2. Horizon les réplique aux serveurs de jeu et aux clients (`items_def/weather_system_def.json`).
3. Dans le jeu, chaque système est un nœud `WeatherSystem`
   (`scenes/_universe/environment/weather/weather_system.gd`), enfant de sa planète ; entre deux mises à jour
   il marche sur ses images-clés avec l'horloge partagée (`Globals.sim_time()`). Le serveur ne les endort
   jamais (`STREAM_ALWAYS_TYPES`, `server/server.gd`).
4. `ClimateWeather` (`scenes/planet/weather/climate_weather.gd`), la `WeatherSource` de la planète, lit ces
   nœuds (`systems(planète)`) et donne le relevé : vent moyen de la bande de latitude (profil climatique) plus
   les systèmes reçus. **Sans système reçu, c'est le climat de fond seul** : le repli prévu par le service.

Tout cela (1 à 3 et `WeatherSampler`, `WeatherLocal`, `ClimateProfile`, les profils) est repris tel quel de la
branche `wip/weather` du prototype d'octobre.

## Profils climatiques

`scenes/planet/climates/<corps>.tres` : générés, jamais édités à la main. Après un changement des données du
service :

1. dans `services/weather` : `WEATHER_EXPORT=1 cargo test -p weather-core --test export_derived`
   (réécrit `data/derived/tarsis.json` et les relevés de référence `data/golden/`) ;
2. dans le jeu : `addons/dyingstar/build_climate_profiles.gd` (il lit `../services/weather/data/derived/`) ;
3. copier `data/golden/tarsis_sandbox_samples.json` vers `test/data/weather/sandbox_samples.json`.

Régénérés le 24/11/2026 après la fusion de la PR `services` n° 54 (albédo 0,66, CO2 0,5 %), qui change le climat
dérivé de Sandbox : température d'équilibre 258,6 K → 217,4 K, écart équateur-pôle 33,5 K → 19,3 K, bord de Hadley
31,9° → 35,8°, vent de référence 9,56 → 8,47 m/s, hauteur d'échelle 10 371 m → 10 444 m. Les autres corps ne bougent
qu'au dernier chiffre (moins de 1e-11 en relatif) : les fichiers précédents venaient d'une autre chaîne de
compilation, ceux-ci du service bâti sous Linux, comme son image.

Les réponses enregistrées du service (`test/data/weather/sandbox_service_answers.json`) se refont en lançant le
service puis en relisant `/systems` et `/point` au même instant `t` et aux mêmes dix points que le fichier.

⚠️ `build_climate_profiles.gd` est un `EditorScript` : le lancer par `-s` hors de l'éditeur ne rend jamais la main.
Passer par le menu DyingStar ▸ Rebuild climate profiles, ou appeler sa fonction statique `build_all()` depuis un
script `extends SceneTree`.

## Outils sans Horizon : lire le service directement

`WeatherService` (`scenes/planet/weather/weather_service.gd`) interroge l'API HTTP du service
(`GET /api/v1/<corps>/systems?t=`) toutes les 30 s et remet les systèmes à `ClimateWeather.feed`. Il sert à la
vue jeu de Nova et à la carte météo du panneau, qui tournent sans Horizon. Le jeu n'en a pas besoin.

- Adresse : `client.ini`, `[weather] service_url` (la racine du service, `http://127.0.0.1:9400` en local).
- Les identifiants des systèmes sont des entiers 64 bits non signés : lus comme texte.
- Service injoignable ou adresse vide : aucun système, climat de fond, et l'outil le dit (« service météo non
  joint » dans la ligne météo de la vue jeu et dans la légende de la carte).

Lancer le service en local (Rust installé) : dans `services/weather`,
`PORT=9400 SYSTEM_JSON=../resourcesDynamic/data/system/tarsis.json CLIMATE_JSON=data/climate/tarsis.json cargo run -p weather-service`.

## Vérifié (21/11/2026)

- Service lancé en local, vue jeu de Nova : 26 systèmes reçus ; sur 10 points au même instant, le relevé du
  jeu et `/point` du service donnent la même pression, le même vent et la même poussière (écart 0).
- Test automatique sur une réponse enregistrée du service (`test/data/weather/sandbox_service_answers.json`) :
  `test/unit/test_climate_weather.gd`. Aussi : les nœuds `WeatherSystem` d'une planète sont lus, ceux d'un
  autre corps non ; une réponse qui n'est pas celle du service ne donne aucun système.
- Service arrêté : climat de fond, mention affichée.
- **Pas vérifié** : la chaîne service → Horizon → serveur de jeu → clients (il faut un environnement
  complet) ; la carte météo du panneau dans l'éditeur ; le jeu réel avec Tarsis 3 branché.

## Tarsis 3 dans le jeu

`scenes/systems/tarsis/tarsis_3.tscn` porte `weather_source = tarsis_3_weather.tres` et un nœud
`WeatherPhenomena`. Tout ce qui lit `Planet.weather_at` (poussière du vent, couche de poussière, son du vent,
cheveux, panache des volcans) suit donc la météo du service sur Tarsis 3 ; les autres corps gardent le vent
uniforme. `WeatherPhenomena` ne dessine rien sur un serveur dédié ni pour un œil à plus de deux rayons du
centre du corps.

## Ce que le jeu ajoute, déduit de la météo du service

Le service donne la météo à l'échelle de la planète. Par-dessus, le jeu pose ce que le relief et le jour en
font (`WeatherRelief`, `WeatherLocal`, `WeatherCanyon`). Ces phénomènes ne décident pas du temps qu'il fait :
ils en dépendent.

- **Tourbillons** : là où le vent donné par le service est faible (entier sous 4 m/s, aucun au-delà de 7), au
  soleil, aux basses latitudes, et hors de la poussière d'une tempête du service (aucun au-delà d'une épaisseur
  optique de 2,5). Vérifié en vue jeu : 25 tourbillons autour du joueur sans système, aucun au même endroit
  sous un anticyclone du service qui porte le vent à 8 m/s.
- **Murs de poussière** : le vent du service à l'endroit où le mur tombe le porte ou le retient (sa vitesse
  propre plus la composante du vent dans son sens, 30 m/s au plus) ; retenu sous le seuil de soulèvement du
  climat, il ne se forme pas ; dans l'air déjà brassé d'une tempête non plus. Vérifié en vue jeu : le même mur
  court à 16 m/s sans système, à 24 m/s porté par le vent du service.
- **Voile permanent, brise de plateau, rafales sous le vent** : ajoutés au vent et à la poussière du relevé du
  service.
- Le lieu et l'instant où un tourbillon ou un mur peut naître sont tirés du hachage du service
  (`WeatherHash`, jumeau de `hash.rs`, vérifié sur ses vecteurs de référence) : tous les joueurs voient les
  mêmes.

Ce qui a été retiré le 21/11 : `weather_synoptic.gd`, qui recalculait les systèmes côté jeu. Pas repris du
prototype : `weather_forces.gd` (poussée du vent sur les véhicules), les nuages, sa carte en jeu.

Coût : 83 images/s devant un mur de 49 km avec 26 systèmes (RTX 4080, 1600×900, vue jeu de Nova). Un relevé
redemandé au même endroit dans le quart de seconde est rendu de mémoire avant tout calcul.

## Détail des phénomènes locaux


- **Météo locale** (18/11) : `scenes/planet/weather/weather_relief.gd` (`WeatherRelief`), les phénomènes locaux
  du rapport, posés par-dessus le climat. Fonctions pures comme le reste : même lieu, même instant, même
  météo pour tous les joueurs. Tests : `test/unit/test_weather_relief.gd`.
  - *Brise de plateau* : l'air monte les pentes le jour (maximum à 15 h, 6 m/s sur une pente pleine) et les
    redescend la nuit, à 60 %. Au-delà de 60° de latitude la pente draine toute la journée (15 m/s).
  - *Rafales sous le vent* : dans les vents d'ouest, derrière un massif (sol 10 km en amont plus haut), le
    vent gagne jusqu'à ×2,5, par rafales de 20 s.
  - *Voile permanent* : poussière entre 500 et 3500 m d'altitude (épaisseur optique 0,6, soit 6,5 km de
    visibilité), 35 % sous la couche, rien au-dessus : les plateaux hauts restent dégagés.
  - *Tourbillons* : basses latitudes, soleil haut, vent faible ; 5 à 150 m de rayon, 100 à 2500 m de haut,
    5 minutes de vie, vent tournant de 10 à 30 m/s.
  - *Murs de poussière* : entre 16 h 30 et 18 h, l'air froid tombe de la pente la plus raide d'une cellule de
    30 km et court 40 minutes (10 à 18 m/s, 15 à 50 km de front, 0,5 à 3 km de haut) en s'amincissant.
  - Un relevé porte en plus `haze_tau`, `updraft_m_s` (ascendance au-dessus d'un plateau ensoleillé) et
    `phenomena` (noms de ce qui est ressenti sur place).
- Le relief vient de la carte des hauteurs au niveau 256 (une hauteur tous les 700 m : plateaux et vallées,
  pas les rochers), lu par `ClimateWeather.relief_at` et gardé par cellule de 250 m. Réglages dans
  `tarsis_3_weather.tres` : `local_enabled`, `haze_base_m`, `haze_top_m`, `haze_tau`.
- **Dessin** : `scenes/planet/weather/weather_phenomena.gd` (`WeatherPhenomena`, enfant de la planète) dessine
  les tourbillons (12 km autour de l'œil) et les murs que la météo annonce, aux mêmes endroits que leur vent
  et leur poussière (`dust_devil.gdshader`, `dust_wall_volume.gdshader`). Le voile et la poussière d'un mur qui passe
  sur le joueur sont rendus par la couche de poussière existante, qui lit `dust_tau`.
- **Vue jeu de Nova** : une ligne « Météo ici » (vent, température, visibilité, phénomènes) et la carte météo
  de la planète sur la touche M, avec la position du joueur (`addons/nova/nova_weather_hud.gd`).
- **Mur en volume** (18/11) : le mur est une boîte de poussière (`dust_wall_volume.gdshader`). Le rayon de
  chaque pixel traverse la boîte (48 pas au plus, de 90 m, plus longs de loin et dans l'air clair) ; à chaque
  pas la densité est lue (une forme rongée par des volutes de bruit 3D) et 3 pas vers le soleil disent
  combien de poussière fait de l'ombre. Vu de l'intérieur, c'est le même volume.
  - *Forme* : front en arc (les deux bouts traînent de 12 % de la demi-longueur) qui serpente (trois ondes
    de longueurs qui ne retombent jamais en phase), crête qui monte et descend sans se répéter, poussière
    qui s'éclaircit derrière le front (divisée par e tous les 0,9 profondeur de mur) jusqu'à une traîne
    basse en lambeaux (la boîte fait 6 fois la profondeur du mur). Le bruit est lu en biais : le long du
    front les mêmes volutes ne reviennent jamais.
  - *Relief* (`wall_ground.gd`, `WallGround`) : une petite carte des hauteurs du sol sous la boîte (64 × 24
    points, niveau 256 de la carte des hauteurs, relue toutes les 8 s sur un fil de travail). La poussière
    se tient sur le terrain, en bas dans les plaines et en haut sur les plateaux. Les hauteurs sont
    absolues (au-dessus de la sphère de référence) et la carte reste posée sur le sol où elle a été lue :
    le mur glisse dessus jusqu'à la suivante. La boîte va de 250 m sous le sol le plus bas à la hauteur du
    mur au-dessus du sol le plus haut. Avant la première carte (une seconde), le sol est pris plat.
  - *Défaut corrigé le 19/11* : la hauteur du mur était calée sur le sol sous son milieu, relu deux fois
    par seconde ; quand ce point passait sur une crête, tout le front montait d'un coup puis redescendait.
    Mesure après correction, mur poussé à 60 m/s sur 4,8 km de relief, caméra fixe : le sol sous le milieu
    varie de 800 m, le haut de la boîte reste à 9 125 m (± 35 m) et la crête à l'écran bouge de 2 à 8
    pixels entre deux captures, sans saut. Pas de mesure équivalente avant correction.
  - *Vie* (`WeatherRelief` : `grown`, `spent`) : le mur naît bas et court (20 % de sa hauteur, 45 % de sa
    longueur) et grandit en 3 minutes ; à partir de 55 % de sa vie il s'affaisse (jusqu'à 45 % de sa hauteur),
    ses bords s'adoucissent, les volutes le rongent et sa poussière s'éclaircit jusqu'à rien.
  - *Éclairs* (`dust_sparks.gd`, `DustSparks`, `dust_bolt.gdshader`) : dans un mur fort, jusqu'à 5 petits
    arcs à la fois. Chacun est un tracé fin et tordu avec 3 ramifications, haut de 180 à 520 m, posé 15 à
    110 m derrière le front, près de l'œil, allumé 0,1 à 0,3 s en scintillant, puis muet 0,6 à 3,2 s. La
    poussière autour s'éclaire faiblement (140 m). Purement visuels : pas de son, pas d'effet sur le joueur,
    et pas les mêmes pour deux joueurs.
  - *Coût* (RTX 4080, 1600×900, mur de 40 km posé devant la caméra) : 111 images par seconde à 6 km, 104 à
    9 km d'altitude, 109 à 60 km, 93 de nuit à 2,2 km ; 120 sans mur.
  - *Limites* : le mur est dessiné après la brume du jeu, donc il n'est pas voilé par elle alors que le
    terrain à la même distance l'est ; de très haut la traîne se voit peu ; les tourbillons restent en
    coquilles ; la carte du sol est au niveau 256 (un point tous les 700 m environ), le pied du mur ne suit
    pas les petits reliefs.
  - Captures : `meteo_mur_jour.png`, `_devant`, `_proche`, `_dedans`, `_eclair`, `_naissance`, `_fin`,
    `_altitude`, `_orbite`.
- **Aller voir** (vue jeu) : touche **P**, aller devant un mur de poussière (les heures où ils tombent sont
  parcourues, le plus imposant à moins de 60 km est gardé, le joueur est posé 2,5 km devant, face à lui ;
  il arrive en 2 à 4 minutes) ; touche **T**, aller voir le plus gros tourbillon à moins de 12 km (l'heure
  passe à 13 h s'il fait nuit). Un message dit ce qu'on regarde. Captures d'un mur réel qui arrive puis
  passe sur le joueur : `meteo_mur_devant.png`, `meteo_mur_proche.png`, `meteo_mur_dedans.png`.
- Les murs tombent entre 16 h 30 et 18 h (40 minutes de vie) : plus tard il fait nuit noire et ils ne se
  voient pas. Le rapport dit « début de soirée ».
- L'horloge de la vue jeu ne retrouve midi qu'au quart d'heure près : remettre la même heure donne un autre
  instant, donc une autre météo. « Aller voir » garde l'instant exact et ne remet pas l'heure en déplaçant
  le joueur (`_place(..., keep_clock)`).
- Mesuré en vue jeu (18/11) : 114 images par seconde, 0,08 ms par relevé. Un mur réel est passé sur le
  joueur : vent de 5 à 16,6 m/s, visibilité de 999 à 2 km. Captures : `docs/nova_captures/meteo_*.png`.
- La saison : `ClimateWeather.sun_over` borne la déclinaison de l'étoile à l'inclinaison du climat. La vue jeu
  de Nova place l'étoile à 39° nord pour une planète inclinée de 15° ; sans cette borne tout l'hémisphère
  nord était en été extrême.
- Écarts connus au rapport : le seuil de vent des tourbillons est adouci (entier sous 4 m/s, nul à 7, le
  rapport dit 5) parce que les alizés du modèle sont à 5,2 m/s ; le phénomène inverse du matin (renverse
  montante) n'est pas fait ; les murs ne suivent pas les vallées, ils courent droit dans le sens de la pente.
- Aspect repris le 18/11 : un tourbillon est fait de 3 coquilles tournant chacune à sa vitesse (bord
  déchiqueté, colonne qui ploie, jupe de poussière au pied, côté soleil plus clair) ; un mur de 7 nappes
  (front bombé en son milieu, crête irrégulière qui s'abaisse aux deux bouts, volutes). La poussière prend
  la couleur du sol où le phénomène se tient, pâlie de moitié (`WeatherPhenomena.DUST_PALE`), et s'efface
  au contact du terrain. Les captures du mur et des tourbillons sont faites avec des phénomènes posés devant
  la caméra par la sonde. Reste visible : quelques arêtes de nappes sur les bords du mur. Le voile, lui,
  prend la couleur du sol sous le joueur (règle de la couche de poussière existante) : vert sur le sol par
  défaut de l'équateur.
- Pas porté, du prototype : nuages d'eau (humidité 0 sur Tarsis 3 : le rapport les exclut), forces du vent
  sur le joueur et les véhicules (côté serveur, touche à l'existant).
- **Plantage à la fermeture (exit 139)**, vu de temps en temps après des tests ou une vue jeu réussis : il
  vient de l'extension de chat vocal `addons/godot-livekit`, pas de Nova ni de la météo. Windows l'a
  enregistré dans `livekit_ffi.dll_unloaded` (la bibliothèque est déchargée alors qu'un de ses fils tourne
  encore). Mesuré le 18/11 sur `test_nova` : 1 plantage sur 12 lancements avec l'extension, 0 sur 36 sans
  (liste `.godot/extension_list.cfg` vidée le temps de l'essai, puis remise). Le travail est fini quand il
  survient : les résultats sont bons, seul le code de sortie est faux. À signaler à qui maintient l'extension.
- **Atmosphère changée le 20/10/2026** (wiki ↔ JSON) : CO2 0,5 %, N2 78,7 %, O2 19,5 % (au lieu de CO2 2 %).
  `scenes/planet/climates/tarsis_3.tres` est généré par le service météo depuis l'ancien `tarsis.json` : à
  régénérer par le service, pas à la main (effet de serre, masse molaire, donc température de surface et
  hauteur d'échelle). Rien dans le dépôt du jeu ne porte la composition.
- **Grottes** : ce que `WeatherPhenomena` dessine (murs, éclairs, tourbillons) s'efface quand l'œil passe sous
  la surface du terrain, entier jusqu'à 10 m dessous et nul à 25 m (`CAVE_FULL_M`, `CAVE_GONE_M`). La couche
  de poussière existante n'est déjà pas dessinée sous le sol (`WeatherSky`) et le son du vent est coupé par
  la roche (`PlaceWatcher.buried`). Reste : le relevé météo lui-même (vent, `dust_tau`) ne sait pas qu'on est
  dans une grotte, donc un consommateur qui le lit directement, comme la ligne « Météo ici », annonce encore
  le mur ; et dans les dix premiers mètres d'une entrée le mur reste dessiné à travers la roche.
- La direction du vent saute aux limites de bande (31,9° et 60°), comme dans le prototype.
- Le temps du jeu (`Globals.sim_time`) n'est celui du service que si les deux partent de la même époque.
