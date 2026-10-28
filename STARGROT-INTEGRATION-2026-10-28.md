# StarGrotte — candidat de fusion du 28 octobre 2026

> Rapport de l’étape antérieure à l’ajout du catalogue des 200 grottes et à la préparation de la PR. Pour la livraison courante, voir [STARGROT-PR-2026-10-28.md](STARGROT-PR-2026-10-28.md). Les états de publication ci-dessous décrivent cette étape antérieure.

## Cible et état du travail

Base Dying Star : `b4f834df9142f9af7ed92174d8c8ab23431fe64e`, dernier `origin/develop` récupéré le 28 octobre. L’ancienne base était `509148dc81a54061ec1422dbe78d03af4ac8648b`. Les 36 commits intermédiaires ont été intégrés par avance rapide, puis les changements locaux ont été réappliqués sans conflit. Les routes, biomes, montagnes et profils de Tarsis 3 réexportés en amont sont conservés ; la clé de cache native reste en version 68.

Branche locale : `codex/stargrot-integration-20261028`. Les fichiers de la contribution sont préparés pour revue dans l’index local. Aucun commit n’a été créé : le dépôt ne possède pas d’identité d’auteur Git configurée et le nom / l’adresse à utiliser ont été demandés. Aucun push, aucune PR ni fusion distante n’ont été effectués. Le travail prépare une revue de fusion et ne publie aucune release. Sauvegarde avant mise à jour : `../stargrot-before-update-20261028.zip`, 282 fichiers, manifeste SHA-256 et patch des fichiers suivis.

## Comportement livré

L’atelier crée, place, habille et valide des grottes, puis exporte un catalogue par planète. Le jeu lit ce catalogue et reconstruit les cavités à proximité des secteurs demandés. Les entrées coupent le terrain et les collisions ; le serveur conserve l’autorité physique. Les chemins et les graines donnent les mêmes géométries au client et au serveur.

Le jeu reçoit le module d’exécution, les catalogues et les assets. L’atelier et les scènes de test sont exclus des exports. Après cette première intégration, il suffit de livrer les nouveaux catalogues avec leur référence de planète et les nouveaux assets éventuels. L’export actuel contient des définitions procédurales, pas des scènes entièrement précalculées indépendantes du module.

Le lot comprend les corrections de raccords, les six modèles intérieurs et la bibliothèque extérieure distincte de douze rochers. Le spawn de rochers minables a été étudié, mais n’est pas implémenté dans ce candidat.

## Nettoyage et optimisations

- Le garde Windows propre à l’atelier, `CaveWindowsLifetime.cs`, est supprimé. Le GDScript de l’atelier réutilise `tools/native/NativeLibraryPin.cs`, apporté par Dying Star. L’unique adaptation de ce fichier natif est `[Tool]`, nécessaire pendant les imports de l’éditeur.
- `CaveResidentSet.pump()` ne refait plus son parcours pour chaque requête de chunk au cours de la même image. Une modification des secteurs invalide immédiatement ce résultat, même dans cette image. La limite de deux tâches et d’un assemblage par image reste en place ; une surface percée ne devient pas disponible avant sa collision de grotte.
- Les six lampes de démonstration au maximum par grotte ne sont créées que pour un lancement explicite de l’atelier. Les grottes du jeu utilisent son éclairage normal. Le serveur ne crée aucun éclairage ni maillage de présentation.
- Les placements mémorisent la signature native du relief en plus de la version des tuiles. Un changement du relief ou de sa sculpture impose un recalage avant export et avant découpe du terrain. La signature du site et de ses caches inclut cette provenance.
- 47 infobulles manquantes du module ont été renseignées. Le contrôle général a également révélé deux infobulles absentes dans `item_dispenser.gd` en amont ; elles sont ajoutées sans changement de comportement du distributeur.
- La vérification conserve les empreintes des sources testées. Le paquet vérifie ces empreintes, inclut les changements déjà commis sur la branche et contrôle l’application du patch sur la base propre.

Ces améliorations suppriment des doublons et du travail répété. Aucun gain de FPS ou pourcentage d’accélération n’est annoncé sans mesure comparative.

## Points de raccord à relire

| Fichiers natifs modifiés | Rôle |
| --- | --- |
| `scenes/planet/planet_data.gd` | Référence du catalogue, définitions, plans actifs et signature des grottes. |
| `scenes/planet/planet_terrain.gd` | Abonnement à la résidence native, cache, attente des collisions, rafraîchissement de l’atelier et fermeture des tâches. |
| `scenes/planet/planet_chunk.gd` | Découpe du maillage et des collisions à partir des ouvertures. |
| `scenes/player/player_server.gd` | Cavités reconnues par la sécurité sous le terrain ; annulation d’un mouvement scripté après téléportation ou vol libre. Les corrections amont NPC restent présentes. |
| `scenes/player/player.gd` | Contrôleur serveur local réservé au lancement explicite de l’atelier. |
| `scenes/globals/globals.gd`, `game_orchestrator.gd`, `chat_network.gd`, `tools/observability/obs.gd` | Démarrage isolé de l’atelier ; le jeu conserve ses services habituels. |
| `addons/dyingstar/dyingstar.gd`, `tools/native/NativeLibraryPin.cs` | Appel du garde Windows pendant les imports de validation. |
| `export_presets.cfg`, `.gitignore` | Exclusion de l’atelier, des tests et des preuves locales dans les builds. |
| `scenes/_universe/structures/dispenser/item_dispenser.gd` | Deux commentaires d’inspection requis par le test général. |

