"""
probe_pack_sparsity.py — décider dense vs « pack creux » SANS faire l'export complet
====================================================================================

LE PROBLÈME
-----------
tarsis_3 doit passer de `n64 × tile_res 50` (2 033 m) à `n1024 × tile_res 32` (198 m).
L'export dense correspondant représente **1,72e10 évaluations du TIN** contre 1,64e8
aujourd'hui — un facteur 105. À la cadence mesurée (~20 min pour l'export actuel), c'est
**environ 34 heures** et 68,7 Go écrits, pour répondre à une seule question :

    « Combien de tuiles fines sont assez proches de l'upsample de leur parent
      pour ne pas valoir la peine d'être stockées ? »

Cette question n'a pas besoin de toute la planète. Quelques centaines de tuiles parentes
tirées au hasard, plus leurs enfants, donnent le taux d'élagage à un point de pourcentage
près en **moins d'une minute**.

CE QUE FAIT CE SCRIPT
---------------------
1. Construit le SphericalTIN exactement comme export_elevation.py — mêmes contours,
   même décimation, même interpolateur. Sans ça, la mesure ne parlerait pas de la donnée
   qui sera réellement exportée.
2. Pour chaque transition de niveau menant à TARGET_NSIDE, tire PARENTS_PER_LEVEL pixels
   parents au hasard, échantillonne le parent et ses 4 enfants contre le TIN.
3. Compare chaque enfant à l'upsample bilinéaire du quadrant correspondant du parent, et
   rapporte la fraction élaguable par seuil d'erreur.

La comparaison réutilise `_upsampler` de tools/analyze_pack_sparsity.py — le mapping de
quadrant NESTED est la seule partie délicate, elle est couverte par
test/unit/test_pack_sparsity_py.py, et elle ne doit exister qu'à un seul endroit.

CE QUE ÇA NE DIT PAS
--------------------
L'élagage est évalué contre le parent RÉEL. Un vrai bake creux élague en cascade et
l'erreur se cumule : les taux ci-dessous sont une BORNE SUPÉRIEURE.

USAGE
-----
Depuis la console Python de QGIS, projet de la planète ouvert :

    exec(open('/chemin/vers/tools/qgis/probe_pack_sparsity.py').read())

Ajustez TARGET_NSIDE / TARGET_TILE_RES pour la résolution visée.
"""

import os
import random
import sys

import numpy as np

# `exec(open(...).read())` depuis la console QGIS n'expose PAS __file__ — d'où le repli,
# même garde que export_roads.py. Ajustez le chemin si le dépôt est ailleurs.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__)) \
    if "__file__" in globals() else \
    "/datas/developpement/sources/DyingStar-game/DyingStar/tools/qgis"
_REPO = os.path.dirname(os.path.dirname(_THIS_DIR))
for _p in (_THIS_DIR, _REPO):
    if _p not in sys.path:
        sys.path.insert(0, _p)

# La console QGIS réutilise UN interpréteur : un helper importé par une exécution
# précédente reste dans sys.modules et n'est jamais relu du disque, si bien qu'une
# correction sous export/planet/ ou dans analyze_pack_sparsity.py ne ferait rien. On
# purge ce qui vient de ce dépôt. Les paquets d'espace de noms n'ont pas de __file__,
# d'où la seconde clause.
_ROOTS = (_THIS_DIR + os.sep, os.path.join(_REPO, "tools") + os.sep)
for _name, _mod in list(sys.modules.items()):
    _mod_file = getattr(_mod, "__file__", None)
    if _mod_file and os.path.abspath(_mod_file).startswith(_ROOTS):
        del sys.modules[_name]
    elif _mod_file is None and (_name in ("export", "tools")
                                or _name.startswith(("export.", "tools."))):
        del sys.modules[_name]

import healpix_utils as hpx
from export.planet.heightmap import extract_contour_points
from export.planet.spherical_tin import SphericalTIN
from tools.analyze_pack_sparsity import _upsampler, bound_prune, cascade_prune

from qgis.core import QgsProject

# ── Configuration ────────────────────────────────────────────────────────────────────
## Résolution visée. n1024 × 32 → 198 m sur une planète de 6 356 km.
TARGET_NSIDE = 1024
TARGET_TILE_RES = 32
## Le niveau le plus grossier à sonder. On ne sonde que les transitions NOUVELLES,
## celles que l'export actuel (n64) ne couvre pas : n64→n128 … n512→n1024.
PROBE_FROM_NSIDE = 64
## Sous-arbres complets tirés au hasard, chacun descendu de PROBE_FROM_NSIDE à
## TARGET_NSIDE. Un sous-arbre n64→n1024 pèse 341 tuiles ; 60 racines ≈ 20 460 tuiles,
## soit ~2,5 min d'échantillonnage du TIN. Monter ce nombre resserre l'intervalle.
SUBTREE_ROOTS = 60
## Seuils d'erreur, en mètres.
THRESHOLDS = (1.0, 5.0, 10.0, 25.0, 50.0)
## Tirage reproductible : deux sondages du même projet doivent être comparables.
SEED = 20260907
## Doit rester identique à export_elevation.HEIGHTMAP_SIZE (dimensionne la décimation).
HEIGHTMAP_SIZE = (4096, 2048)


def find_layers_by_keyword(keyword):
    """Calque du helper d'export_elevation.py, qui n'est pas importable (il lance
    run_export() au chargement)."""
    kw = keyword.lower()
    return [l for l in QgsProject.instance().mapLayers().values()
            if kw in l.name().lower()]


def _memlog(*_args, **_kwargs):
    pass


