#!/usr/bin/env python3
"""Publie un export directement sur le serveur de tuiles (nginx), par SSH.

Le jeu ne lit plus que ce que sert le service de tuiles : un export n'existe pour lui qu'une
fois publié. Ce script fait la publication d'un bout à l'autre, depuis le poste qui exporte.

POURQUOI LE PACK VOYAGE ET PAS LES TUILES
-----------------------------------------
Une version de tarsis_3 se compte en MILLIONS de fichiers d'environ un kilo-octet. Les éclater
en local puis les transférer, c'est payer des millions d'allers-retours de métadonnées ; envoyer
le pack (un seul fichier, quelques centaines de Mo) puis lancer publish_tiles.py SUR le serveur
crée ces fichiers là où ils seront servis. rsync, quand les deux côtés l'ont, ne renvoie que les
blocs d'un pack qui ont changé depuis l'envoi précédent.

Étapes, pour un fichier (heights.pack, terrainmodifier.pack ou grade_profiles.pack) :
  1. copie du code de publication dans <workdir> sur le serveur (quelques Ko, à chaque fois :
     le serveur publie avec la version du format qui va avec ce poste) ;
  2. envoi du fichier dans <workdir>/<planète>_chunks/ ;
  3. `publish_tiles.py <fichier> --out <dist> --channel unstable` sur le serveur ;
  4. vérification EN HTTP depuis ce poste (publish_tiles.verify_http : un échantillon par
     niveau, comparé au fichier local) — ce que recevra vraiment un client ;
  5. trace dans <planète>_chunks/.published.json : un export inchangé n'est pas republié.

CONFIGURATION
-------------
tools/planettech/qgis/export_config.ini, section [publish] (variables d'environnement d'abord) :

    [publish]
    ssh      = deploy@planettech.dyingstar-game.space   ; $DS_PUBLISH_SSH — sans lui, rien ne part
    port     = 22                                       ; $DS_PUBLISH_PORT
    dist     = /var/www/dist                            ; $DS_PUBLISH_DIST
    workdir  = ds-publish                               ; $DS_PUBLISH_WORKDIR (relatif au $HOME distant)
    python   = python3                                  ; $DS_PUBLISH_PYTHON
    channel  = unstable                                 ; $DS_PUBLISH_CHANNEL
    http     = https://planettech.dyingstar-game.space  ; $DS_PUBLISH_HTTP (défaut : client.ini)

Les exporteurs QGIS (link_modifiers.link, export_elevation.py) et le bake des profils
(tools/bake_grade_profiles.gd) l'appellent d'eux-mêmes en arrière-plan quand `ssh` est configuré.

USAGE
-----
    python3 tools/planettech/publish/publish_remote.py --check
    python3 tools/planettech/publish/publish_remote.py assets/qgis/export/tarsis_3_chunks/terrainmodifier.pack
    python3 tools/planettech/publish/publish_remote.py <fichier> --background     # rend la main, journal à côté
    python3 tools/planettech/publish/publish_remote.py --promote dev --planet tarsis_3.mod tarsis_3.lines
    python3 tools/planettech/publish/publish_remote.py --gc            # mesure ; --gc --yes supprime
    python3 tools/planettech/publish/publish_remote.py --adopt --planet tarsis_3   # publié avant les canaux
    python3 tools/planettech/publish/publish_remote.py --pull tarsis_3      # parts du serveur

LES PARTS VIVENT SUR LE SERVEUR
-------------------------------
Les parts/*.dsmpart (sources de terrainmodifier.pack, une par exporteur) ne sont plus dans git :
le serveur garde le dernier pack publié dans <workdir>/<planète>_chunks/, et ce pack les
contient toutes — link_modifiers.explode() les régénère, link(explode(pack)) == pack.

  - Chaque exporteur commence par link_modifiers.pull_parts() → pull() : si le serveur a un
    pack plus récent que la dernière synchro de ce poste, il est rapatrié (rsync : delta) et
    éclaté dans parts/ ; l'exporteur réécrit ensuite SA part par-dessus, et la table de
    chaînes (strings.json, en ajout seul) est celle du serveur.
  - La « base » (dernière version reçue ou publiée par ce poste) est notée dans .published.json.
  - Concurrence optimiste : si le serveur a changé depuis la base ET que le pack local aussi,
    pull() refuse (PartsConflict) au lieu d'écraser du travail, et publish() refuse d'envoyer
    un pack qui écraserait la publication de quelqu'un d'autre. --force passe outre.
"""

