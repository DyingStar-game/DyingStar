#!/usr/bin/env python3
"""Mesure le potentiel de « pack creux » d'un heights.pack (format DSHP v1).

POURQUOI CET OUTIL EXISTE
-------------------------
La pyramide d'élévation est massivement sur-échantillonnée : les contours de tarsis_3 ne
portent que ~438 000 valeurs indépendantes, alors qu'à 198 m la pyramide en stockerait
1,29e10. L'essentiel des niveaux fins n'est donc pas de la donnée, c'est de
l'interpolation qu'on pourrait recalculer.

Le « pack creux » exploite ça : au bake, une tuile fine n'est PAS stockée si l'upsample
bilinéaire de son parent la reproduit à moins de epsilon près. À la lecture, le client
ne la trouve pas et remonte d'un niveau — ce que PlanetData.sample_nside_for() sait déjà
faire.

Mais le taux d'élagage dépend entièrement du relief : une planète de plaines s'élague
presque entièrement, une planète de montagnes pas du tout. Et il change à chaque
ré-export dès qu'on touche aux contours. D'où cet outil, à rejouer par planète et après
toute modification de terrain, pour décider AVEC UN CHIFFRE si le pack creux vaut sa
complexité — au lieu de le supposer.

Voir docs/PLANET_CHUNK_STREAMING.md, phase 1.

CE QU'IL MESURE
---------------
Pour chaque tuile de chaque niveau (sauf le plus grossier), l'écart maximal en mètres
entre la tuile réelle et l'upsample bilinéaire du quadrant correspondant de son parent.
Puis, par seuil, la fraction de tuiles élaguables et ce que ça donnerait en fichiers et
en octets.

CE QU'IL NE MESURE PAS
----------------------
L'élagage est évalué NIVEAU PAR NIVEAU contre le parent RÉEL. Un vrai pack creux élague
en cascade : si un parent est lui-même élagué, ses enfants sont prédits depuis le
grand-parent et l'erreur se cumule. Les taux ci-dessous sont donc une BORNE SUPÉRIEURE
de ce qu'un bake hiérarchique obtiendrait à epsilon donné.

CONVENTIONS (doivent suivre tools/qgis/healpix_utils.py)
-------------------------------------------------------
* Grille de tuile centrée sur les cellules : t = (i + 0.5) / tile_res, lignes = fy,
  colonnes = fx (meshgrid indexing='xy').
* Ordonnancement NESTED : l'enfant k (0..3) du pixel `ipix` est `4 * ipix + k`, et
  occupe le quadrant (dx, dy) = (k & 1, (k >> 1) & 1) du parent.
* Un enfant couvre une demi-arête du parent, donc son centre de cellule i tombe à
  u = (i + 0.5) / 2 - 0.5 cellule parent : un upsample x2 décalé d'une demi-cellule,
  d'où le clamp aux bords.

USAGE
-----
    python3 tools/analyze_pack_sparsity.py assets/qgis/export/tarsis_3_chunks/heights.pack
    python3 tools/analyze_pack_sparsity.py <pack> --sample 2000 --json rapport.json
"""

import argparse
import json
import os
import struct
import sys

try:
    import numpy as np
except ImportError:  # pragma: no cover - dépend de l'environnement
    sys.exit("numpy requis : pip install numpy")

MAGIC = b"DSHP"
DEFAULT_THRESHOLDS = (1.0, 5.0, 10.0, 25.0, 50.0)


