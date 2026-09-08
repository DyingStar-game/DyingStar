#!/usr/bin/env python3
"""Éclate un heights.pack en une arborescence de tuiles servable par nginx.

Phase 2 de docs/PLANET_CHUNK_STREAMING.md. Outil SÉPARÉ de l'exporteur, à dessein :

  · il ne complique pas l'exporteur, déjà le code le plus long et le plus lent ;
  · il se rejoue sans ré-exporter — changer de sharding ou de compression ne coûte plus
    des heures de TIN ;
  · il fonctionne sur v1 comme sur v2, donc les planètes encore en float32 dense peuvent
    être publiées sans être ré-exportées ;
  · il est testable sur des packs synthétiques.

ARBORESCENCE PRODUITE
---------------------
    <out>/<planet>/latest.json                    pointeur de version, Cache-Control: no-cache
    <out>/<planet>/<version>/manifest.json        copie du manifeste du pack
    <out>/<planet>/<version>/n<nside>/f<shard>/f<ipix>.bin      une tuile
    <out>/<planet>/<version>/n<nside>/f<shard>/present.bin      présence du shard

La version est dans le CHEMIN, donc chaque objet est immuable et se sert avec
`Cache-Control: immutable, max-age=1y`. Publier une nouvelle version n'invalide rien : on
écrit un nouvel arbre et on bascule le pointeur, ce qui rend le retour arrière trivial et
laisse les clients en vol finir sur leur version.

SHARDING
--------
Un répertoire par tranche de SHARD_TILES ipix. Sans lui, le niveau n1024 de tarsis_3
mettrait 12,6 M de fichiers dans 12 répertoires de face. En NESTED les ipix contigus sont
spatialement contigus, donc un shard est aussi une région du globe.

PRÉSENCE
--------
Sur un pack creux, 35 à 65 % des tuiles n'existent pas, et le client doit remonter d'un
niveau. Sans indication il devrait le découvrir par un 404 : deux allers-retours sur la
majorité des requêtes. Chaque shard porte donc `present.bin`, SHARD_TILES bits (512 o pour
4096 tuiles) disant lesquelles existent. Le client en tire l'information pour 4096 tuiles
voisines d'un coup, et ne demande jamais une tuile absente.

C'est le compromis retenu contre un manifeste global : celui de tarsis_3 pèserait 537 Mo en
sha256, alors que l'ensemble de travail d'un joueur fait ~580 Ko (§7 du document).

INTÉGRITÉ
---------
Chaque tuile porte un en-tête de 12 octets : magie, CRC32 de la charge utile, flags. TLS
couvre le transport, pas un cache disque corrompu ni un objet erroné servi par un CDN — et
la magie attrape le cas classique où une page d'erreur HTML se retrouve mise en cache à la
place d'une tuile.

USAGE
-----
    python3 tools/publish_tiles.py assets/qgis/export/tarsis_3_chunks/heights.pack \\
        --out dist/ --compress
    python3 tools/publish_tiles.py <pack> --out dist/ --verify
"""

import argparse
import json
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.analyze_pack_sparsity import Pack

TILE_MAGIC = b"DSTL"
TILE_HEADER = 12
FLAG_DEFLATE = 1
## Tuiles par répertoire de shard. 4096 -> une carte de présence de 512 octets, et
## 3072 répertoires au niveau n1024 de tarsis_3 au lieu de 12.
SHARD_TILES = 4096


def tile_blob(payload, compress):
    """En-tête + charge utile. Le CRC porte sur les octets RÉELLEMENT transmis."""
    flags = 0
    if compress:
        packed = zlib.compress(payload, 6)
        if len(packed) < len(payload):
            payload, flags = packed, FLAG_DEFLATE
    return struct.pack("<4sII", TILE_MAGIC, zlib.crc32(payload) & 0xFFFFFFFF,
                       flags) + payload


def read_tile_blob(blob):
    """Inverse de tile_blob. Lève sur magie ou CRC invalide plutôt que rendre du bruit."""
    if len(blob) < TILE_HEADER:
        raise ValueError("tuile tronquée (%d octets)" % len(blob))
    magic, crc, flags = struct.unpack("<4sII", blob[:TILE_HEADER])
    if magic != TILE_MAGIC:
        raise ValueError("magie %r — ce n'est pas une tuile (page d'erreur mise en cache ?)"
                         % magic)
    payload = blob[TILE_HEADER:]
    if (zlib.crc32(payload) & 0xFFFFFFFF) != crc:
        raise ValueError("CRC invalide — objet corrompu")
    return zlib.decompress(payload) if flags & FLAG_DEFLATE else payload


def shard_of(ipix):
    return ipix // SHARD_TILES