import argparse
import configparser
import datetime
import json
import os
import shlex
import shutil
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
CONFIG_INI = os.path.join(_REPO, "tools", "planettech", "qgis", "export_config.ini")
CLIENT_INI = os.path.join(_REPO, "client.ini")

#: Code envoyé au serveur, par chemin relatif au dépôt : publish_tiles.py et ce qu'il importe.
REMOTE_CODE = (
    "tools/planettech/publish/publish_tiles.py",
    "tools/planettech/publish/stream_channels.py",
    "tools/planettech/analyze_pack_sparsity.py",
)

#: Fichiers qu'un export produit et que ce script sait publier.
PUBLISHABLE = ("heights.pack", "terrainmodifier.pack", "grade_profiles.pack")

#: Le pack dont le serveur garde les parts (voir LES PARTS VIVENT SUR LE SERVEUR).
PARTS_PACK = "terrainmodifier.pack"

#: Trace des publications, posée à côté des fichiers publiés.
TRACE_FILE = ".published.json"
#: Clé de la trace : la base de synchronisation des parts.
SYNC_KEY = "_parts_base"
LOG_FILE = "publish.log"

_DEFAULTS = {"port": "22", "dist": "/var/www/dist", "workdir": "ds-publish",
             "python": "python3", "channel": "unstable", "http": ""}


# ── Configuration ────────────────────────────────────────────────────────────

def load_config(env=None, ini_path=CONFIG_INI, client_ini=CLIENT_INI):
    """{ssh, port, dist, workdir, python, channel, http} ; ssh vide = non configuré."""
    env = os.environ if env is None else env
    cfg = dict(_DEFAULTS, ssh="")
    if os.path.exists(ini_path):
        cp = configparser.ConfigParser(inline_comment_prefixes=(";", "#"))
        cp.read(ini_path)
        if cp.has_section("publish"):
            for key in cfg:
                if cp.has_option("publish", key):
                    cfg[key] = cp.get("publish", key).strip()
    for key in cfg:
        v = env.get("DS_PUBLISH_" + key.upper(), "")
        if v:
            cfg[key] = v
    if not cfg["http"] and os.path.exists(client_ini):
        cp = configparser.ConfigParser(inline_comment_prefixes=(";", "#"))
        try:
            cp.read(client_ini)
            cfg["http"] = cp.get("stream", "tiles_url", fallback="").strip().strip('"')
        except configparser.Error:
            pass
    return cfg


def configured(cfg=None):
    return bool((cfg or load_config())["ssh"])


# ── Ce qui se publie ─────────────────────────────────────────────────────────

def planet_of(path):
    """La planète d'un fichier posé dans <...>/<planète>_chunks/."""
    parent = os.path.basename(os.path.dirname(os.path.abspath(path)))
    return parent[:-len("_chunks")] if parent.endswith("_chunks") else ""


def identity(path):
    """(corps publié, version) que publish_tiles.py donnera à ce fichier, sans le publier."""
    sys.path.insert(0, _REPO)
    from tools.planettech.publish import publish_tiles as pt
    name = os.path.basename(path)
    if pt.is_whole_file(path):
        return planet_of(path) + pt.FILE_BODY_SUFFIX[name], pt.file_version(path)
    pack = pt.open_pack(path)
    if isinstance(pack, pt.DsmpPack):
        out = pack.planet_name + pack.body_suffix, pack.data_version()
        pack._fh.close()
        return out
    return pack.planet_name, str(pack.manifest.get("data_version", "")) or "nodataversion"


def _whole_file(path):
    """Publié en un objet (l'ancien bake des lignes, déjà compressé) plutôt qu'en tuiles ?"""
    sys.path.insert(0, _REPO)
    from tools.planettech.publish import publish_tiles as pt
    return pt.is_whole_file(path)


def _trace_path(path):
    return os.path.join(os.path.dirname(os.path.abspath(path)), TRACE_FILE)


def already_published(path, cfg, version):
    """Ce fichier, à cette version, est-il déjà sur cette cible et ce canal ?"""
    try:
        with open(_trace_path(path), encoding="utf-8") as fh:
            got = json.load(fh).get(os.path.basename(path), {})
    except (OSError, ValueError):
        return False
    return (got.get("version") == version and got.get("ssh") == cfg["ssh"]
            and got.get("dist") == cfg["dist"] and got.get("channel") == cfg["channel"])