Le noyau de densité et de triangulation reste dans `CaveNetworkMesher.cs`. La génération des plans, les raccords, le placement, les décors, le streaming et l’atelier sont en GDScript. La suppression du doublon Windows ne porte pas sur le noyau géométrique.

## Validation initiale avant la correction du porche

Le passage complet de `verify_develop.ps1 -WithPlanetTest` s’est terminé avec le code 0 sur cette base le 28 octobre 2026 :

| Contrôle | Résultat |
| --- | --- |
| Compilation .NET 9 / import Godot 4.7 Mono double précision | Réussis, zéro erreur de compilation ou de script ; garde Windows actif pendant l’import. |
| Tests unitaires du module et des contrats natifs concernés | 138 tests, 3 551 assertions, zéro échec. |
| Lot de 200 sites sur terrain synthétique plat | 40 contrôles réussis ; chargement, déchargement et retour dans le même secteur vérifiés. Ce test ne mesure pas la génération de 200 sites sur le relief réel de Tarsis 3. |
| Catalogue livré initialisé côté client et serveur | 20 contrôles réussis ; géométrie identique, signatures et résidence vérifiées. |
| Ciel et cycle jour/nuit sur le système réel | 15 contrôles réussis. |
| Création / recalage / export / suppression / annulation / fermeture sur Tarsis 3 | 40 contrôles réussis ; catalogue d’exemple de 11 sites réexporté sur le relief actuel. |
| Placement à la souris sur la planète | 23 contrôles réussis. |
| Porche / doline / puits de lumière sur la planète | 33 contrôles réussis. |
| Décors intérieurs / extérieurs et raccords synthétiques | Six modèles intérieurs, 105 occurrences ; poses et séparation validées. Bibliothèque extérieure de douze formes, budget et collisions validés, aucun échec. Scène des raccords terminée normalement. |
| Atelier | Ouverture et fermeture réussies, zéro tâche de profilage du relief restante. |
| Style GDScript du module, de l’atelier et de leurs tests | 58 scripts, zéro problème. |
| Crédits, avec les nouveaux fichiers présentés au validateur | 211 crédits bien formés ; aucun nouveau modèle sans attribution. |
| Patch complet | 281 fichiers ; application contrôlée sur un index propre de `b4f834df`. |

Les 171 contrôles chiffrés hors tests unitaires (40 + 20 + 15 + 40 + 23 + 33) ont réussi, en complément des scénarios de décors, de raccords et de fermeture. Aucun scénario final ne présente d’erreur de script. Le recalage et les reconstructions sur le relief réel sont coûteux et ne sont pas présentés comme instantanés. Les résultats du 24 et du 27 octobre décrivent leurs propres bases ; ils ne certifient pas automatiquement ce candidat.

Les preuves datées sont conservées dans `.stargrot-validation/`. Le manifeste du paquet inclut les empreintes et le certificat courant. Une unique ligne vide finale de `cave_natural_opening.gd` a été supprimée après le passage complet, sans autre changement d’octets ; le contrôle de syntaxe/style et le contrôle des espaces Git ont été rejoués. Le certificat conserve les empreintes avant/après de ce nettoyage. Les captures planétaires ont été examinées en complément des contrôles automatiques.

## Marche à suivre pour la fusion

1. Relire le patch complet contre la base ci-dessus, en commençant par les raccords natifs du tableau, puis le contrat de placement et le streaming. Les fichiers de l’atelier peuvent être relus séparément du module d’exécution.
2. Rejouer la commande du guide `STARGROT-LIVRAISON-DEVELOP.md` avec Godot 4.7 Mono double précision et .NET 9 fournis par Dying Star.
3. Examiner la correction et les preuves de `STARGROT-REVUE-2026-10-28.md`, puis essayer le catalogue dans un vrai client et un vrai serveur exportés.
4. Choisir explicitement les catalogues destinés au jeu et les affecter aux planètes. Le catalogue d’exemple reste une démonstration ; aucune planète de production ne reçoit automatiquement ses grottes.
5. Ouvrir une demande de fusion vers `develop` après revue du candidat. Si `develop` avance, récupérer ses changements et rejouer les contrôles. Ne pas réutiliser le paquet du 24 octobre pour intégrer ce lot.

## Réserves avant fusion définitive

**Réserve initiale traitée par la révision relue :** le grand triangle sans sol au pied du porche a été reproduit par un test de pente croisée, corrigé et contrôlé sur le maillage affiché et les collisions serveur. La revue courante, les résultats de sa validation ciblée et les captures avant/après sont dans `STARGROT-REVUE-2026-10-28.md`. Le contraste de teinte avec le terrain reste une réserve artistique. Cette correction ne constitue pas une preuve exhaustive de toutes les jonctions de toutes les grottes.

Les scénarios locaux Windows ne certifient pas les exports Linux/macOS, les sessions multijoueurs distantes, les transferts entre serveurs ni les performances de 200 grottes simultanément visibles. Les avertissements de terrain construit sur des tuiles ancêtres doivent rester visibles : ils signalent une divergence possible entre la présentation et les collisions ; ils restent une limite native à vérifier dans les essais de déploiement.

L’avertissement NuGet NU1902 d’OpenTelemetry 1.12.0 appartient aux dépendances de la base actuelle. Les diagnostics natifs de l’éditeur, des shaders et de fermeture sont consignés dans les journaux ; ils ne sont pas assimilés à une certification sans défaut de tout le jeu.

Le dossier Word du 27 octobre reste utile pour l’architecture générale. Sa base, certains numéros de ligne, le garde Windows et les éclairages de démonstration sont historiques : utiliser ce bilan et les sources actuelles pour la revue de ce candidat.
