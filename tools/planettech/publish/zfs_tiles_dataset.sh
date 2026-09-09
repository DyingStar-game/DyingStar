#!/bin/sh
# Crée le dataset ZFS qui héberge les tuiles de terrain servies par nginx (FreeBSD).
#
# ── Le profil de charge, mesuré et non supposé ───────────────────────────────
#
#   5 109 933 fichiers par version de tarsis_3 à 198 m
#   moyenne 1090 o, médiane 1106 o, AUCUN fichier au-dessus de 2060 o
#   écrits une fois par publication, relus indéfiniment par nginx
#   supprimés en bloc, une version entière à la fois
#   déjà compressés en deflate par tools/planettech/publish/publish_tiles.py
#
# Deux conséquences dictent tout le reste : les fichiers sont minuscules, et ils sont
# des millions. Ce n'est pas un stockage d'octets, c'est un stockage de métadonnées.
#
# ── Ce que ce script NE PEUT PAS décider pour vous ───────────────────────────
#
# `ashift` se fixe à la création du VDEV et ne se change JAMAIS ensuite. C'est la seule
# décision irréversible, et sur cette charge elle vaut un facteur trois :
#
#   ashift=12 (4 Kio)   1 version = 19,5 Gio    4 versions = 78,0 Gio
#   ashift=9  (512 o)   1 version =  6,4 Gio    4 versions = 25,8 Gio
#
# Parce qu'une tuile de 1106 octets occupe UN secteur de 4 Kio, ou TROIS secteurs de
# 512 o. Le gaspillage passe de 276 % à 24 %.
#
# ashift=9 sur des disques 4Kn ou 512e fait payer un read-modify-write au disque à
# chaque écriture. Ici cette pénalité ne tombe qu'à la publication — le dataset est
# écrit une fois puis lu — mais elle est réelle, et sur un pool partagé avec d'autres
# charges elle ne se limitera pas à ce dataset.
#
# Vérifiez l'existant AVANT de créer quoi que ce soit :
#     zpool get ashift <pool>
#     zdb -C <pool> | grep ashift        # par vdev, la vraie source
#
# Si le pool est déjà en ashift=12, ce script marche quand même : vous paierez 19,5 Gio
# par version au lieu de 6,4. Recréer un pool pour ça ne se justifie que si l'espace est
# la contrainte qui mord.

set -eu

POOL="${POOL:-tank}"
DATASET="${DATASET:-$POOL/dyingstar-tiles}"
MOUNT="${MOUNT:-/var/www/dist}"
# Quatre versions (une par canal) plus une en cours de publication, avec de la marge.
# À recalculer si vous changez d'ashift : 6,4 Gio/version en 512 o, 19,5 en 4 Kio.
QUOTA="${QUOTA:-120G}"

echo "== Création de $DATASET sur $MOUNT (quota $QUOTA) =="

zfs create -o mountpoint="$MOUNT" "$DATASET"

# ── atime=off : LE réglage qui compte ────────────────────────────────────────
# Avec le défaut, CHAQUE lecture de tuile écrit une métadonnée. Un serveur web servant
# cinq millions de petits fichiers transformerait une charge purement lecture en charge
# écriture. C'est le seul réglage de cette liste dont l'oubli se voit à l'œil nu.
zfs set atime=off "$DATASET"

# ── compression=lz4 ──────────────────────────────────────────────────────────
# Les tuiles sont déjà déflatées (48 % du brut) : lz4 ne regagnera rien dessus, et son
# abandon précoce sur l'incompressible fait que cela ne coûte rien non plus. Il gagne en
# revanche sur ce qui l'entoure — les 4 100 present.bin sont des bitmaps souvent
# entièrement à 0xFF, les manifestes et les manifestes de canaux sont du JSON.
# zstd serait du CPU dépensé cinq millions de fois pour rien.
zfs set compression=lz4 "$DATASET"