def _read_trace(path):
    try:
        with open(_trace_path(path), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _write_trace(path, key, value):
    trace = _trace_path(path)
    data = _read_trace(path)
    data[key] = value
    tmp = trace + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, trace)


def _now():
    return datetime.datetime.now().isoformat(timespec="seconds")


def record_published(path, cfg, body, version):
    _write_trace(path, os.path.basename(path), {
        "body": body, "version": version, "ssh": cfg["ssh"], "dist": cfg["dist"],
        "channel": cfg["channel"], "at": _now()})
    if os.path.basename(path) == PARTS_PACK:
        record_base(path, cfg, version)


def record_base(pack_path, cfg, version):
    """Ce poste a, à cet instant, la même version des parts que le serveur."""
    _write_trace(pack_path, SYNC_KEY, {"version": version, "ssh": cfg["ssh"],
                                       "workdir": cfg["workdir"], "at": _now()})


def parts_base(pack_path, cfg):
    """Dernière version des parts partagée avec CE serveur, ou None.

    À défaut de synchro notée, la dernière publication du pack vers ce serveur : un poste qui
    publiait avant que les parts quittent git a, par construction, la base qu'il a envoyée.
    """
    data = _read_trace(pack_path)
    got = data.get(SYNC_KEY, {})
    if got.get("ssh") == cfg["ssh"] and got.get("workdir") == cfg["workdir"]:
        return got.get("version")
    got = data.get(PARTS_PACK, {})
    return got.get("version") if got.get("ssh") == cfg["ssh"] else None


# ── Commandes ────────────────────────────────────────────────────────────────

def _ssh_base(cfg):
    return ["ssh", "-p", str(cfg["port"]), "-o", "BatchMode=yes", cfg["ssh"]]


def ssh_cmd(cfg, remote):
    """ssh … sh -c '<remote>' : [remote] est UNE ligne de shell POSIX, exécutée dans le $HOME
    distant.

    sshd la confie au shell de CONNEXION de l'utilisateur — csh pour root sous FreeBSD, où
    `if …; then … fi` est une erreur de syntaxe. Passer par sh rend chaque ligne indépendante
    de ce shell-là.
    """
    return _ssh_base(cfg) + ["sh -c %s" % shlex.quote(remote)]


def copy_cmd(cfg, local, remote_path, rsync):
    """rsync (delta, reprise) quand les deux côtés l'ont, scp sinon."""
    if rsync:
        return ["rsync", "-t", "--partial", "--inplace", "-e",
                "ssh -p %s -o BatchMode=yes" % cfg["port"], local,
                "%s:%s" % (cfg["ssh"], remote_path)]
    return ["scp", "-q", "-P", str(cfg["port"]), "-o", "BatchMode=yes", local,
            "%s:%s" % (cfg["ssh"], remote_path)]


def fetch_cmd(cfg, remote_path, local, rsync):
    """Sens inverse de copy_cmd. rsync sans --inplace : il écrit à côté puis renomme, en se
    servant du fichier local comme base du delta."""
    if rsync:
        return ["rsync", "-t", "--partial", "-e", "ssh -p %s -o BatchMode=yes" % cfg["port"],
                "%s:%s" % (cfg["ssh"], remote_path), local]
    return ["scp", "-q", "-P", str(cfg["port"]), "-o", "BatchMode=yes",
            "%s:%s" % (cfg["ssh"], remote_path), local]


#: Lu SUR le serveur, avec le code que push_code y a mis : la version du pack gardé.
_REMOTE_VERSION_PY = ("import sys; sys.path.insert(0, '.'); "
                      "from tools.planettech.publish import publish_tiles as pt; "
                      "print('DS_VERSION=' + pt.open_pack(sys.argv[1]).data_version())")


def publish_cmd(cfg, remote_file, compress):
    """The server-side publish_tiles.py line; [remote_file] is relative to the workdir."""
    q = shlex.quote
    # -u: the server's lines reach publish.log as they are printed, not in one block at the end.
    cmd = "cd %s && %s -u tools/planettech/publish/publish_tiles.py %s --out %s --channel %s" % (
        q(cfg["workdir"]), q(cfg["python"]), q(remote_file), q(cfg["dist"]), q(cfg["channel"]))
    return cmd + (" --compress" if compress else "")