class Pack:
    """Lecteur DSHP v1 en lecture seule, adossé à un memmap numpy."""

    def __init__(self, path):
        with open(path, "rb") as fh:
            if fh.read(4) != MAGIC:
                raise ValueError("%s : magic DSHP absent" % path)
            (self.version, self.tile_res, self.nside_min, self.nside_max,
             _flags, self.blob_start, json_len) = struct.unpack("<7I", fh.read(28))
            if self.version != 1:
                raise ValueError("DSHP v%d non supporté" % self.version)
            self.manifest = json.loads(fh.read(json_len).decode("utf-8"))

        self.tile_n = self.tile_res * self.tile_res
        self.levels = []
        ns = self.nside_min
        while ns <= self.nside_max:
            self.levels.append(ns)
            ns *= 2

        self.base = {}
        off = 0
        for ns in self.levels:
            self.base[ns] = off
            off += 12 * ns * ns * self.tile_n
        self._mm = np.memmap(path, dtype="<f4", mode="r", offset=self.blob_start)

        # Les valeurs sont normalisées [0,1] ; max_height les remet en mètres.
        self.max_height = float(self.manifest.get("max_height", 1.0))

        # Le manifest.json posé à côté fait AUTORITÉ sur l'en-tête du pack : c'est lui
        # que PlanetData lit, l'en-tête n'étant qu'un repli quand le fichier manque.
        # Les deux peuvent diverger — tools/qgis/swap_sandbox_gaea_export.py réécrit le
        # manifest.json et jamais l'en-tête, si bien qu'après l'échange de créneaux
        # Sandbox/Gaea les packs de tarsis_3 et tarsis_4 s'annoncent encore sous leur
        # ancien nom. Inoffensif tant que le manifest.json existe, faux dès qu'il manque.
        self.loose = {}
        loose_path = os.path.join(os.path.dirname(os.path.abspath(path)), "manifest.json")
        if os.path.exists(loose_path):
            with open(loose_path, encoding="utf-8") as fh:
                self.loose = json.load(fh)

    @property
    def planet_name(self):
        return self.loose.get("planet_name") or self.manifest.get("planet_name", "?")

    @property
    def name_mismatch(self):
        """(nom du manifest.json, nom de l'en-tête) quand ils divergent, sinon None."""
        a = self.loose.get("planet_name")
        b = self.manifest.get("planet_name")
        return (a, b) if a and b and a != b else None

    def tile(self, nside, ipix):
        off = self.base[nside] + ipix * self.tile_n
        return np.asarray(self._mm[off:off + self.tile_n]).reshape(self.tile_res, self.tile_res)


def _upsampler(tile_res):
    """Retourne une fonction (quadrant h×h) -> (tile_res×tile_res), bilinéaire décalée."""
    half = tile_res // 2
    u = (np.arange(tile_res) + 0.5) / 2.0 - 0.5
    i0 = np.clip(np.floor(u).astype(int), 0, half - 1)
    i1 = np.clip(i0 + 1, 0, half - 1)
    w = (u - i0).astype(np.float32)

    def up(quad):
        rows = quad[i0, :] * (1.0 - w)[:, None] + quad[i1, :] * w[:, None]
        return rows[:, i0] * (1.0 - w)[None, :] + rows[:, i1] * w[None, :]

    return up


def cascade_prune(get_tile, root_nside, root_ipix, target_nside, eps,
                  tile_res, up=None):
    """Rejoue la décision d'un baker creux sur un sous-arbre, EN CASCADE.

    C'est l'algorithme que le baker doit réellement implémenter, et il diffère de la
    comparaison naïve sur un point qui compte : une tuile élaguée n'est pas comparée à
    son parent RÉEL, mais à la **reconstruction que le client obtiendra**. Quand 75 % des
    tuiles disparaissent, la plupart des parents sont eux-mêmes absents, et prédire
    depuis le grand-parent cumule les erreurs sur toute la profondeur.

    Comparer à la reconstruction borne l'erreur visible à exactement `eps`, quelle que
    soit la profondeur de la cascade — et ça ne coûte rien, l'état reconstruit étant déjà
    disponible pendant la descente. Le taux d'élagage obtenu est plus bas que la borne
    naïve ; c'est le vrai.

    [param get_tile] : callable (nside, ipix) -> tuile réelle (tile_res × tile_res).
    Retourne (élaguées par niveau, total par niveau, pire erreur d'une tuile élaguée).
    La pire erreur doit rester <= eps : c'est le contrôle interne de l'algorithme.
    """
    if up is None:
        up = _upsampler(tile_res)
    half = tile_res // 2
    pruned, total = {}, {}
    worst = 0.0
    # `recon` : ce que le client reconstruirait pour ce noeud, pas ce que le TIN a calculé.
    stack = [(root_nside, root_ipix, get_tile(root_nside, root_ipix))]
    while stack:
        nside, ipix, recon = stack.pop()
        if nside >= target_nside:
            continue
        child_nside = nside * 2
        for k in range(4):
            dx, dy = k & 1, (k >> 1) & 1
            pred = up(recon[dy * half:(dy + 1) * half, dx * half:(dx + 1) * half])
            real = get_tile(child_nside, 4 * ipix + k)
            err = float(np.abs(pred - real).max())
            total[child_nside] = total.get(child_nside, 0) + 1
            if err <= eps:
                pruned[child_nside] = pruned.get(child_nside, 0) + 1
                worst = max(worst, err)
                child_recon = pred          # le client verra la prédiction
            else:
                child_recon = real          # la tuile est stockée
            stack.append((child_nside, 4 * ipix + k, child_recon))
    return pruned, total, worst


