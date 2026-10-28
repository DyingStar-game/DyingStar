# Intégrer StarGrotte 0.9 dans develop

Base de cette livraison : `b4f834df9142f9af7ed92174d8c8ab23431fe64e` (`origin/develop`, récupérée le 28 octobre 2026). Branche locale de préparation : `codex/stargrot-integration-20261028`. Le dossier courant est `STARGROT-PR-2026-10-28.md`. Les bilans de portage et de correction décrivent les étapes précédentes ; le rapport du 24 octobre est historique.

Les textures Rock029 des décors sont celles du dépôt Dying Star, déjà présentes à cette base ; le patch ne les duplique pas.

La contribution complète porte sur le module planétaire des grottes (`scenes/planet/cave/`), l’atelier (`tools/stargrot/`, `levels/stargrot/`), leurs tests et les points de raccord natifs. Le jeu utilise le module d’exécution et les catalogues ; l’atelier reste un outil de développement exclu des exports. Une fois le module intégré, un auteur peut conserver son atelier et livrer seulement ses catalogues, leur référence de planète et les éventuels nouveaux assets.

## Contenu déjà raccordé dans cette PR

Le catalogue `levels/stargrot/catalogs/tarsis_3_200_grottes.tres` est déjà affecté au champ **Cave Catalog** de `scenes/systems/tarsis/tarsis_3.tscn`. L’application de la contribution complète active donc les 200 grottes créées dans l’atelier sur Tarsis III, pour le client et le serveur. Les étapes de référence de scène ci-dessous servent aux livraisons suivantes ou à une autre planète.

## Préparer le paquet

```powershell
python tools/stargrot/package_develop.py --output CHEMIN
```

La commande produit `StarGrotte-0.9-pour-develop.zip` : un patch Git complet, son manifeste (empreintes SHA-256), ce guide et le bilan actuel. Le patch inclut les modifications locales et celles déjà commises sur la branche par rapport à `origin/develop`. L’option `--base REVISION` permet de fixer explicitement la cible. Son application est contrôlée sur un index propre de cette base. L’index Git réel n’est pas touché ; la commande refuse les modifications suivies extérieures au périmètre prévu. Aucun commit, push ou merge n’est effectué par cette commande.

Le manifeste exige les résultats du dernier contrôle. S’ils sont absents, désignent une autre base ou si les empreintes de leurs sources ont changé, la préparation échoue et demande de rejouer la vérification.

## Première intégration du module

Extraire le ZIP dans un dossier séparé. Depuis une branche de travail basée sur develop :

```powershell
git apply --check "CHEMIN/StarGrotte-0.9-develop.patch"
git apply "CHEMIN/StarGrotte-0.9-develop.patch"
```

Si develop a changé et que la première commande signale un conflit, mettre le portage à jour avant d’appliquer ; ne pas forcer l’écrasement des fichiers. Compiler avec le moteur Godot 4.7 Mono **double précision** utilisé par Dying Star et .NET 9, puis exécuter :

```powershell
./tools/stargrot/verify_develop.ps1 -Godot "CHEMIN/godot_console.exe" -Dotnet "CHEMIN/dotnet.exe" -WithPlanetTest
```

Les arguments utilisateur de l’atelier sont `--stargrot-explorer --stargrot-workbench`. Le jeu conserve son démarrage habituel. L’import de validation et l’atelier Windows réutilisent le garde natif `tools/native/NativeLibraryPin.cs` fourni par Dying Star ; son attribut `[Tool]` permet aussi son appel pendant l’import. Le doublon C# propre à l’atelier a été supprimé.

## Ajouter ensuite les grottes d’une planète

1. Dans l’atelier, choisir la planète et préparer / placer ses grottes. Les ajouts sont sauvegardés automatiquement dans la collection locale.
2. Ouvrir **Livrer → Exporter toutes les grottes de cette planète**. Enregistrer le catalogue sous `levels/stargrot/catalogs/<planete>_grottes.tres` dans le dépôt de développement.
3. Dans Godot, ouvrir la scène de cette planète. Dans sa ressource **Planet Data**, groupe **Stargrot**, affecter le fichier au champ **Cave Catalog**. Enregistrer la scène.
4. Livrer le catalogue et cette référence de scène dans la même modification. Client et serveur doivent recevoir le même contenu et la même version du relief.

Le catalogue utilisé par le jeu est `levels/stargrot/catalogs/tarsis_3_200_grottes.tres` (200 grottes version 9). `levels/stargrot/catalogs/tarsis_3_example.tres` reste une démonstration de onze grottes, séparée du contenu activé.

Les bibliothèques fournies font partie du module. Pour une bibliothèque personnelle, ajouter également ses modèles, matériaux et textures au dépôt en conservant leurs chemins `res://`.

Le catalogue devient la source des grottes de la planète. Le jeu ouvre les entrées (porches, dolines, puits de lumière, sorties) et charge les cavités proches avec ses secteurs de terrain. L’interface StarGrotte n’apparaît pas chez les joueurs.

## Quand le terrain ou develop évolue

Conserver les essais. Utiliser **Peupler → Recaler les grottes sur le relief actuel** : l’entrée, l’enfouissement et les puits de lumière sont réajustés au nouveau relief. Le placement mémorise à la fois `chunk_data_version` et la signature native `relief_signature` : un changement de sculpture du terrain impose aussi le recalage, même si les tuiles de hauteur sont inchangées. Les anciennes définitions sans cette signature doivent être recalées sur une planète qui en fournit une. Les sites refusés restent dans la collection, marqués à recaler, et ne percent pas le nouveau terrain. Corriger ou supprimer ces sites avant l’export.

Seules les versions 8 et 9 du générateur sont prises en charge. Une définition plus ancienne est refusée avec un message explicite ; la régénérer dans l’atelier.

## Validation et limites

`verify_develop.ps1` rejoue la compilation, l’import, les tests unitaires (`test/unit/test_stargrot_*.gd`), la population de 200 sites et le catalogue livré, sans fenêtre. Avec `-WithPlanetTest`, il lance en plus, avec le rendu, les scénarios sur Tarsis : ciel du système, placement créatif, clic sur la surface, porches / doline / puits de lumière, assets, fermeture de l’atelier. Les journaux et captures vont dans `.stargrot-validation/` (ignoré par Git).

Le contrôle inclut les contrats amont de documentation des propriétés, voix, rôle NPC, placement des charges et terminal de véhicules. Les empreintes des sources sont enregistrées avant les essais et comparées à la fin ; un fichier modifié pendant la vérification empêche l’émission du certificat `passed.json`. Les éclairages de démonstration sont réservés au lancement explicite de l’atelier : une grotte livrée utilise l’éclairage normal du jeu.

Pour la correction du porche et la revue du 28 octobre, voir `STARGROT-REVUE-2026-10-28.md`. Le paramètre facultatif `-Scenes` sélectionne explicitement les scénarios à rejouer ; le certificat en conserve la liste, afin qu’un contrôle ciblé ne soit pas confondu avec la suite complète. Les documents Markdown peuvent être actualisés avec les résultats après les essais ; le manifeste de livraison en conserve aussi les empreintes.

Les performances graphiques de centaines de sites sur une planète réelle, les transferts entre serveurs et Mac/Linux ne sont pas certifiés par ces essais Windows.