def _run(cmd):
    """(code, sortie). La sortie est aussi affichée au fil de l'eau : c'est un journal."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out = []
    for line in proc.stdout:
        print("    " + line.rstrip())
        out.append(line)
    return proc.wait(), "".join(out)


def check(cfg, run=_run):
    """ssh, python3 et droit d'écriture dans dist. Rend la liste des problèmes."""
    q = shlex.quote
    code, out = run(ssh_cmd(cfg, "%s -c 'import sys; print(sys.version)' && test -w %s && echo DS_OK"
                            % (q(cfg["python"]), q(cfg["dist"]))))
    if code != 0 or "DS_OK" not in out:
        return ["le serveur ne répond pas comme attendu (ssh %s, %s, écriture dans %s)"
                % (cfg["ssh"], cfg["python"], cfg["dist"])]
    return []


def remote_has_rsync(cfg, run=_run):
    if shutil.which("rsync") is None:
        return False
    code, _out = run(ssh_cmd(cfg, "command -v rsync >/dev/null"))
    return code == 0


def remote_version(cfg, planet, run=_run):
    """data_version du pack de modificateurs gardé par le serveur ; "" s'il n'en a pas,
    None s'il ne répond pas. Le code doit y être (push_code)."""
    q = shlex.quote
    rel = "%s_chunks/%s" % (planet, PARTS_PACK)
    code, out = run(ssh_cmd(cfg, "cd %s && if test -f %s; then %s -c %s %s; else echo DS_NONE; fi"
                            % (q(cfg["workdir"]), q(rel), q(cfg["python"]),
                               q(_REMOTE_VERSION_PY), q(rel))))
    if code != 0:
        return None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("DS_VERSION="):
            return line[len("DS_VERSION="):]
        if line == "DS_NONE":
            return ""
    return None


def push_code(cfg, run=_run, *extra_dirs):
    """Copie REMOTE_CODE dans <workdir> — à chaque fois : le serveur exécute toujours le code
    du dépôt, y compris les garde-fous du gc. Rend 0 si tout est en place."""
    q = shlex.quote
    code, _ = run(ssh_cmd(cfg, "mkdir -p %s %s/tools/planettech/publish"
                          % (" ".join(extra_dirs), q(cfg["workdir"]))))
    if code != 0:
        print("ERREUR : ssh %s injoignable" % cfg["ssh"])
        return 1
    for rel in REMOTE_CODE:
        code, _ = run(copy_cmd(cfg, os.path.join(_REPO, rel), "%s/%s" % (cfg["workdir"], rel), False))
        if code != 0:
            print("ERREUR : copie de %s" % rel)
            return 1
    return 0


def publish(path, cfg, run=_run, force=False, verify=True, rsync=None):
    """Publie [path] sur la cible de [cfg]. Rend 0 si tout s'est bien passé."""
    path = os.path.abspath(path)
    name = os.path.basename(path)
    if name not in PUBLISHABLE:
        print("ERREUR : %s n'est pas un fichier publiable (%s)" % (name, ", ".join(PUBLISHABLE)))
        return 1
    planet = planet_of(path)
    if not planet:
        print("ERREUR : %s n'est pas dans un dossier <planète>_chunks" % path)
        return 1
    body, version = identity(path)
    if not force and already_published(path, cfg, version):
        print("%s %s déjà publié sur %s (%s) — rien à faire (--force pour republier)"
              % (body, version, cfg["ssh"], cfg["channel"]))
        return 0
    print("== %s → %s:%s (corps %s, version %s, canal %s)"
          % (name, cfg["ssh"], cfg["dist"], body, version, cfg["channel"]))
    q = shlex.quote
    remote_dir = "%s/%s_chunks" % (cfg["workdir"], planet)
    if push_code(cfg, run, q(remote_dir)) != 0:
        return 1
    if name == PARTS_PACK and not force:
        # Le pack du serveur porte les parts de toute l'équipe : n'envoyer celui-ci que s'il
        # a été construit sur la dernière version que ce poste en connaît.
        remote = remote_version(cfg, planet, run)
        base = parts_base(path, cfg)
        if remote and remote not in (version, base):
            print("ERREUR : le serveur a reçu le pack %s depuis ta dernière synchro (%s). "
                  "Publier %s effacerait ces changements. Relance ton export : il récupère "
                  "d'abord les parts du serveur (ou --force pour écraser)."
                  % (remote, base or "aucune", version))
            return 1
    if rsync is None:
        rsync = remote_has_rsync(cfg, run)
    print("  envoi de %s (%.1f Mo, %s)" % (name, os.path.getsize(path) / 1e6,
                                           "rsync" if rsync else "scp"))
    code, _ = run(copy_cmd(cfg, path, "%s/%s" % (remote_dir, name), rsync))
    if code != 0:
        print("ERREUR : envoi de %s" % name)
        return 1
    print("  éclatement sur le serveur")
    # Relative to the workdir publish_cmd cd's into, not to the remote $HOME.
    code, _ = run(ssh_cmd(cfg, publish_cmd(cfg, "%s_chunks/%s" % (planet, name),
                                            compress=not _whole_file(path))))
    if code != 0:
        print("ERREUR : publish_tiles.py a échoué sur le serveur")
        return 1
    if verify:
        bad = verify_http(path, cfg, body, version)
        if bad:
            print("ERREUR : %d désaccord(s) entre le service et le fichier local" % bad)
            return 1
    record_published(path, cfg, body, version)
    print("== publié : %s %s sur le canal %s" % (body, version, cfg["channel"]))
    print("   promotion : python3 tools/planettech/publish/publish_remote.py --promote dev --planet %s"
          % body)
    return 0