def bound_prune(get_tile, root_nside, root_ipix, target_nside, eps, tile_res, up=None):
    """Même parcours, mais chaque tuile est comparée à son parent RÉEL.

    C'est la borne supérieure : elle ignore l'accumulation d'erreur d'un vrai bake creux.
    Fournie pour chiffrer l'écart avec [method cascade_prune] sur les mêmes tuiles.
    """
    if up is None:
        up = _upsampler(tile_res)
    half = tile_res // 2
    pruned, total = {}, {}
    stack = [(root_nside, root_ipix)]
    while stack:
        nside, ipix = stack.pop()
        if nside >= target_nside:
            continue
        parent = get_tile(nside, ipix)
        child_nside = nside * 2
        for k in range(4):
            dx, dy = k & 1, (k >> 1) & 1
            pred = up(parent[dy * half:(dy + 1) * half, dx * half:(dx + 1) * half])
            err = float(np.abs(pred - get_tile(child_nside, 4 * ipix + k)).max())
            total[child_nside] = total.get(child_nside, 0) + 1
            if err <= eps:
                pruned[child_nside] = pruned.get(child_nside, 0) + 1
            stack.append((child_nside, 4 * ipix + k))
    return pruned, total


def predict_error_m(pack, up, parent_nside, parent_ipix, k):
    """Écart max, en mètres, entre l'enfant k réel et sa prédiction depuis le parent."""
    half = pack.tile_res // 2
    dx, dy = k & 1, (k >> 1) & 1
    quad = pack.tile(parent_nside, parent_ipix)[dy * half:(dy + 1) * half,
                                                dx * half:(dx + 1) * half]
    child = pack.tile(parent_nside * 2, 4 * parent_ipix + k)
    return float(np.abs(up(quad) - child).max() * pack.max_height)


def analyse(pack, thresholds, sample=0, seed=12345):
    """Erreurs de prédiction par niveau. sample>0 limite le nombre de PARENTS par niveau."""
    rng = np.random.default_rng(seed)
    up = _upsampler(pack.tile_res)
    per_level = []

    for parent_ns in pack.levels:
        if parent_ns * 2 > pack.nside_max:
            break
        n_parents = 12 * parent_ns * parent_ns
        if sample and sample < n_parents:
            parents = rng.choice(n_parents, size=sample, replace=False)
            sampled = True
        else:
            parents = range(n_parents)
            sampled = False

        errs = [predict_error_m(pack, up, parent_ns, int(pip), k)
                for pip in parents for k in range(4)]
        errs = np.array(errs)
        per_level.append({
            "nside": parent_ns * 2,
            "tiles_total": 12 * (parent_ns * 2) ** 2,
            "tiles_measured": int(errs.size),
            "sampled": sampled,
            "err_median_m": float(np.median(errs)),
            "err_p90_m": float(np.percentile(errs, 90)),
            "prunable": {str(t): float((errs <= t).mean()) for t in thresholds},
        })
    return per_level