# ── redundant_metadata=most ──────────────────────────────────────────────────
# Le défaut `all` écrit des copies redondantes de TOUS les niveaux de métadonnées. À
# 5,1 millions de dnodes par version — 2,4 Gio de métadonnées à elles seules — c'est le
# poste qui domine. `most` réduit ces copies. Le contenu reste reproductible : une
# version perdue se republie, ce qui est précisément ce qui rend ce compromis acceptable
# ici et pas sur des données irremplaçables.
zfs set redundant_metadata=most "$DATASET"

# ── recordsize : laissé par défaut, DÉLIBÉRÉMENT ─────────────────────────────
# Réflexe courant et inutile ici : recordsize est un MAXIMUM. Un fichier plus petit
# occupe un seul enregistrement dimensionné à sa taille, arrondi à l'ashift. Aucun de
# nos fichiers n'atteint 4 Kio, donc recordsize ne change rien à leur stockage. Le
# baisser n'apporterait rien et pénaliserait tout autre fichier posé là.

# ── Hygiène pour un dataset servi par un serveur web ─────────────────────────
zfs set exec=off "$DATASET"
zfs set setuid=off "$DATASET"

# ── Le garde-fou ─────────────────────────────────────────────────────────────
# Une publication écrit 5,1 millions de fichiers sans jamais demander la permission. Le
# quota est ce qui l'arrête avant qu'elle ne remplisse le pool sous les autres services.
zfs set quota="$QUOTA" "$DATASET"

echo
echo "== Réglages appliqués =="
zfs get -o property,value \
    atime,compression,redundant_metadata,recordsize,quota,exec,setuid "$DATASET"
echo
echo "ashift du pool (NON modifiable après coup) :"
zpool get -o property,value ashift "$POOL"

# ─────────────────────────────────────────────────────────────────────────────
# DEUX OPTIONS NON APPLIQUÉES — elles engagent le matériel ou la sécurité des
# écritures, donc elles se décident, elles ne se lancent pas.
# ─────────────────────────────────────────────────────────────────────────────
#
# ── A. Un vdev `special` sur SSD ─────────────────────────────────────────────
#
# C'est le levier le plus fort après atime=off. À 5,1 millions de fichiers, chaque
# requête HTTP traverse des métadonnées, et un scrub ou une suppression de version se
# paie en nombre d'objets et non en octets. Les mettre sur SSD change l'ordre de
# grandeur de ces opérations.
#
#     zpool add <pool> special mirror /dev/ada1 /dev/ada2
#
# Toujours en MIROIR : perdre un vdev special, c'est perdre le pool entier, pas
# seulement les métadonnées.
#
# Et surtout, l'option qui va avec, dont l'effet est brutal sur CETTE charge :
#
#     zfs set special_small_blocks=4K <dataset>
#
# Elle envoie sur le vdev special tout bloc de 4 Kio ou moins. Or AUCUNE de nos tuiles
# n'atteint 4 Kio : ce n'est donc pas « les métadonnées sur SSD », c'est **le dataset
# entier sur SSD**. Dimensionnez en conséquence — 19,5 Gio par version en ashift=12,
# 6,4 en ashift=9 — sinon le special se remplit et ZFS déborde silencieusement sur les
# disques normaux, ce qui marche mais rend la performance imprévisible.
#
# Si vous voulez les métadonnées seules sur SSD, laissez special_small_blocks à 0 : un
# vdev special sans cette option ne prend que les métadonnées, soit ~2,4 Gio par version.
#
# ── B. sync=disabled pendant la publication ──────────────────────────────────
#
# Publier écrit 5,1 millions de fichiers. `sync=disabled` supprime l'attente du ZIL et
# accélère nettement cette phase.
#
#     zfs set sync=disabled <dataset>     # avant la publication
#     zfs set sync=standard <dataset>     # après
#
# Le risque est réel et borné : une panne pendant la publication perd les écritures
# récentes. Ce qui le rend acceptable ici, c'est que le contenu est REPRODUCTIBLE — on
# republie depuis le pack — et qu'une version incomplète ne peut de toute façon pas être
# promue : `stream_channels.py --to <canal>` vérifie l'arborescence avant de faire monter
# le pointeur, et refuse tout ou rien.
#
# Ne le laissez pas actif en permanence : le reste du temps le dataset ne fait que de la
# lecture, donc il n'apporte rien et ne fait que retirer une garantie.