class PartsConflict(Exception):
    """Le serveur et ce poste ont chacun des parts que l'autre n'a pas."""


def _explode(pack_path):
    """link_modifiers.explode sur le dossier d'export de [pack_path] ; rend les parts écrites."""
    qgis = os.path.join(_REPO, "tools", "planettech", "qgis")
    if qgis not in sys.path:
        sys.path.insert(0, qgis)
    import link_modifiers
    chunks = os.path.dirname(os.path.abspath(pack_path))
    return link_modifiers.explode(planet_of(pack_path), os.path.dirname(chunks), verbose=False)


def pull(pack_path, cfg, run=_run, force=False, rsync=None, explode=_explode):
    """Met parts/ à la version du serveur avant un export. Rend un mot :

    "absent"  le serveur n'a pas encore de pack : les parts locales serviront de départ ;
    "à jour"  rien à rapatrier (même version, ou ce poste est en avance) ;
    "reçu"    le pack du serveur a été rapatrié et éclaté dans parts/ ;
    "injoignable"  le serveur ne répond pas : l'export continue sur les parts locales, et
              publish() refusera plus tard si cela écrasait quelqu'un.

    Lève PartsConflict quand le pack local ET celui du serveur ont changé depuis la base :
    rapatrier écraserait le travail local, exporter écraserait celui du serveur.
    """
    pack_path = os.path.abspath(pack_path)
    planet = planet_of(pack_path)
    parts_dir = os.path.join(os.path.dirname(pack_path), "parts")
    local = identity(pack_path)[1] if os.path.exists(pack_path) else None
    base = parts_base(pack_path, cfg)
    if push_code(cfg, run) != 0:
        return "injoignable"
    remote = remote_version(cfg, planet, run)
    if remote is None:
        print("ATTENTION : version du pack du serveur illisible — export sur les parts locales")
        return "injoignable"
    if remote == "":
        return "absent"
    has_parts = bool([n for n in os.listdir(parts_dir) if n.endswith(".dsmpart")]) \
        if os.path.isdir(parts_dir) else False
    if remote == local and has_parts:
        if base != remote:
            record_base(pack_path, cfg, remote)
        return "à jour"
    if remote == base and local is not None and has_parts:
        return "à jour"  # ce poste a un export pas encore publié : il est en avance
    if local is not None and local != base and has_parts and not force:
        raise PartsConflict(
            "%s : le serveur a le pack %s, ce poste a %s, la dernière synchro est %s — les deux "
            "ont changé. Publie le tien (publish_remote.py --force %s) ou reprends celui du "
            "serveur (publish_remote.py --pull %s --force)."
            % (planet, remote, local, base or "inconnue", pack_path, planet))
    if rsync is None:
        rsync = remote_has_rsync(cfg, run)
    print("  parts : rapatriement du pack %s du serveur (%s)" % (remote, "rsync" if rsync else "scp"))
    os.makedirs(parts_dir, exist_ok=True)
    tmp = pack_path if rsync else pack_path + ".part"
    code, _ = run(fetch_cmd(cfg, "%s/%s_chunks/%s" % (cfg["workdir"], planet, PARTS_PACK), tmp, rsync))
    if code != 0:
        raise PartsConflict("%s : rapatriement du pack du serveur impossible" % planet)
    if tmp != pack_path:
        os.replace(tmp, pack_path)
    got = identity(pack_path)[1]
    if got != remote:
        raise PartsConflict("%s : pack rapatrié en version %s, le serveur annonçait %s"
                            % (planet, got, remote))
    # Les parts d'une famille que le pack n'a plus ne doivent pas revenir au prochain lien.
    for name in os.listdir(parts_dir):
        if name.endswith(".dsmpart"):
            os.remove(os.path.join(parts_dir, name))
    written = explode(pack_path)
    record_base(pack_path, cfg, remote)
    print("  parts : %d éclatée(s) depuis %s" % (len(written), remote))
    return "reçu"