def _sample_tile(tin, nside, ipix, tile_res):
    """Une tuile en MÈTRES (pas de normalisation : les seuils sont des mètres)."""
    gx, gy, gz = hpx.get_tile_grid_vec(nside, ipix, tile_res)
    flat = tin.sample_vec(gx.ravel(), gy.ravel(), gz.ravel())
    return flat.reshape(tile_res, tile_res)


def probe():
    print("=" * 78)
    print("Sondage de creusabilité — cible n%d × tr%d, %d sous-arbres"
          % (TARGET_NSIDE, TARGET_TILE_RES, SUBTREE_ROOTS))
    print("=" * 78)

    pts = extract_contour_points(HEIGHTMAP_SIZE, find_layers_by_keyword, _memlog)
    if pts is None or len(pts) < 4:
        print("Pas de contours exploitables : cette planète est plate, elle n'a pas "
              "besoin de pyramide du tout (voir docs/PLANET_CHUNK_STREAMING.md, phase 1).")
        return
    print("  %d sommets de contour → construction du TIN…" % len(pts))
    tin = SphericalTIN(pts[:, 0], pts[:, 1], pts[:, 2])

    up = _upsampler(TARGET_TILE_RES)
    rng = random.Random(SEED)
    roots = rng.sample(range(12 * PROBE_FROM_NSIDE * PROBE_FROM_NSIDE), SUBTREE_ROOTS)

    # Chaque tuile du sous-arbre n'est échantillonnée qu'UNE fois : le parcours en
    # cascade est rejoué pour chaque epsilon, mais sur les mêmes tuiles réelles. Sans ce
    # cache, sonder cinq seuils coûterait cinq fois le TIN.
    cache = {}

    def get_tile(nside, ipix):
        key = (nside, ipix)
        tile = cache.get(key)
        if tile is None:
            tile = _sample_tile(tin, nside, ipix, TARGET_TILE_RES)
            cache[key] = tile
        return tile

    per_root = 1 + sum(4 ** k for k in range(1, int(np.log2(TARGET_NSIDE / PROBE_FROM_NSIDE)) + 1))
    print("  échantillonnage de %d sous-arbres × %d tuiles = %d tuiles…"
          % (SUBTREE_ROOTS, per_root, SUBTREE_ROOTS * per_root))

    levels = []
    ns = PROBE_FROM_NSIDE * 2
    while ns <= TARGET_NSIDE:
        levels.append(ns)
        ns *= 2

    results = {}
    for eps in THRESHOLDS:
        casc_p, casc_t, bnd_p, bnd_t = {}, {}, {}, {}
        worst = 0.0
        for root in roots:
            p1, t1, w = cascade_prune(get_tile, PROBE_FROM_NSIDE, root,
                                      TARGET_NSIDE, eps, TARGET_TILE_RES, up)
            p2, t2 = bound_prune(get_tile, PROBE_FROM_NSIDE, root,
                                 TARGET_NSIDE, eps, TARGET_TILE_RES, up)
            worst = max(worst, w)
            for dst, src in ((casc_p, p1), (casc_t, t1), (bnd_p, p2), (bnd_t, t2)):
                for k, v in src.items():
                    dst[k] = dst.get(k, 0) + v
        results[eps] = (casc_p, casc_t, bnd_p, bnd_t, worst)

    print("\nTaux d'élagage par niveau — CASCADE (réel) vs BORNE (parent réel)")
    header = "niveau   tuiles  " + "  ".join("%16s" % ("eps=%gm" % t) for t in THRESHOLDS)
    print(header)
    print("%s  %s" % (" " * 16, "  ".join("%16s" % "casc.  /  borne" for _ in THRESHOLDS)))
    for lvl in levels:
        cells = []
        for eps in THRESHOLDS:
            cp, ct, bp, bt = results[eps][:4]
            cells.append("%6.1f%% / %5.1f%%" % (100.0 * cp.get(lvl, 0) / max(ct.get(lvl, 1), 1),
                                                100.0 * bp.get(lvl, 0) / max(bt.get(lvl, 1), 1)))
        print("n%-6d %7d  %s" % (lvl, results[THRESHOLDS[0]][1].get(lvl, 0),
                                 "  ".join("%16s" % c for c in cells)))

    print("\nprojection sur la pyramide n1…n%d (uint16, %d o/tuile) :"
          % (TARGET_NSIDE, TARGET_TILE_RES * TARGET_TILE_RES * 2))
    tile_bytes = TARGET_TILE_RES * TARGET_TILE_RES * 2
    depth = int(np.log2(TARGET_NSIDE)) + 1
    dense = sum(12 * (1 << k) ** 2 for k in range(depth))
    for eps in THRESHOLDS:
        cp, ct, bp, bt, worst = results[eps]
        kept_c = kept_b = 0
        for k in range(depth):
            ns = 1 << k
            n = 12 * ns * ns
            fc = cp.get(ns, 0) / ct[ns] if ns in ct and ct[ns] else 0.0
            fb = bp.get(ns, 0) / bt[ns] if ns in bt and bt[ns] else 0.0
            kept_c += n * (1.0 - fc)
            kept_b += n * (1.0 - fb)
        print("  eps=%5gm : cascade %9d tuiles (%4.1f%% élaguées, %5.2f Go) | "
              "borne %9d (%4.1f%%) | pire erreur élaguée %.3f m"
              % (eps, int(kept_c), 100.0 * (dense - kept_c) / dense,
                 kept_c * tile_bytes / 1e9,
                 int(kept_b), 100.0 * (dense - kept_b) / dense, worst))

    print("\nLa colonne 'cascade' est celle sur laquelle dimensionner : elle rejoue la")
    print("décision réelle du baker, où une tuile élaguée est prédite depuis la")
    print("RECONSTRUCTION du client et non depuis son parent réel. 'pire erreur élaguée'")
    print("doit rester <= eps — c'est le contrôle interne de l'algorithme.")
    print("=" * 78)


probe()
