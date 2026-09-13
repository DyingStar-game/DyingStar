"""
export_elevation.py — QGIS → Godot per-chunk elevation export (standard mesh pipeline)
======================================================================================

Elevation-ONLY exporter. Produces one heightmap file per HEALPix chunk so the
standard mesh terrain (scenes/planet/planet_terrain.gd) can displace its sphere
chunks directly from QGIS contour data — no recipes, no voxels.

Pipeline
--------
1. Read the contour / elevation line layer (field: elev/elevation/height/z/alt).
   Contours are drawn at 50 m intervals in EPSG:4326 (lon/lat degrees).
2. Triangulate those vertices ON THE SPHERE (export/planet/spherical_tin.py) and
   interpolate every tile barycentrically from that TIN.
   This is deliberately NOT the equirectangular raster path: that interpolator
   averages source vertices into coarse cells (measured on tarsis_4: a 936×468
   working grid, i.e. 42.7 km per cell), which pulls isolated peaks toward the
   local mean — a 9000 m summit came out at 6196 m, and every pyramid level
   inherited it because all levels resampled that one raster. A TIN is exact at
   each contour vertex and bounded by the input range everywhere else, so tiles
   now carry the elevations that were actually drawn.
   The equirectangular {planet}_heightmap.tif is still written, sampled from the
   same TIN, for the runtime's whole-planet fallback.
3. For each pyramid level nside ∈ {NSIDE_MIN, …, NSIDE/2, NSIDE}, and each of
   its 12·nside² HEALPix pixels, sample a (TILE_RES × TILE_RES) grid of
   directions covering that pixel against the TIN (tiles are sampled in groups
   of TILE_BATCH so the per-call overhead is amortised — 8× faster than one
   call per tile, measured).
4. Stream every tile (raw float32, normalized to [0,1] over
   [ELEV_MIN, ELEV_MAX]) into a single dense archive
   {planet}_chunks/heights.pack (DSHP v1, spec below), read at runtime by
   scenes/planet/height_pack.gd. One file instead of ~65k tiny .r32 files:
   fast tar/rsync/Godot export, O(1) offsets, no index.
   Set WRITE_LOOSE_TILES = True to ALSO write the legacy
   n{nside}/face_{face}/f{ipix}.r32 tree (debug / diffing only — the
   runtime reads exclusively from heights.pack).
   The pyramid lets far LODs read one coarse tile per chunk instead of
   point-sampling many fine tiles (no aliasing, cheap whole-planet view).

DSHP on-disk format (little-endian) — authoritative spec
--------------------------------------------------------
    0   magic       "DSHP" (4 B)
    4   version     u32 = 1 or 2
    8   tile_res    u32     samples per tile edge (tile = tile_res² samples)
    12  nside_min   u32     coarsest pyramid level
    16  nside_max   u32     finest pyramid level (levels = all powers of two between)
    20  flags       u32     v1: reserved, 0
                            v2: bit0 = samples are u16, bit1 = sparse
    24  blob_start  u32     absolute offset of the tile blob
    28  json_len    u32
    32  manifest    json_len B  (verbatim manifest.json, UTF-8)
    …   [v2, sparse only] one presence bitmap per level, ascending:
              ceil(12·nside²/8) B, bit i (LSB-first) set when tile i is stored
    …   padding to blob_start (16-byte aligned)
    blob: for nside = nside_min, 2·nside_min, …, nside_max (ascending):
              the STORED tiles in ipix order, each tile_res²·sample_size B LE

v1 is dense float32: every ipix exists at every level, so the reader needs no
index — offset(nside, ipix) = blob_start + level_base[nside] + ipix·tile_size.

v2 samples are u16 by default: a planet's elevation span fits in 10 700 m, where
float32 offers 0.163 m steps — far below the 50 m vertical resolution of the
source contours. Halves the archive. The runtime reader widens back to float32
on read, so nothing downstream of HeightPack.read_tile() changes.

A sparse v2 pack omits tiles the bilinear upsample of their parent already
reproduces, so offsets stop being arithmetic: the per-level presence bitmap plus
a rank index give the tile's slot within its level. See scenes/planet/height_pack.gd.

Why .r32 (raw float32) instead of 16-bit PNG?
    Godot's PNG loader downsamples 16-bit greyscale to 8-bit on import (256
    elevation steps → visible terracing). A raw float32 blob is loaded losslessly
    via Image.create_from_data(..., Image.FORMAT_RF, bytes) — exact, no importer.

Round-trip with Godot
---------------------
    Godot decodes height as:  elev = pixel.r * max_height + height_offset
    so the manifest exports:  height_offset = ELEV_MIN
                              max_height    = ELEV_MAX - ELEV_MIN
    Set these on the PlanetData resource (or let it read manifest.json).

Run from the QGIS Python Console:
    exec(open('/datas/developpement/sources/DyingStar-game/DyingStar/tools/planettech/qgis/export_elevation.py').read())
"""
import os
import sys
import json
import math
import time
import hashlib
import struct
import numpy as np