def verify_http(path, cfg, body, version, samples=20):
    """Ce que reçoit un client : publish_tiles.verify_http, ou l'objet entier en mode fichier."""
    if not cfg["http"]:
        print("  (pas d'URL http configurée : vérification sautée)")
        return 0
    sys.path.insert(0, _REPO)
    from tools.planettech.publish import publish_tiles as pt
    name = os.path.basename(path)
    print("  vérification en HTTP : %s" % cfg["http"])
    if pt.is_whole_file(path):
        base = cfg["http"].rstrip("/")
        code, blob, _h = pt._http("%s/%s/%s/%s" % (base, body, version, name))
        if code != 200:
            print("  ECHEC %s -> HTTP %d" % (name, code))
            return 1
        with open(path, "rb") as fh:
            return 0 if pt.read_tile_blob(blob) == fh.read() else 1
    bad, _checked = pt.verify_http(pt.open_pack(path), cfg["http"], body, version, samples)
    return bad


def promote(cfg, channel, bodies, run=_run):
    if push_code(cfg, run) != 0:
        return 1
    q = shlex.quote
    planets = " ".join("--planet %s" % q(b) for b in bodies)
    code, _ = run(ssh_cmd(cfg, "cd %s && %s tools/planettech/publish/stream_channels.py --dist %s --to %s %s"
                          % (q(cfg["workdir"]), q(cfg["python"]), q(cfg["dist"]), q(channel), planets)))
    return code


def adopt(cfg, bodies, run=_run):
    """Inscrit dans unstable des corps publiés avant les canaux (leur latest.json)."""
    if push_code(cfg, run) != 0:
        return 1
    q = shlex.quote
    planets = " ".join("--planet %s" % q(b) for b in bodies)
    code, _ = run(ssh_cmd(cfg, "cd %s && %s tools/planettech/publish/stream_channels.py --dist %s --adopt %s"
                          % (q(cfg["workdir"]), q(cfg["python"]), q(cfg["dist"]), planets)))
    return code


def gc(cfg, really, run=_run):
    if push_code(cfg, run) != 0:
        return 1
    q = shlex.quote
    code, _ = run(ssh_cmd(cfg, "cd %s && %s tools/planettech/publish/stream_channels.py --dist %s --gc%s"
                          % (q(cfg["workdir"]), q(cfg["python"]), q(cfg["dist"]),
                             "" if really else " --dry-run")))
    return code