def project(pack, per_level, threshold):
    """Fichiers et octets d'un pack creux à ce seuil, contre le pack dense."""
    tile_bytes = pack.tile_res * pack.tile_res * 4
    kept = dense = 0
    for ns in pack.levels:
        n = 12 * ns * ns
        dense += n
        row = next((r for r in per_level if r["nside"] == ns), None)
        # Le niveau le plus grossier n'a pas de parent : toujours conservé.
        frac = row["prunable"][str(threshold)] if row else 0.0
        kept += n * (1.0 - frac)
    return {
        "threshold_m": threshold,
        "tiles_dense": dense,
        "tiles_sparse": int(round(kept)),
        "pruned_pct": 100.0 * (dense - kept) / dense,
        "bytes_dense": dense * tile_bytes,
        "bytes_sparse": int(round(kept * tile_bytes)),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pack", help="chemin d'un heights.pack (DSHP v1)")
    ap.add_argument("--sample", type=int, default=0,
                    help="parents échantillonnés par niveau (0 = tous). "
                         "Indispensable sur un pack fin : un n1024 dense a 16,8 M de tuiles.")
    ap.add_argument("--thresholds", default=",".join(str(t) for t in DEFAULT_THRESHOLDS),
                    help="seuils d'erreur en mètres, séparés par des virgules")
    ap.add_argument("--json", help="écrit le rapport complet dans ce fichier")
    args = ap.parse_args(argv)

    thresholds = [float(t) for t in args.thresholds.split(",")]
    pack = Pack(args.pack)
    print("%s — DSHP v%d, tile_res=%d, niveaux n%d..n%d, max_height=%.0f m"
          % (pack.planet_name, pack.version, pack.tile_res,
             pack.nside_min, pack.nside_max, pack.max_height))
    if pack.name_mismatch:
        loose_name, embedded = pack.name_mismatch
        print("ATTENTION : manifest.json dit '%s', l'en-tête du pack dit '%s'. "
              "PlanetData suit le manifest.json, mais son repli sur l'en-tête (fichier "
              "manquant) donnerait le mauvais planet_name, donc la mauvaise clé de cache."
              % (loose_name, embedded))
    if args.sample:
        print("échantillonnage : %d parents par niveau" % args.sample)

    per_level = analyse(pack, thresholds, sample=args.sample)
    if not per_level:
        sys.exit("pack à un seul niveau : rien à comparer")

    head = "niveau   tuiles  mesurées   méd.(m)   p90(m)  " + "  ".join(
        "%7s" % ("<=%gm" % t) for t in thresholds)
    print("\n" + head)
    for r in per_level:
        print("n%-6d %8d %9d %9.1f %8.1f  %s"
              % (r["nside"], r["tiles_total"], r["tiles_measured"],
                 r["err_median_m"], r["err_p90_m"],
                 "  ".join("%6.1f%%" % (100 * r["prunable"][str(t)]) for t in thresholds)))

    print("\nprojection sur la pyramide complète :")
    print("seuil     tuiles conservées    élaguées      octets")
    projections = []
    for t in thresholds:
        p = project(pack, per_level, t)
        projections.append(p)
        print("%5g m  %10d / %-10d %6.1f%%   %6.2f Go -> %.2f Go"
              % (t, p["tiles_sparse"], p["tiles_dense"], p["pruned_pct"],
                 p["bytes_dense"] / 1e9, p["bytes_sparse"] / 1e9))

    # La tendance décide de l'extrapolation vers un nside plus fin : l'élagage doit
    # croître avec la profondeur, sinon le sur-échantillonnage n'est pas au rendez-vous.
    if len(per_level) >= 2:
        t = thresholds[len(thresholds) // 2]
        first = per_level[0]["prunable"][str(t)]
        last = per_level[-1]["prunable"][str(t)]
        print("\ntendance à <=%gm : n%d %.1f%% -> n%d %.1f%% (%s)"
              % (t, per_level[0]["nside"], 100 * first, per_level[-1]["nside"], 100 * last,
                 "croissante, l'élagage progressera aux niveaux plus fins"
                 if last > first else
                 "NON croissante : n'extrapolez pas vers un nside plus fin"))

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"pack": args.pack, "manifest": pack.manifest,
                       "per_level": per_level, "projections": projections}, fh, indent=2)
        print("\nrapport écrit dans %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