# ── Make tools/ importable so we can reuse healpix_utils + the interpolator ──
def _repo_root(start):
    """Remonte jusqu'au dépôt, repéré par project.godot.

    Compter les `dirname` marche jusqu'au jour où l'on déplace le fichier — ce qui vient
    d'arriver en passant de tools/ à tools/planettech/. Un marqueur ne se décale pas.
    """
    d = start
    while d != os.path.dirname(d):
        if os.path.exists(os.path.join(d, "project.godot")):
            return d
        d = os.path.dirname(d)
    return start

_tools_dir = os.path.dirname(os.path.abspath(__file__))
if _tools_dir not in sys.path:
    sys.path.insert(0, _tools_dir)

# The documented entry point is exec()-ing this file from the QGIS Python console,
# which reuses ONE long-lived interpreter: any helper imported by an earlier run
# stays in sys.modules and is never re-read from disk, so edits under
# export/planet/ silently do nothing — and a newly ADDED function surfaces as an
# ImportError from the import block right below. Drop the previously loaded
# modules so every exec() picks up the current source. Matching on the file's
# location (rather than on its name) keeps this from touching anything QGIS or
# another plugin has loaded; namespace packages carry no __file__, hence the
# second clause.
for _name, _mod in list(sys.modules.items()):
    _mod_file = getattr(_mod, "__file__", None)
    if _mod_file and os.path.abspath(_mod_file).startswith(_tools_dir + os.sep):
        del sys.modules[_name]
    elif _mod_file is None and (_name == "export" or _name.startswith("export.")):
        del sys.modules[_name]

import healpix_utils as hpx
# Le mapping de quadrant NESTED et l'upsample bilinéaire décalé d'une demi-cellule ne
# doivent exister qu'à un seul endroit : tools/planettech/analyze_pack_sparsity.py les porte, et
# test/unit/test_pack_sparsity_py.py les couvre.
sys.path.insert(0, _repo_root(_tools_dir))
from tools.planettech.analyze_pack_sparsity import _upsampler
from export.planet.heightmap import (
    extract_contour_points,
    generate_heightmap_from_contours,
    save_heightmap_geotiff,
)
from export.planet.spherical_tin import SphericalTIN

from qgis.core import (
    QgsProject,
    QgsVectorLayer,
    QgsExpressionContextUtils,
)

# ============================================================
# CONFIGURATION — edit for your planet
# ============================================================
_project = QgsProject.instance()
_proj_planet_name = QgsExpressionContextUtils.projectScope(_project).variable("planet_name")
_proj_planet_radius = QgsExpressionContextUtils.projectScope(_project).variable("planet_radius_m")

PLANET_NAME = str(_proj_planet_name) if _proj_planet_name else "tarsis_5"
# Planet radius in metres (sea-level surface). New value: 6356 km.
PLANET_RADIUS = int(_proj_planet_radius) if _proj_planet_radius else 6_356_000

EXPORT_DIR = os.path.expanduser(
    "/datas/developpement/sources/DyingStar-game/DyingStar/assets/qgis/export"
)

# Découpage HEALPix, PAR CORPS. La clé est le planet_name lu du projet QGIS.
#
# L'espacement au sol ne dépend que du PRODUIT nside × tile_res :
#     espacement = 6 504 266 / (nside × tile_res)   mètres, pour R = 6 356 km
# Le partage entre les deux, lui, décide de tout le reste (voir
# docs/PLANET_CHUNK_STREAMING.md §4) :
#   · l'empreinte réseau d'un joueur croît comme tile_res² — une grosse tuile sur-livre,
#     puisqu'un chunk-feuille en tire une entière pour n'en lire qu'une poignée de valeurs ;
#   · le nombre de fichiers croît comme nside² ;
#   · tile_res doit rester ≥ chunk_resolution (32) — un chunk-feuille échantillonne 33
#     points par arête dans sa propre tuile — et donner une tuile d'un bloc disque entier
#     (4 Kio), sans quoi le stockage est gaspillé par le padding.
# n1024 × 32 coche les trois : 198 m, tuile de 4 096 o en float32 (2 048 en uint16).
#
# Cette table existe pour qu'exporter une planète après une autre ne demande PAS d'éditer
# le script entre les deux : une erreur ici coûte un export entier, et un export de
# tarsis_3 à 198 m dure ~35 heures.
PLANET_TILING = {
    "tarsis_3": (1024, 32),     # 198 m — la planète jouable
    "tarsis_8": (256, 32),
}
# Tout le reste : 4 065 m. Suffisant pour des corps sans relief travaillé, et 19 × 164 Mo
# au lieu de 19 × 68 Go.
DEFAULT_TILING = (64, 25)

NSIDE, TILE_RES = PLANET_TILING.get(PLANET_NAME, DEFAULT_TILING)

