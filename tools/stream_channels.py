#!/usr/bin/env python3
"""Canaux de publication des tuiles de terrain — et la promotion d'un cran.

Un canal est un MANIFESTE : quelle version de données chaque corps utilise.

    <dist>/channels/<canal>.json
    {
      "channel": "preprod",
      "promoted_at": "2026-09-08T21:14:03Z",
      "promoted_from": "dev",
      "planets": {
        "tarsis_3": {"data_version": "81ab…", "nside_min": 1, "nside_max": 256,
                     "tile_res": 32, "shard_tiles": 4096, "floor_nside_max": 8}
      }
    }

Les arborescences de tuiles vivent en `<dist>/<corps>/<version>/` et sont IMMUABLES :
elles ne portent pas le nom du canal. Promouvoir ne recopie donc aucun octet — c'est le
manifeste qui monte d'un cran, et la version déjà servie en dev est littéralement la même
que celle qui passe en preprod. Un octet ne peut pas changer entre deux canaux.

C'est aussi ce qui fait la garantie client/serveur : deux processus qui résolvent le même
canal lisent le même manifeste et obtiennent les mêmes versions par construction. Il n'y a
pas de négociation à faire, seulement un canal à partager.

Cycle de vie, du moins stable au plus stable :

    unstable  →  dev  →  preprod  →  prod

  unstable  ce que quelqu'un vient d'exporter, testé en local par lui seul
  dev       ce que tous les développeurs partagent
  preprod   client et serveur construits ensemble ; le préfixe est figé au build
  prod      les joueurs

Les canaux donnent aussi le critère de suppression : une version qu'AUCUN canal ne cite
est morte. C'est ce que fait `--gc`, et il en faut un — une version de tarsis_3 à 198 m
pèse 5,1 millions de fichiers et 20 Gio, si bien que le volume se remplit en trois
publications.

Run:
    python3 tools/stream_channels.py --dist DIR --list
    python3 tools/stream_channels.py --dist DIR --to dev
    python3 tools/stream_channels.py --dist DIR --to prod --planet tarsis_3
    python3 tools/stream_channels.py --dist DIR --gc --dry-run
"""

import argparse
import datetime
import json
import os
import shutil
import sys

## Du moins stable au plus stable. Promouvoir, c'est passer au rang suivant.
CHANNELS = ["unstable", "dev", "preprod", "prod"]

## Canal qu'un export alimente par défaut : celui qui n'engage que son auteur.
PUBLISH_CHANNEL = "unstable"


def channel_path(dist, channel):
    return os.path.join(dist, "channels", "%s.json" % channel)


def previous_channel(channel):
    """Le cran juste en dessous, ou None pour le plus bas."""
    i = CHANNELS.index(channel)
    return CHANNELS[i - 1] if i > 0 else None