def publish_in_background(path, extra=()):
    """Lance la publication de [path] détachée, journal dans <planète>_chunks/publish.log.

    Pour les exporteurs (QGIS, bake) : ils rendent la main tout de suite. Rend le chemin du
    journal, ou None quand aucune cible n'est configurée — l'export continue comme avant.
    Les publications d'un même dossier se suivent (verrou), jamais en parallèle.
    """
    if not configured():
        return None
    log = os.path.join(os.path.dirname(os.path.abspath(path)), LOG_FILE)
    python = shutil.which("python3") or sys.executable
    with open(log, "a", encoding="utf-8") as fh:
        fh.write("\n--- %s %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), path))
        fh.flush()
        # -u: stdout is a file here, so Python would buffer it and publish.log (followed live by
        # the QGIS plugin's « Journal de publication ») would stay empty until the very end.
        subprocess.Popen([python, "-u", os.path.abspath(__file__), os.path.abspath(path)]
                         + list(extra),
                         stdout=fh, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                         cwd=_REPO, start_new_session=True)
    return log


def _export_dir():
    qgis = os.path.join(_REPO, "tools", "planettech", "qgis")
    if qgis not in sys.path:
        sys.path.insert(0, qgis)
    import link_modifiers
    return link_modifiers.resolve_export_dir()


def pull_for_export(pack_path):
    """Pour les exporteurs (link_modifiers.pull_parts) : pull() sous le verrou de publication.

    Sans attendre : si une publication de ce poste est en cours, c'est que le pack local est
    le plus récent — rien à rapatrier, et la publication suivante se fera après elle.
    """
    cfg = load_config()
    if not configured(cfg):
        return "non configuré"
    import fcntl
    os.makedirs(os.path.dirname(os.path.abspath(pack_path)), exist_ok=True)
    fh = open(os.path.join(os.path.dirname(os.path.abspath(pack_path)), ".publish.lock"), "w")
    try:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return "publication en cours"
        return pull(pack_path, cfg)
    finally:
        fh.close()


def _locked(path):
    """Verrou par dossier d'export : deux exports rapprochés publient l'un après l'autre."""
    import fcntl
    fh = open(os.path.join(os.path.dirname(os.path.abspath(path)), ".publish.lock"), "w")
    fcntl.flock(fh, fcntl.LOCK_EX)
    return fh


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="*", help="heights.pack, terrainmodifier.pack, grade_profiles.pack")
    ap.add_argument("--check", action="store_true", help="teste ssh, python3 et l'écriture dans dist")
    ap.add_argument("--background", action="store_true",
                    help="rend la main, publie détaché (journal publish.log à côté du fichier)")
    ap.add_argument("--force", action="store_true", help="republie même un fichier inchangé")
    ap.add_argument("--no-verify", action="store_true", help="saute la vérification HTTP")
    ap.add_argument("--promote", metavar="CANAL", help="fait monter --planet d'un cran vers CANAL")
    ap.add_argument("--planet", nargs="+", default=[], help="corps à promouvoir (tarsis_3.mod …)")
    ap.add_argument("--adopt", action="store_true",
                    help="inscrit dans unstable les --planet publiés avant les canaux")
    ap.add_argument("--gc", action="store_true", help="versions mortes : mesure (--yes pour supprimer)")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--pull", metavar="PLANETE",
                    help="met <planète>_chunks/parts à la version du serveur (--force : écrase le local)")
    args = ap.parse_args(argv)

    cfg = load_config()
    if not configured(cfg):
        print("publish_remote : aucune cible ([publish] ssh dans %s, ou $DS_PUBLISH_SSH) — "
              "rien n'est publié." % CONFIG_INI)
        return 0 if args.background else 2
    if args.background:
        for f in args.files:
            log = publish_in_background(f, ["--no-verify"] if args.no_verify else [])
            print("publication de %s en arrière-plan : %s" % (os.path.basename(f), log))
        return 0
    if args.check:
        problems = check(cfg)
        for p in problems:
            print("ERREUR : " + p)
        if not problems:
            print("OK : %s, %s, écriture dans %s" % (cfg["ssh"], cfg["python"], cfg["dist"]))
        return 1 if problems else 0
    if args.promote:
        if not args.planet:
            print("ERREUR : --promote demande --planet <corps> …")
            return 1
        return promote(cfg, args.promote, args.planet)
    if args.adopt:
        if not args.planet:
            print("ERREUR : --adopt demande --planet <corps> …")
            return 1
        return adopt(cfg, args.planet)
    if args.gc:
        return gc(cfg, args.yes)
    if args.pull:
        pack = os.path.join(_export_dir(), "%s_chunks" % args.pull, PARTS_PACK)
        lock = _locked(pack)
        try:
            print("parts de %s : %s" % (args.pull, pull(pack, cfg, force=args.force)))
        except PartsConflict as exc:
            print("ERREUR : %s" % exc)
            return 1
        finally:
            lock.close()
        return 0
    rc = 0
    for f in args.files:
        lock = _locked(f)
        try:
            rc |= publish(f, cfg, force=args.force, verify=not args.no_verify)
        finally:
            lock.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