def publish(pack, out_root, planet, version, compress):
    root = os.path.join(out_root, planet, version)
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(pack.manifest, fh, indent=2)

    written = raw_bytes = out_bytes = 0
    for nside in pack.levels:
        npix = 12 * nside * nside
        for base in range(0, npix, SHARD_TILES):
            end = min(base + SHARD_TILES, npix)
            sdir = os.path.join(root, "n%d" % nside, "f%d" % shard_of(base))
            os.makedirs(sdir, exist_ok=True)
            bits = bytearray((end - base + 7) // 8)
            for ipix in range(base, end):
                if not pack.has_tile(nside, ipix):
                    continue
                i = ipix - base
                bits[i >> 3] |= 1 << (i & 7)
                payload = pack.raw_tile(nside, ipix)
                blob = tile_blob(payload, compress)
                with open(os.path.join(sdir, "f%d.bin" % ipix), "wb") as fh:
                    fh.write(blob)
                written += 1
                raw_bytes += len(payload)
                out_bytes += len(blob)
            with open(os.path.join(sdir, "present.bin"), "wb") as fh:
                fh.write(bits)
    return written, raw_bytes, out_bytes


def verify(pack, out_root, planet, version):
    """Relit l'arborescence et la compare au pack. Rend le nombre de désaccords.

    Publier sans relire, c'est découvrir un décalage de sharding une fois les clients
    dessus : ici un octet de travers se voit tout de suite.
    """
    root = os.path.join(out_root, planet, version)
    bad = checked = 0
    for nside in pack.levels:
        npix = 12 * nside * nside
        for base in range(0, npix, SHARD_TILES):
            end = min(base + SHARD_TILES, npix)
            sdir = os.path.join(root, "n%d" % nside, "f%d" % shard_of(base))
            try:
                with open(os.path.join(sdir, "present.bin"), "rb") as fh:
                    bits = fh.read()
            except OSError:
                print("  MANQUE %s/present.bin" % sdir)
                bad += 1
                continue
            for ipix in range(base, end):
                i = ipix - base
                here = bool(bits[i >> 3] >> (i & 7) & 1)
                if here != pack.has_tile(nside, ipix):
                    print("  PRESENCE n%d f%d: arbre=%s pack=%s"
                          % (nside, ipix, here, pack.has_tile(nside, ipix)))
                    bad += 1
                    continue
                if not here:
                    continue
                checked += 1
                path = os.path.join(sdir, "f%d.bin" % ipix)
                try:
                    with open(path, "rb") as fh:
                        got = read_tile_blob(fh.read())
                except (OSError, ValueError, zlib.error) as exc:
                    print("  ILLISIBLE %s: %s" % (path, exc))
                    bad += 1
                    continue
                if got != pack.raw_tile(nside, ipix):
                    print("  CONTENU n%d f%d diffère du pack" % (nside, ipix))
                    bad += 1
    return bad, checked


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pack")
    ap.add_argument("--out", required=True, help="racine de publication")
    ap.add_argument("--planet", help="nom du corps (défaut : celui du manifeste)")
    ap.add_argument("--compress", action="store_true", help="deflate chaque tuile")
    ap.add_argument("--verify", action="store_true",
                    help="ne publie pas : relit l'arborescence et la compare au pack")
    args = ap.parse_args(argv)

    pack = Pack(args.pack)
    planet = args.planet or pack.planet_name
    version = str(pack.manifest.get("data_version", "")) or "nodataversion"
    if version == "nodataversion":
        print("ATTENTION : le manifeste ne porte pas de data_version. La version d'URL "
              "sera 'nodataversion' et deux exports différents s'écraseraient. "
              "Ré-exportez avec un exporteur qui l'écrit.")
    print("%s — DSHP v%d, %s%s, niveaux n%d..n%d, version %s"
          % (planet, pack.version, "uint16" if pack.u16 else "float32",
             ", creux" if pack.sparse else "", pack.nside_min, pack.nside_max, version))

    if args.verify:
        bad, checked = verify(pack, args.out, planet, version)
        print("  %d tuiles vérifiées, %d désaccord(s)" % (checked, bad))
        return 1 if bad else 0

    written, raw_bytes, out_bytes = publish(pack, args.out, planet, version, args.compress)
    ptr = os.path.join(args.out, planet, "latest.json")
    with open(ptr, "w", encoding="utf-8") as fh:
        json.dump({"data_version": version, "nside_min": pack.nside_min,
                   "nside_max": pack.nside_max, "tile_res": pack.tile_res,
                   "shard_tiles": SHARD_TILES}, fh, indent=2)
    ratio = (100.0 * out_bytes / raw_bytes) if raw_bytes else 100.0
    print("  %d tuiles publiées, %.1f Mo (%.0f%% de la charge brute)"
          % (written, out_bytes / 1e6, ratio))
    print("  pointeur : %s" % ptr)
    print("  nginx : immutable/max-age=1y sur <version>/, no-cache sur latest.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