def load(dist, channel):
    """Manifeste du canal, ou un manifeste vide s'il n'existe pas encore."""
    try:
        with open(channel_path(dist, channel), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {"channel": channel, "planets": {}}
    data.setdefault("channel", channel)
    data.setdefault("planets", {})
    return data


def save(dist, channel, data):
    path = channel_path(dist, channel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # Écriture puis renommage : un client qui lit pendant une promotion voit l'ancien
    # manifeste ou le nouveau, jamais un fichier à moitié écrit.
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
    os.replace(tmp, path)
    return path


def record(dist, channel, planet, entry):
    """Inscrit un corps dans un canal, en laissant les autres intacts.

    Lecture-modification-écriture : publier tarsis_3 ne doit pas effacer les dix-huit
    autres corps du canal.
    """
    data = load(dist, channel)
    data["planets"][planet] = entry
    data["updated_at"] = _now()
    return save(dist, channel, data)


def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tree_problems(dist, planet, entry):
    """Ce qui manque pour qu'une version soit réellement servable. Liste vide = bonne.

    On promeut un POINTEUR : si l'arborescence qu'il désigne est incomplète, la promotion
    casse le canal supérieur sans rien signaler, et le premier à s'en apercevoir est un
    joueur devant un terrain absent. D'où ce contrôle avant, pas après.
    """
    version = entry.get("data_version", "")
    if not version:
        return ["%s : pas de data_version" % planet]
    root = os.path.join(dist, planet, version)
    bad = []
    if not os.path.isdir(root):
        return ["%s : arborescence absente (%s)" % (planet, root)]
    if not os.path.exists(os.path.join(root, "manifest.json")):
        bad.append("%s : manifest.json absent" % planet)
    if entry.get("floor_nside_max", 0) and not os.path.exists(
            os.path.join(root, "floor.bin")):
        bad.append("%s : floor.bin annoncé mais absent" % planet)
    nside = entry.get("nside_max", 0)
    if nside and not os.path.isdir(os.path.join(root, "n%d" % nside)):
        bad.append("%s : niveau n%d absent" % (planet, nside))
    return bad


def promote(dist, to_channel, planets=None):
    """Fait monter d'un cran. Rend (promus, problèmes).

    [param planets] limite la promotion à ces corps ; None les promeut tous. Promouvoir un
    seul corps est le cas courant : on ne veut pas qu'un ré-export de tarsis_3 embarque
    avec lui dix-huit corps qui n'ont pas été retestés.
    """
    if to_channel not in CHANNELS:
        return [], ["canal inconnu : %s" % to_channel]
    src = previous_channel(to_channel)
    if src is None:
        return [], ["%s est le premier cran : rien en dessous d'où promouvoir"
                    % to_channel]
    source = load(dist, src)
    if not source["planets"]:
        return [], ["le canal %s est vide" % src]

    want = list(source["planets"]) if planets is None else list(planets)
    problems = []
    moved = []
    target = load(dist, to_channel)
    for planet in want:
        entry = source["planets"].get(planet)
        if entry is None:
            problems.append("%s : absent du canal %s" % (planet, src))
            continue
        bad = tree_problems(dist, planet, entry)
        if bad:
            problems.extend(bad)
            continue
        before = target["planets"].get(planet, {}).get("data_version")
        target["planets"][planet] = entry
        moved.append((planet, before, entry["data_version"]))
    if problems:
        # Tout ou rien : un canal à moitié promu est pire que pas promu du tout, car il
        # mêle des corps de deux exports sans que rien ne le dise.
        return [], problems
    target["channel"] = to_channel
    target["promoted_from"] = src
    target["promoted_at"] = _now()
    save(dist, to_channel, target)
    return moved, []


def referenced(dist):
    """Ensemble des (corps, version) qu'au moins un canal cite. Tout le reste est mort.

    On lit TOUS les crans, y compris unstable : une version fraîchement publiée que
    personne n'a encore promue est du travail en cours, pas un déchet.
    """
    live = set()
    for channel in CHANNELS:
        for planet, entry in load(dist, channel)["planets"].items():
            version = entry.get("data_version", "")
            if version:
                live.add((planet, version))
    return live


def dead_versions(dist):
    """Répertoires de version qu'aucun canal ne cite. Rend [(corps, version, chemin)].

    Le pointeur `latest.json` par corps est délibérément IGNORÉ : il suit la dernière
    publication, donc s'il faisait autorité une version publiée puis abandonnée serait
    immortelle. Ce sont les canaux qui décident.
    """
    live = referenced(dist)
    dead = []
    for planet in sorted(os.listdir(dist)):
        pdir = os.path.join(dist, planet)
        if planet == "channels" or not os.path.isdir(pdir):
            continue
        for version in sorted(os.listdir(pdir)):
            vdir = os.path.join(pdir, version)
            if not os.path.isdir(vdir):
                continue
            if (planet, version) not in live:
                dead.append((planet, version, vdir))
    return dead


def measure(path):
    """(fichiers, octets) sous ce répertoire. Les deux comptent : sur un volume à table
    d'inodes fixe, ce sont les fichiers qui s'épuisent en premier, pas les octets."""
    files = size = 0
    for _root, _dirs, names in os.walk(path):
        for name in names:
            try:
                size += os.stat(os.path.join(_root, name)).st_size
                files += 1
            except OSError:
                pass
    return files, size


def collect(dist, dry_run=True):
    """Supprime les versions mortes. Rend [(corps, version, fichiers, octets)].

    En dry-run, mesure sans rien toucher — et c'est le mode par défaut : effacer
    5 millions de fichiers ne se rejoue pas.
    """
    out = []
    for planet, version, vdir in dead_versions(dist):
        files, size = measure(vdir)
        if not dry_run:
            shutil.rmtree(vdir)
        out.append((planet, version, files, size))
    return out


def human(n):
    for unit in ("o", "Kio", "Mio", "Gio"):
        if n < 1024 or unit == "Gio":
            return "%.1f %s" % (n, unit)
        n /= 1024.0
    return "%.1f Gio" % n


def describe(dist):
    """Une ligne par canal, du plus stable au moins stable — l'ordre où on veut le lire."""
    out = []
    for channel in reversed(CHANNELS):
        data = load(dist, channel)
        planets = data["planets"]
        if not planets:
            out.append("%-9s (vide)" % channel)
            continue
        out.append("%-9s %d corps%s" % (
            channel, len(planets),
            "  promu depuis %s le %s" % (data["promoted_from"], data["promoted_at"])
            if data.get("promoted_at") else ""))
        for planet in sorted(planets):
            out.append("            %-24s %s" % (
                planet, planets[planet].get("data_version", "?")))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dist", required=True, help="racine de publication")
    ap.add_argument("--to", choices=CHANNELS, help="canal à alimenter depuis celui du dessous")
    ap.add_argument("--planet", action="append",
                    help="ne promouvoir que ce corps (répétable ; défaut : tous)")
    ap.add_argument("--list", action="store_true", help="état des canaux")
    ap.add_argument("--gc", action="store_true",
                    help="supprime les versions qu'aucun canal ne cite. Combiner avec "
                         "--dry-run pour ne que les lister (fortement conseillé d'abord).")
    ap.add_argument("--dry-run", action="store_true",
                    help="dit ce qui serait promu, sans rien écrire")
    args = ap.parse_args(argv)

    if args.gc:
        found = collect(args.dist, dry_run=args.dry_run)
        if not found:
            print("Aucune version morte : tout ce qui est publié est cité par un canal.")
            return 0
        files = sum(f for _p, _v, f, _s in found)
        size = sum(s for _p, _v, _f, s in found)
        for planet, version, f, s in found:
            print("  %s %-24s %s  %d fichiers, %s"
                  % ("listé " if args.dry_run else "SUPPRIMÉ", planet, version, f, human(s)))
        print("%s : %d version(s), %d fichiers, %s"
              % ("À libérer" if args.dry_run else "Libéré", len(found), files, human(size)))
        if args.dry_run:
            print("Relancer sans --dry-run pour supprimer.")
        return 0

    if args.list or not args.to:
        for line in describe(args.dist):
            print(line)
        return 0

    if args.dry_run:
        src = previous_channel(args.to)
        if src is None:
            print("%s est le premier cran." % args.to)
            return 1
        source = load(args.dist, src)
        target = load(args.dist, args.to)
        want = list(source["planets"]) if not args.planet else args.planet
        rc = 0
        for planet in want:
            entry = source["planets"].get(planet)
            if entry is None:
                print("  MANQUE %s dans %s" % (planet, src))
                rc = 1
                continue
            bad = tree_problems(args.dist, planet, entry)
            for b in bad:
                print("  BLOQUE %s" % b)
                rc = 1
            if not bad:
                print("  %s : %s -> %s" % (
                    planet, target["planets"].get(planet, {}).get("data_version", "(rien)"),
                    entry["data_version"]))
        return rc

    moved, problems = promote(args.dist, args.to, args.planet)
    for p in problems:
        print("  BLOQUE %s" % p)
    if problems:
        print("Rien promu : un canal à moitié promu mêlerait deux exports en silence.")
        return 1
    for planet, before, after in moved:
        print("  %s : %s -> %s" % (planet, before or "(rien)", after))
    print("%s ← %s : %d corps promus, 0 octet copié (les versions sont partagées)"
          % (args.to, previous_channel(args.to), len(moved)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