# Coarsest pyramid level to bake. 1 → the 12 HEALPix base faces (whole-planet view).
# Levels baked: NSIDE, NSIDE/2, … , NSIDE_MIN (all powers of two).
NSIDE_MIN = 1

# Tiles per TIN call, sized to hold the measured sweet spot of ~160k directions per
# call whatever TILE_RES is. One call per tile wastes ~85% of the time in per-call
# overhead (measured: 6.06 ms/tile alone vs 0.73 ms/tile grouped).
TILE_BATCH = max(1, 160_000 // (TILE_RES * TILE_RES))

# Also write the legacy loose-tile tree (n{nside}/face_{face}/f{ipix}.r32) next
# to heights.pack. Off by default: the pack alone is what the runtime reads,
# and ~65k tiny files per planet are exactly what this format eliminates.
WRITE_LOOSE_TILES = False

# Échantillons stockés en uint16 normalisé plutôt qu'en float32 (DSHP v2). L'amplitude
# d'une planète tient dans [ELEV_MIN, ELEV_MAX] ; sur 10 700 m, 65 535 pas donnent 0,16 m,
# soit bien en dessous des 50 m d'équidistance des contours. Le float32 y offrait des pas
# de 0,163 m — de la précision dépensée pour rien, sur la moitié de l'archive.
# Mettre à False pour réémettre un pack v1 dense float32.
SAMPLE_U16 = True

# Élagage du pack : une tuile n'est PAS stockée quand la reconstruction que le client en
# ferait depuis son parent s'en écarte de moins de SPARSE_EPSILON_M mètres. 0 désactive.
#
# La pyramide est massivement sur-échantillonnée — les contours de tarsis_3 portent ~438 000
# valeurs indépendantes pour 1,29e10 échantillons à 198 m — donc l'essentiel des niveaux fins
# n'est pas de la donnée mais de l'interpolation. Sondé sur le vrai TIN : 75 % des tuiles
# élaguables à 1 m, SANS perte de relief (1 m représente 0,009 % de l'amplitude et se situe
# bien sous les 50 m d'équidistance des contours).
#
# La comparaison se fait contre la RECONSTRUCTION, pas contre le parent réel : à 75 %
# d'élagage la plupart des parents sont eux-mêmes absents, et prédire depuis le grand-parent
# cumulerait l'erreur. Comparer à ce que le client verra vraiment la borne à epsilon quelle
# que soit la profondeur.
SPARSE_EPSILON_M = 1.0

# Bump manuel pour toute évolution de l'ALGORITHME d'échantillonnage qui change les
# élévations produites sans toucher à une seule constante ci-dessus (nouvel
# interpolateur, changement de convention de grille, agrégation différente). Les valeurs
# des constantes, elles, entrent déjà dans data_version toutes seules.
ALGO_VERSION = 2

# Global interpolation raster (equirectangular, width = 2 × height).
HEIGHTMAP_SIZE = (4096, 2048)

# Elevation range for normalization. None = auto-detect from contour data.
ELEV_MIN = None
ELEV_MAX = None

# Contour field names accepted, in priority order.
_ELEV_FIELDS = ("elev", "elevation", "height", "z", "alt")


# ============================================================
# Helpers
# ============================================================
_DSHP_MAGIC = b"DSHP"
_DSHP_VERSION = 1
_DSHP_ALIGN = 16


def build_header(manifest_bytes, tile_res, nside_min, nside_max, extra_bytes=0):
    """DSHP fixed header + embedded manifest, padded to _DSHP_ALIGN.

    Emits v1 (dense float32) or v2 (u16) depending on SAMPLE_U16. The version is not
    bumped gratuitously: a v1 reader would misread u16 samples as float32, so the
    encoding change has to be visible in the header.
    """
    version = 2 if (SAMPLE_U16 or extra_bytes) else _DSHP_VERSION
    flags = (1 if SAMPLE_U16 else 0) | (2 if extra_bytes else 0)
    raw_len = 32 + len(manifest_bytes) + extra_bytes
    blob_start = (raw_len + _DSHP_ALIGN - 1) // _DSHP_ALIGN * _DSHP_ALIGN
    head = struct.pack("<4s6I", _DSHP_MAGIC, version, tile_res,
                       nside_min, nside_max, flags, blob_start)
    head += struct.pack("<I", len(manifest_bytes)) + manifest_bytes
    # extra_bytes réserve la place des cartes de présence, écrites par l'appelant juste
    # après le manifeste ; le bourrage d'alignement vient après elles.
    return head, blob_start - raw_len


def _memlog(label, *extra):
    """No-op progress logger passed to the shared interpolator."""
    if extra:
        print(f"  · {label}: {' '.join(str(e) for e in extra)}")
    else:
        print(f"  · {label}")


def find_layers_by_keyword(keyword):
    """Return project layers whose name contains *keyword* (case-insensitive)."""
    kw = keyword.lower()
    return [l for l in QgsProject.instance().mapLayers().values()
            if kw in l.name().lower()]


def _find_contour_layer():
    layers = find_layers_by_keyword("contour") + find_layers_by_keyword("elevation")
    for l in layers:
        if isinstance(l, QgsVectorLayer):
            return l
    return None


def _elev_field(layer):
    for field in layer.fields():
        if field.name().lower() in _ELEV_FIELDS:
            return field.name()
    return None


def scan_elevation_range(layer, field):
    """Auto-detect [ELEV_MIN, ELEV_MAX] from the contour layer if not set."""
    global ELEV_MIN, ELEV_MAX
    if ELEV_MIN is not None and ELEV_MAX is not None:
        print(f"  Using configured elevation range: [{ELEV_MIN}, {ELEV_MAX}]m")
        return
    vals = []
    for feat in layer.getFeatures():
        v = feat[field]
        if v is None:
            continue
        try:
            e = float(v)
        except (ValueError, TypeError):
            continue
        geom = feat.geometry()
        if geom and not geom.isNull():
            c = geom.centroid().asPoint()
            if abs(c.x()) < 0.01 and abs(c.y()) < 0.01 and e == 0.0:
                continue  # skip setup stub feature at (0,0)
        vals.append(e)
    if vals:
        cmin, cmax = min(vals), max(vals)
        ELEV_MIN = 0.0 if cmin >= 0 else cmin
        ELEV_MAX = cmax if cmax > ELEV_MIN else ELEV_MIN + 1.0
        print(f"  ✓ Auto elevation range from {len(vals)} contour values: "
              f"[{ELEV_MIN}, {ELEV_MAX}]m")
    else:
        ELEV_MIN, ELEV_MAX = 0.0, 1000.0
        print(f"  ⚠ No contour values — default range [{ELEV_MIN}, {ELEV_MAX}]m")


def _read_global_raster(path, size):
    """Read the interpolated global heightmap back as a (H, W) float32 array."""
    w, h = size
    if path.endswith(".npy"):
        arr = np.load(path)
    else:
        from osgeo import gdal
        ds = gdal.Open(path)
        arr = ds.GetRasterBand(1).ReadAsArray().astype(np.float32)
        ds = None
    if arr.shape != (h, w):
        print(f"  ⚠ Raster shape {arr.shape} != expected {(h, w)}; using actual.")
    return arr


def _sample_equirect_bilinear(raster, lon, lat):
    """
    Bilinearly sample an equirectangular raster (origin lon=-180, lat=+90) at
    arrays of (lon, lat) in degrees. Returns an array of the same shape.
    """
    h, w = raster.shape
    col = (lon + 180.0) / 360.0 * w - 0.5
    row = (90.0 - lat) / 180.0 * h - 0.5

    # Longitude wraps; latitude clamps.
    x0 = np.floor(col).astype(np.int64)
    y0 = np.floor(row).astype(np.int64)
    fx = col - x0
    fy = row - y0
    x0w = np.mod(x0, w)
    x1w = np.mod(x0 + 1, w)
    y0c = np.clip(y0, 0, h - 1)
    y1c = np.clip(y0 + 1, 0, h - 1)

    a00 = raster[y0c, x0w]
    a10 = raster[y0c, x1w]
    a01 = raster[y1c, x0w]
    a11 = raster[y1c, x1w]
    return (a00 * (1 - fx) * (1 - fy) + a10 * fx * (1 - fy)
            + a01 * (1 - fx) * fy + a11 * fx * fy)


# ============================================================
# Main export
# ============================================================
def compute_data_version(pts):
    """Empreinte des ENTRÉES de l'export, écrite dans le manifeste sous `data_version`.

    Elle ferme un piège silencieux. `PlanetTerrain` construit sa clé de cache à partir de
    planet_name / radius / max_height / height_offset / tile_res : cinq champs qu'un
    ré-export laisse le plus souvent identiques, alors que TOUTES les élévations ont
    changé (contours redessinés, interpolateur modifié, NSIDE relevé). L'ancienne clé
    rapportait alors « Cache valid » et servait le terrain d'avant, indéfiniment — un
    ré-export sans effet visible, à ne pas confondre avec un export raté.

    Le côté runtime est déjà branché : PlanetData lit `data_version` (planet_data.gd) et
    planet_terrain.gd en fait le suffixe `_dv` de la clé. Seul ce champ manquait, donc
    aucun planet n'a jamais bénéficié de l'invalidation automatique.

    On hache les ENTRÉES, pas le blob produit : le manifeste est écrit dans l'EN-TÊTE du
    pack, donc avant les tuiles — hacher la sortie demanderait de revenir écrire dedans.

    Un manifeste sans le champ donne un suffixe vide côté Godot, donc une clé identique
    à celle sous laquelle les planètes non ré-exportées ont déjà bâti leur cache : elles
    ne sont pas invalidées pour rien.
    """
    h = hashlib.blake2b(digest_size=8)
    for value in (PLANET_NAME, PLANET_RADIUS, NSIDE, NSIDE_MIN, TILE_RES,
                  ELEV_MIN, ELEV_MAX, HEIGHTMAP_SIZE, ALGO_VERSION, SAMPLE_U16,
                  SPARSE_EPSILON_M):
        h.update(repr(value).encode("utf-8"))
    if pts is None:
        h.update(b"flat")           # planète sans contours : pas de sommets à hacher
    else:
        arr = np.ascontiguousarray(pts, dtype=np.float64)
        h.update(str(arr.shape).encode("utf-8"))
        h.update(arr.tobytes())
    return h.hexdigest()


def write_pack(tmp_path, chunks_dir, manifest_bytes, levels, total_tiles,
               elev_range, sample_norm, loose_dir_fn=None):
    """Écrit le pack DSHP (deux passes) et rend (tuiles gardées, total).

    Extrait de run_export pour être testable sans QGIS : c'est le code le plus risqué de
    l'exporteur — deux passes, fichiers temporaires, cartes de présence, décision
    d'élagage en cascade — et un export réel de tarsis_3 dure ~35 h. Le découvrir cassé
    après coup coûterait la journée.

    [param sample_norm] : callable(nside, group) -> ndarray (n, TILE_RES, TILE_RES) de
    valeurs NORMALISÉES [0,1]. C'est le seul lien avec le TIN, donc le seul point à
    remplacer dans un test.
    """
    sparse = SPARSE_EPSILON_M > 0.0
    up = _upsampler(TILE_RES)
    half = TILE_RES // 2
    bitmap_bytes = sum((12 * n * n + 7) // 8 for n in levels) if sparse else 0
    head, pad = build_header(manifest_bytes, TILE_RES, int(min(levels)),
                             int(max(levels)), bitmap_bytes)

    # PASSE 1 — échantillonner, décider, écrire les tuiles gardées par niveau.
    #
    # Les cartes de présence précèdent le blob dans le fichier mais ne sont connues qu'après
    # avoir tout calculé, d'où les fichiers temporaires par niveau, concaténés en passe 2.
    #
    # La reconstruction du niveau parent passe par un memmap plutôt que par la RAM : à
    # n1024 un niveau pèse ~13 Go, ce qui exclut de le garder en mémoire. Les accès sont
    # séquentiels (l'ipix parent croît avec l'ipix enfant), donc le cache disque suffit.
    written = 0
    kept_total = 0
    tmp_files = []
    bitmaps = {}
    recon_prev = None
    recon_prev_path = None
    for level_nside in levels:
        npix = 12 * level_nside * level_nside
        npface = level_nside * level_nside
        level_dir = loose_dir_fn(level_nside) if loose_dir_fn else None
        bits = bytearray((npix + 7) // 8)
        # La reconstruction ne sert qu'aux ENFANTS : inutile de l'écrire pour le niveau le
        # plus fin, qui n'en a pas. À n1024 ce fichier pèserait 51 Go pour rien.
        needs_recon = sparse and level_nside < max(levels)
        recon_path = os.path.join(chunks_dir, f".recon_n{level_nside}.tmp")
        recon = (np.memmap(recon_path, dtype=np.float32, mode="w+",
                           shape=(npix, TILE_RES, TILE_RES)) if needs_recon else None)
        blob_path = os.path.join(chunks_dir, f".blob_n{level_nside}.tmp")
        tmp_files.append(blob_path)
        kept_here = 0
        with open(blob_path, "wb") as lvl:
            for base in range(0, npix, TILE_BATCH):
                group = range(base, min(base + TILE_BATCH, npix))
                # Un seul appel par groupe : le lot amortit la requête KD-tree et la
                # résolution barycentrique du TIN (8x plus rapide qu'un appel par tuile),
                # et les tuiles restent en ordre d'ipix, donc la disposition du blob est
                # inchangée.
                norms = sample_norm(level_nside, group)
                for offset, ipix in enumerate(group):
                    norm = norms[offset]

                    keep = True
                    pred = None
                    if sparse and recon_prev is not None:
                        k = ipix & 3
                        dx, dy = k & 1, (k >> 1) & 1
                        quad = recon_prev[ipix >> 2][dy * half:(dy + 1) * half,
                                                     dx * half:(dx + 1) * half]
                        pred = up(quad)
                        err_m = float(np.abs(pred - norm).max()) * elev_range
                        keep = err_m > SPARSE_EPSILON_M

                    if keep:
                        if SAMPLE_U16:
                            # Borné avant quantification : FORMAT_RF n'était pas clampé et
                            # laissait passer les valeurs hors [ELEV_MIN, ELEV_MAX], mais un
                            # u16 les replierait au lieu de les saturer.
                            q = np.rint(np.clip(norm, 0.0, 1.0) * 65535.0).astype("<u2")
                            lvl.write(q.tobytes())
                            # La reconstruction est ce que le CLIENT verra, donc la valeur
                            # déquantifiée — sinon epsilon ignorerait l'erreur de quantification.
                            if needs_recon:
                                recon[ipix] = q.astype(np.float32) / 65535.0
                        else:
                            lvl.write(norm.tobytes())
                            if needs_recon:
                                recon[ipix] = norm
                        bits[ipix >> 3] |= 1 << (ipix & 7)
                        kept_here += 1
                    elif needs_recon:
                        recon[ipix] = pred

                    if level_dir is not None:
                        face = ipix // npface
                        norm.tofile(os.path.join(
                            level_dir, f"face_{face}", f"f{ipix}.r32"))
                    written += 1
                    if written % 8192 == 0:
                        print(f"    {written}/{total_tiles} tiles…")
        if needs_recon:
            recon.flush()
        bitmaps[level_nside] = bytes(bits)
        kept_total += kept_here
        pct = 100.0 * (npix - kept_here) / npix if npix else 0.0
        print(f"    · level n{level_nside}: {npix} tiles, {kept_here} kept "
              f"({pct:.1f}% pruned)" if sparse
              else f"    · level n{level_nside}: {npix} tiles")
        del recon_prev
        if recon_prev_path and os.path.exists(recon_prev_path):
            os.remove(recon_prev_path)
        recon_prev = (np.memmap(recon_path, dtype=np.float32, mode="r",
                                shape=(npix, TILE_RES, TILE_RES))
                      if needs_recon else None)
        recon_prev_path = recon_path if needs_recon else None

    del recon_prev
    if recon_prev_path and os.path.exists(recon_prev_path):
        os.remove(recon_prev_path)

    # PASSE 2 — en-tête, cartes de présence, puis les blobs de niveau dans l'ordre.
    with open(tmp_path, "wb") as out:
        out.write(head)
        if sparse:
            for level_nside in levels:
                out.write(bitmaps[level_nside])
        out.write(b"\x00" * pad)
        for blob_path in tmp_files:
            with open(blob_path, "rb") as lvl:
                while True:
                    chunk = lvl.read(1 << 22)
                    if not chunk:
                        break
                    out.write(chunk)
    for blob_path in tmp_files:
        os.remove(blob_path)
    if sparse:
        print(f"  Sparse pack: {kept_total}/{total_tiles} tiles kept "
              f"({100.0 * (total_tiles - kept_total) / total_tiles:.1f}% pruned "
              f"at epsilon={SPARSE_EPSILON_M} m)")
    return kept_total, total_tiles


## Débit d'échantillonnage du TIN, mesuré sur l'export tarsis_3 n256 × tr32 :
## 1,07e9 échantillons en un peu moins de 30 min, coûts fixes déduits.
##
## Une première version calait ce débit sur un export n64 complet (20 min) et se trompait
## d'un facteur 5 : à n64 l'échantillonnage des tuiles est MINORITAIRE devant les coûts
## fixes — extraction de 3,9 M sommets de contours, décimation, construction du TIN
## (1,86 M triangles), raster de repli 4096×2048. Il faut donc calibrer sur un run
## réellement dominé par l'échantillonnage, sans quoi l'annonce dissuade d'un export qui
## tient en une nuit.
##
## Ce chiffre ne couvre QUE l'échantillonnage : comptez quelques minutes de plus pour les
## coûts fixes, qui ne dépendent pas de la résolution.
_REF_SAMPLES_PER_SEC = 7.0e5


def print_plan():
    """Ce que l'export va coûter, AVANT de le lancer."""
    levels = []
    n = NSIDE_MIN
    while n <= NSIDE:
        levels.append(n)
        n *= 2
    tiles = sum(12 * n * n for n in levels)
    samples = tiles * TILE_RES * TILE_RES
    spacing = PLANET_RADIUS * math.sqrt(math.pi / 3.0) / (NSIDE * TILE_RES)
    hours = samples / _REF_SAMPLES_PER_SEC / 3600.0
    tile_bytes = TILE_RES * TILE_RES * (2 if SAMPLE_U16 else 4)
    print("=" * 64)
    print(f"  Planet     : {PLANET_NAME}  (R = {PLANET_RADIUS} m)")
    print(f"  Tiling     : n{NSIDE} × tile_res {TILE_RES}"
          + ("" if PLANET_NAME in PLANET_TILING else "   [DEFAULT_TILING]"))
    print(f"  Spacing    : {spacing:.0f} m")
    print(f"  Pyramid    : n{NSIDE_MIN}…n{NSIDE}, {tiles} tiles, {samples:.3g} TIN samples")
    print(f"  Encoding   : {'uint16' if SAMPLE_U16 else 'float32'}, "
          f"{tile_bytes} B/tile, dense max {tiles * tile_bytes / 1e9:.1f} GB")
    print(f"  Sparse     : " + (f"epsilon {SPARSE_EPSILON_M} m" if SPARSE_EPSILON_M > 0
                                else "off (dense)"))
    print(f"  Est. time  : ~{hours:.1f} h of TIN sampling (+ a few minutes of fixed cost)")
    print("=" * 64)


def run_export():
    # Annoncer le plan AVANT de calculer quoi que ce soit : à 198 m l'export dure
    # des dizaines d'heures, et s'en apercevoir en cours de route est désagréable.
    print_plan()
    global ELEV_MIN, ELEV_MAX
    print("=" * 64)
    print(f"  export_elevation: planet='{PLANET_NAME}' radius={PLANET_RADIUS}m "
          f"nside={NSIDE} tile_res={TILE_RES}")
    print("=" * 64)

    layer = _find_contour_layer()
    if layer is None:
        print("  ✗ No contour/elevation vector layer found. Aborting.")
        return
    field = _elev_field(layer)
    if not field:
        # No elevation field yet → nothing to displace. Export a FLAT planet
        # rather than aborting, so planets still being authored can be built.
        print(f"  ⚠ No elevation field in '{layer.name()}' "
              f"(expected one of {_ELEV_FIELDS}) — exporting FLAT terrain.")
    else:
        print(f"  Contour layer: '{layer.name()}'  field: '{field}'")

    os.makedirs(EXPORT_DIR, exist_ok=True)
    if field:
        scan_elevation_range(layer, field)
    else:
        if ELEV_MIN is None:
            ELEV_MIN = 0.0
        if ELEV_MAX is None:
            ELEV_MAX = 1000.0
        print(f"  Flat terrain range: [{ELEV_MIN}, {ELEV_MAX}]m")
    elev_range = ELEV_MAX - ELEV_MIN

    # ── Step 1: global interpolated raster (reuse shared interpolator) ──
    # If the contour layer has no (or too few) lines yet, the interpolator
    # returns None; we then export a FLAT raster (elev = ELEV_MIN everywhere)
    # so the planet still builds as a smooth sea-level sphere.
    pts = None
    tin = None
    raster = None
    if field:
        print("  Reading contour vertices…")
        pts = extract_contour_points(HEIGHTMAP_SIZE, find_layers_by_keyword, _memlog)
    if pts is not None and len(pts) >= 4:
        try:
            tin = SphericalTIN(pts[:, 0], pts[:, 1], pts[:, 2])
        except ImportError:
            print("  ⚠ scipy unavailable — falling back to the equirect raster path "
                  "(peaks will be averaged down; see the module docstring).")
    if tin is not None:
        # The .tif is no longer what the tiles are built from, but the runtime still
        # uses it as a whole-planet fallback, so sample it from the SAME TIN — a
        # fallback that disagreed with the tiles would move the ground under the
        # player exactly when a chunk failed to load.
        w, h = HEIGHTMAP_SIZE
        lon_vals = np.linspace(-180.0, 180.0, w, endpoint=False) + (360.0 / w / 2.0)
        lat_vals = np.linspace(90.0, -90.0, h, endpoint=False) - (180.0 / h / 2.0)
        grid_lon, grid_lat = np.meshgrid(lon_vals, lat_vals)
        print(f"  Sampling the {w}×{h} fallback raster from the TIN…")
        raster = tin.sample_lonlat(grid_lon, grid_lat).astype(np.float32)
        save_heightmap_geotiff(
            os.path.join(EXPORT_DIR, f"{PLANET_NAME}_heightmap.tif"), raster)
        print(f"  Global raster (TIN-sampled): {raster.shape}  range "
              f"[{np.nanmin(raster):.1f}, {np.nanmax(raster):.1f}]m")
    else:
        raster_path = None
        if pts is not None:
            print("  Building global elevation raster…")
            raster_path = generate_heightmap_from_contours(
                PLANET_NAME, EXPORT_DIR, HEIGHTMAP_SIZE,
                find_layers_by_keyword, _memlog, points=pts,
            )
        if raster_path is None:
            w, h = HEIGHTMAP_SIZE
            raster = np.full((h, w), ELEV_MIN, dtype=np.float32)
            print(f"  ⚠ No usable contour data — FLAT raster {raster.shape} "
                  f"at elev={ELEV_MIN}m (whole planet at sea level).")
        else:
            raster = _read_global_raster(raster_path, HEIGHTMAP_SIZE)
            print(f"  Global raster: {raster.shape}  range "
                  f"[{np.nanmin(raster):.1f}, {np.nanmax(raster):.1f}]m")

    # ── Step 2: manifest (written first — it is embedded in heights.pack) ──
    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    os.makedirs(chunks_dir, exist_ok=True)

    # Pyramid levels: NSIDE_MIN, … , NSIDE/2, NSIDE (ascending powers of two —
    # the DSHP blob layout requires coarse levels first).
    levels = []
    ns = max(NSIDE_MIN, 1)
    while ns <= NSIDE:
        levels.append(ns)
        ns *= 2
    total_tiles = sum(12 * n * n for n in levels)

    depth = int(round(math.log2(NSIDE)))
    manifest = {
        "planet_name": PLANET_NAME,
        "radius": float(PLANET_RADIUS),
        "nside": NSIDE,                    # finest level (== nside_max)
        "chunk_export_depth": depth,       # log2(finest nside)
        "tile_res": TILE_RES,
        # Encodage des échantillons, row-major, normalisé [0,1] sur [elev_min, elev_max].
        "format": "u16_normalized" if SAMPLE_U16 else "r32_f32_normalized",
        # Pyramid descriptor. Runtime reads level n{nside} for a chunk whose own
        # nside is clamp(chunk_nside, nside_min, nside_max).
        "pyramid": True,
        "nside_min": int(min(levels)),
        "nside_max": int(max(levels)),
        "layout": "n{nside}/face_{face}/f{ipix}.r32",
        "elev_min": float(ELEV_MIN),
        "elev_max": float(ELEV_MAX),
        # Godot PlanetData round-trip: elev = pixel.r * max_height + height_offset
        "height_offset": float(ELEV_MIN),
        "max_height": float(elev_range),
        "count": total_tiles,
        # Empreinte des entrées : c'est elle qui invalide les caches de meshes et de
        # collision au prochain lancement. Voir compute_data_version().
        "data_version": compute_data_version(pts),
    }
    manifest["packed"] = True
    manifest["pack_file"] = "heights.pack"
    manifest_bytes = json.dumps(manifest, indent=2).encode("utf-8")
    manifest_path = os.path.join(chunks_dir, "manifest.json")
    with open(manifest_path, "wb") as f:
        f.write(manifest_bytes)

    # ── Step 3: stream all tiles into one dense heights.pack (DSHP v1) ──
    # Tile order matches height_pack.gd: levels ascending, ipix ascending, each
    # tile TILE_RES²·4 bytes → offset(nside, ipix) is pure arithmetic at runtime.
    # Each level independently samples the SAME smooth global raster, so all
    # levels agree on the underlying surface (minimal LOD popping) while a coarse
    # level's tile already represents the average shape over its larger footprint.
    pack_path = os.path.join(chunks_dir, "heights.pack")
    tmp_path = pack_path + ".tmp"
    print(f"  Writing pyramid levels {levels} = {total_tiles} tiles "
          f"({TILE_RES}×{TILE_RES} float32) → {pack_path}")

    def _sample_norm(level_nside, group):
        """Tuiles du groupe, en valeurs normalisées [0,1] sur [ELEV_MIN, ELEV_MAX]."""
        if tin is not None:
            # Sample the whole group in one TIN call — the KD-tree query and the
            # barycentric solve both amortise (8x faster than one call per tile).
            grids = [hpx.get_tile_grid_vec(level_nside, ip, TILE_RES) for ip in group]
            flat = tin.sample_vec(
                np.concatenate([g[0].ravel() for g in grids]),
                np.concatenate([g[1].ravel() for g in grids]),
                np.concatenate([g[2].ravel() for g in grids]))
            elevs = flat.reshape(len(grids), TILE_RES, TILE_RES)
        else:
            elevs = np.stack([
                _sample_equirect_bilinear(
                    raster, *hpx.get_tile_grid_lonlat(level_nside, ip, TILE_RES))
                for ip in group])
        return ((elevs - ELEV_MIN) / elev_range).astype(np.float32)

    def _loose_dir(level_nside):
        d = os.path.join(chunks_dir, f"n{level_nside}")
        for face in range(12):
            os.makedirs(os.path.join(d, f"face_{face}"), exist_ok=True)
        return d

    written, _tt = write_pack(
        tmp_path, chunks_dir, manifest_bytes, levels, total_tiles, elev_range,
        _sample_norm, _loose_dir if WRITE_LOOSE_TILES else None)
    os.replace(tmp_path, pack_path)
    pack_mb = os.path.getsize(pack_path) / (1 << 20)

    print("=" * 64)
    print(f"  ✓ Done. {written} tiles ({len(levels)} levels) → "
          f"heights.pack ({pack_mb:.1f} MB) + manifest.json")
    print(f"    chunks_dir : {chunks_dir}")
    print(f"    radius     : {PLANET_RADIUS} m")
    print(f"    pyramid    : n{min(levels)} … n{max(levels)}")
    print(f"    height_offset={ELEV_MIN}  max_height={elev_range}")
    print(f"    → Set PlanetData.chunk_heightmaps_dir to the chunks dir "
          f"(or load manifest.json).")
    print("=" * 64)


# Chronométrer depuis l'appel plutôt que dans run_export() : la fonction a
# plusieurs sorties anticipées (pas de couche, pas de points…) et on veut le
# temps total dans tous les cas.
_t0 = time.perf_counter()
try:
    run_export()
finally:
    _elapsed = time.perf_counter() - _t0
    _h, _rem = divmod(int(_elapsed), 3600)
    _m, _s = divmod(_rem, 60)
    print(f"  Temps total d'exécution : {_h:02d}h{_m:02d}m{_s:02d}s "
          f"({_elapsed:.1f} s)")
