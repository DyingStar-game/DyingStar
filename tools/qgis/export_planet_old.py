"""
QGIS Planet Export Script for StarDeception
============================================
Run this script in QGIS Python Console (Ctrl+Alt+P) or as a Processing script.

It exports all planet layers to GeoJSON + GeoTIFF heightmaps ready for Godot import.

Uses HEALPix (Hierarchical Equal Area isoLatitude Pixelisation) for chunk tiling.
12 base pixels, each subdivides into 4 children — natural hierarchical LOD.

Heightmaps are exported as GeoTIFF (Float32) for maximum precision.
Resolution target: <50m per pixel where contour data is available.

Usage in QGIS Python Console:
    exec(open('/path/to/StarDeception/tools/qgis/export_planet.py').read())

Or modify PLANET_NAME and EXPORT_DIR below, then run.
"""

import os
import sys
import json
import math
import gc
import time as _time_mod
import numpy as np
from pathlib import Path


# ============================================================
# MEMORY LOGGING — writes RSS/VMS snapshots to /tmp/qgis.log
# ============================================================
_MEMLOG_PATH = "/tmp/qgis.log"
_MEMLOG_START = _time_mod.time()


def _mem_rss_mb():
    """Return current RSS (Resident Set Size) in MB, reading /proc/self/status."""
    try:
        with open("/proc/self/status", "r") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) / 1024.0  # kB → MB
    except Exception:
        pass
    return -1.0


def _mem_vms_mb():
    """Return current VMS (Virtual Memory Size) in MB."""
    try:
        with open("/proc/self/status", "r") as f:
            for line in f:
                if line.startswith("VmSize:"):
                    return int(line.split()[1]) / 1024.0
    except Exception:
        pass
    return -1.0


def memlog(label, extra=""):
    """Write a timestamped memory snapshot line to /tmp/qgis.log and print it."""
    elapsed = _time_mod.time() - _MEMLOG_START
    rss = _mem_rss_mb()
    vms = _mem_vms_mb()
    msg = (f"[{elapsed:8.1f}s] MEMLOG | RSS={rss:10.1f} MB | "
           f"VMS={vms:10.1f} MB | {label}")
    if extra:
        msg += f" | {extra}"
    print(msg)
    try:
        with open(_MEMLOG_PATH, "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass


def memlog_objects(label):
    """Log memory + top object counts by type (expensive, use sparingly)."""
    gc.collect()
    rss = _mem_rss_mb()
    # Count objects by type
    type_counts = {}
    for obj in gc.get_objects():
        t = type(obj).__name__
        type_counts[t] = type_counts.get(t, 0) + 1
    top10 = sorted(type_counts.items(), key=lambda x: -x[1])[:10]
    top_str = ", ".join(f"{n}:{c}" for n, c in top10)
    memlog(label, f"gc_objects_top10=[{top_str}]")

# Add tools directory to path so we can import healpix_utils
_tools_dir = os.path.dirname(os.path.abspath(__file__))
if _tools_dir not in sys.path:
    sys.path.insert(0, _tools_dir)

import healpix_utils as hpx

from qgis.core import (
    QgsProject,
    QgsVectorLayer,
    QgsRasterLayer,
    QgsVectorFileWriter,
    QgsCoordinateReferenceSystem,
    QgsCoordinateTransform,
    QgsRectangle,
    QgsRasterPipe,
    QgsRasterFileWriter,
    QgsRasterProjector,
    Qgis,
    QgsExpressionContextUtils,
)
from qgis.utils import iface


# ============================================================
# CONFIGURATION — Edit these for your planet
# ============================================================
# Read planet_name and planet_radius from QGIS project variables
# (set by setup_planet_project.py). Fall back to hardcoded defaults.
_project = QgsProject.instance()
_proj_planet_name = QgsExpressionContextUtils.projectScope(_project).variable("planet_name")
_proj_planet_radius = QgsExpressionContextUtils.projectScope(_project).variable("planet_radius_m")

PLANET_NAME = str(_proj_planet_name) if _proj_planet_name else "tarsis_5"
PLANET_RADIUS = int(_proj_planet_radius) if _proj_planet_radius else 23097236  # meters
EXPORT_DIR = os.path.expanduser(
    "/datas/developpement/sources/DyingStar-game/DyingStar/assets/qgis/.export"
)

# Project root is three levels above EXPORT_DIR (…/DyingStar/assets/qgis/.export)
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(EXPORT_DIR)))

# Canonical fallback if no other method resolves the Godot binary. Keep in sync
# with .github/copilot-instructions.md.
_GODOT_BIN_FALLBACK = (
    "/datas/developpement/sources/godotengine/godot-build-scripts/releases/"
    "4.6.1-stable/mono/Godot_v4.6.1-stable_mono_linux_x86_64/"
    "Godot_v4.6.1-stable_mono_linux.x86_64"
)

# Raster export resolution (width x height in pixels)
# Equirectangular: width should be 2× height
HEIGHTMAP_SIZE = (4096, 2048)
BIOMEMAP_SIZE = (2048, 1024)

# Elevation range for heightmap normalization
# Set to None = auto-detect from contour data (recommended).
# Override with explicit values only if you need a custom range.
ELEV_MIN = None
ELEV_MAX = None

# Import the terrain_modifier classification from the catalogue
try:
    from setup_planet_project import BIOME_IS_TERRAIN_MODIFIER, BIOME_BY_NAME
except ImportError:
    # Fallback: if setup_planet_project is not importable, hardcode the set
    _TERRAIN_MODIFIER_BIOME_TYPES = {
        "spatial-crater", "icy-ice_crevasse", "icy-ice_pick",
        "volcanic_geothermal-ice_geyser",
        "volcanic_geothermal-mineral_thermal_source",
        "volcanic_geothermal-lava_dome",
        "maritime_river-river", "volcanic_geothermal-lava_river",
        "rocky_landform-pressure_canyon", "aride_desert-dry_river_bed",
    }
    BIOME_IS_TERRAIN_MODIFIER = {bt: (bt in _TERRAIN_MODIFIER_BIOME_TYPES)
                                  for bt in _TERRAIN_MODIFIER_BIOME_TYPES}
    BIOME_BY_NAME = {}


def _is_terrain_modifier(biome_type):
    """Return True if this biome modifies the chunk heightmap."""
    return BIOME_IS_TERRAIN_MODIFIER.get(biome_type, False)


def _biome_index_for_type(biome_type):
    """Return the numeric biome index for a biome_type string, or -1."""
    entry = BIOME_BY_NAME.get(biome_type)
    return entry[0] if entry else -1


def scan_elevation_range():
    """
    Scan all contour / elevation vector layers to find the actual
    min and max elevation values.  Sets the global ELEV_MIN / ELEV_MAX
    used by all heightmap functions.

    Called automatically at the start of run_export().  If no contour
    data is found, falls back to 0 .. 1000.
    """
    global ELEV_MIN, ELEV_MAX

    # If the user already set explicit values, keep them
    if ELEV_MIN is not None and ELEV_MAX is not None:
        print(f"  Using manually configured elevation range: "
              f"[{ELEV_MIN}, {ELEV_MAX}]m")
        return

    contour_layers = find_layers_by_keyword("contour") + find_layers_by_keyword(
        "elevation"
    )
    vector_layers = [l for l in contour_layers if isinstance(l, QgsVectorLayer)]

    all_elevations = []
    for layer in vector_layers:
        elev_field = None
        for field in layer.fields():
            if field.name().lower() in ("elev", "elevation", "height", "z", "alt"):
                elev_field = field.name()
                break
        if not elev_field:
            continue
        for feature in layer.getFeatures():
            val = feature[elev_field]
            if val is None:
                continue
            try:
                e = float(val)
            except (ValueError, TypeError):
                continue
            # Skip stub features created by setup_planet_project
            # (tiny geometries near 0,0 with default elevation 0)
            geom = feature.geometry()
            if geom and not geom.isNull():
                centroid = geom.centroid().asPoint()
                if abs(centroid.x()) < 0.01 and abs(centroid.y()) < 0.01 and e == 0.0:
                    continue
            all_elevations.append(e)

    if all_elevations:
        computed_min = min(all_elevations)
        computed_max = max(all_elevations)
        # Floor min to 0 if close to zero (sea-level convention)
        if computed_min >= 0:
            ELEV_MIN = 0.0
        else:
            ELEV_MIN = computed_min
        ELEV_MAX = computed_max
        print(f"  ✓ Auto-detected elevation range from {len(all_elevations)} values: "
              f"[{ELEV_MIN}, {ELEV_MAX}]m")
    else:
        ELEV_MIN = 0.0
        ELEV_MAX = 1000.0
        print(f"  ⚠ No contour data found — using default range [{ELEV_MIN}, {ELEV_MAX}]m")

    # ── Extend range to accommodate crater depths ──
    # Craters dig below the terrain surface; the deepest point depends on the
    # largest crater radius.  We scan biomes_point layers long before
    # stamp_craters_on_chunks() runs so that the 16-bit heightmaps have
    # enough dynamic range to encode the crater bottoms without clipping.
    point_layers = find_layers_by_keyword("biomes_point")
    point_layers = [l for l in point_layers if isinstance(l, QgsVectorLayer)]
    max_crater_radius = 0.0
    for layer in point_layers:
        has_btype = layer.fields().indexOf("biome_type") >= 0
        has_radius = layer.fields().indexOf("radius") >= 0
        if not has_btype:
            continue
        for feat in layer.getFeatures():
            if feat["biome_type"] != "spatial-crater":
                continue
            r = 185.0  # default radius
            if has_radius and feat["radius"] is not None:
                try:
                    r = float(feat["radius"])
                except (ValueError, TypeError):
                    pass
            if r > max_crater_radius:
                max_crater_radius = r

    if max_crater_radius > 0.0:
        max_crater_depth = _crater_depth_for_radius(max_crater_radius)
        old_min = ELEV_MIN
        ELEV_MIN = ELEV_MIN - max_crater_depth
        print(f"  ✓ Largest crater radius={max_crater_radius:.0f}m → "
              f"depth={max_crater_depth:.1f}m → ELEV_MIN adjusted "
              f"{old_min:.1f} → {ELEV_MIN:.1f}m")

# HEALPix chunk export.
# CHUNK_EXPORT_DEPTH controls the HEALPix N_side for exported tiles:
#   depth k → N_side = 2^k, total tiles = 12 × 4^k
#   depth 3 → N_side=8,   768 tiles
#   depth 4 → N_side=16,  3,072 tiles
#   depth 5 → N_side=32,  12,288 tiles
#   depth 6 → N_side=64,  49,152 tiles (good balance)
#   depth 7 → N_side=128, 196,608 tiles (high precision)
CHUNK_EXPORT_DEPTH = 6

# Heightmap tile resolution in pixels per edge
CHUNK_TILE_PX = 256

# Number of grid elevation samples per edge added to each recipe.
# These are sampled from the global heightmap raster to fill gaps
# in flat areas where contour vertices are sparse.
# 16 → 256 extra points per chunk (~6 KB).  Set to 0 to disable.
RECIPE_GRID_SAMPLES = 32

def compute_max_quadtree_depth(planet_radius, target_chunk_m=400.0):
    """
    Compute the max HEALPix depth so the finest LOD chunks are approximately
    *target_chunk_m* metres wide.

    HEALPix pixel side ≈ R × sqrt(π/3) / N_side
    N_side = 2^depth
    depth = ceil(log2(R × sqrt(π/3) / target))

    For R = 2,118,666 m, target = 400 m → depth ≈ 14 (pixel ≈ 405 m).
    """
    if planet_radius <= 0:
        return 6
    raw_nside = planet_radius * math.sqrt(math.pi / 3.0) / target_chunk_m
    depth = int(math.ceil(math.log2(max(raw_nside, 1))))
    return max(6, min(depth, 18))

# Dynamically computed max quadtree depth for this planet
MAX_QUADTREE_DEPTH = compute_max_quadtree_depth(PLANET_RADIUS)
# Corresponding N_side values
EXPORT_NSIDE = 2 ** min(MAX_QUADTREE_DEPTH, CHUNK_EXPORT_DEPTH)
MAX_NSIDE = 2 ** MAX_QUADTREE_DEPTH
print(f"  HEALPix: export N_side={EXPORT_NSIDE}, max N_side={MAX_NSIDE}, "
      f"max depth={MAX_QUADTREE_DEPTH}")


def ensure_dir(path):
    """Create directory if it doesn't exist."""
    os.makedirs(path, exist_ok=True)


def tif_to_png(tif_path, normalize_to_16bit=False):
    """
    Convert a GeoTIFF to a PNG that Godot can load natively.

    Parameters
    ----------
    tif_path : str
        Path to the input .tif file.
    normalize_to_16bit : bool
        If True, normalize Float32 elevation data to 16-bit greyscale PNG
        using ELEV_MIN / ELEV_MAX (for heightmaps).
        If False, convert pixel values directly to 8-bit (for biomemaps where
        pixel value = biome index).

    Returns the output .png path, or None on failure.
    """
    png_path = tif_path.replace(".tif", ".png")
    try:
        from osgeo import gdal
        ds = gdal.Open(tif_path)
        if ds is None:
            print(f"  ⚠ Cannot open {tif_path} for PNG conversion")
            return None

        band = ds.GetRasterBand(1)
        data = band.ReadAsArray()

        if normalize_to_16bit:
            # Heightmap: normalize [ELEV_MIN, ELEV_MAX] → [0, 65535] as 16-bit
            e_min = ELEV_MIN if ELEV_MIN is not None else float(np.nanmin(data))
            e_max = ELEV_MAX if ELEV_MAX is not None else float(np.nanmax(data))
            data_clipped = np.clip(data, e_min, e_max)
            if e_max > e_min:
                data_norm = (data_clipped - e_min) / (e_max - e_min)
            else:
                data_norm = np.zeros_like(data_clipped)
            data_16 = (data_norm * 65535).astype(np.uint16)

            try:
                from PIL import Image
                img = Image.fromarray(data_16, mode="I;16")
                img.save(png_path)
                print(f"  ✓ Heightmap PNG (16-bit): {png_path}")
                ds = None
                return png_path
            except ImportError:
                # Fallback: use GDAL Translate
                translate_opts = gdal.TranslateOptions(
                    format="PNG",
                    outputType=gdal.GDT_UInt16,
                    scaleParams=[[float(e_min), float(e_max), 0, 65535]],
                )
                gdal.Translate(png_path, ds, options=translate_opts)
                print(f"  ✓ Heightmap PNG (16-bit, GDAL): {png_path}")
                ds = None
                return png_path
        else:
            # Biomemap: biome index values (0-255), direct copy to 8-bit PNG
            translate_opts = gdal.TranslateOptions(
                format="PNG",
                outputType=gdal.GDT_Byte,
            )
            gdal.Translate(png_path, ds, options=translate_opts)
            print(f"  ✓ Biome PNG (8-bit): {png_path}")
            ds = None
            return png_path

    except ImportError:
        print("  ⚠ GDAL not available for TIF→PNG conversion")
        return None
    except Exception as e:
        print(f"  ⚠ TIF→PNG conversion failed: {e}")
        return None


def export_vector_layer_to_geojson(layer, output_path):
    """Export a QGIS vector layer to GeoJSON in EPSG:4326."""
    crs_4326 = QgsCoordinateReferenceSystem("EPSG:4326")

    options = QgsVectorFileWriter.SaveVectorOptions()
    options.driverName = "GeoJSON"
    options.ct = QgsCoordinateTransform(
        layer.crs(), crs_4326, QgsProject.instance()
    )

    error = QgsVectorFileWriter.writeAsVectorFormatV3(
        layer, output_path, QgsProject.instance().transformContext(), options
    )

    if error[0] == QgsVectorFileWriter.WriterError.NoError:
        print(f"  ✓ Exported: {output_path}")
    else:
        print(f"  ✗ Error exporting {layer.name()}: {error}")

    return error[0] == QgsVectorFileWriter.WriterError.NoError


def find_layers_by_keyword(keyword):
    """Find all layers whose name contains the keyword (case-insensitive)."""
    layers = []
    for layer_id, layer in QgsProject.instance().mapLayers().items():
        if keyword.lower() in layer.name().lower():
            layers.append(layer)
    return layers


def find_all_biome_layers():
    """
    Find all biome layers — both grouped (terrain, vegetation, liquid, linear,
    point) and individual (one layer per biome, identified by the 'biome_type'
    custom property).
    Returns a dict: { 'polygon': [...], 'line': [...], 'point': [...] }
    grouped by geometry type.
    """
    biome_keywords = ["biomes_terrain", "biomes_vegetation", "biomes_liquid",
                      "biomes_linear", "biomes_point"]
    result = {"polygon": [], "line": [], "point": []}
    seen_ids = set()

    def _add_layer(layer):
        if layer.id() in seen_ids:
            return
        seen_ids.add(layer.id())
        geom_type = layer.geometryType()
        if geom_type == 2:
            result["polygon"].append(layer)
        elif geom_type == 1:
            result["line"].append(layer)
        elif geom_type == 0:
            result["point"].append(layer)

    # Grouped biome layers
    for kw in biome_keywords:
        for layer in find_layers_by_keyword(kw):
            if isinstance(layer, QgsVectorLayer):
                _add_layer(layer)

    # Individual biome layers (have 'biome_type' custom property)
    for layer in QgsProject.instance().mapLayers().values():
        if not isinstance(layer, QgsVectorLayer):
            continue
        if layer.customProperty("biome_type"):
            _add_layer(layer)

    # Fallback: look for legacy single "_biomes" layer (backward compat)
    if not any(result.values()):
        for layer in find_layers_by_keyword("biome"):
            if isinstance(layer, QgsVectorLayer) and layer.geometryType() == 2:
                _add_layer(layer)
                break

    total = sum(len(v) for v in result.values())
    print(f"  Found {total} biome layer(s): "
          f"{len(result['polygon'])} polygon, "
          f"{len(result['line'])} line, "
          f"{len(result['point'])} point")
    return result


def merge_biome_layers_to_geojson(output_path):
    """
    Merge all biome layers into a single GeoJSON file.
    Line features are buffered by their 'width' field into polygons.
    Point features are buffered by their 'radius' field into circles.
    This produces a unified polygon GeoJSON that BiomeQuery can load.
    """
    import processing
    from qgis.core import (
        QgsFeature, QgsGeometry, QgsPointXY, QgsVectorFileWriter,
        QgsCoordinateTransform, QgsFields,
    )

    biome_layers = find_all_biome_layers()
    memlog("merge_biome_layers_to_geojson START")

    # Standard fields for the merged output
    STANDARD_FIELDS = ["biome_type", "biome_index", "color_hex",
                       "density", "tree_type", "depth", "width",
                       "radius", "intensity", "wave_intensity",
                       "canopy_height", "undergrowth",
                       "min_elevation", "max_elevation",
                       "flow_direction"]

    def _to_json_safe(val):
        """Convert a QGIS field value to a JSON-serializable Python type.
        QVariant(NULL) and similar non-native types are converted to None."""
        if val is None:
            return None
        # QVariant NULL check — PyQt wraps NULL as a special QVariant that
        # passes `is not None` but fails json serialization.
        try:
            from qgis.PyQt.QtCore import QVariant as _QV
            if isinstance(val, _QV) or (hasattr(val, 'isNull') and val.isNull()):
                return None
        except Exception:
            pass
        # Convert to native Python type
        if isinstance(val, (int, float, str, bool)):
            return val
        # Try common conversions
        try:
            # PyQt sometimes wraps ints/floats in QVariant
            if hasattr(val, 'value'):
                v = val.value()
                if isinstance(v, (int, float, str, bool)):
                    return v
        except Exception:
            pass
        # Last resort: stringify
        s = str(val)
        return None if s in ("NULL", "null", "") else s

    def extract_props(feat, layer):
        """Extract a normalized property dict from a feature.
        For individual biome layers, biome_type / biome_index / color_hex
        come from the layer's custom properties rather than feature fields."""
        props = {}
        # Individual biome layer: inject identity from custom properties
        layer_btype = layer.customProperty("biome_type")
        if layer_btype:
            props["biome_type"] = layer_btype
            bi = layer.customProperty("biome_index")
            props["biome_index"] = int(bi) if bi is not None else None
            props["color_hex"] = layer.customProperty("color_hex")
        for fn in STANDARD_FIELDS:
            if fn in props:
                continue  # already set from custom properties
            idx = layer.fields().indexOf(fn)
            if idx >= 0:
                val = feat[fn]
                props[fn] = _to_json_safe(val)
            # Don't add missing fields — they'll be null in GeoJSON
        # Also export any non-standard fields from the feature
        if layer_btype:
            for field in layer.fields():
                fn = field.name()
                if fn not in props and fn not in STANDARD_FIELDS:
                    props[fn] = _to_json_safe(feat[fn])
        return props

    def _write_feature_json(f, geom, props, is_first):
        """Serialize one feature and write directly to file, freeing memory immediately."""
        geom_json = json.loads(geom.asJson())
        feature = {
            "type": "Feature",
            "geometry": geom_json,
            "properties": props,
        }
        if not is_first:
            f.write(",")
        json.dump(feature, f, separators=(',', ':'))

    # ── Stream features directly to file ──
    # Instead of collecting millions of features in a list and then
    # serializing, we write each feature to the file as we go.
    # This keeps memory usage constant regardless of feature count.
    feature_count = 0
    m_per_deg = PLANET_RADIUS * math.pi / 180.0

    with open(output_path, "w") as f:
        # Write GeoJSON header
        f.write('{"type":"FeatureCollection",'
                '"crs":{"type":"name","properties":{"name":"EPSG:4326"}},'
                '"features":[')

        # ── Polygon layers: pass through as-is ──
        for layer in biome_layers["polygon"]:
            layer_count = 0
            for feat in layer.getFeatures():
                geom = feat.geometry()
                if geom.isEmpty():
                    continue
                props = extract_props(feat, layer)
                _write_feature_json(f, geom, props, feature_count == 0)
                feature_count += 1
                layer_count += 1
            print(f"    ✓ {layer.name()}: {layer_count} polygon(s)")
            memlog(f"merge_biome: polygon layer done",
                   f"layer={layer.name()} count={layer_count} total={feature_count}")

        # ── Line layers: buffer by width_start/width_end → polygon ──
        # Rivers/lava-rivers use progressive width (width_start → width_end).
        # The buffer polygon uses the max of the two so the biome polygon
        # fully covers the widest section.  Both values plus the original
        # centerline are stored in properties for runtime cross-section.
        for layer in biome_layers["line"]:
            buffered = 0
            has_ws = layer.fields().indexOf("width_start") >= 0
            has_we = layer.fields().indexOf("width_end") >= 0
            has_w = layer.fields().indexOf("width") >= 0
            for feat in layer.getFeatures():
                geom = feat.geometry()
                if geom.isEmpty():
                    continue
                # Read progressive width (metres).  Fall back to single
                # 'width' field or 100 m default for backward compat.
                width_start_m = 0.0
                width_end_m = 0.0
                if has_ws and feat["width_start"] is not None:
                    try:
                        ws = float(feat["width_start"])
                        if ws > 0:
                            width_start_m = ws
                    except (ValueError, TypeError):
                        pass
                if has_we and feat["width_end"] is not None:
                    try:
                        we = float(feat["width_end"])
                        if we > 0:
                            width_end_m = we
                    except (ValueError, TypeError):
                        pass
                # Legacy fallback: single 'width' field.
                if width_start_m <= 0.0 and width_end_m <= 0.0 and has_w:
                    w_raw = _to_json_safe(feat["width"])
                    if w_raw is not None:
                        w = float(w_raw)
                        if w > 0:
                            width_start_m = w
                            width_end_m = w
                if width_start_m <= 0.0 and width_end_m <= 0.0:
                    width_start_m = 100.0
                    width_end_m = 100.0
                # Buffer uses the max width so the polygon covers everything.
                max_width_m = max(width_start_m, width_end_m)
                width_deg = max_width_m / m_per_deg
                # Extract the original centerline before buffering.
                centerline = []
                if geom.isMultipart():
                    for part in geom.asMultiPolyline():
                        for pt in part:
                            centerline.append([pt.x(), pt.y()])
                else:
                    for pt in geom.asPolyline():
                        centerline.append([pt.x(), pt.y()])
                buffered_geom = geom.buffer(width_deg / 2.0, 8)  # 8 segments
                if buffered_geom.isEmpty():
                    continue
                props = extract_props(feat, layer)
                # Embed centerline and progressive width for runtime.
                props["centerline"] = centerline
                props["width_start"] = width_start_m
                props["width_end"] = width_end_m
                _write_feature_json(f, buffered_geom, props, feature_count == 0)
                feature_count += 1
                buffered += 1
            print(f"    ✓ {layer.name()}: {buffered} line(s) buffered to polygon")
            memlog(f"merge_biome: line layer done",
                   f"layer={layer.name()} count={buffered} total={feature_count}")

        # ── Point layers: buffer by 'radius' field → circle polygon ──
        # Radius is in METRES; convert to degrees for the buffer.
        # Crater points are skipped — their profiles are baked into chunk
        # heightmaps by stamp_craters_on_chunks(), so Godot doesn't need them.
        for layer in biome_layers["point"]:
            buffered = 0
            skipped_craters = 0
            for feat in layer.getFeatures():
                geom = feat.geometry()
                if geom.isEmpty():
                    continue
                # Crater points: emit as compact Point + radius property.
                # biome_query.gd stores these in flat PackedFloat32Arrays
                # (~50 bytes each) instead of 3 KB polygon zone Dictionaries.
                # biome_type is a layer custom property, not a per-feature field.
                layer_btype = layer.customProperty("biome_type")
                if layer_btype == "spatial-crater":
                    props = extract_props(feat, layer)
                    _write_feature_json(f, geom, props, feature_count == 0)
                    feature_count += 1
                    skipped_craters += 1
                    continue
                # Radius in metres. Default ~185 m.
                radius_idx = layer.fields().indexOf("radius")
                radius_m = 185.0
                if radius_idx >= 0:
                    r_raw = _to_json_safe(feat["radius"])
                    if r_raw is not None:
                        r = float(r_raw)
                        if r > 0:
                            radius_m = r
                radius_deg = radius_m / m_per_deg
                buffered_geom = geom.buffer(radius_deg, 16)  # 16 segments for circles
                if buffered_geom.isEmpty():
                    continue
                props = extract_props(feat, layer)
                _write_feature_json(f, buffered_geom, props, feature_count == 0)
                feature_count += 1
                buffered += 1
                # Log memory every 100K point features to track progression
                if (buffered + skipped_craters) % 100_000 == 0:
                    memlog(f"merge_biome: point layer progress",
                           f"layer={layer.name()} processed={buffered + skipped_craters} "
                           f"buffered={buffered} skipped={skipped_craters}")
            msg = f"    ✓ {layer.name()}: {buffered} point(s) buffered to polygon"
            if skipped_craters:
                msg += f" ({skipped_craters} craters emitted as compact Point+radius)"
            print(msg)
            memlog(f"merge_biome: point layer done",
                   f"layer={layer.name()} buffered={buffered} "
                   f"skipped={skipped_craters} total={feature_count}")

        # Close the features array and the FeatureCollection
        f.write("]}")

    memlog("merge_biome: file written", f"features={feature_count}")

    if feature_count == 0:
        print("  ⚠ No biome features found across any layer.")
        os.remove(output_path)
        return None

    print(f"  ✓ Merged biome GeoJSON: {output_path} ({feature_count} features)")
    return output_path


def get_merged_biome_polygon_layers():
    """
    Return all biome POLYGON layers (terrain, vegetation, liquid).
    Used by rasterization and color map which only need polygon geometry.
    For buffered line/point features, use merge_biome_layers_to_geojson().
    """
    biome_layers = find_all_biome_layers()
    return biome_layers["polygon"]


def merge_road_layers_to_geojson(output_path):
    """
    Export road LineString layers as buffered polygons with preserved
    centerlines, so Godot's BiomeQuery can load and render them.

    Each road feature becomes a Polygon with properties:
      - road_type, width, lanes, surface, name  (from QGIS layer)
      - centerline: [[lon, lat], ...]  (original LineString)
      - half_width_deg: precomputed for cross-section queries

    The detection polygon is WIDER than the visual road (3× half-width)
    so chunk-level bounding-box sampling reliably catches narrow trails.
    """
    from qgis.core import QgsFeature, QgsGeometry

    # Road half-widths per type (metres) — must match RoadTerrain.gd
    ROAD_HALF_WIDTHS = {
        "highway": 6.0,
        "road": 3.0,
        "path": 1.0,
        "trail": 0.5,
    }
    DETECTION_MULTIPLIER = 3.0

    road_layers = find_layers_by_keyword("road")
    road_layers = [l for l in road_layers
                   if isinstance(l, QgsVectorLayer) and l.geometryType() == 1]

    if not road_layers:
        print("  ⚠ No road LineString layers found. Skipping roads GeoJSON.")
        return None

    m_per_deg = PLANET_RADIUS * math.pi / 180.0
    all_features = []

    ROAD_FIELDS = ["name", "road_type", "width", "lanes", "surface",
                   "speed_limit", "has_sidewalk", "has_lighting"]

    def _to_safe(val):
        if val is None:
            return None
        try:
            from qgis.PyQt.QtCore import QVariant as _QV
            if isinstance(val, _QV) or (hasattr(val, 'isNull') and val.isNull()):
                return None
        except Exception:
            pass
        if isinstance(val, (int, float, str, bool)):
            return val
        s = str(val)
        return None if s in ("NULL", "null", "") else s

    for layer in road_layers:
        buffered_count = 0
        for feat in layer.getFeatures():
            geom = feat.geometry()
            if geom.isEmpty():
                continue

            # Extract properties
            props = {}
            for fn in ROAD_FIELDS:
                idx = layer.fields().indexOf(fn)
                if idx >= 0:
                    props[fn] = _to_safe(feat[fn])

            road_type = props.get("road_type", "trail") or "trail"

            # Determine half-width: use feature's width if set, else default
            hw_m = ROAD_HALF_WIDTHS.get(road_type, 0.5)
            width_val = props.get("width")
            if width_val is not None:
                w = float(width_val)
                if w > 0:
                    hw_m = w / 2.0

            # Extract original centerline
            centerline = []
            if geom.isMultipart():
                for part in geom.asMultiPolyline():
                    for pt in part:
                        centerline.append([pt.x(), pt.y()])
            else:
                for pt in geom.asPolyline():
                    centerline.append([pt.x(), pt.y()])

            if len(centerline) < 2:
                continue

            # Buffer to detection polygon (wider than visual)
            detection_hw_deg = (hw_m * DETECTION_MULTIPLIER) / m_per_deg
            buffered_geom = geom.buffer(detection_hw_deg, 8)
            if buffered_geom.isEmpty():
                continue

            props["centerline"] = centerline
            props["width"] = hw_m * 2.0  # full width in metres
            all_features.append({"geometry": buffered_geom, "properties": props})
            buffered_count += 1

        print(f"    ✓ {layer.name()}: {buffered_count} road(s) buffered to polygon")

    if not all_features:
        print("  ⚠ No road features found. Skipping roads GeoJSON.")
        return None

    geojson = {
        "type": "FeatureCollection",
        "crs": {"type": "name", "properties": {"name": "EPSG:4326"}},
        "features": [],
    }

    for item in all_features:
        geom_json = json.loads(item["geometry"].asJson())
        feature = {
            "type": "Feature",
            "geometry": geom_json,
            "properties": item["properties"],
        }
        geojson["features"].append(feature)

    with open(output_path, "w") as f:
        json.dump(geojson, f)

    print(f"  ✓ Merged roads GeoJSON: {output_path} ({len(all_features)} features)")
    return output_path


def export_all_vector_layers():
    """
    Export all relevant vector layers to GeoJSON.

    Biome layers are handled specially:
      - Each biome sub-layer is exported individually (for debugging).
      - A MERGED biome GeoJSON is produced where line/point features are
        buffered into polygons. This is what Godot's BiomeQuery loads.
    """
    ensure_dir(EXPORT_DIR)

    # ── 1. Export non-biome layers by keyword ──
    layer_map = {
        "elevation": f"{PLANET_NAME}_elevation.json",
        "contour": f"{PLANET_NAME}_elevation.json",
        "road": f"{PLANET_NAME}_roads.json",
        "poi": f"{PLANET_NAME}_poi.json",
        "city": f"{PLANET_NAME}_poi.json",
        "feature": f"{PLANET_NAME}_features.json",
    }

    exported = set()
    for keyword, filename in layer_map.items():
        if filename in exported:
            continue
        layers = find_layers_by_keyword(keyword)
        for layer in layers:
            if isinstance(layer, QgsVectorLayer):
                output = os.path.join(EXPORT_DIR, filename)
                if output not in exported:
                    export_vector_layer_to_geojson(layer, output)
                    exported.add(output)

    # ── 2. Export each biome sub-layer individually (for debugging / QGIS reload) ──
    # Skip layers with very large feature counts: those files would be too large
    # to split into git-friendly chunks and too expensive to load in memory.
    # Crater data is already stored per-chunk in the recipe JSON files.
    MAX_INDIVIDUAL_EXPORT_FEATURES = 100_000
    prefix = f"{PLANET_NAME}_"
    for layer_id, layer in QgsProject.instance().mapLayers().items():
        if isinstance(layer, QgsVectorLayer):
            fc = layer.featureCount()
            safe_name = layer.name().replace(" ", "_").lower()
            if safe_name.startswith(prefix):
                filename = f"{safe_name}.json"
            else:
                filename = f"{prefix}{safe_name}.json"
            output = os.path.join(EXPORT_DIR, filename)
            if output not in exported:
                if fc > MAX_INDIVIDUAL_EXPORT_FEATURES:
                    print(f"    ⚠ Skipping {layer.name()}: {fc} features "
                          f"(> {MAX_INDIVIDUAL_EXPORT_FEATURES} limit — "
                          f"crater data is embedded in chunk recipes)")
                    exported.add(output)
                    continue
                export_vector_layer_to_geojson(layer, output)
                exported.add(output)

    # ── 3. Biome merge — SKIPPED (biome data is now in recipes) ──
    # The merged biomes GeoJSON is no longer needed: populate_zones are
    # embedded directly in each chunk recipe (v7+).
    # Uncomment for manual verification against the recipe data:
    # memlog("export_vectors: before biome merge")
    # merged_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_biomes.json")
    # print(f"\n  Merging all biome layers into {os.path.basename(merged_path)}...")
    # merge_biome_layers_to_geojson(merged_path)
    # exported.add(merged_path)

    # ── 4. Merge road layers into buffered polygon GeoJSON ──
    memlog("export_vectors: before road merge")
    # Roads are buffered from LineStrings into polygons with centerlines
    # preserved, so Godot's road overlay system can render them.
    roads_merged_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_roads_buffered.json")
    print(f"\n  Merging road layers into {os.path.basename(roads_merged_path)}...")
    merge_road_layers_to_geojson(roads_merged_path)
    exported.add(roads_merged_path)

    print(f"\nExported {len(exported)} file(s) to {EXPORT_DIR}")


def generate_heightmap_from_contours():
    """
    Generate a heightmap GeoTIFF from contour lines.

    Instead of using QGIS's built-in TIN interpolation (which freezes the GUI
    on large rasters), this extracts vertices directly from contour features
    and interpolates with scipy (fast Delaunay) or a numpy IDW fallback.
    """
    contour_layers = find_layers_by_keyword("contour") + find_layers_by_keyword(
        "elevation"
    )

    vector_layers = [l for l in contour_layers if isinstance(l, QgsVectorLayer)]
    if not vector_layers:
        print("  ⚠ No contour/elevation vector layer found. Skipping heightmap.")
        return None

    layer = vector_layers[0]

    # Find the elevation field
    elev_field = None
    for field in layer.fields():
        if field.name().lower() in ("elev", "elevation", "height", "z", "alt"):
            elev_field = field.name()
            break

    if not elev_field:
        print(
            f"  ⚠ No elevation field found in {layer.name()}. "
            f"Available: {[f.name() for f in layer.fields()]}"
        )
        return None

    # ── Extract all vertices with elevation from contour features ──
    print(f"  Extracting vertices from '{layer.name()}' field '{elev_field}'...")
    points = []  # list of (lon, lat, elev)
    for feature in layer.getFeatures():
        elev = feature[elev_field]
        if elev is None:
            continue
        elev = float(elev)
        geom = feature.geometry()
        if geom is None or geom.isNull():
            continue
        # Skip stub features from setup_planet_project
        centroid = geom.centroid().asPoint()
        if abs(centroid.x()) < 0.01 and abs(centroid.y()) < 0.01 and elev == 0.0:
            continue
        for vertex in geom.vertices():
            points.append((vertex.x(), vertex.y(), elev))

    if not points:
        print("  ⚠ No vertices with elevation found. Skipping heightmap.")
        return None

    MIN_POINTS_FOR_TRIANGULATION = 4
    if len(points) < MIN_POINTS_FOR_TRIANGULATION:
        print(f"  ⚠ Only {len(points)} contour vertices found "
              f"(need ≥ {MIN_POINTS_FOR_TRIANGULATION} for interpolation). "
              f"Draw more contour lines in QGIS before exporting.")
        return None

    pts = np.array(points, dtype=np.float64)  # shape (N, 3)
    del points  # free the Python list, numpy array is sufficient
    memlog("heightmap: contour vertices extracted", f"count={len(pts)}")
    print(f"  {len(pts)} vertices, elevation range "
          f"[{pts[:, 2].min():.1f}, {pts[:, 2].max():.1f}]m")

    output_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_heightmap.tif")
    w, h = HEIGHTMAP_SIZE

    # ── Decimate redundant contour vertices ──
    # Contour lines from QGIS are densely sampled along curves (often
    # millions of vertices). Feeding them all to scipy.griddata triggers
    # a Delaunay triangulation that stalls for hours past ~500K points.
    # We adaptively bin source points to coarser grids until the count
    # drops below the safe Delaunay budget, preserving mean elevation
    # per bin so quality loss is negligible at the output resolution.
    DECIMATION_THRESHOLD = 500_000
    if len(pts) > DECIMATION_THRESHOLD:
        # Start at 4× the output resolution and halve until under budget
        oversample = 4
        decimated = pts
        while len(decimated) > DECIMATION_THRESHOLD and oversample >= 1:
            bin_w = max(w * oversample, 1)
            bin_h = max(h * oversample, 1)
            src = decimated if decimated is not pts else pts
            col_idx = np.clip(
                ((src[:, 0] + 180.0) * (bin_w / 360.0)).astype(np.int64),
                0, bin_w - 1,
            )
            row_idx = np.clip(
                ((90.0 - src[:, 1]) * (bin_h / 180.0)).astype(np.int64),
                0, bin_h - 1,
            )
            flat_bin = row_idx * bin_w + col_idx
            sums = np.bincount(flat_bin, weights=src[:, 2])
            counts = np.bincount(flat_bin)
            occupied = np.nonzero(counts)[0]
            mean_elev = sums[occupied] / counts[occupied]
            bin_row = occupied // bin_w
            bin_col = occupied % bin_w
            bin_lon = -180.0 + (bin_col + 0.5) * (360.0 / bin_w)
            bin_lat = 90.0 - (bin_row + 0.5) * (180.0 / bin_h)
            decimated = np.column_stack([bin_lon, bin_lat, mean_elev])
            print(f"  Decimation pass (oversample={oversample}): "
                  f"{len(src)} → {len(decimated)} vertices "
                  f"(bin grid {bin_w}×{bin_h})")
            del sums, counts, occupied, bin_row, bin_col, bin_lon, bin_lat
            del mean_elev, flat_bin, col_idx, row_idx
            oversample //= 2
        # If still above budget at oversample=1 (output resolution), halve
        # the bin grid further until we fit.
        coarsen = 2
        while len(decimated) > DECIMATION_THRESHOLD:
            bin_w = max(w // coarsen, 64)
            bin_h = max(h // coarsen, 32)
            col_idx = np.clip(
                ((decimated[:, 0] + 180.0) * (bin_w / 360.0)).astype(np.int64),
                0, bin_w - 1,
            )
            row_idx = np.clip(
                ((90.0 - decimated[:, 1]) * (bin_h / 180.0)).astype(np.int64),
                0, bin_h - 1,
            )
            flat_bin = row_idx * bin_w + col_idx
            sums = np.bincount(flat_bin, weights=decimated[:, 2])
            counts = np.bincount(flat_bin)
            occupied = np.nonzero(counts)[0]
            mean_elev = sums[occupied] / counts[occupied]
            bin_row = occupied // bin_w
            bin_col = occupied % bin_w
            bin_lon = -180.0 + (bin_col + 0.5) * (360.0 / bin_w)
            bin_lat = 90.0 - (bin_row + 0.5) * (180.0 / bin_h)
            decimated = np.column_stack([bin_lon, bin_lat, mean_elev])
            print(f"  Decimation pass (coarsen=1/{coarsen}): "
                  f"→ {len(decimated)} vertices (bin grid {bin_w}×{bin_h})")
            del sums, counts, occupied, bin_row, bin_col, bin_lon, bin_lat
            del mean_elev, flat_bin, col_idx, row_idx
            coarsen *= 2
            if bin_w <= 64:
                break  # safety: stop shrinking
        print(f"  ✓ Final: {len(pts)} → {len(decimated)} vertices")
        del pts
        pts = decimated
        memlog("heightmap: decimation done", f"count={len(pts)}")

    # Build output grid (pixel centres)
    lon_vals = np.linspace(-180.0, 180.0, w, endpoint=False) + (360.0 / w / 2.0)
    lat_vals = np.linspace(90.0, -90.0, h, endpoint=False) - (180.0 / h / 2.0)
    grid_lon, grid_lat = np.meshgrid(lon_vals, lat_vals)  # both (h, w)

    grid_data = None
    import time as _time
    _t0 = _time.time()
    memlog("heightmap: before interpolation", f"grid={w}x{h} verts={len(pts)}")

    # ── Method 1: Rasterize → fill gaps → upsample ──
    # Instead of Delaunay triangulation (which stalls on large point sets),
    # we rasterize the decimated points onto a coarse grid matching the last
    # decimation bin size, fill empty cells with nearest-neighbor diffusion,
    # then upsample to the output resolution with bilinear interpolation.
    # This is O(N + output_pixels) and completes in seconds regardless of N.
    try:
        from scipy.ndimage import zoom as ndimage_zoom, distance_transform_edt
        # Rasterize pts onto a coarse grid
        # Choose coarse grid so it covers all pts with minimal empty cells.
        # Use a grid that matches the output aspect ratio but is small enough
        # that most cells are occupied by at least one point.
        coarse_w = min(w, max(256, int(np.sqrt(len(pts) * (w / h)))))
        coarse_h = min(h, max(128, int(np.sqrt(len(pts) * (h / w)))))
        print(f"  Rasterizing {len(pts)} vertices onto {coarse_w}×{coarse_h} "
              f"coarse grid...")

        # Map (lon, lat) → pixel indices
        col_idx = np.clip(
            ((pts[:, 0] + 180.0) * (coarse_w / 360.0)).astype(np.int64),
            0, coarse_w - 1,
        )
        row_idx = np.clip(
            ((90.0 - pts[:, 1]) * (coarse_h / 180.0)).astype(np.int64),
            0, coarse_h - 1,
        )
        flat_idx = row_idx * coarse_w + col_idx
        # Mean elevation per cell
        sums = np.bincount(flat_idx, weights=pts[:, 2],
                           minlength=coarse_h * coarse_w)
        counts = np.bincount(flat_idx, minlength=coarse_h * coarse_w)
        coarse = np.zeros(coarse_h * coarse_w, dtype=np.float64)
        mask_occupied = counts > 0
        coarse[mask_occupied] = sums[mask_occupied] / counts[mask_occupied]
        coarse = coarse.reshape(coarse_h, coarse_w)
        mask_empty = ~mask_occupied.reshape(coarse_h, coarse_w)

        occupied_pct = 100.0 * mask_occupied.sum() / mask_occupied.size
        print(f"  Coarse grid: {occupied_pct:.1f}% cells occupied, "
              f"filling {mask_empty.sum()} empty cells...")

        # Fill empty cells: for each empty cell, copy value from nearest
        # occupied cell (using distance transform for indexing).
        if mask_empty.any():
            # distance_transform_edt returns distances and indices of
            # nearest background (=0) cell. We invert: mark empty as 1.
            _, nearest_idx = distance_transform_edt(
                mask_empty, return_distances=True, return_indices=True
            )
            coarse[mask_empty] = coarse[
                nearest_idx[0][mask_empty], nearest_idx[1][mask_empty]
            ]

        # Upsample to output resolution with bilinear interpolation
        zoom_y = h / coarse_h
        zoom_x = w / coarse_w
        print(f"  Upsampling {coarse_w}×{coarse_h} → {w}×{h} "
              f"(bilinear zoom {zoom_x:.1f}×{zoom_y:.1f})...")
        grid_data = ndimage_zoom(coarse, (zoom_y, zoom_x),
                                 order=1).astype(np.float32)
        # Ensure exact output shape (zoom can be off by 1 pixel)
        if grid_data.shape != (h, w):
            tmp = np.zeros((h, w), dtype=np.float32)
            sh = min(grid_data.shape[0], h)
            sw = min(grid_data.shape[1], w)
            tmp[:sh, :sw] = grid_data[:sh, :sw]
            grid_data = tmp
        memlog("heightmap: rasterize+fill+upsample done")
        print(f"  ✓ Heightmap interpolation complete ({_time.time() - _t0:.1f}s)")
    except ImportError:
        print("  ⚠ scipy.ndimage not available, trying griddata fallback...")

    # ── Method 2: scipy linear interpolation (Delaunay) ──
    # Fallback if scipy.ndimage is unavailable. Works well for <500K points.
    if grid_data is None:
        try:
            from scipy.interpolate import griddata as scipy_griddata
            print(f"  Interpolating {w}×{h} grid with scipy linear "
                  f"({len(pts)} source vertices)...")
            grid_data = scipy_griddata(
                pts[:, :2],   # (lon, lat) source points
                pts[:, 2],    # elevation values
                (grid_lon, grid_lat),
                method='linear',
                fill_value=0.0,
            ).astype(np.float32)
            memlog("heightmap: scipy interpolation done")
            print(f"  ✓ scipy interpolation complete ({_time.time() - _t0:.1f}s)")
        except ImportError:
            print("  ⚠ scipy not available, falling back to KD-tree IDW...")

    # ── Method 2: KD-tree IDW (no scipy.interpolate, but scipy.spatial) ──
    # Uses a KD-tree for fast nearest-neighbor lookups instead of brute-force.
    # O(M × K × log N) where K is the number of neighbors used.
    if grid_data is None:
        try:
            from scipy.spatial import cKDTree
            print(f"  Interpolating {w}×{h} grid with KD-tree IDW "
                  f"({len(pts)} source vertices, k=12)...")
            K = min(12, len(pts))  # number of nearest neighbors
            tree = cKDTree(pts[:, :2])
            grid_pts = np.column_stack([grid_lon.ravel(), grid_lat.ravel()])
            # Query in batches to limit memory usage
            batch_size = 500_000
            flat_result = np.zeros(grid_pts.shape[0], dtype=np.float64)
            for b_start in range(0, len(flat_result), batch_size):
                b_end = min(b_start + batch_size, len(flat_result))
                dists, idxs = tree.query(grid_pts[b_start:b_end], k=K)
                # IDW with squared distance
                weights = 1.0 / np.maximum(dists ** 2, 1e-12)  # (batch, K)
                values = pts[idxs, 2]  # (batch, K)
                flat_result[b_start:b_end] = (
                    np.sum(weights * values, axis=1) /
                    np.sum(weights, axis=1)
                )
                if b_start % (batch_size * 4) == 0 and b_start > 0:
                    print(f"    {b_start}/{len(flat_result)} pixels...")
            grid_data = flat_result.reshape(h, w).astype(np.float32)
            print(f"  ✓ KD-tree IDW interpolation complete ({_time.time() - _t0:.1f}s)")
        except ImportError:
            pass

    # ── Method 3: pure numpy IDW fallback (last resort, no scipy at all) ──
    # Processes in row batches to cap memory, still viable for <5K vertices.
    if grid_data is None:
        print(f"  Interpolating {w}×{h} grid with numpy IDW "
              f"({len(pts)} source vertices)...")
        grid_data = np.zeros((h, w), dtype=np.float32)
        src_lon = pts[:, 0]  # (N,)
        src_lat = pts[:, 1]
        src_elev = pts[:, 2]
        for row in range(h):
            dlat = grid_lat[row, 0] - src_lat          # (N,)
            dlon = grid_lon[row, :, np.newaxis] - src_lon  # (w, N)
            dist_sq = np.maximum(dlon ** 2 + dlat ** 2, 1e-12)
            weights = 1.0 / dist_sq                     # (w, N)
            grid_data[row, :] = (
                np.sum(weights * src_elev, axis=1) /
                np.sum(weights, axis=1)
            )
            if row % 500 == 0:
                print(f"    row {row}/{h}...")
        print(f"  ✓ numpy IDW interpolation complete ({_time.time() - _t0:.1f}s)")

    # ── Save as GeoTIFF ──
    try:
        from osgeo import gdal, osr
        driver = gdal.GetDriverByName('GTiff')
        out_ds = driver.Create(output_path, w, h, 1, gdal.GDT_Float32)
        # GeoTransform: (origin_lon, pixel_width, 0, origin_lat, 0, -pixel_height)
        pixel_w = 360.0 / w
        pixel_h = 180.0 / h
        out_ds.SetGeoTransform((-180.0, pixel_w, 0.0, 90.0, 0.0, -pixel_h))
        srs = osr.SpatialReference()
        srs.ImportFromEPSG(4326)
        out_ds.SetProjection(srs.ExportToWkt())
        out_ds.GetRasterBand(1).WriteArray(grid_data)
        out_ds.FlushCache()
        out_ds = None
        print(f"  ✓ Heightmap saved: {output_path}")
        print(f"    Data range: [{np.nanmin(grid_data):.2f}, {np.nanmax(grid_data):.2f}]")
        return output_path
    except ImportError:
        # Fallback: save as raw numpy array (less ideal)
        npy_path = output_path.replace('.tif', '.npy')
        np.save(npy_path, grid_data)
        print(f"  ✓ Heightmap saved (numpy): {npy_path}")
        return npy_path


def generate_biome_raster():
    """
    Rasterize biome polygons into a biome index image.
    R channel = biome_index (0-255), normalized.

    Reads from ALL polygon biome layers (terrain, vegetation, liquid).
    For line/point biome layers, uses the merged GeoJSON which contains
    already-buffered polygon geometries.
    """
    import processing

    # Try to use the merged GeoJSON (includes buffered lines + points)
    merged_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_biomes.json")
    if os.path.exists(merged_path):
        layer = QgsVectorLayer(merged_path, "merged_biomes_raster", "ogr")
        if layer.isValid():
            print(f"  Using merged biome GeoJSON for rasterization ({layer.featureCount()} features)")
        else:
            layer = None
    else:
        layer = None

    # Fallback: use polygon biome layers directly (no buffered lines/points)
    if layer is None:
        polygon_layers = get_merged_biome_polygon_layers()
        if not polygon_layers:
            # Legacy fallback: single "_biomes" layer
            biome_layers = find_layers_by_keyword("biome")
            polygon_layers = [l for l in biome_layers
                              if isinstance(l, QgsVectorLayer) and l.geometryType() == 2]
        if not polygon_layers:
            print("  ⚠ No biome layer found. Skipping biome raster.")
            return None
        layer = polygon_layers[0]
        if len(polygon_layers) > 1:
            print(f"  ⚠ Multiple polygon biome layers found, using first: {layer.name()}")
            print(f"    (Run the merge step first for best results)")

    # Find biome_index field
    index_field = None
    for field in layer.fields():
        if field.name().lower() in ("biome_index", "index", "biome_id", "type_id"):
            index_field = field.name()
            break

    if not index_field:
        print(
            f"  ⚠ No biome_index field in {layer.name()}. "
            f"Will use feature ID instead."
        )

    output_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_biomemap.tif")

    try:
        params = {
            "INPUT": layer,
            "FIELD": index_field if index_field else "",
            "BURN": 0 if index_field else 1,
            "UNITS": 1,  # Pixels
            "WIDTH": BIOMEMAP_SIZE[0],
            "HEIGHT": BIOMEMAP_SIZE[1],
            "EXTENT": "-180,180,-90,90",
            "OUTPUT": output_path,
            "NODATA": 255,
        }
        result = processing.run("gdal:rasterize", params)
        print(f"  ✓ Biome map saved: {output_path}")
        return output_path
    except Exception as e:
        print(f"  ✗ Biome rasterization failed: {e}")
        return None


def generate_color_map():
    """
    Generate a low-res color map for ultra-far LOD (LOD4).
    Each pixel = dominant biome color at that lat/lon.
    Output: 512×256 RGB PNG

    Uses a QgsSpatialIndex for fast point-in-polygon lookup instead of
    iterating all features per pixel.

    Fallback behaviour when no polygon biomes exist:
      1. Also rasterise point biomes (buffered by 'radius' metres) and line
         biomes (buffered by 'width' metres) so arid/rocky planets with only
         scatter spawners still show surface variation from orbit.
      2. Pick the canvas fill colour from, in order of priority:
           a. QGIS project variable  `colormap_base_color`  (hex "#rrggbb")
           b. The dominant feature colour across all buffered layers
           c. A neutral rocky brown (90, 80, 72) — never ocean blue, which
              is misleading for non-aquatic worlds.
    """
    # Prefer merged GeoJSON (includes buffered line/point biomes)
    merged_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_biomes.json")
    merged_layer = None
    if os.path.exists(merged_path):
        candidate = QgsVectorLayer(merged_path, "merged_biomes_colormap", "ogr")
        if candidate.isValid() and candidate.featureCount() > 0:
            merged_layer = candidate
            print(f"  Using merged biome GeoJSON for color map ({merged_layer.featureCount()} features)")

    width, height = 512, 256
    output_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_colormap.png")

    # Default biome colors (full catalogue)
    default_colors = {
        # Terrestrial / Earth-like
        "maritime_river-ocean": (26, 82, 118),
        "ocean": (26, 82, 118),  # legacy alias
        "maritime_river-lake": (52, 152, 219),
        "lake": (52, 152, 219),  # legacy alias
        "maritime_river-delta": (26, 110, 92),
        "river_delta": (26, 110, 92),  # legacy alias
        "maritime_river-beach": (240, 217, 160),
        "beach": (240, 217, 160),  # legacy alias
        "aride_desert-sandy_desert": (212, 164, 55),
        "desert_sandy": (212, 164, 55),  # legacy alias
        "aride_desert-rocky_desert": (160, 116, 79),
        "desert_rocky": (160, 116, 79),  # legacy alias
        "aride_desert-salt_desert": (232, 220, 200),
        "desert_salt": (232, 220, 200),  # legacy alias
        "meadow_steppe-meadow": (125, 174, 82),
        "grassland": (125, 174, 82),  # legacy alias
        "meadow_steppe-savanna": (184, 168, 74),
        "savanna": (184, 168, 74),  # legacy alias
        "meadow_steppe-steppe": (156, 160, 86),
        "steppe": (156, 160, 86),  # legacy alias
        "forest-temperate_forest": (45, 90, 30),
        "forest_temperate": (45, 90, 30),  # legacy alias
        "forest-boreal_forest": (30, 74, 42),
        "forest_boreal": (30, 74, 42),  # legacy alias
        "forest-tropical_forest": (26, 90, 16),
        "forest_tropical": (26, 90, 16),  # legacy alias
        "forest-dead_forest": (92, 74, 58),
        "forest_dead": (92, 74, 58),  # legacy alias
        # "jungle" has been deleted
        "wetland-swamp": (74, 103, 65),
        "swamp": (74, 103, 65),  # legacy alias
        "wetland-mangrove": (58, 90, 48),
        "mangrove": (58, 90, 48),  # legacy alias
        "wetland-bog": (90, 106, 74),
        "bog": (90, 106, 74),  # legacy alias
        "icy-tundra": (143, 168, 181),
        "tundra": (143, 168, 181),  # legacy alias
        "icy-snow": (232, 234, 237),
        "snow": (232, 234, 237),  # legacy alias
        "icy-glacier": (200, 224, 240),
        "glacier": (200, 224, 240),  # legacy alias
        "rocky_landform-raw_mountain": (122, 122, 122),
        "mountain_bare": (122, 122, 122),  # legacy alias
        "rocky_landform-alpine_mountain": (106, 138, 90),
        "mountain_alpine": (106, 138, 90),  # legacy alias
        "rocky_landform-cliff": (110, 110, 110),
        "cliff": (110, 110, 110),  # legacy alias
        "rocky_landform-canyon": (138, 90, 58),
        "canyon": (138, 90, 58),  # legacy alias
        # Volcanic / Geothermal
        "volcanic_geothermal-active_volcano": (74, 44, 42),
        "volcanic_active": (74, 44, 42),  # legacy alias
        "volcanic_geothermal-volcanic_basalt": (42, 42, 42),
        "volcanic_basalt": (42, 42, 42),  # legacy alias
        "volcanic_geothermal-lava_field": (26, 10, 10),
        "lava_field": (26, 10, 10),  # legacy alias
        "volcanic_geothermal-lava_lake": (204, 51, 0),
        "lava_lake": (204, 51, 0),  # legacy alias
        "volcanic_geothermal-fumarole": (138, 122, 90),
        "fumarole": (138, 122, 90),  # legacy alias
        "volcanic_geothermal-geothermal": (106, 138, 106),
        "geothermal": (106, 138, 106),  # legacy alias
        "volcanic_geothermal-obsidian_field": (10, 10, 26),
        "obsidian_field": (10, 10, 26),  # legacy alias
        "volcanic_geothermal-ash_desert": (74, 74, 74),
        "ash_wasteland": (74, 74, 74),  # legacy alias
        "volcanic_geothermal-magmatic_crust": (58, 26, 10),
        "magma_crust": (58, 26, 10),  # legacy alias
        # Barren / Lunar / Airless
        "spatial-lunar_ground": (170, 170, 170),
        "regolith": (170, 170, 170),  # legacy alias (merged into spatial-lunar_ground)
        "highland_lunar": (170, 170, 170),  # legacy alias (merged into spatial-lunar_ground)
        "spatial-crater": (128, 128, 112),
        "crater": (128, 128, 112),  # legacy alias
        "spatial-lunar_pool": (74, 74, 90),
        "mare": (74, 74, 90),  # legacy alias
        "aride_desert-dusty_plain": (176, 168, 144),
        "dust_plain": (176, 168, 144),  # legacy alias
        # Cryo / Ice Worlds
        "icy-ice_plain": (208, 232, 240),
        "ice_plain": (208, 232, 240),  # legacy alias
        "icy-ice_crevasse": (144, 184, 208),
        "ice_crevasse": (144, 184, 208),  # legacy alias
        "icy-ice_pick": (192, 216, 232),
        "ice_spire": (192, 216, 232),  # legacy alias
        "icy-nitrogen_ice": (224, 232, 240),
        "nitrogen_ice": (224, 232, 240),  # legacy alias
        "icy-methane_lake": (42, 74, 106),
        "methane_lake": (42, 74, 106),  # legacy alias
        "icy-hydrocarbon_dune": (90, 74, 58),
        "methane_dune": (90, 74, 58),  # legacy alias
        "icy-cryovolcanic": (176, 200, 216),
        "cryovolcanic": (176, 200, 216),  # legacy alias
        "icy-frozen_ocean": (138, 176, 200),
        "frozen_ocean": (138, 176, 200),  # legacy alias
        "icy-sublimation_pit": (200, 216, 224),
        "sublimation_pit": (200, 216, 224),  # legacy alias
        "icy-permafrost": (138, 154, 138),
        "permafrost": (138, 154, 138),  # legacy alias
        "volcanic_geothermal-ice_geyser": (216, 232, 248),
        "ice_geyser": (216, 232, 248),  # legacy alias
        # Martian / Arid Rocky
        "aride_desert-iron_desert": (192, 96, 58),
        "iron_desert": (192, 96, 58),  # legacy alias
        # dust_storm removed (biome 55 deleted)
        "aride_desert-dry_river_bed": (138, 122, 90),
        "dry_riverbed": (138, 122, 90),  # legacy alias
        # polar_cap removed (biome 57 deleted)
        # ventifact removed (biome 58 deleted)
        # Dense Atmosphere
        # cloud_deck removed (biome 59 deleted)
        # acid_rain removed (biome 60 deleted)
        "rocky_landform-pressure_canyon": (74, 58, 42),
        "pressure_canyon": (74, 58, 42),  # legacy alias
        "liquid_hydrocarbon_areas": (58, 90, 122),
        "supercritical_fluid": (58, 90, 122),  # legacy alias
        # Toxic / Exotic Chemistry
        "meadow_steppe-sulfur_plain": (200, 192, 48),
        "sulfur_plain": (200, 192, 48),  # legacy alias
        "volcanic_geothermal-sulfur_volcano": (184, 160, 32),
        "sulfur_volcano": (184, 160, 32),  # legacy alias
        "maritime_river-acid_lake": (128, 160, 48),
        "acid_lake": (128, 160, 48),  # legacy alias
        "wetland-ammonia_swamp": (96, 128, 160),
        "ammonia_marsh": (96, 128, 160),  # legacy alias
        "meadow_steppe-chlorinated_field": (128, 192, 96),
        "chlorine_flat": (128, 192, 96),  # legacy alias
        "radioactive_waste": (80, 160, 80),
        "tar_basin": (26, 26, 26),
        "tar_pit": (26, 26, 26),  # legacy alias
        "brine_basin": (74, 122, 122),
        "brine_pool": (74, 122, 122),  # legacy alias
        # Crystalline / Mineral
        "crystalline-crystalline_fields": (160, 192, 224),
        "crystal_field": (160, 192, 224),  # legacy alias
        "aride_desert-metal_plain": (138, 138, 154),
        "metal_plain": (138, 138, 154),  # legacy alias
        "rocky_landform-cave": (112, 80, 160),
        "gemstone_cave": (112, 80, 160),  # legacy alias
        "crystalline-quartz_desert": (208, 200, 184),
        "quartz_desert": (208, 200, 184),  # legacy alias
        "volcanic_geothermal-mineral_thermal_source": (80, 176, 160),
        "mineral_hot_spring": (80, 176, 160),  # legacy alias
        "crystalline-salt_crystal_field": (224, 216, 200),
        "salt_crystal_field": (224, 216, 200),  # legacy alias
        # Artificial / Processed
        "meadow_steppe-terraformed_grass": (96, 192, 64),
        "terraformed_grass": (96, 192, 64),  # legacy alias
        "forest-terraformed_forest": (32, 128, 32),
        "terraformed_forest": (32, 128, 32),  # legacy alias
        "urban-mining_excavation": (90, 74, 58),
        "mining_excavation": (90, 74, 58),  # legacy alias
        "urban-ruins": (106, 96, 96),
        "ruins": (106, 96, 96),  # legacy alias
        "urban-urban": (112, 112, 112),
        "urban": (112, 112, 112),  # legacy alias
        "meadow_steppe-agriculture_land": (160, 192, 64),
        "agriculture": (160, 192, 64),  # legacy alias
        "urban-landing_pad": (80, 80, 80),
        "landing_pad": (80, 80, 80),  # legacy alias
        "meadow_steppe-wasteland_irradiated": (74, 90, 58),
        "wasteland_irradiated": (74, 90, 58),  # legacy alias
        "rocky_landform-mining_cave": (138, 106, 74),
        # River (line-based, auto-buffered to polygon)
        "maritime_river-river": (36, 113, 163),
        "river": (36, 113, 163),  # legacy alias
        "volcanic_geothermal-lava_river": (204, 80, 0),
        "lava_river": (204, 80, 0),  # legacy alias
        "volcanic_geothermal-columnar_basalt_vertical": (61, 61, 74),
        "aride_desert-anhydrite_desert": (200, 191, 176),
        "aride_desert-valley_of_fire": (184, 90, 58),
        "aride_desert-corundum_plateau": (138, 112, 128),
        "aride_desert-corundum_sand_desert": (176, 120, 136),
        "rocky_landform-arachnoide": (106, 90, 80),
        "volcanic_geothermal-lava_dome": (138, 48, 32),
        "rocky_landform-perforated_limestone": (200, 184, 152),
        "volcanic_geothermal-pele_haire": (138, 106, 32),
        "icy-frozen_methane": (208, 218, 232),
    }

    # ── Resolve base fill colour ─────────────────────────────────────
    # Priority: project variable → dominant feature colour (computed below)
    # → neutral rocky brown (NOT ocean blue, which is misleading for
    # non-aquatic worlds).
    DEFAULT_BASE_FILL = (90, 80, 72)  # neutral rocky brown
    base_fill = DEFAULT_BASE_FILL
    try:
        cfg_hex = QgsExpressionContextUtils.projectScope(_project).variable("colormap_base_color")
        if cfg_hex:
            cfg_hex = str(cfg_hex).strip()
            if cfg_hex.startswith("#") and len(cfg_hex) == 7:
                base_fill = (int(cfg_hex[1:3], 16), int(cfg_hex[3:5], 16), int(cfg_hex[5:7], 16))
                print(f"  Base fill from project variable colormap_base_color: {cfg_hex}")
    except Exception:
        pass

    try:
        from PIL import Image as PILImage
    except ImportError:
        print("  ⚠ PIL/Pillow not available. Install with: pip install Pillow")
        print("  Generating color map as raw JSON instead...")
        json_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_colormap.json")
        color_data = {"width": width, "height": height,
                      "default": list(base_fill)}
        with open(json_path, "w") as f:
            json.dump(color_data, f)
        return json_path

    from qgis.core import QgsPointXY, QgsGeometry, QgsSpatialIndex

    # ── Build a unified feature list (geom, color) from any source ───
    # Helper: pull a biome-type string from a layer/feature, preferring
    # the layer custom property used by individual biome layers.
    def _feature_biome_type(feat, layer):
        bt = layer.customProperty("biome_type")
        if bt:
            return str(bt).lower()
        for field_name in ("biome_type", "type", "name"):
            idx = layer.fields().indexOf(field_name)
            if idx >= 0:
                val = feat[field_name]
                if val is not None:
                    return str(val).lower()
        return ""

    # Helper: pull a per-feature color (feature field → layer property →
    # default_colors lookup → base_fill).
    def _feature_color(feat, layer, biome_type):
        hex_idx = layer.fields().indexOf("color_hex")
        hex_color = None
        if hex_idx >= 0:
            raw = feat["color_hex"]
            if raw:
                hex_color = str(raw)
        if hex_color is None:
            lp = layer.customProperty("color_hex")
            if lp:
                hex_color = str(lp)
        if hex_color and hex_color.startswith("#") and len(hex_color) == 7:
            try:
                return (int(hex_color[1:3], 16),
                        int(hex_color[3:5], 16),
                        int(hex_color[5:7], 16))
            except ValueError:
                pass
        if biome_type in default_colors:
            return default_colors[biome_type]
        return base_fill

    memlog("colormap: collecting features")
    features = []  # list of {"geometry": QgsGeometry, "color": (r,g,b)}
    m_per_deg = PLANET_RADIUS * math.pi / 180.0

    if merged_layer is not None:
        for feat in merged_layer.getFeatures():
            geom = feat.geometry()
            if geom.isEmpty():
                continue
            bt = _feature_biome_type(feat, merged_layer)
            features.append({"geometry": QgsGeometry(geom),
                             "color": _feature_color(feat, merged_layer, bt)})
    else:
        # No pre-merged GeoJSON. Harvest all biome layers and buffer
        # line / point geometry in-memory so they paint onto the map.
        biome_layers = find_all_biome_layers()

        # Polygons: use as-is.
        for l in biome_layers["polygon"]:
            for feat in l.getFeatures():
                geom = feat.geometry()
                if geom.isEmpty():
                    continue
                bt = _feature_biome_type(feat, l)
                features.append({"geometry": QgsGeometry(geom),
                                 "color": _feature_color(feat, l, bt)})

        # Lines: buffer by width (metres) → degrees.
        for l in biome_layers["line"]:
            has_ws = l.fields().indexOf("width_start") >= 0
            has_we = l.fields().indexOf("width_end") >= 0
            has_w = l.fields().indexOf("width") >= 0
            for feat in l.getFeatures():
                geom = feat.geometry()
                if geom.isEmpty():
                    continue
                w = 0.0
                if has_ws:
                    try:
                        ws = float(feat["width_start"])
                        if ws > 0:
                            w = max(w, ws)
                    except (TypeError, ValueError):
                        pass
                if has_we:
                    try:
                        we = float(feat["width_end"])
                        if we > 0:
                            w = max(w, we)
                    except (TypeError, ValueError):
                        pass
                if w <= 0.0 and has_w:
                    try:
                        ww = float(feat["width"])
                        if ww > 0:
                            w = ww
                    except (TypeError, ValueError):
                        pass
                if w <= 0.0:
                    w = 100.0  # sensible fallback
                width_deg = w / m_per_deg
                buf = geom.buffer(width_deg / 2.0, 8)
                if buf.isEmpty():
                    continue
                bt = _feature_biome_type(feat, l)
                features.append({"geometry": buf,
                                 "color": _feature_color(feat, l, bt)})

        # Points: buffer by radius (metres) → degrees.
        # Craters stay as unbuffered dots — they're too small to influence
        # a 512×256 colormap meaningfully, and buffering thousands of them
        # would dominate the fill colour.
        for l in biome_layers["point"]:
            layer_btype = l.customProperty("biome_type")
            if layer_btype == "spatial-crater":
                continue
            radius_idx = l.fields().indexOf("radius")
            for feat in l.getFeatures():
                geom = feat.geometry()
                if geom.isEmpty():
                    continue
                r_m = 185.0
                if radius_idx >= 0:
                    try:
                        rv = float(feat["radius"])
                        if rv > 0:
                            r_m = rv
                    except (TypeError, ValueError):
                        pass
                # Minimum visual radius ~1 colormap pixel (360°/512 ≈ 0.7°)
                min_deg = 0.7 / 2.0
                rad_deg = max(r_m / m_per_deg, min_deg)
                buf = geom.buffer(rad_deg, 16)
                if buf.isEmpty():
                    continue
                bt = _feature_biome_type(feat, l)
                features.append({"geometry": buf,
                                 "color": _feature_color(feat, l, bt)})

    print(f"  Generating {width}×{height} color map ({len(features)} biome features)...")
    memlog("colormap: feature pool built", f"features={len(features)}")

    # ── Compute dominant feature colour for the canvas fill ──────────
    # Only used if project variable didn't set one. Ignores ocean-blue
    # when the planet is clearly arid (no liquid biome features at all).
    if base_fill is DEFAULT_BASE_FILL and features:
        from collections import Counter
        counter = Counter(f["color"] for f in features)
        # Area-weight would be ideal but counting features is good enough
        # and cheap. Skip colours that look like ocean unless they appear
        # a lot more than any other colour.
        most_common = counter.most_common(3)
        if most_common:
            base_fill = most_common[0][0]
            print(f"  Base fill from dominant feature colour: rgb{base_fill}")

    # ── Rasterise ────────────────────────────────────────────────────
    pixels = np.full((height, width, 3), base_fill, dtype=np.uint8)

    if features:
        memlog("colormap: building spatial index")
        feature_cache = {i: f for i, f in enumerate(features)}
        # QgsSpatialIndex.insertFeature() expects features with geometries and
        # IDs — fabricate lightweight QgsFeature wrappers.
        from qgis.core import QgsFeature
        spatial_idx = QgsSpatialIndex()
        for fid, cached in feature_cache.items():
            qf = QgsFeature(fid)
            qf.setGeometry(cached["geometry"])
            spatial_idx.insertFeature(qf)
        memlog("colormap: spatial index built")

        for py in range(height):
            lat = 90.0 - (py / height) * 180.0
            for px in range(width):
                lon = -180.0 + (px / width) * 360.0
                point_geom = QgsGeometry.fromPointXY(QgsPointXY(lon, lat))
                candidates = spatial_idx.intersects(point_geom.boundingBox())
                for fid in candidates:
                    cached = feature_cache.get(fid)
                    if cached and cached["geometry"].contains(point_geom):
                        pixels[py, px] = cached["color"]
                        break
    else:
        print(f"  ⚠ No biome features available — emitting flat base-colour map rgb{base_fill}.")

    img = PILImage.fromarray(pixels, mode='RGB')
    img.save(output_path)
    print(f"  ✓ Color map saved: {output_path}")
    return output_path


def healpix_pix2vec(nside, ipix):
    """
    Convert HEALPix nested pixel index to a unit sphere direction (x, y, z).
    Delegates to healpix_utils for consistency with Godot's healpix.gd.
    """
    return hpx.pix2vec_nest(nside, ipix)


def healpix_vec2pix(nside, x, y, z):
    """
    Convert unit direction (x, y, z) to HEALPix nested pixel index.
    """
    return hpx.vec2pix_nest(nside, x, y, z)


# Keep cube_to_sphere for backward compatibility during transition
def cube_to_sphere(face, u, v):
    """
    Convert cube-face local coordinates to a unit sphere direction.
    Matches the Godot PlanetData.cube_to_sphere() exactly.
    face: 0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z
    u, v: scalars in [-1, 1]
    Returns (x, y, z) unit vector as tuple.
    """
    if face == 0:
        x, y, z = 1.0, v, -u
    elif face == 1:
        x, y, z = -1.0, v, u
    elif face == 2:
        x, y, z = u, 1.0, -v
    elif face == 3:
        x, y, z = u, -1.0, v
    elif face == 4:
        x, y, z = u, v, 1.0
    elif face == 5:
        x, y, z = -u, v, -1.0
    else:
        x, y, z = 0.0, 1.0, 0.0
    norm = math.sqrt(x * x + y * y + z * z)
    if norm > 0:
        x /= norm; y /= norm; z /= norm
    return (x, y, z)


# Keep cube_to_sphere_vectorized for backward compatibility during transition
def cube_to_sphere_vectorized(face, u_arr, v_arr):
    """
    Vectorized version: u_arr, v_arr are 2D numpy arrays (chunk_px, chunk_px).
    Returns (x, y, z) each as 2D numpy arrays, normalized to unit sphere.
    """
    ones = np.ones_like(u_arr)
    if face == 0:
        x, y, z = ones, v_arr, -u_arr
    elif face == 1:
        x, y, z = -ones, v_arr, u_arr
    elif face == 2:
        x, y, z = u_arr, ones, -v_arr
    elif face == 3:
        x, y, z = u_arr, -ones, v_arr
    elif face == 4:
        x, y, z = u_arr, v_arr, ones
    elif face == 5:
        x, y, z = -u_arr, v_arr, -ones
    else:
        x, y, z = np.zeros_like(u_arr), ones, np.zeros_like(u_arr)
    norm = np.sqrt(x * x + y * y + z * z)
    norm = np.where(norm > 0, norm, 1.0)
    return x / norm, y / norm, z / norm


def direction_to_lonlat(d):
    """
    Convert a unit direction (x, y, z) to (longitude, latitude) in degrees.
    Matches PlanetData.direction_to_uv() → EPSG:4326.
    """
    lon = math.degrees(math.atan2(d[2], d[0]))
    lat = math.degrees(math.asin(max(-1.0, min(1.0, d[1]))))
    return lon, lat


def direction_to_lonlat_vectorized(x, y, z):
    """
    Vectorized version: x, y, z are numpy arrays.
    Returns (lon_arr, lat_arr) in degrees.
    """
    lon = np.degrees(np.arctan2(z, x))
    lat = np.degrees(np.arcsin(np.clip(y, -1.0, 1.0)))
    return lon, lat


def generate_chunked_heightmaps(heightmap_tif_path):
    """
    Split the global equirectangular heightmap into per-tile GeoTIFF heightmaps
    using HEALPix tiling. Each tile is a Float32 GeoTIFF at CHUNK_TILE_PX resolution.

    Uses HEALPix nested indexing for hierarchical LOD — 12 base pixels,
    each subdivided into 4 children. At export depth k, N_side = 2^k,
    total tiles = 12 × N_side².
    """
    try:
        from osgeo import gdal
    except ImportError:
        print("  ⚠ GDAL Python bindings not available.")
        return None

    ds = gdal.Open(heightmap_tif_path)
    if ds is None:
        print(f"  ✗ Cannot open {heightmap_tif_path}")
        return None

    band = ds.GetRasterBand(1)
    gt = ds.GetGeoTransform()  # (lon_min, pixel_w, 0, lat_max, 0, -pixel_h)
    width = ds.RasterXSize
    height = ds.RasterYSize
    global_data = band.ReadAsArray().astype(np.float32)  # shape (height, width)

    print(f"  Global heightmap: {width}×{height}, "
          f"min={np.nanmin(global_data):.2f}, max={np.nanmax(global_data):.2f}")

    elev_min = ELEV_MIN if ELEV_MIN is not None else 0.0
    elev_max = ELEV_MAX if ELEV_MAX is not None else 0.0
    if elev_max <= elev_min:
        elev_max = float(np.nanmax(global_data))
        elev_min = float(np.nanmin(global_data))

    global_data = np.nan_to_num(global_data, nan=elev_min)

    def sample_global_vectorized(lon_arr, lat_arr):
        """Bilinear sample from global heightmap. lon_arr, lat_arr are 2D numpy arrays."""
        px = (lon_arr - gt[0]) / gt[1]
        py = (lat_arr - gt[3]) / gt[5]
        px = np.clip(px, 0.0, width - 1.001)
        py = np.clip(py, 0.0, height - 1.001)
        x0 = px.astype(np.int32)
        y0 = py.astype(np.int32)
        x1 = np.minimum(x0 + 1, width - 1)
        y1 = np.minimum(y0 + 1, height - 1)
        fx = px - x0
        fy = py - y0
        v00 = global_data[y0, x0]
        v10 = global_data[y0, x1]
        v01 = global_data[y1, x0]
        v11 = global_data[y1, x1]
        return v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) + \
               v01 * (1 - fx) * fy + v11 * fx * fy

    chunk_px = CHUNK_TILE_PX
    nside = EXPORT_NSIDE
    npix = 12 * nside * nside
    export_depth = min(MAX_QUADTREE_DEPTH, CHUNK_EXPORT_DEPTH)

    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    ensure_dir(chunks_dir)

    chunk_manifest = []
    total = npix
    count = 0

    print(f"  Generating {total} chunk heightmaps (HEALPix nside={nside}) "
          f"({chunk_px}×{chunk_px} px each, from global raster)...")

    driver = gdal.GetDriverByName('GTiff')

    for ipix in range(npix):
        base_pixel = ipix // (nside * nside)
        base_dir = os.path.join(chunks_dir, f"base_{base_pixel}")
        ensure_dir(base_dir)

        lon_grid, lat_grid = hpx.get_tile_grid_lonlat(nside, ipix, chunk_px)

        # Vectorized bilinear sampling
        raw = sample_global_vectorized(lon_grid, lat_grid)

        # Save as GeoTIFF Float32 (raw elevation in metres)
        chunk_key = f"hp_n{nside}_p{ipix}"
        out_path = os.path.join(base_dir, f"{chunk_key}.tif")

        out_ds = driver.Create(out_path, chunk_px, chunk_px, 1, gdal.GDT_Float32)
        out_ds.GetRasterBand(1).WriteArray(raw.astype(np.float32))
        out_ds.FlushCache()
        out_ds = None

        chunk_manifest.append({
            "key": chunk_key,
            "nside": nside,
            "ipix": ipix,
            "file": os.path.relpath(out_path, EXPORT_DIR),
        })

        count += 1
        if count % 50 == 0:
            print(f"    {count}/{total} chunks...")

    # Write manifest JSON
    manifest_path = os.path.join(chunks_dir, "chunk_manifest.json")
    manifest_data = {
        "planet_name": PLANET_NAME,
        "planet_radius": PLANET_RADIUS,
        "projection": "healpix",
        "nside": nside,
        "depth": export_depth,
        "total_pixels": npix,
        "chunk_resolution_px": chunk_px,
        "format": "geotiff",
        "elev_min": elev_min,
        "elev_max": elev_max,
        "total_chunks": len(chunk_manifest),
        "chunks": chunk_manifest,
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest_data, f, indent=2)

    ds = None  # Close GDAL dataset
    print(f"  ✓ {count} chunk heightmaps saved in {chunks_dir}")
    print(f"  ✓ Manifest: {manifest_path}")
    return chunks_dir


def generate_chunked_heightmaps_direct(export_depth_override=None):
    """
    Generate per-chunk heightmaps by interpolating DIRECTLY from contour
    vertices in cube-sphere space — bypasses the global equirectangular
    raster entirely, giving each chunk the full precision of the source
    contour data.

    The key insight: the old pipeline went
        contours → 4096×2048 global raster → chunk samples
    which capped every chunk's precision to ~3 km/pixel for large planets.

    This function instead does:
        contours → (project vertices into lon/lat) → per-chunk interpolation
    so each 256×256 chunk gets its own Delaunay/IDW interpolation from
    the actual contour vertices, at whatever resolution they provide.
    """
    import time as _time

    contour_layers = find_layers_by_keyword("contour") + find_layers_by_keyword(
        "elevation"
    )
    vector_layers = [l for l in contour_layers if isinstance(l, QgsVectorLayer)]
    if not vector_layers:
        print("  ⚠ No contour/elevation vector layer found. Skipping direct chunk export.")
        return None

    layer = vector_layers[0]

    # Find the elevation field
    elev_field = None
    for field in layer.fields():
        if field.name().lower() in ("elev", "elevation", "height", "z", "alt"):
            elev_field = field.name()
            break

    if not elev_field:
        print(
            f"  ⚠ No elevation field found in {layer.name()}. "
            f"Available: {[f.name() for f in layer.fields()]}"
        )
        return None

    # ── Extract all contour vertices with elevation ──
    print(f"  Extracting vertices from '{layer.name()}' field '{elev_field}'...")
    points = []  # list of (lon, lat, elev)
    for feature in layer.getFeatures():
        elev = feature[elev_field]
        if elev is None:
            continue
        elev = float(elev)
        geom = feature.geometry()
        if geom is None or geom.isNull():
            continue
        # Skip stub features from setup_planet_project
        centroid = geom.centroid().asPoint()
        if abs(centroid.x()) < 0.01 and abs(centroid.y()) < 0.01 and elev == 0.0:
            continue
        for vertex in geom.vertices():
            points.append((vertex.x(), vertex.y(), elev))

    if not points:
        print("  ⚠ No vertices with elevation found.")
        return None

    MIN_POINTS_FOR_TRIANGULATION = 4
    if len(points) < MIN_POINTS_FOR_TRIANGULATION:
        print(f"  ⚠ Only {len(points)} contour vertices found "
              f"(need ≥ {MIN_POINTS_FOR_TRIANGULATION} for interpolation). "
              f"Draw more contour lines in QGIS before exporting.")
        return None

    all_pts = np.array(points, dtype=np.float64)  # shape (N, 3)
    print(f"  {len(all_pts)} total contour vertices, elevation range "
          f"[{all_pts[:, 2].min():.1f}, {all_pts[:, 2].max():.1f}]m")

    # Elevation normalization range
    elev_min = ELEV_MIN if ELEV_MIN is not None else 0.0
    elev_max = ELEV_MAX if ELEV_MAX is not None else 0.0
    if elev_max <= elev_min:
        elev_max = float(all_pts[:, 2].max())
        elev_min = float(all_pts[:, 2].min())
    elev_range = elev_max - elev_min if elev_max > elev_min else 1.0

    # Build a global KD-tree on (lon, lat) for fast spatial queries
    try:
        from scipy.spatial import cKDTree
        from scipy.interpolate import griddata as scipy_griddata
        has_scipy = True
    except ImportError:
        has_scipy = False

    if has_scipy:
        global_tree = cKDTree(all_pts[:, :2])
        print(f"  Built global KD-tree over {len(all_pts)} vertices")
    else:
        global_tree = None
        print("  ⚠ scipy not available — falling back to numpy IDW (slower)")

    try:
        from osgeo import gdal
    except ImportError:
        print("  ⚠ GDAL Python bindings not available for GeoTIFF output.")
        return None

    chunk_px = CHUNK_TILE_PX
    export_depth = export_depth_override if export_depth_override is not None \
        else min(MAX_QUADTREE_DEPTH, CHUNK_EXPORT_DEPTH)
    nside = 2 ** export_depth
    npix = 12 * nside * nside

    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    ensure_dir(chunks_dir)

    chunk_manifest = []
    total = npix
    count = 0
    empty_count = 0

    # Margin in degrees to expand the bounding box when selecting nearby vertices.
    # This ensures we capture contour points just outside the chunk boundary so
    # interpolation doesn't produce hard edges.
    MARGIN_DEG = 5.0

    # Minimum number of source vertices required in the chunk's neighbourhood
    # to attempt scipy linear interpolation (needs ≥3 for triangulation).
    # Below this we use KD-tree IDW or fill with 0.
    MIN_PTS_FOR_LINEAR = 10

    print(f"  Generating {total} chunk heightmaps (HEALPix nside={nside}) "
          f"({chunk_px}×{chunk_px} px, DIRECT from contour vertices)...")

    _t0 = _time.time()
    driver = gdal.GetDriverByName('GTiff')

    for ipix in range(npix):
        base_pixel = ipix // (nside * nside)
        base_dir = os.path.join(chunks_dir, f"base_{base_pixel}")
        ensure_dir(base_dir)

        lon_grid, lat_grid = hpx.get_tile_grid_lonlat(nside, ipix, chunk_px)

        # Determine the lon/lat bounding box of this chunk + margin
        lon_min_chunk, lon_max_chunk, lat_min_chunk, lat_max_chunk = \
            hpx.get_tile_lonlat_bbox(nside, ipix, margin_deg=MARGIN_DEG)

        # Select contour vertices that fall within the expanded bbox
        if has_scipy and global_tree is not None:
            center_lon = (lon_min_chunk + lon_max_chunk) / 2.0
            center_lat = (lat_min_chunk + lat_max_chunk) / 2.0
            search_radius = max(
                lon_max_chunk - lon_min_chunk,
                lat_max_chunk - lat_min_chunk
            ) / 2.0 * 1.5  # 1.5× for safety
            nearby_idxs = global_tree.query_ball_point(
                [center_lon, center_lat], search_radius
            )
            chunk_pts = all_pts[nearby_idxs]
        else:
            # Brute-force bbox filter
            mask = (
                (all_pts[:, 0] >= lon_min_chunk) &
                (all_pts[:, 0] <= lon_max_chunk) &
                (all_pts[:, 1] >= lat_min_chunk) &
                (all_pts[:, 1] <= lat_max_chunk)
            )
            chunk_pts = all_pts[mask]

        # Interpolate elevation for this chunk's pixel grid
        flat_lon = lon_grid.ravel()
        flat_lat = lat_grid.ravel()

        if len(chunk_pts) >= MIN_PTS_FOR_LINEAR and has_scipy:
            # scipy Delaunay linear interpolation — best quality
            raw_flat = scipy_griddata(
                chunk_pts[:, :2],
                chunk_pts[:, 2],
                (flat_lon, flat_lat),
                method='linear',
                fill_value=np.nan,
            )
            # Fill NaN holes with nearest-neighbor
            nan_mask = np.isnan(raw_flat)
            if nan_mask.any():
                nn_fill = scipy_griddata(
                    chunk_pts[:, :2],
                    chunk_pts[:, 2],
                    (flat_lon[nan_mask], flat_lat[nan_mask]),
                    method='nearest',
                )
                raw_flat[nan_mask] = nn_fill
            raw = raw_flat.reshape(chunk_px, chunk_px)
        elif len(chunk_pts) >= 3 and has_scipy:
            # Too few for reliable linear, use IDW with KD-tree
            local_tree = cKDTree(chunk_pts[:, :2])
            K = min(8, len(chunk_pts))
            grid_pts = np.column_stack([flat_lon, flat_lat])
            dists, idxs = local_tree.query(grid_pts, k=K)
            if K == 1:
                dists = dists[:, np.newaxis]
                idxs = idxs[:, np.newaxis]
            weights = 1.0 / np.maximum(dists ** 2, 1e-12)
            values = chunk_pts[idxs, 2]
            raw = (
                np.sum(weights * values, axis=1) /
                np.sum(weights, axis=1)
            ).reshape(chunk_px, chunk_px)
        elif len(chunk_pts) > 0:
            # Very few points — simple nearest-neighbor
            from scipy.spatial import cKDTree as _cKD
            local_tree = _cKD(chunk_pts[:, :2])
            grid_pts = np.column_stack([flat_lon, flat_lat])
            _, idxs = local_tree.query(grid_pts, k=1)
            raw = chunk_pts[idxs, 2].reshape(chunk_px, chunk_px)
        else:
            # No contour data in this region — flat chunk
            raw = np.full((chunk_px, chunk_px), elev_min, dtype=np.float32)
            empty_count += 1

        # Save as GeoTIFF Float32 (raw elevation in metres)
        chunk_key = f"hp_n{nside}_p{ipix}"
        out_path = os.path.join(base_dir, f"{chunk_key}.tif")

        out_ds = driver.Create(out_path, chunk_px, chunk_px, 1, gdal.GDT_Float32)
        out_ds.GetRasterBand(1).WriteArray(raw.astype(np.float32))
        out_ds.FlushCache()
        out_ds = None

        chunk_manifest.append({
            "key": chunk_key,
            "nside": nside,
            "ipix": ipix,
            "file": os.path.relpath(out_path, EXPORT_DIR),
            "source_vertices": int(len(chunk_pts)),
        })

        count += 1
        if count % 50 == 0:
            elapsed = _time.time() - _t0
            rate = count / elapsed if elapsed > 0 else 0
            eta = (total - count) / rate if rate > 0 else 0
            print(f"    {count}/{total} chunks... "
                  f"({elapsed:.0f}s elapsed, ~{eta:.0f}s remaining)")

    # Write manifest JSON
    manifest_path = os.path.join(chunks_dir, "chunk_manifest.json")
    manifest_data = {
        "planet_name": PLANET_NAME,
        "planet_radius": PLANET_RADIUS,
        "projection": "healpix",
        "nside": nside,
        "depth": export_depth,
        "total_pixels": npix,
        "chunk_resolution_px": chunk_px,
        "format": "geotiff",
        "elev_min": elev_min,
        "elev_max": elev_max,
        "total_chunks": len(chunk_manifest),
        "interpolation": "direct_from_contours",
        "total_source_vertices": int(len(all_pts)),
        "chunks": chunk_manifest,
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest_data, f, indent=2)

    elapsed = _time.time() - _t0
    print(f"  ✓ {count} chunk heightmaps saved in {chunks_dir} "
          f"({elapsed:.1f}s, {empty_count} empty chunks)")
    print(f"  ✓ Manifest: {manifest_path}")
    return chunks_dir


def _generate_chunked_heightmaps_rasterio(heightmap_tif_path):
    """Fallback chunked export using rasterio instead of GDAL (vectorized)."""
    try:
        import rasterio
    except ImportError:
        print("  ✗ Neither GDAL nor rasterio available. Cannot generate chunked heightmaps.")
        print("    Install with: pip install rasterio  or  pip install GDAL")
        return None

    with rasterio.open(heightmap_tif_path) as src:
        global_data = src.read(1).astype(np.float32)  # band 1, shape (h, w)
        transform = src.transform
        r_height, r_width = global_data.shape

    print(f"  Global heightmap: {r_width}×{r_height}, "
          f"min={np.nanmin(global_data):.2f}, max={np.nanmax(global_data):.2f}")

    elev_min = ELEV_MIN
    elev_max = ELEV_MAX
    if elev_max <= elev_min:
        elev_max = float(np.nanmax(global_data))
        elev_min = float(np.nanmin(global_data))
    elev_range = elev_max - elev_min if elev_max > elev_min else 1.0

    global_data = np.nan_to_num(global_data, nan=elev_min)

    # GeoTransform equivalent from rasterio affine
    gt0 = transform.c  # lon_min
    gt1 = transform.a  # pixel_width
    gt3 = transform.f  # lat_max
    gt5 = transform.e  # -pixel_height

    def sample_global_vectorized(lon_arr, lat_arr):
        px = (lon_arr - gt0) / gt1
        py = (lat_arr - gt3) / gt5
        px = np.clip(px, 0.0, r_width - 1.001)
        py = np.clip(py, 0.0, r_height - 1.001)
        x0 = px.astype(np.int32)
        y0 = py.astype(np.int32)
        x1 = np.minimum(x0 + 1, r_width - 1)
        y1 = np.minimum(y0 + 1, r_height - 1)
        fx = px - x0
        fy = py - y0
        v00 = global_data[y0, x0]; v10 = global_data[y0, x1]
        v01 = global_data[y1, x0]; v11 = global_data[y1, x1]
        return v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) + \
               v01 * (1 - fx) * fy + v11 * fx * fy

    try:
        from osgeo import gdal as _gdal_rio
    except ImportError:
        print("  ⚠ GDAL Python bindings not available for GeoTIFF output.")
        return None

    chunk_px = CHUNK_TILE_PX
    export_depth = min(MAX_QUADTREE_DEPTH, CHUNK_EXPORT_DEPTH)
    nside = 2 ** export_depth
    npix = 12 * nside * nside

    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    ensure_dir(chunks_dir)

    chunk_manifest = []
    total = npix
    count = 0

    print(f"  Generating {total} chunk heightmaps (HEALPix nside={nside}) "
          f"({chunk_px}×{chunk_px} px each, rasterio fallback)...")

    driver = _gdal_rio.GetDriverByName('GTiff')

    for ipix in range(npix):
        base_pixel = ipix // (nside * nside)
        base_dir = os.path.join(chunks_dir, f"base_{base_pixel}")
        ensure_dir(base_dir)

        lon_grid, lat_grid = hpx.get_tile_grid_lonlat(nside, ipix, chunk_px)
        raw = sample_global_vectorized(lon_grid, lat_grid)

        chunk_key = f"hp_n{nside}_p{ipix}"
        out_path = os.path.join(base_dir, f"{chunk_key}.tif")

        out_ds = driver.Create(out_path, chunk_px, chunk_px, 1, _gdal_rio.GDT_Float32)
        out_ds.GetRasterBand(1).WriteArray(raw.astype(np.float32))
        out_ds.FlushCache()
        out_ds = None

        chunk_manifest.append({
            "key": chunk_key, "nside": nside, "ipix": ipix,
            "file": os.path.relpath(out_path, EXPORT_DIR),
        })
        count += 1
        if count % 50 == 0:
            print(f"    {count}/{total} chunks...")

    manifest_path = os.path.join(chunks_dir, "chunk_manifest.json")
    manifest_data = {
        "planet_name": PLANET_NAME, "planet_radius": PLANET_RADIUS,
        "projection": "healpix", "nside": nside,
        "depth": export_depth, "total_pixels": npix,
        "chunk_resolution_px": chunk_px,
        "format": "geotiff",
        "elev_min": elev_min, "elev_max": elev_max,
        "total_chunks": len(chunk_manifest), "chunks": chunk_manifest,
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest_data, f, indent=2)

    print(f"  ✓ {count} chunk heightmaps saved in {chunks_dir}")
    print(f"  ✓ Manifest: {manifest_path}")
    return chunks_dir


def generate_combined_planet_json():
    """
    Generate a single combined JSON file with all planet metadata
    that the Godot importer can read.
    """
    output_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_planet.json")

    planet_data = {
        "planet_name": PLANET_NAME,
        "radius": PLANET_RADIUS,
        "elevation_min": ELEV_MIN,
        "elevation_max": ELEV_MAX,
        "max_height": ELEV_MAX - ELEV_MIN,
        "height_offset": ELEV_MIN if ELEV_MIN < 0 else 0.0,
        "max_quadtree_depth": MAX_QUADTREE_DEPTH,
        "chunk_export_depth": min(MAX_QUADTREE_DEPTH, CHUNK_EXPORT_DEPTH),
        "coordinate_system": "EPSG:4326",
        "projection": "healpix",
        "nside": EXPORT_NSIDE,
        "total_pixels": 12 * EXPORT_NSIDE * EXPORT_NSIDE,
        "chunk_heightmaps": f"{PLANET_NAME}_chunks/chunk_manifest.json",
        "chunk_heightmaps_dir": f"assets/qgis/.export/{PLANET_NAME}_chunks",
        "files": {},
        "lod": {
            "lod0_distance": 5000,
            "lod1_distance": 50000,
            "lod2_distance": 200000,
            "lod3_distance": 2000000,
            "lod4_distance": 500000000,
        },
        "lod_resolutions": {
            "lod0": {"heightmap": "full", "features": "all"},
            "lod1": {"heightmap": "1/4", "features": "major_roads,biome_outlines"},
            "lod2": {"heightmap": "1/16", "features": "biome_colors,major_terrain"},
            "lod3": {"heightmap": "1/64", "features": "smoothed_terrain,biome_tint"},
            "lod4": {"heightmap": "none", "features": "dominant_color_only"},
        },
    }

    # Check recipe format and crater data from the chunk manifest
    manifest_path = os.path.join(
        EXPORT_DIR, f"{PLANET_NAME}_chunks", "chunk_manifest.json")
    if os.path.exists(manifest_path):
        with open(manifest_path, "r") as mf:
            manifest = json.load(mf)
        chunk_format = manifest.get("format", "png")
        planet_data["chunk_format"] = chunk_format
        if chunk_format == "recipe":
            # Recipes handle craters at runtime — not baked
            planet_data["craters_baked"] = False
            planet_data["craters_count"] = manifest.get("total_craters", 0)
            planet_data["noise_config"] = manifest.get("noise_config", {})
            planet_data["biome_data_in_recipes"] = manifest.get("biome_data_in_recipes", False)
        elif manifest.get("craters_baked", False):
            planet_data["craters_baked"] = True
            planet_data["craters_count"] = manifest.get("craters_count", 0)

    # List exported files
    if os.path.exists(EXPORT_DIR):
        for fname in os.listdir(EXPORT_DIR):
            if fname.startswith(PLANET_NAME) and not os.path.isdir(
                os.path.join(EXPORT_DIR, fname)
            ):
                key = fname.replace(f"{PLANET_NAME}_", "").rsplit(".", 1)[0]
                planet_data["files"][key] = fname

    # Check for biomes spatial index inside the chunks directory
    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    biomes_idx_name = f"{PLANET_NAME}_biomes_index.json"
    biomes_idx_path = os.path.join(chunks_dir, biomes_idx_name)
    if os.path.exists(biomes_idx_path):
        planet_data["files"]["biomes_index"] = (
            f"{PLANET_NAME}_chunks/{biomes_idx_name}")

    with open(output_path, "w") as f:
        json.dump(planet_data, f, indent=2)

    print(f"  ✓ Planet config saved: {output_path}")
    return output_path


def generate_flat_chunked_heightmaps():
    """
    Generate flat (elevation = 0) chunk heightmaps when no contour or
    raster heightmap data is available.  This ensures the chunk directory
    and manifest always exist so the Godot terrain system can load.
    """
    try:
        from osgeo import gdal
    except ImportError:
        print("  ⚠ GDAL Python bindings not available for GeoTIFF output.")
        return None

    chunk_px = CHUNK_TILE_PX
    export_depth = min(MAX_QUADTREE_DEPTH, CHUNK_EXPORT_DEPTH)
    nside = 2 ** export_depth
    npix = 12 * nside * nside

    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    ensure_dir(chunks_dir)

    # All pixels = 0 (flat at sea level)
    flat_arr = np.zeros((chunk_px, chunk_px), dtype=np.float32)

    chunk_manifest = []
    total = npix
    count = 0

    elev_min = ELEV_MIN if ELEV_MIN is not None else 0.0
    elev_max = ELEV_MAX if ELEV_MAX is not None else 0.0

    print(f"  Generating {total} FLAT chunk heightmaps (HEALPix nside={nside}) "
          f"({chunk_px}×{chunk_px} px, no elevation data)...")

    driver = gdal.GetDriverByName('GTiff')

    for ipix in range(npix):
        base_pixel = ipix // (nside * nside)
        base_dir = os.path.join(chunks_dir, f"base_{base_pixel}")
        ensure_dir(base_dir)

        chunk_key = f"hp_n{nside}_p{ipix}"
        out_path = os.path.join(base_dir, f"{chunk_key}.tif")

        out_ds = driver.Create(out_path, chunk_px, chunk_px, 1, gdal.GDT_Float32)
        out_ds.GetRasterBand(1).WriteArray(flat_arr)
        out_ds.FlushCache()
        out_ds = None

        chunk_manifest.append({
            "key": chunk_key,
            "nside": nside,
            "ipix": ipix,
            "file": os.path.relpath(out_path, EXPORT_DIR),
            "source_vertices": 0,
        })

        count += 1
        if count % 50 == 0:
            print(f"    {count}/{total} chunks...")

    manifest_path = os.path.join(chunks_dir, "chunk_manifest.json")
    manifest_data = {
        "planet_name": PLANET_NAME,
        "planet_radius": PLANET_RADIUS,
        "projection": "healpix",
        "nside": nside,
        "depth": export_depth,
        "total_pixels": npix,
        "chunk_resolution_px": chunk_px,
        "format": "geotiff",
        "elev_min": elev_min,
        "elev_max": elev_max,
        "total_chunks": len(chunk_manifest),
        "interpolation": "flat",
        "total_source_vertices": 0,
        "chunks": chunk_manifest,
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest_data, f, indent=2)

    print(f"  ✓ {count} flat chunk heightmaps saved in {chunks_dir}")
    print(f"  ✓ Manifest: {manifest_path}")
    return chunks_dir


# ============================================================
# POPULATE ZONE HELPERS — clip biome polygons to chunk bounding boxes
# ============================================================

def _clip_polygon_to_chunk(poly_coords, lon_min, lon_max, lat_min, lat_max):
    """
    Clip a polygon (list of [lon, lat] vertices) to the chunk bounding box.

    Returns:
      "full"       — chunk is entirely inside the polygon
      None         — no intersection
      list of [lon, lat] — clipped polygon vertices (partial overlap)

    Uses Sutherland-Hodgman clipping against the 4 bbox edges.
    """
    if not poly_coords or len(poly_coords) < 3:
        return None

    # Quick AABB reject
    plons = [p[0] for p in poly_coords]
    plats = [p[1] for p in poly_coords]
    if max(plons) < lon_min or min(plons) > lon_max:
        return None
    if max(plats) < lat_min or min(plats) > lat_max:
        return None

    # Check if chunk is entirely inside polygon (all 4 corners inside)
    corners = [
        [lon_min, lat_min], [lon_max, lat_min],
        [lon_max, lat_max], [lon_min, lat_max],
    ]
    all_inside = all(
        _point_in_polygon(c[0], c[1], poly_coords) for c in corners
    )
    if all_inside:
        return "full"

    # Sutherland-Hodgman clipping
    output = list(poly_coords)
    edges = [
        ("left",   lon_min, None),
        ("right",  lon_max, None),
        ("bottom", None,    lat_min),
        ("top",    None,    lat_max),
    ]
    for edge_type, val_lon, val_lat in edges:
        if not output:
            return None
        clipped = []
        for i in range(len(output)):
            curr = output[i]
            prev = output[i - 1]
            curr_inside = _inside_edge(curr, edge_type, val_lon, val_lat)
            prev_inside = _inside_edge(prev, edge_type, val_lon, val_lat)
            if curr_inside:
                if not prev_inside:
                    clipped.append(_intersect_edge(prev, curr, edge_type, val_lon, val_lat))
                clipped.append(curr)
            elif prev_inside:
                clipped.append(_intersect_edge(prev, curr, edge_type, val_lon, val_lat))
        output = clipped

    if len(output) < 3:
        return None

    # Round the output vertices
    return [[round(p[0], 6), round(p[1], 6)] for p in output]


def _inside_edge(point, edge_type, val_lon, val_lat):
    """Check if a point is inside a clipping edge."""
    if edge_type == "left":
        return point[0] >= val_lon
    elif edge_type == "right":
        return point[0] <= val_lon
    elif edge_type == "bottom":
        return point[1] >= val_lat
    elif edge_type == "top":
        return point[1] <= val_lat
    return True


def _intersect_edge(p1, p2, edge_type, val_lon, val_lat):
    """Compute intersection point of segment p1→p2 with a clipping edge."""
    dx = p2[0] - p1[0]
    dy = p2[1] - p1[1]
    if edge_type in ("left", "right"):
        if abs(dx) < 1e-12:
            return [val_lon, p1[1]]
        t = (val_lon - p1[0]) / dx
        return [val_lon, p1[1] + t * dy]
    else:
        if abs(dy) < 1e-12:
            return [p1[0], val_lat]
        t = (val_lat - p1[1]) / dy
        return [p1[0] + t * dx, val_lat]


def _point_in_polygon(x, y, poly):
    """Ray-casting point-in-polygon test."""
    n = len(poly)
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = poly[i][0], poly[i][1]
        xj, yj = poly[j][0], poly[j][1]
        if ((yi > y) != (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def _simplify_polygon(coords, tolerance=0.0001):
    """
    Douglas-Peucker simplification for a polygon ring.
    tolerance is in degrees (~11m at equator for 0.0001).
    """
    if len(coords) <= 4:
        return coords

    def _dp(points, start, end, tol):
        max_dist = 0.0
        max_idx = start
        for i in range(start + 1, end):
            d = _point_line_dist(points[i], points[start], points[end])
            if d > max_dist:
                max_dist = d
                max_idx = i
        if max_dist > tol:
            left = _dp(points, start, max_idx, tol)
            right = _dp(points, max_idx, end, tol)
            return left[:-1] + right
        return [points[start], points[end]]

    def _point_line_dist(p, a, b):
        dx = b[0] - a[0]
        dy = b[1] - a[1]
        if dx == 0 and dy == 0:
            return math.sqrt((p[0] - a[0]) ** 2 + (p[1] - a[1]) ** 2)
        t = max(0, min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)))
        proj_x = a[0] + t * dx
        proj_y = a[1] + t * dy
        return math.sqrt((p[0] - proj_x) ** 2 + (p[1] - proj_y) ** 2)

    result = _dp(coords, 0, len(coords) - 1, tolerance)
    return result if len(result) >= 3 else coords


def _collect_populate_data():
    """
    Collect all populate-only biome features from QGIS layers.

    Returns:
      polygon_zones: list of {"biome_type", "biome_index", "coords": [[lon,lat],...], "props": {}}
      point_zones: list of {"biome_type", "biome_index", "lon", "lat", "props": {}}
    """
    biome_layers = find_all_biome_layers()
    polygon_zones = []
    point_zones = []

    # ── Polygon populate biomes ──
    for layer in biome_layers["polygon"]:
        has_btype = layer.fields().indexOf("biome_type") >= 0
        if not has_btype:
            continue
        # Collect property field names (density, canopy_height, etc.)
        prop_fields = []
        for field in layer.fields():
            fname = field.name().lower()
            if fname not in ("biome_type", "fid", "id") and not fname.startswith("_"):
                prop_fields.append(field.name())

        for feat in layer.getFeatures():
            btype = str(feat["biome_type"]) if feat["biome_type"] else ""
            if not btype or _is_terrain_modifier(btype):
                continue  # skip terrain modifiers — already in recipes
            geom = feat.geometry()
            if geom is None or geom.isEmpty():
                continue
            bindex = _biome_index_for_type(btype)

            # Collect properties
            props = {}
            for fname in prop_fields:
                val = feat[fname]
                if val is not None:
                    try:
                        props[fname] = float(val) if isinstance(val, (int, float)) else str(val)
                    except (ValueError, TypeError):
                        props[fname] = str(val)

            # Extract polygon rings
            if geom.isMultipart():
                for part in geom.asMultiPolygon():
                    if part and part[0]:
                        coords = [[round(p.x(), 6), round(p.y(), 6)] for p in part[0]]
                        if len(coords) >= 3:
                            polygon_zones.append({
                                "biome_type": btype,
                                "biome_index": bindex,
                                "coords": coords,
                                "props": props,
                            })
            else:
                rings = geom.asPolygon()
                if rings and rings[0]:
                    coords = [[round(p.x(), 6), round(p.y(), 6)] for p in rings[0]]
                    if len(coords) >= 3:
                        polygon_zones.append({
                            "biome_type": btype,
                            "biome_index": bindex,
                            "coords": coords,
                            "props": props,
                        })

    # ── Point populate biomes ──
    for layer in biome_layers["point"]:
        has_btype = layer.fields().indexOf("biome_type") >= 0
        if not has_btype:
            continue
        prop_fields = []
        for field in layer.fields():
            fname = field.name().lower()
            if fname not in ("biome_type", "fid", "id", "radius", "depth") and not fname.startswith("_"):
                prop_fields.append(field.name())

        for feat in layer.getFeatures():
            btype = str(feat["biome_type"]) if feat["biome_type"] else ""
            if not btype or _is_terrain_modifier(btype):
                continue  # skip terrain modifiers
            geom = feat.geometry()
            if geom is None or geom.isEmpty():
                continue
            pt = geom.asPoint()
            bindex = _biome_index_for_type(btype)
            props = {}
            for fname in prop_fields:
                val = feat[fname]
                if val is not None:
                    try:
                        props[fname] = float(val) if isinstance(val, (int, float)) else str(val)
                    except (ValueError, TypeError):
                        props[fname] = str(val)
            point_zones.append({
                "biome_type": btype,
                "biome_index": bindex,
                "lon": round(pt.x(), 6),
                "lat": round(pt.y(), 6),
                "props": props,
            })

    print(f"  Collected {len(polygon_zones)} populate polygon zones, "
          f"{len(point_zones)} populate point zones")
    return polygon_zones, point_zones


def _build_populate_zones_for_chunk(lon_min, lon_max, lat_min, lat_max,
                                     polygon_zones, point_zones,
                                     polygon_spatial_idx=None):
    """
    Build the populate_zones array for a single chunk.

    For each populate polygon: clip to chunk bbox, classify as full/partial/None.
    For each populate point: check if inside chunk bbox.

    Returns list of zone dicts ready for recipe JSON.
    """
    zones = []

    # Polygon zones — check spatial index if available, else brute force bbox
    if polygon_spatial_idx is not None:
        candidates = polygon_spatial_idx(lon_min, lon_max, lat_min, lat_max)
    else:
        candidates = range(len(polygon_zones))

    for idx in candidates:
        pz = polygon_zones[idx]
        result = _clip_polygon_to_chunk(pz["coords"], lon_min, lon_max, lat_min, lat_max)
        if result is None:
            continue
        zone = {
            "biome_type": pz["biome_type"],
            "biome_index": pz["biome_index"],
        }
        if result == "full":
            zone["coverage"] = "full"
        else:
            clipped = _simplify_polygon(result)
            zone["coverage"] = "partial"
            zone["vertices"] = clipped
        # Merge any biome-specific properties
        if pz["props"]:
            zone.update(pz["props"])
        zones.append(zone)

    # Point zones
    for pz in point_zones:
        if lon_min <= pz["lon"] <= lon_max and lat_min <= pz["lat"] <= lat_max:
            zone = {
                "biome_type": pz["biome_type"],
                "biome_index": pz["biome_index"],
                "coverage": "point",
                "lon": pz["lon"],
                "lat": pz["lat"],
            }
            if pz["props"]:
                zone.update(pz["props"])
            zones.append(zone)

    return zones


# ============================================================
# CHUNK RECIPE EXPORT — JSON recipes for runtime heightmap generation
# ============================================================

def generate_chunk_recipes(heightmap_tif_path=None):
    """
    Export per-chunk JSON recipe files instead of pre-baked PNG heightmaps.

    Each recipe contains the contour vertices, crater data, linear features
    (rivers/canyons), radial features (fumaroles/caves/volcanoes), and noise
    parameters needed to generate a heightmap at runtime at any resolution.

    If *heightmap_tif_path* is provided and RECIPE_GRID_SAMPLES > 0,
    a regular NxN grid of elevation samples is read from the global
    heightmap and appended to each chunk's contour_vertices.  This fills
    gaps in flat areas where contour lines are sparse.
    """
    import time as _time
    memlog("chunk_recipes: START")

    # ── 1. Collect contour vertices ──
    contour_layers = find_layers_by_keyword("contour") + find_layers_by_keyword(
        "elevation"
    )
    vector_layers = [l for l in contour_layers if isinstance(l, QgsVectorLayer)]

    all_contour_pts = []  # list of [lon, lat, elev]
    elev_field_name = None
    for layer in vector_layers:
        elev_field = None
        for field in layer.fields():
            if field.name().lower() in ("elev", "elevation", "height", "z", "alt"):
                elev_field = field.name()
                break
        if not elev_field:
            continue
        elev_field_name = elev_field
        for feature in layer.getFeatures():
            elev = feature[elev_field]
            if elev is None:
                continue
            elev = float(elev)
            geom = feature.geometry()
            if geom is None or geom.isNull():
                continue
            centroid = geom.centroid().asPoint()
            if abs(centroid.x()) < 0.01 and abs(centroid.y()) < 0.01 and elev == 0.0:
                continue
            for vertex in geom.vertices():
                all_contour_pts.append([vertex.x(), vertex.y(), elev])

    if all_contour_pts:
        contour_arr = np.array(all_contour_pts, dtype=np.float64)
        # Free the Python list immediately — numpy array is all we need.
        _n_contour_pts = len(all_contour_pts)
        del all_contour_pts
        memlog("chunk_recipes: contour_arr built",
               f"pts={_n_contour_pts}, bytes={contour_arr.nbytes}")
        print(f"  {len(contour_arr)} contour vertices, elevation range "
              f"[{contour_arr[:, 2].min():.1f}, {contour_arr[:, 2].max():.1f}]m")
    else:
        contour_arr = np.empty((0, 3), dtype=np.float64)
        del all_contour_pts
        print("  ⚠ No contour vertices found — recipes will have flat base elevation.")

    # ── 2. Collect crater data ──
    point_layers = find_all_biome_layers()["point"]

    # Use 4 parallel float lists instead of a list of dicts — saves ~1.5 GB
    # for dense crater datasets (e.g. 6M craters).  The lists are converted
    # to a compact numpy array once collection is complete.
    _cr_lons = []
    _cr_lats = []
    _cr_radii = []
    _cr_depths = []
    radial_features = []  # fumaroles, caves, volcanoes, etc.
    m_per_deg = PLANET_RADIUS * math.pi / 180.0

    for layer in point_layers:
        has_btype = layer.fields().indexOf("biome_type") >= 0
        has_radius = layer.fields().indexOf("radius") >= 0
        has_depth = layer.fields().indexOf("depth") >= 0
        # Individual biome layers store biome_type as a layer custom property
        # instead of a per-feature field.
        layer_btype = layer.customProperty("biome_type", "")
        if not has_btype and not layer_btype:
            continue
        for feat in layer.getFeatures():
            geom = feat.geometry()
            if geom is None or geom.isEmpty():
                continue
            pt = geom.asPoint()
            if has_btype and feat["biome_type"]:
                btype = str(feat["biome_type"])
            else:
                btype = layer_btype

            if btype == "spatial-crater":
                radius_m = 185.0
                if has_radius and feat["radius"] is not None:
                    try:
                        r = float(feat["radius"])
                        if r > 0:
                            radius_m = r
                    except (ValueError, TypeError):
                        pass
                if radius_m < _CR_MIN_RADIUS_M:
                    continue
                depth_m = _crater_depth_for_radius(radius_m)
                _cr_lons.append(round(pt.x(), 6))
                _cr_lats.append(round(pt.y(), 6))
                _cr_radii.append(round(radius_m, 1))
                _cr_depths.append(round(depth_m, 2))
            elif btype in ("volcanic_geothermal-fumarole", "fumarole", "cave", "volcanic_geothermal-active_volcano",
                           "volcanic_active", "volcanic_geothermal-ice_geyser", "ice_geyser",
                           "volcanic_geothermal-mineral_thermal_source", "mineral_hot_spring"):
                radius_m = 185.0
                if has_radius and feat["radius"] is not None:
                    try:
                        r = float(feat["radius"])
                        if r > 0:
                            radius_m = r
                    except (ValueError, TypeError):
                        pass
                depth_m = 15.0  # default
                if has_depth and feat["depth"] is not None:
                    try:
                        d = float(feat["depth"])
                        if d > 0:
                            depth_m = d
                    except (ValueError, TypeError):
                        pass
                profile = "bowl"
                if btype in ("volcanic_geothermal-active_volcano", "volcanic_active"):
                    profile = "volcanic"
                radial_features.append({
                    "type": btype,
                    "lon": round(pt.x(), 6),
                    "lat": round(pt.y(), 6),
                    "radius_m": round(radius_m, 1),
                    "depth_m": round(depth_m, 2),
                    "profile": profile,
                })

    # Convert to compact numpy float64 array: (N, 4) columns = lon, lat, radius_m, depth_m.
    # Free the primitive lists immediately to reclaim memory before KDTree construction.
    _crater_count = len(_cr_lons)
    print(f"  {_crater_count} craters, {len(radial_features)} radial features")
    memlog("chunk_recipes: craters collected", f"count={_crater_count}")
    if _crater_count > 0:
        crater_arr = np.array([_cr_lons, _cr_lats, _cr_radii, _cr_depths], dtype=np.float64).T
        # Deduplicate craters that appear in multiple QGIS layers
        _pre_dedup = len(crater_arr)
        crater_arr = np.unique(crater_arr, axis=0)
        if len(crater_arr) < _pre_dedup:
            print(f"  Removed {_pre_dedup - len(crater_arr)} duplicate craters "
                  f"({len(crater_arr)} unique)")
    else:
        crater_arr = np.empty((0, 4), dtype=np.float64)
    del _cr_lons, _cr_lats, _cr_radii, _cr_depths

    # ── 3. Collect linear features (rivers, canyons, lava rivers, etc.) ──
    linear_features = []
    biome_layers = find_all_biome_layers()
    for layer in biome_layers["line"]:
        has_btype = layer.fields().indexOf("biome_type") >= 0
        has_ws = layer.fields().indexOf("width_start") >= 0
        has_we = layer.fields().indexOf("width_end") >= 0
        has_width = layer.fields().indexOf("width") >= 0
        has_depth = layer.fields().indexOf("depth") >= 0
        for feat in layer.getFeatures():
            geom = feat.geometry()
            if geom is None or geom.isEmpty():
                continue
            btype = str(feat["biome_type"]) if has_btype and feat["biome_type"] else "maritime_river-river"

            # Extract centerline
            centerline = []
            if geom.isMultipart():
                for part in geom.asMultiPolyline():
                    for pt in part:
                        centerline.append([round(pt.x(), 6), round(pt.y(), 6)])
            else:
                for pt in geom.asPolyline():
                    centerline.append([round(pt.x(), 6), round(pt.y(), 6)])
            if len(centerline) < 2:
                continue

            # Read progressive width (metres)
            width_start_m = 0.0
            width_end_m = 0.0
            if has_ws and feat["width_start"] is not None:
                try:
                    ws = float(feat["width_start"])
                    if ws > 0:
                        width_start_m = ws
                except (ValueError, TypeError):
                    pass
            if has_we and feat["width_end"] is not None:
                try:
                    we = float(feat["width_end"])
                    if we > 0:
                        width_end_m = we
                except (ValueError, TypeError):
                    pass
            # Legacy fallback: single 'width' field
            if width_start_m <= 0.0 and width_end_m <= 0.0 and has_width:
                if feat["width"] is not None:
                    try:
                        w = float(feat["width"])
                        if w > 0:
                            width_start_m = w
                            width_end_m = w
                    except (ValueError, TypeError):
                        pass
            if width_start_m <= 0.0 and width_end_m <= 0.0:
                width_start_m = 100.0
                width_end_m = 100.0

            # Skip degenerate rivers where both widths are effectively zero
            if max(width_start_m, width_end_m) < 0.01:
                continue

            # Depth: override from 'depth' field, or derive from width (1:10 ratio)
            depth_override = None
            if has_depth and feat["depth"] is not None:
                try:
                    d = float(feat["depth"])
                    if d > 0:
                        depth_override = d
                except (ValueError, TypeError):
                    pass

            max_width_m = max(width_start_m, width_end_m)
            half_width_max_deg = (max_width_m / 2.0) / m_per_deg

            # Compute per-segment cumulative lengths for along_t calculation.
            # This allows the runtime to compute normalized position along
            # the centerline for width interpolation.
            seg_lengths = []
            for i in range(len(centerline) - 1):
                dx = (centerline[i + 1][0] - centerline[i][0]) * m_per_deg
                dy = (centerline[i + 1][1] - centerline[i][1]) * m_per_deg
                seg_lengths.append(round(math.sqrt(dx * dx + dy * dy), 2))
            total_length = sum(seg_lengths)
            cum_lengths = [0.0]
            running = 0.0
            for sl in seg_lengths:
                running += sl
                cum_lengths.append(round(running, 2))

            # Determine profile type
            profile = "v_shape"
            if btype in ("rocky_landform-canyon", "canyon", "icy-ice_crevasse", "ice_crevasse", "aride_desert-dry_river_bed", "dry_riverbed", "rocky_landform-pressure_canyon", "pressure_canyon"):
                profile = "u_shape"
            elif btype in ("volcanic_geothermal-lava_river", "lava_river"):
                profile = "u_shape"

            # Compute bounding box of this feature
            lons = [p[0] for p in centerline]
            lats = [p[1] for p in centerline]
            linear_features.append({
                "type": btype,
                "centerline": centerline,
                "width_start_m": round(width_start_m, 3),
                "width_end_m": round(width_end_m, 3),
                "half_width_max_deg": round(half_width_max_deg, 8),
                "depth_override": round(depth_override, 2) if depth_override is not None else None,
                "total_length_m": round(total_length, 2),
                "cum_lengths": cum_lengths,
                "profile": profile,
                "bbox_min": [min(lons) - half_width_max_deg, min(lats) - half_width_max_deg],
                "bbox_max": [max(lons) + half_width_max_deg, max(lats) + half_width_max_deg],
            })

    print(f"  {len(linear_features)} linear features")
    memlog("chunk_recipes: linear features collected",
           f"count={len(linear_features)}")

    # ── 3b. Collect populate-only biome data ──
    populate_polygons, populate_points = _collect_populate_data()
    memlog("chunk_recipes: populate data collected",
           f"polygons={len(populate_polygons)}, points={len(populate_points)}")

    # Build a simple AABB spatial index for populate polygons
    # Each entry: (min_lon, max_lon, min_lat, max_lat, original_index)
    _poly_bboxes = []
    for i, pz in enumerate(populate_polygons):
        coords = pz["coords"]
        lons = [c[0] for c in coords]
        lats = [c[1] for c in coords]
        _poly_bboxes.append((min(lons), max(lons), min(lats), max(lats), i))

    def _polygon_spatial_query(lon_min, lon_max, lat_min, lat_max):
        """Return indices of populate polygons whose AABB overlaps the chunk bbox."""
        result = []
        for pmin_lon, pmax_lon, pmin_lat, pmax_lat, idx in _poly_bboxes:
            if pmax_lon >= lon_min and pmin_lon <= lon_max and \
               pmax_lat >= lat_min and pmin_lat <= lat_max:
                result.append(idx)
        return result

    # ── 4. Build spatial indices ──
    try:
        from scipy.spatial import cKDTree
        has_scipy = True
    except ImportError:
        has_scipy = False

    contour_tree = None
    if has_scipy and len(contour_arr) > 0:
        contour_tree = cKDTree(contour_arr[:, :2])
        print(f"  Built contour KD-tree over {len(contour_arr)} vertices")
        memlog("chunk_recipes: contour KD-tree built")

    crater_tree = None
    max_crater_outer_deg = 0.0
    if len(crater_arr) > 0:
        max_crater_outer_deg = float(crater_arr[:, 2].max()) * _CR_RIM_OUTER_MULT / m_per_deg
        if has_scipy:
            crater_tree = cKDTree(crater_arr[:, :2])
            print(f"  Built crater KD-tree over {len(crater_arr)} craters")
            memlog("chunk_recipes: crater KD-tree built")

    # ── 5. Export configuration ──
    export_depth = min(MAX_QUADTREE_DEPTH, CHUNK_EXPORT_DEPTH)
    nside = 2 ** export_depth
    npix = 12 * nside * nside

    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    ensure_dir(chunks_dir)

    elev_min = ELEV_MIN if ELEV_MIN is not None else 0.0
    elev_max = ELEV_MAX if ELEV_MAX is not None else 0.0
    if elev_max <= elev_min and len(contour_arr) > 0:
        elev_max = float(contour_arr[:, 2].max())
        elev_min = float(contour_arr[:, 2].min())
    elev_range = elev_max - elev_min if elev_max > elev_min else 1.0

    # Contour search margin: ~1× chunk angular width.
    # At depth 6, chunk ≈ 0.9°, so margin ≈ 0.9° is plenty for IDW overlap.
    # The grid samples from the global heightmap fill the interior anyway.
    _chunk_side_deg = math.degrees(math.sqrt(math.pi / 3.0) / nside)
    MARGIN_DEG = _chunk_side_deg * 1.0

    chunk_manifest = []
    total = npix
    count = 0

    # Global noise config — deterministic per chunk via seed
    noise_config = {
        "octaves": [
            {"frequency": 0.02, "amplitude": 2.0},
            {"frequency": 0.005, "amplitude": 8.0},
            {"frequency": 0.001, "amplitude": 20.0},
        ]
    }

    # ── 6. Load global heightmap for grid sampling ──
    global_hm_data = None
    global_hm_gt = None  # GeoTransform (origin_lon, pixel_w, 0, origin_lat, 0, -pixel_h)
    global_hm_w = 0
    global_hm_h = 0
    grid_n = RECIPE_GRID_SAMPLES  # samples per edge (0 = disabled)

    if grid_n > 0 and heightmap_tif_path and os.path.exists(heightmap_tif_path):
        try:
            from osgeo import gdal as _gdal_hm
            ds = _gdal_hm.Open(heightmap_tif_path)
            if ds is not None:
                global_hm_gt = ds.GetGeoTransform()
                global_hm_w = ds.RasterXSize
                global_hm_h = ds.RasterYSize
                global_hm_data = ds.GetRasterBand(1).ReadAsArray().astype(np.float64)
                ds = None
                print(f"  Loaded global heightmap {global_hm_w}×{global_hm_h} "
                      f"for {grid_n}×{grid_n} grid sampling per chunk")
                memlog("chunk_recipes: global heightmap loaded",
                       f"bytes={global_hm_data.nbytes}")
        except Exception as e:
            print(f"  ⚠ Could not load global heightmap for grid sampling: {e}")
            global_hm_data = None

    print(f"  Generating {total} chunk recipes (HEALPix nside={nside})...")
    memlog("chunk_recipes: entering main loop",
           f"total={total}, contours={len(contour_arr)}, "
           f"craters={len(crater_arr)}, linear={len(linear_features)}")
    _t0 = _time.time()

    for ipix in range(npix):
        base_pixel = ipix // (nside * nside)
        base_dir = os.path.join(chunks_dir, f"base_{base_pixel}")
        ensure_dir(base_dir)

        # Get lon/lat bounding box for this HEALPix pixel
        lon_min_c, lon_max_c, lat_min_c, lat_max_c = \
            hpx.get_tile_lonlat_bbox(nside, ipix, margin_deg=0.0)
        lat_span = lat_max_c - lat_min_c
        # lon_span can be ~360° for date-line-crossing chunks — never trust it
        # for search radius.  Use the known angular pixel size instead.
        safe_span = _chunk_side_deg * 2.0  # generous: 2× pixel side

        # ── Query nearby contour vertices ──
        chunk_contours = []
        if contour_tree is not None:
            center_lon = (lon_min_c + lon_max_c) / 2.0
            center_lat = (lat_min_c + lat_max_c) / 2.0
            search_radius = safe_span + MARGIN_DEG
            nearby_idxs = contour_tree.query_ball_point(
                [center_lon, center_lat], search_radius)
            pts = contour_arr[nearby_idxs] if nearby_idxs else np.empty((0, 3))
            if len(pts) > 0:
                chunk_contours = [
                    [round(float(p[0]), 6),
                     round(float(p[1]), 6),
                     round(float(p[2]), 2)]
                    for p in pts
                ]
        elif len(contour_arr) > 0:
            # Brute-force bbox filter — use center + safe_span to avoid
            # 360° wrap at date line
            center_lon = (lon_min_c + lon_max_c) / 2.0
            center_lat = (lat_min_c + lat_max_c) / 2.0
            half_search = safe_span / 2.0 + MARGIN_DEG
            mask = (
                (np.abs(contour_arr[:, 0] - center_lon) <= half_search) &
                (np.abs(contour_arr[:, 1] - center_lat) <= half_search)
            )
            pts = contour_arr[mask]
            chunk_contours = [
                [round(float(p[0]), 6),
                 round(float(p[1]), 6),
                 round(float(p[2]), 2)]
                for p in pts
            ]

        # ── Sample regular elevation grid in PIXEL space from global heightmap ──
        # Grid is aligned to HEALPix sub-pixel positions, NOT regular lon/lat.
        # This avoids non-uniform sampling near HEALPix face boundaries where
        # the lon/lat → pixel mapping is highly non-linear.
        # Grid has inner_n × inner_n cells + 1-cell margin = (inner_n+2)².
        # Godot samples this grid via: gx = px * inner_n / resolution + 0.5
        grid_elevations = []
        if global_hm_data is not None and grid_n > 0:
            gt = global_hm_gt
            npface = nside * nside
            hp_face = ipix // npface
            hp_local = ipix % npface
            hp_ix, hp_iy = hpx.nest2xy(hp_local)
            recipe_res = 256  # must match Godot _recipe_resolution
            sub_nside = nside * recipe_res
            pix_step = float(recipe_res) / grid_n  # pixels per grid cell
            grid_total = grid_n + 2  # inner + margin
            for gy in range(grid_total):
                row = []
                # Pixel center for grid row gy
                fpy = (gy - 0.5) * pix_step
                sub_iy = hp_iy * recipe_res + fpy
                for gx in range(grid_total):
                    # Pixel center for grid column gx
                    fpx = (gx - 0.5) * pix_step
                    sub_ix = hp_ix * recipe_res + fpx
                    # Convert HEALPix sub-pixel to lon/lat
                    sample_lon, sample_lat = hpx.face_xy_to_lonlat(
                        hp_face, sub_ix + 0.5, sub_iy + 0.5, sub_nside)
                    # Convert lon/lat to heightmap pixel coords via GeoTransform
                    px_f = (sample_lon - gt[0]) / gt[1]
                    py_f = (sample_lat - gt[3]) / gt[5]
                    x0 = int(px_f)
                    y0 = int(py_f)
                    if x0 < 0 or x0 >= global_hm_w - 1 or \
                       y0 < 0 or y0 >= global_hm_h - 1:
                        row.append(round(float(elev_min), 2))
                        continue
                    # Bilinear interpolation
                    fx = px_f - x0
                    fy = py_f - y0
                    x1 = min(x0 + 1, global_hm_w - 1)
                    y1 = min(y0 + 1, global_hm_h - 1)
                    v00 = global_hm_data[y0, x0]
                    v10 = global_hm_data[y0, x1]
                    v01 = global_hm_data[y1, x0]
                    v11 = global_hm_data[y1, x1]
                    elev_val = (v00 * (1 - fx) * (1 - fy)
                                + v10 * fx * (1 - fy)
                                + v01 * (1 - fx) * fy
                                + v11 * fx * fy)
                    row.append(round(float(elev_val), 2))
                grid_elevations.append(row)

        # Base elevation (median of nearby contours, or global min)
        if chunk_contours:
            elevations = [p[2] for p in chunk_contours]
            base_elev = round(float(np.median(elevations)), 2)
        else:
            base_elev = round(elev_min, 2)

        # ── Query nearby craters ──
        # Dicts are built on demand from the compact numpy array to avoid
        # keeping 6M Python dicts in memory simultaneously.
        chunk_craters = []
        if crater_tree is not None and len(crater_arr) > 0:
            search_r = safe_span + max_crater_outer_deg
            center_lon = (lon_min_c + lon_max_c) / 2.0
            center_lat = (lat_min_c + lat_max_c) / 2.0
            nearby_cr = crater_tree.query_ball_point(
                [center_lon, center_lat], search_r)
            for idx in nearby_cr:
                cr_lon_v = float(crater_arr[idx, 0])
                cr_lat_v = float(crater_arr[idx, 1])
                cr_radius_v = float(crater_arr[idx, 2])
                cr_depth_v = float(crater_arr[idx, 3])
                cr_outer_deg_lat = cr_radius_v * _CR_RIM_OUTER_MULT / m_per_deg
                _cos_c = math.cos(math.radians(cr_lat_v)) if abs(cr_lat_v) < 89.5 else 0.01
                cr_outer_deg_lon = cr_outer_deg_lat / _cos_c
                # AABB overlap check
                if (lon_max_c + cr_outer_deg_lon >= cr_lon_v - cr_outer_deg_lon and
                    lon_min_c - cr_outer_deg_lon <= cr_lon_v + cr_outer_deg_lon and
                    lat_max_c + cr_outer_deg_lat >= cr_lat_v - cr_outer_deg_lat and
                    lat_min_c - cr_outer_deg_lat <= cr_lat_v + cr_outer_deg_lat):
                    chunk_craters.append({
                        "lon": round(cr_lon_v, 6),
                        "lat": round(cr_lat_v, 6),
                        "radius_m": round(cr_radius_v, 1),
                        "depth_m": round(cr_depth_v, 2),
                    })
        elif len(crater_arr) > 0:
            for ci in range(len(crater_arr)):
                cr_lon_v = float(crater_arr[ci, 0])
                cr_lat_v = float(crater_arr[ci, 1])
                cr_radius_v = float(crater_arr[ci, 2])
                cr_depth_v = float(crater_arr[ci, 3])
                cr_outer_deg_lat = cr_radius_v * _CR_RIM_OUTER_MULT / m_per_deg
                _cos_c = math.cos(math.radians(cr_lat_v)) if abs(cr_lat_v) < 89.5 else 0.01
                cr_outer_deg_lon = cr_outer_deg_lat / _cos_c
                if (lon_max_c + cr_outer_deg_lon >= cr_lon_v - cr_outer_deg_lon and
                    lon_min_c - cr_outer_deg_lon <= cr_lon_v + cr_outer_deg_lon and
                    lat_max_c + cr_outer_deg_lat >= cr_lat_v - cr_outer_deg_lat and
                    lat_min_c - cr_outer_deg_lat <= cr_lat_v + cr_outer_deg_lat):
                    chunk_craters.append({
                        "lon": round(cr_lon_v, 6),
                        "lat": round(cr_lat_v, 6),
                        "radius_m": round(cr_radius_v, 1),
                        "depth_m": round(cr_depth_v, 2),
                    })

        # ── Query overlapping linear features ──
        chunk_linear = []
        margin_lin = 0.5  # extra degrees margin for linear feature overlap
        for lf in linear_features:
            bb = lf["bbox_min"]
            bt = lf["bbox_max"]
            if (lon_max_c + margin_lin >= bb[0] and
                lon_min_c - margin_lin <= bt[0] and
                lat_max_c + margin_lin >= bb[1] and
                lat_min_c - margin_lin <= bt[1]):
                # Store without bbox (not needed at runtime)
                entry = {
                    "type": lf["type"],
                    "centerline": lf["centerline"],
                    "width_start_m": lf["width_start_m"],
                    "width_end_m": lf["width_end_m"],
                    "half_width_max_deg": lf["half_width_max_deg"],
                    "total_length_m": lf["total_length_m"],
                    "cum_lengths": lf["cum_lengths"],
                    "profile": lf["profile"],
                }
                if lf["depth_override"] is not None:
                    entry["depth_override"] = lf["depth_override"]
                chunk_linear.append(entry)

        # ── Query overlapping radial features ──
        chunk_radial = []
        for rf in radial_features:
            rf_outer_deg = rf["radius_m"] * 1.5 / m_per_deg  # generous margin
            if (lon_max_c + rf_outer_deg >= rf["lon"] - rf_outer_deg and
                lon_min_c - rf_outer_deg <= rf["lon"] + rf_outer_deg and
                lat_max_c + rf_outer_deg >= rf["lat"] - rf_outer_deg and
                lat_min_c - rf_outer_deg <= rf["lat"] + rf_outer_deg):
                chunk_radial.append(rf)

        # ── Deterministic noise seed ──
        noise_seed = ipix * 104729 + nside * 7919

        # ── Build populate zones for this chunk ──
        chunk_populate = _build_populate_zones_for_chunk(
            lon_min_c, lon_max_c, lat_min_c, lat_max_c,
            populate_polygons, populate_points,
            polygon_spatial_idx=_polygon_spatial_query,
        )

        # ── Build recipe ──
        chunk_key = f"hp_n{nside}_p{ipix}"
        has_grid = grid_elevations and grid_n >= 2
        elevation_section = {
            "base_elevation": base_elev,
            "interpolation": "idw",
            "idw_power": 2,
            "idw_k": 8,
            "grid_elevations": grid_elevations,
            "grid_inner_n": grid_n if grid_elevations else 0,
        }
        # Only include contour_vertices when there is no pixel-space grid,
        # as the grid path (v5+) makes them redundant.  Omitting them
        # shrinks recipes from ~200 KiB to ~10 KiB (97% of the file).
        if not has_grid:
            elevation_section["contour_vertices"] = chunk_contours
        recipe = {
            "version": 7,
            "key": chunk_key,
            "nside": nside,
            "ipix": ipix,
            "elevation": elevation_section,
            "terrain_modifiers": {
                "craters": chunk_craters,
                "linear_features": chunk_linear,
                "radial_features": chunk_radial,
            },
            "populate_zones": chunk_populate,
            "noise": {
                "seed": noise_seed,
                "octaves": noise_config["octaves"],
            },
        }

        # Backwards compat: keep flat keys too until Godot is updated
        recipe["craters"] = chunk_craters
        recipe["linear_features"] = chunk_linear
        recipe["radial_features"] = chunk_radial

        # ── Save recipe JSON ──
        out_path = os.path.join(base_dir, f"{chunk_key}.recipe.json")
        with open(out_path, "w") as f:
            json.dump(recipe, f, separators=(',', ':'))

        chunk_manifest.append({
            "key": chunk_key,
            "nside": nside,
            "ipix": ipix,
            "file": os.path.relpath(out_path, EXPORT_DIR),
            "contour_count": len(chunk_contours),
            "crater_count": len(chunk_craters),
            "linear_count": len(chunk_linear),
            "radial_count": len(chunk_radial),
            "populate_zone_count": len(chunk_populate),
        })

        count += 1
        if count % 200 == 0:
            elapsed = _time.time() - _t0
            rate = count / elapsed if elapsed > 0 else 0
            eta = (total - count) / rate if rate > 0 else 0
            print(f"    {count}/{total} recipes... "
                  f"({elapsed:.0f}s elapsed, ~{eta:.0f}s remaining)")
        if count % 1000 == 0:
            memlog(f"chunk_recipes: loop {count}/{total}",
                   f"contours={len(chunk_contours)} craters={len(chunk_craters)} "
                   f"grid={len(grid_elevations)} linear={len(chunk_linear)}")
        if count == 1:
            memlog("chunk_recipes: first iteration done",
                   f"contours={len(chunk_contours)} craters={len(chunk_craters)} "
                   f"grid={len(grid_elevations)} linear={len(chunk_linear)}")

    # ── Write manifest JSON ──
    manifest_path = os.path.join(chunks_dir, "chunk_manifest.json")
    manifest_data = {
        "planet_name": PLANET_NAME,
        "planet_radius": PLANET_RADIUS,
        "projection": "healpix",
        "nside": nside,
        "depth": export_depth,
        "total_pixels": npix,
        "format": "recipe",
        "elev_min": elev_min,
        "elev_max": elev_max,
        "noise_config": noise_config,
        "grid_samples_per_edge": grid_n if global_hm_data is not None else 0,
        "grid_with_margin": True,
        "total_chunks": len(chunk_manifest),
        "total_contour_vertices": len(contour_arr),
        "total_craters": len(crater_arr),
        "total_linear_features": len(linear_features),
        "total_radial_features": len(radial_features),
        "total_populate_polygons": len(populate_polygons),
        "total_populate_points": len(populate_points),
        "biome_data_in_recipes": True,
        "chunks": chunk_manifest,
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest_data, f, indent=2)

    elapsed = _time.time() - _t0
    memlog("chunk_recipes: loop finished", f"elapsed={elapsed:.1f}s")
    print(f"  ✓ {count} chunk recipes saved in {chunks_dir} ({elapsed:.1f}s)")
    print(f"  ✓ Manifest: {manifest_path}")
    memlog("chunk_recipes: END")
    return chunks_dir


# ============================================================
# CRATER BAKING — stamp crater profiles into chunk heightmaps
# ============================================================

# Crater depth-to-diameter ratios (must match crater_terrain.gd exactly).
_CR_RATIO_LARGE  = 0.20  # diameter > 400 m
_CR_RATIO_MEDIUM = 0.17  # diameter 200–400 m
_CR_RATIO_SMALL  = 0.15  # diameter 100–200 m
_CR_RATIO_TINY   = 0.12  # diameter 30–100 m
_CR_RATIO_MICRO  = 0.10  # diameter < 30 m
_CR_MAX_DEPTH_M  = 500.0
_CR_MIN_RADIUS_M = 20.0
_CR_RIM_UPLIFT_RATIO = 0.04
_CR_RIM_OUTER_MULT   = 1.15


def _crater_depth_for_radius(radius_m):
    """Compute crater depth from radius (metres).  Matches SpatialCraterTerrain.depth_for_radius."""
    diameter = radius_m * 2.0
    if diameter > 400.0:
        ratio = _CR_RATIO_LARGE
    elif diameter > 200.0:
        t = (diameter - 200.0) / 200.0
        ratio = _CR_RATIO_MEDIUM + (_CR_RATIO_LARGE - _CR_RATIO_MEDIUM) * t
    elif diameter > 100.0:
        t = (diameter - 100.0) / 100.0
        ratio = _CR_RATIO_SMALL + (_CR_RATIO_MEDIUM - _CR_RATIO_SMALL) * t
    elif diameter > 30.0:
        t = (diameter - 30.0) / 70.0
        ratio = _CR_RATIO_TINY + (_CR_RATIO_SMALL - _CR_RATIO_TINY) * t
    else:
        ratio = _CR_RATIO_MICRO
    return min(diameter * ratio, _CR_MAX_DEPTH_M)


def _crater_height_offset_vectorized(dist_m, radius_m, depth_m):
    """
    Vectorized crater height offset for numpy arrays.
    Matches SpatialCraterTerrain.height_offset exactly.
    Returns height adjustment array (negative = dig, positive = rim).
    """
    rim_outer = radius_m * _CR_RIM_OUTER_MULT
    rim_h = depth_m * _CR_RIM_UPLIFT_RATIO

    result = np.zeros_like(dist_m)

    # Rim band: radius <= dist < rim_outer
    rim_mask = (dist_m >= radius_m) & (dist_m < rim_outer)
    if rim_mask.any():
        t = 1.0 - (dist_m[rim_mask] - radius_m) / (rim_outer - radius_m)
        result[rim_mask] = rim_h * t * t * (3.0 - 2.0 * t)  # smoothstep

    # Bowl: dist < radius
    bowl_mask = dist_m < radius_m
    if bowl_mask.any():
        t = dist_m[bowl_mask] / radius_m
        result[bowl_mask] = -depth_m * (1.0 - t * t) + rim_h * t * t * (3.0 - 2.0 * t)

    return result


def stamp_craters_on_chunks():
    """
    Post-process chunk heightmaps by stamping crater depression profiles.

    Reads crater point features from QGIS biomes_point layers, builds a
    spatial index, then for each chunk PNG applies the crater height offset
    (matching SpatialCraterTerrain.gd) directly into the heightmap pixels.

    This eliminates all runtime crater computation in Godot.
    """
    import time as _time

    # ── Collect crater data from QGIS point layers ──
    point_layers = find_layers_by_keyword("biomes_point")
    point_layers = [l for l in point_layers if isinstance(l, QgsVectorLayer)]

    craters = []  # list of (lon, lat, radius_m)
    for layer in point_layers:
        for feat in layer.getFeatures():
            props_btype = feat["biome_type"] if layer.fields().indexOf("biome_type") >= 0 else ""
            if props_btype != "spatial-crater":
                continue
            geom = feat.geometry()
            if geom is None or geom.isEmpty():
                continue
            pt = geom.asPoint()
            radius_m = 185.0
            if layer.fields().indexOf("radius") >= 0:
                r = feat["radius"]
                if r is not None and float(r) > 0:
                    radius_m = float(r)
            if radius_m < _CR_MIN_RADIUS_M:
                continue
            craters.append((pt.x(), pt.y(), radius_m))  # lon, lat, radius_m

    if not craters:
        print("  No crater point features found — skipping crater baking.")
        return

    craters_arr = np.array(craters, dtype=np.float64)  # shape (N, 3)
    print(f"  Found {len(craters_arr)} craters, radius range "
          f"[{craters_arr[:, 2].min():.0f}, {craters_arr[:, 2].max():.0f}]m")

    # Degrees per metre at planet surface
    m_per_deg = PLANET_RADIUS * math.pi / 180.0

    # Max crater outer radius in degrees (for spatial queries)
    max_crater_outer_deg = float(craters_arr[:, 2].max()) * _CR_RIM_OUTER_MULT / m_per_deg

    # Build KD-tree on (lon, lat)
    try:
        from scipy.spatial import cKDTree
        has_scipy = True
    except ImportError:
        has_scipy = False

    if has_scipy:
        crater_tree = cKDTree(craters_arr[:, :2])
        print(f"  Built KD-tree over {len(craters_arr)} craters")
    else:
        crater_tree = None
        print("  ⚠ scipy not available — using brute-force crater lookup (slow)")

    # ── Load chunk manifest ──
    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    manifest_path = os.path.join(chunks_dir, "chunk_manifest.json")
    if not os.path.exists(manifest_path):
        print(f"  ✗ Chunk manifest not found: {manifest_path}")
        return

    with open(manifest_path, "r") as f:
        manifest = json.load(f)

    elev_min = manifest.get("elev_min", 0.0)
    elev_max = manifest.get("elev_max", 0.0)
    nside = manifest.get("nside", EXPORT_NSIDE)
    chunk_px = manifest.get("chunk_resolution_px", CHUNK_TILE_PX)
    chunks = manifest["chunks"]

    try:
        from osgeo import gdal
    except ImportError:
        print("  ✗ GDAL required for crater baking on GeoTIFF chunks")
        return

    _t0 = _time.time()
    stamped = 0
    craters_applied_total = 0

    for ci, chunk_info in enumerate(chunks):
        ipix = chunk_info["ipix"]

        # Build lon/lat grid for this HEALPix pixel
        lon_grid, lat_grid = hpx.get_tile_grid_lonlat(nside, ipix, chunk_px)

        # Find craters overlapping this chunk
        lon_min_c, lon_max_c, lat_min_c, lat_max_c = \
            hpx.get_tile_lonlat_bbox(nside, ipix, margin_deg=0.0)
        lon_center = (lon_min_c + lon_max_c) / 2.0
        lat_center = (lat_min_c + lat_max_c) / 2.0
        _chunk_side = math.degrees(math.sqrt(math.pi / 3.0) / nside)
        chunk_half_diag_deg = _chunk_side * 2.0  # safe cap for date-line chunks

        search_radius_deg = chunk_half_diag_deg + max_crater_outer_deg

        if has_scipy and crater_tree is not None:
            nearby_idxs = crater_tree.query_ball_point(
                [lon_center, lat_center], search_radius_deg)
        else:
            # Brute force
            dists = np.sqrt(
                (craters_arr[:, 0] - lon_center) ** 2 +
                (craters_arr[:, 1] - lat_center) ** 2)
            nearby_idxs = np.where(dists <= search_radius_deg)[0].tolist()

        if not nearby_idxs:
            continue

        # Load existing chunk heightmap (GeoTIFF Float32)
        chunk_file = os.path.join(EXPORT_DIR, chunk_info["file"])
        if not os.path.exists(chunk_file):
            continue

        ds = gdal.Open(chunk_file)
        if ds is None:
            continue
        height_m = ds.GetRasterBand(1).ReadAsArray().astype(np.float64)
        ds = None

        chunk_modified = False
        for idx in nearby_idxs:
            cr_lon, cr_lat, cr_radius_m = craters_arr[idx]
            cr_outer_deg_lat = cr_radius_m * _CR_RIM_OUTER_MULT / m_per_deg
            # Longitude degrees are shorter by cos(lat) — widen the AABB.
            _cos_cr = math.cos(math.radians(cr_lat)) if abs(cr_lat) < 89.5 else 0.01
            cr_outer_deg_lon = cr_outer_deg_lat / _cos_cr

            # Quick per-crater AABB check
            if (lon_grid.max() < cr_lon - cr_outer_deg_lon or
                lon_grid.min() > cr_lon + cr_outer_deg_lon or
                lat_grid.max() < cr_lat - cr_outer_deg_lat or
                lat_grid.min() > cr_lat + cr_outer_deg_lat):
                continue

            # Distance from each pixel to crater centre, in metres.
            cos_lat = np.cos(np.radians((lat_grid + cr_lat) * 0.5))
            dist_m_arr = np.sqrt(
                ((lon_grid - cr_lon) * cos_lat * m_per_deg) ** 2 +
                ((lat_grid - cr_lat) * m_per_deg) ** 2)

            # Only compute for pixels within the outer rim
            affect_mask = dist_m_arr < (cr_radius_m * _CR_RIM_OUTER_MULT)
            if not affect_mask.any():
                continue

            cr_depth = _crater_depth_for_radius(cr_radius_m)
            offset = _crater_height_offset_vectorized(
                dist_m_arr[affect_mask], cr_radius_m, cr_depth)
            height_m[affect_mask] += offset
            chunk_modified = True
            craters_applied_total += 1

        if chunk_modified:
            # Save back as GeoTIFF Float32
            driver = gdal.GetDriverByName('GTiff')
            out_ds = driver.Create(chunk_file, chunk_px, chunk_px, 1, gdal.GDT_Float32)
            out_ds.GetRasterBand(1).WriteArray(height_m.astype(np.float32))
            out_ds.FlushCache()
            out_ds = None
            stamped += 1

        if (ci + 1) % 200 == 0:
            elapsed = _time.time() - _t0
            print(f"    {ci + 1}/{len(chunks)} chunks scanned... "
                  f"({stamped} modified, {elapsed:.0f}s)")

    elapsed = _time.time() - _t0
    print(f"  ✓ Crater baking complete: {stamped} chunks modified, "
          f"{craters_applied_total} crater stamps applied ({elapsed:.1f}s)")

    # Update manifest to record that craters are baked
    manifest["craters_baked"] = True
    manifest["craters_count"] = len(craters_arr)
    with open(manifest_path, "w") as mf:
        json.dump(manifest, mf, indent=2)


# ============================================================
# SPATIAL TILE INDEX (lazy biome loading)
# ============================================================

TILE_DEG = 10  # degrees per tile cell (lon and lat)
TILE_NUM_COLS = 36  # 360 / 10
TILE_NUM_ROWS = 18  # 180 / 10


def _lonlat_to_tile(lon, lat):
    """Return (col, row) tile indices for a lon/lat point."""
    col = int((lon + 180.0) / TILE_DEG)
    row = int((lat + 90.0) / TILE_DEG)
    col = max(0, min(col, TILE_NUM_COLS - 1))
    row = max(0, min(row, TILE_NUM_ROWS - 1))
    return col, row


def _bbox_to_tiles(bbox_min_lon, bbox_min_lat, bbox_max_lon, bbox_max_lat):
    """Return all (col, row) tile indices that a bounding box overlaps."""
    col_min, row_min = _lonlat_to_tile(bbox_min_lon, bbox_min_lat)
    col_max, row_max = _lonlat_to_tile(bbox_max_lon, bbox_max_lat)
    tiles = []
    for c in range(col_min, col_max + 1):
        for r in range(row_min, row_max + 1):
            tiles.append((c, r))
    return tiles


def _feature_bbox(feat):
    """Extract the lon/lat bounding box from a GeoJSON feature's geometry.

    For Point + radius (spatial-crater) features the bbox is expanded by
    radius × RIM_OUTER_MULT so tile assignment covers the full crater rim.
    """
    geom = feat.get("geometry", {})
    coords = geom.get("coordinates", [])
    if not coords:
        return None
    gtype = geom.get("type")
    if gtype == "Point":
        lon, lat = float(coords[0]), float(coords[1])
        props = feat.get("properties", {})
        radius_m = float(props.get("radius") or 0)
        if radius_m > 0:
            rim_mult = 1.15  # SpatialCraterTerrain.RIM_OUTER_MULT
            m_per_deg = PLANET_RADIUS * math.pi / 180.0
            r_deg = radius_m * rim_mult / m_per_deg
            return lon - r_deg, lat - r_deg, lon + r_deg, lat + r_deg
        return lon, lat, lon, lat
    if gtype != "Polygon":
        return None
    ring = coords[0]
    if not ring:
        return None
    min_lon = min_lat = float("inf")
    max_lon = max_lat = float("-inf")
    for pt in ring:
        lon, lat = pt[0], pt[1]
        if lon < min_lon:
            min_lon = lon
        if lon > max_lon:
            max_lon = lon
        if lat < min_lat:
            min_lat = lat
        if lat > max_lat:
            max_lat = lat
    return min_lon, min_lat, max_lon, max_lat


def _round_coordinates(coords, decimals):
    """Recursively round all floats in a nested coordinate list."""
    if isinstance(coords, list):
        if coords and isinstance(coords[0], (int, float)):
            return [round(c, decimals) for c in coords]
        return [_round_coordinates(c, decimals) for c in coords]
    return coords


def _build_spatial_tile_index(merged_path, dest_dir=None):
    """Build per-tile biome files + spatial index from a merged biome GeoJSON.

    Creates:
      - ``{stem}_index.json`` — lightweight spatial index mapping tile keys
        to tile file names and zone counts.
      - ``{stem}_tile_{col}_{row}.json`` — per-tile GeoJSON files containing
        only the zones whose AABB overlaps that tile cell.

    Each zone is assigned a sequential ``zone_id`` (stored in its properties)
    so the runtime can deduplicate zones that appear in multiple tiles.
    Zones that span tile boundaries are duplicated into all overlapping tiles.

    Processes the main file and any existing .partN.json files one at a time,
    so memory usage stays at ~1x the size of the largest single file.

    After building tiles, stale ``.partN.json`` files from previous exports
    are cleaned up.

    If *dest_dir* is given, tile files and the spatial index are written there
    instead of next to the merged file.  This allows placing biome tiles
    alongside chunk recipe files.
    """
    if not os.path.exists(merged_path):
        return False

    stem, ext = os.path.splitext(merged_path)
    base_stem = os.path.basename(stem)

    # Determine output directory
    if dest_dir is not None:
        ensure_dir(dest_dir)
        output_dir = dest_dir
    else:
        output_dir = os.path.dirname(merged_path)

    index_path = os.path.join(output_dir, f"{base_stem}_index.json")

    # Compute coordinate precision for ~1 mm on the planet surface.
    # 1 degree of arc = π·R/180 metres.  For *d* decimal places the
    # resolution is 10^{-d} degrees → π·R / (180 · 10^d) metres.
    # We need π·R / (180 · 10^d) ≤ 0.001  ⟹  d ≥ log10(π·R / 0.18).
    coord_decimals = math.ceil(math.log10(math.pi * PLANET_RADIUS / 0.18))
    print(f"    Coordinate precision: {coord_decimals} decimal places "
          f"(~{math.pi * PLANET_RADIUS / (180 * 10**coord_decimals) * 1000:.2f} mm) "
          f"for radius {PLANET_RADIUS} m")

    # Remove stale tile files from a previous run
    if os.path.isdir(output_dir):
        for fname in os.listdir(output_dir):
            if fname.startswith(f"{base_stem}_tile_") and fname.endswith(ext):
                os.remove(os.path.join(output_dir, fname))

    # Enumerate files to process: main file + any .partN.json files
    files_to_process = [merged_path]
    part_num = 2
    while True:
        part_path = f"{stem}.part{part_num}{ext}"
        if os.path.exists(part_path):
            files_to_process.append(part_path)
            part_num += 1
        else:
            break

    total_file_size = sum(os.path.getsize(f) for f in files_to_process)
    memlog("build_spatial_tiles: START",
           f"files={len(files_to_process)} "
           f"total_size={total_file_size / (1024 * 1024):.1f}MB")

    # ── Process each file, building per-tile feature buffers ──
    # We accumulate serialized feature JSON strings per tile key in memory.
    # For ~6M small features at ~2.6KB each, the serialized strings for
    # a single file (~34K features) fit easily.  Tile files are flushed
    # after processing all input files.
    tile_buckets = {}  # (col, row) → list of feat_json strings
    all_biome_indices = set()
    zone_id = 0
    envelope = None  # captured from the first file

    for file_idx, fpath in enumerate(files_to_process):
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                raw = f.read()
        except MemoryError:
            print(f"  ⚠ {os.path.basename(fpath)}: too large to read; skipping.")
            continue

        decoder = json.JSONDecoder()

        # Locate the "features" array
        feat_key_pos = raw.find('"features"')
        if feat_key_pos < 0:
            del raw
            continue

        arr_start = raw.find('[', feat_key_pos)
        if arr_start < 0:
            del raw
            continue

        # Capture envelope from the first file
        if envelope is None:
            envelope = {"type": "FeatureCollection"}
            for key in ("name", "crs"):
                kp = raw.find(f'"{key}"')
                if 0 <= kp < arr_start:
                    val_start = raw.find(':', kp) + 1
                    while val_start < arr_start and raw[val_start] in ' \t\n\r':
                        val_start += 1
                    try:
                        val, _ = decoder.raw_decode(raw, val_start)
                        envelope[key] = val
                    except (json.JSONDecodeError, ValueError):
                        pass

        # Stream through features
        pos = arr_start + 1
        raw_len = len(raw)
        file_count = 0

        while pos < raw_len:
            while pos < raw_len and raw[pos] in ' \t\n\r,':
                pos += 1
            if pos >= raw_len or raw[pos] == ']':
                break

            try:
                feat, end_pos = decoder.raw_decode(raw, pos)
            except (json.JSONDecodeError, ValueError):
                break

            # Inject zone_id
            if "properties" not in feat:
                feat["properties"] = {}
            feat["properties"]["zone_id"] = zone_id

            # Collect biome_index
            bi = feat.get("properties", {}).get("biome_index")
            if bi is not None:
                all_biome_indices.add(int(bi))

            # Round coordinates to millimetre precision
            geom = feat.get("geometry")
            if geom and "coordinates" in geom:
                geom["coordinates"] = _round_coordinates(
                    geom["coordinates"], coord_decimals)

            bbox = _feature_bbox(feat)
            if bbox is not None:
                tiles = _bbox_to_tiles(bbox[0], bbox[1], bbox[2], bbox[3])
            else:
                tiles = [(0, 0)]

            feat_json = json.dumps(feat, separators=(',', ':'))
            for tile_key in tiles:
                if tile_key not in tile_buckets:
                    tile_buckets[tile_key] = []
                tile_buckets[tile_key].append(feat_json)

            del feat
            zone_id += 1
            file_count += 1
            pos = end_pos

        del raw
        gc.collect()

        if file_idx == 0 or (file_idx + 1) % 20 == 0 or file_idx == len(files_to_process) - 1:
            print(f"    Processed file {file_idx + 1}/{len(files_to_process)}: "
                  f"{os.path.basename(fpath)} ({file_count} features, "
                  f"{zone_id} total so far)")
            memlog("build_spatial_tiles: file done",
                   f"file={file_idx + 1}/{len(files_to_process)} "
                   f"zones={zone_id} tiles={len(tile_buckets)}")

    total_zones = zone_id
    if total_zones == 0 or envelope is None:
        print("  ⚠ No features found — spatial tile index not created.")
        return False

    # ── Write tile files ──
    envelope_json_prefix = json.dumps(envelope)[:-1]  # open '{' without closing '}'
    tiles_meta = {}

    for (col, row), feat_jsons in sorted(tile_buckets.items()):
        tile_key = f"{col}_{row}"
        tile_filename = f"{base_stem}_tile_{tile_key}{ext}"
        tile_path = os.path.join(output_dir, tile_filename)

        with open(tile_path, "w", encoding="utf-8") as tf:
            tf.write(envelope_json_prefix)
            tf.write(',"features":[')
            tf.write(",".join(feat_jsons))
            tf.write(']}')

        tile_size = os.path.getsize(tile_path)
        tiles_meta[tile_key] = {
            "file": tile_filename,
            "zone_count": len(feat_jsons),
            "size_bytes": tile_size,
        }

    del tile_buckets
    gc.collect()

    # ── Write spatial index ──
    index_data = {
        "version": 1,
        "tile_deg": TILE_DEG,
        "num_cols": TILE_NUM_COLS,
        "num_rows": TILE_NUM_ROWS,
        "total_zones": total_zones,
        "biome_indices": sorted(all_biome_indices),
        "tiles": tiles_meta,
    }
    with open(index_path, "w", encoding="utf-8") as f:
        json.dump(index_data, f, indent=2)

    # ── Cleanup old .partN.json files ──
    removed = 0
    pn = 2
    while True:
        pp = f"{stem}.part{pn}{ext}"
        if os.path.exists(pp):
            os.remove(pp)
            removed += 1
            pn += 1
        else:
            break
    if removed:
        print(f"    Removed {removed} stale .partN.json file(s)")

    # Remove the monolithic biomes file — the spatial tiles replace it
    if os.path.exists(merged_path):
        mono_size = os.path.getsize(merged_path) / (1024 * 1024)
        os.remove(merged_path)
        print(f"    Removed monolithic {os.path.basename(merged_path)} "
              f"({mono_size:.0f} MB) — replaced by {len(tiles_meta)} tile(s)")

    tile_count = len(tiles_meta)
    total_tile_size = sum(t["size_bytes"] for t in tiles_meta.values())
    print(f"  ✓ Built spatial tile index: {tile_count} tile(s), "
          f"{total_zones} zone(s), "
          f"{total_tile_size / (1024 * 1024):.1f} MB total")
    print(f"    Index: {os.path.basename(index_path)}")
    memlog("build_spatial_tiles: DONE",
           f"tiles={tile_count} zones={total_zones} "
           f"size={total_tile_size / (1024 * 1024):.1f}MB")
    return True


# ============================================================
# GEOJSON FILE SPLITTING (repo file-size limit)
# ============================================================

MAX_GEOJSON_BYTES = 90 * 1024 * 1024  # 90 MB — safety margin below 100 MB repo limit


def _split_geojson_if_needed(output_path, max_bytes=MAX_GEOJSON_BYTES):
    """Split a GeoJSON FeatureCollection into ≤ *max_bytes* part files.

    Part naming:
      - Part 1 overwrites the original file (``output_path``).
      - Part 2+: ``{stem}.part2.json``, ``{stem}.part3.json``, …

    Each part is a self-contained FeatureCollection with the same ``crs``.
    If the file is already within the limit, only stale part files from a
    previous export are cleaned up.
    """
    if not os.path.exists(output_path):
        return

    file_size = os.path.getsize(output_path)

    stem, ext = os.path.splitext(output_path)  # e.g. ("/…/tarsis_4_biomes", ".json")

    def _cleanup_stale_parts(keep_up_to=1):
        """Remove .partN.json files whose number exceeds *keep_up_to*."""
        n = keep_up_to + 1
        while True:
            part_path = f"{stem}.part{n}{ext}"
            if os.path.exists(part_path):
                os.remove(part_path)
                n += 1
            else:
                break

    if file_size <= max_bytes:
        _cleanup_stale_parts(keep_up_to=1)
        return

    # ── Choose split strategy based on file size ──
    # For files larger than 200 MB, json.load() would materialize the entire
    # feature graph as Python objects (~10-15x the file size in RAM), which
    # can exhaust system memory on datasets with millions of features (e.g.
    # 6M crater points → ~10 GB).  Use a streaming approach instead: read
    # the raw text once (~1x file size) and decode features one at a time.
    STREAMING_THRESHOLD = 200 * 1024 * 1024  # 200 MB
    if file_size > STREAMING_THRESHOLD:
        memlog("split_geojson: streaming split",
               f"file={os.path.basename(output_path)} size={file_size/(1024*1024):.1f}MB")
        _split_geojson_streaming(output_path, stem, ext, max_bytes, _cleanup_stale_parts)
        return

    # ── In-memory split for smaller files (< 200 MB) ──
    memlog("split_geojson: in-memory split",
           f"file={os.path.basename(output_path)} size={file_size/(1024*1024):.1f}MB")
    with open(output_path, "r") as f:
        data = json.load(f)

    features = data.get("features", [])
    if not features:
        _cleanup_stale_parts(keep_up_to=1)
        return

    # Reusable envelope (everything except "features")
    envelope = {k: v for k, v in data.items() if k != "features"}

    # Measure the byte overhead of an empty FeatureCollection wrapper
    empty_fc = dict(envelope, features=[])
    wrapper_overhead = len(json.dumps(empty_fc).encode("utf-8"))

    # ── Bucket features by serialized size ──
    buckets = [[]]           # list of lists of feature dicts
    bucket_sizes = [wrapper_overhead]  # current byte total per bucket

    for feat in features:
        feat_bytes = len(json.dumps(feat).encode("utf-8")) + 2  # +2 for comma/spacing
        if bucket_sizes[-1] + feat_bytes > max_bytes and buckets[-1]:
            # Start a new bucket
            buckets.append([])
            bucket_sizes.append(wrapper_overhead)
        buckets[-1].append(feat)
        bucket_sizes[-1] += feat_bytes

    # ── Write part files ──
    for i, bucket in enumerate(buckets):
        if i == 0:
            part_path = output_path
        else:
            part_path = f"{stem}.part{i + 1}{ext}"

        part_fc = dict(envelope, features=bucket)
        with open(part_path, "w") as f:
            json.dump(part_fc, f)

    _cleanup_stale_parts(keep_up_to=len(buckets))

    sizes_str = ", ".join(
        f"{os.path.getsize(output_path if i == 0 else f'{stem}.part{i+1}{ext}') / (1024*1024):.1f} MB"
        for i in range(len(buckets))
    )
    print(f"  ✓ Split {os.path.basename(output_path)} into {len(buckets)} part(s) ({sizes_str})")


def _split_geojson_streaming(output_path, stem, ext, max_bytes, cleanup_fn):
    """Memory-efficient GeoJSON splitter for large files (> 200 MB).

    Reads the file as a flat string (~1× file size in RAM) and decodes
    features one at a time with JSONDecoder.raw_decode(), writing each
    part to disk as it fills up.  Peak extra memory is one part-buffer
    of serialised JSON strings (≤ max_bytes) rather than the full Python
    object graph that json.load() would create.
    """
    try:
        with open(output_path, "r", encoding="utf-8") as f:
            raw = f.read()
        memlog("streaming_split: file read into memory",
               f"len={len(raw)} chars ({len(raw)/(1024*1024):.1f} MB)")
    except MemoryError:
        print(f"  ⚠ {os.path.basename(output_path)}: file too large to read "
              f"({os.path.getsize(output_path) // (1024 * 1024)} MB); skipping split.")
        return

    decoder = json.JSONDecoder()

    # ── Extract envelope (type, crs, name …) — everything before "features" ──
    feat_key_pos = raw.find('"features"')
    if feat_key_pos < 0:
        print(f"  ⚠ {os.path.basename(output_path)}: no 'features' key found; "
              f"skipping split.")
        del raw
        return

    arr_start = raw.find('[', feat_key_pos)
    if arr_start < 0:
        del raw
        return

    # Build envelope dict from the header portion
    envelope = {"type": "FeatureCollection"}
    for key in ("name", "crs"):
        key_pos = raw.find(f'"{key}"')
        if 0 <= key_pos < arr_start:
            val_start = raw.find(':', key_pos) + 1
            # skip whitespace
            while val_start < arr_start and raw[val_start] in ' \t\n\r':
                val_start += 1
            try:
                val, _ = decoder.raw_decode(raw, val_start)
                envelope[key] = val
            except (json.JSONDecodeError, ValueError):
                pass

    # Pre-compute the per-part wrapper overhead once
    empty_fc = dict(envelope, features=[])
    wrapper_overhead = len(json.dumps(empty_fc).encode("utf-8"))

    # ── Stream features and write parts incrementally ──
    pos = arr_start + 1  # skip opening '['
    raw_len = len(raw)
    part_idx = 0
    num_parts = 0
    current_buf = []        # list of serialised feature strings for current part
    current_size = wrapper_overhead

    def _flush_part(buf, pidx):
        """Serialise *buf* as a FeatureCollection part and write to disk."""
        fpath = output_path if pidx == 0 else f"{stem}.part{pidx + 1}{ext}"
        with open(fpath, "w", encoding="utf-8") as fout:
            fout.write(json.dumps(envelope)[:-1])  # open '{' without closing '}'
            fout.write(',"features":[')
            fout.write(",".join(buf))
            fout.write(']}')
        return fpath

    while pos < raw_len:
        # Skip whitespace and feature separators
        while pos < raw_len and raw[pos] in ' \t\n\r,':
            pos += 1
        if pos >= raw_len or raw[pos] == ']':
            break

        try:
            feat, end_pos = decoder.raw_decode(raw, pos)
        except (json.JSONDecodeError, ValueError):
            break

        feat_json = json.dumps(feat, separators=(',', ':'))
        feat_bytes = len(feat_json.encode("utf-8")) + 1  # +1 for comma separator
        del feat  # free parsed dict immediately

        if current_size + feat_bytes > max_bytes and current_buf:
            _flush_part(current_buf, part_idx)
            part_idx += 1
            num_parts += 1
            current_buf = []
            current_size = wrapper_overhead

        current_buf.append(feat_json)
        current_size += feat_bytes
        pos = end_pos

    del raw  # release the raw text ASAP

    if current_buf:
        _flush_part(current_buf, part_idx)
        num_parts += 1

    if num_parts == 0:
        return

    cleanup_fn(keep_up_to=num_parts)
    sizes_str = ", ".join(
        f"{os.path.getsize(output_path if i == 0 else f'{stem}.part{i + 1}{ext}') / (1024 * 1024):.1f} MB"
        for i in range(num_parts)
    )
    print(f"  ✓ Streaming-split {os.path.basename(output_path)} "
          f"into {num_parts} part(s) ({sizes_str})")


def _split_all_oversized_geojson():
    """Scan the export directory and split any GeoJSON exceeding the size limit.

    Biome files get spatial tile indices instead of sequential splits, so
    Godot can lazy-load only the tiles a chunk needs.
    """
    if not os.path.exists(EXPORT_DIR):
        return

    biomes_base = f"{PLANET_NAME}_biomes.json"
    planet_json_name = f"{PLANET_NAME}_planet.json"
    for fname in sorted(os.listdir(EXPORT_DIR)):
        if not fname.startswith(PLANET_NAME):
            continue
        if not fname.endswith(".json"):
            continue
        if fname == planet_json_name:
            continue
        # Skip part files and tile files — they are generated by base file processing
        if ".part" in fname or "_tile_" in fname or "_index" in fname:
            continue
        fpath = os.path.join(EXPORT_DIR, fname)
        if os.path.isdir(fpath):
            continue
        # Biome files get spatial tile index instead of sequential split
        if fname == biomes_base:
            print(f"  Building spatial tile index for {fname}...")
            chunks_dest = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
            if _build_spatial_tile_index(fpath, dest_dir=chunks_dest):
                continue
            # Fallback to sequential split if spatial tiling fails
            print(f"  Spatial tiling failed, falling back to sequential split...")
        _split_geojson_if_needed(fpath)


# ============================================================
# MAIN EXECUTION
# ============================================================
def _resolve_godot_binary():
    """Resolve the Godot binary path using, in order:
      1. $GODOT_BIN environment variable
      2. [godot] path = … in tools/qgis/export_config.ini
      3. `godot` on PATH (via shutil.which)
      4. Hard-coded canonical fallback (Godot 4.6.1 mono double-precision build)
    Returns the resolved path, or None if nothing usable was found.
    """
    import shutil
    import configparser

    env_bin = os.environ.get("GODOT_BIN", "").strip()
    if env_bin and os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
        return env_bin

    ini_path = os.path.join(PROJECT_ROOT, "tools", "qgis", "export_config.ini")
    if os.path.isfile(ini_path):
        try:
            cp = configparser.ConfigParser()
            cp.read(ini_path)
            if cp.has_option("godot", "path"):
                candidate = os.path.expanduser(cp.get("godot", "path").strip())
                if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                    return candidate
        except Exception as exc:
            print(f"  [GodotBin] Failed to parse {ini_path}: {exc}")

    which_bin = shutil.which("godot")
    if which_bin:
        return which_bin

    if os.path.isfile(_GODOT_BIN_FALLBACK) and os.access(_GODOT_BIN_FALLBACK, os.X_OK):
        return _GODOT_BIN_FALLBACK

    return None


def convert_and_cleanup_recipes_binary():
    """Phase 0: convert `.recipe.json` → `.recipe.bin` for the current planet
    using the existing Godot headless script, then delete the JSON files
    whose binary counterpart was successfully written.

    Runs `tools/convert_recipes_binary.gd` with `--planet <PLANET_NAME>` so only
    the freshly-exported planet is processed (not every prebake planet).
    """
    import subprocess

    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    if not os.path.isdir(chunks_dir):
        print(f"  [RecipeBin] No chunks dir at {chunks_dir}, skipping conversion.")
        return

    godot_bin = _resolve_godot_binary()
    if godot_bin is None:
        raise RuntimeError(
            "Could not resolve Godot binary for recipe conversion. "
            "Set $GODOT_BIN, add [godot] path = … to tools/qgis/export_config.ini, "
            "put `godot` on PATH, or install the canonical build at "
            f"{_GODOT_BIN_FALLBACK}"
        )

    print(f"  [RecipeBin] Using Godot binary: {godot_bin}")
    print(f"  [RecipeBin] Converting recipes for planet '{PLANET_NAME}' ...")

    cmd = [
        godot_bin,
        "--headless",
        "--path", PROJECT_ROOT,
        "--script", "res://tools/convert_recipes_binary.gd",
        "--",
        "--planet", PLANET_NAME,
    ]
    t0 = _time_mod.time()
    try:
        proc = subprocess.run(
            cmd,
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            check=False,
            timeout=3600,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("Recipe conversion timed out after 1h")

    stdout = proc.stdout or ""
    stderr = proc.stderr or ""
    # Forward Godot output so the QGIS console shows progress/errors.
    for line in stdout.splitlines():
        print(f"    [godot] {line}")
    if stderr.strip():
        for line in stderr.splitlines():
            print(f"    [godot-err] {line}")

    if proc.returncode != 0:
        raise RuntimeError(
            f"Recipe conversion failed (exit {proc.returncode}). See output above."
        )

    print(f"  [RecipeBin] Conversion finished in {_time_mod.time() - t0:.1f}s. "
          "Cleaning up JSON recipes ...")

    removed = 0
    kept = 0
    errors = 0
    for base_name in sorted(os.listdir(chunks_dir)):
        base_dir = os.path.join(chunks_dir, base_name)
        if not base_dir.startswith(os.path.join(chunks_dir, "base_")) or not os.path.isdir(base_dir):
            continue
        for fname in os.listdir(base_dir):
            if not fname.endswith(".recipe.json"):
                continue
            json_path = os.path.join(base_dir, fname)
            bin_path = json_path[: -len(".recipe.json")] + ".recipe.bin"
            try:
                if os.path.isfile(bin_path) and os.path.getmtime(bin_path) >= os.path.getmtime(json_path):
                    os.remove(json_path)
                    removed += 1
                else:
                    kept += 1
            except OSError as exc:
                errors += 1
                print(f"    [RecipeBin] Error handling {json_path}: {exc}")

    print(f"  [RecipeBin] Deleted {removed} .recipe.json, kept {kept} without a fresh .bin, "
          f"{errors} errors.")
    if kept > 0:
        raise RuntimeError(
            f"Recipe conversion incomplete: {kept} .recipe.json files have no up-to-date .bin. "
            "Aborting export to avoid shipping inconsistent data."
        )


# Public (non-hidden) export dir consumed by Godot. This is where the
# per-planet .planetpack files and the loose JSON/PNG assets live so Godot
# scans and exports them.
_PUBLIC_EXPORT_DIR_NAME = os.path.join("assets", "qgis", "export")


def _public_export_dir():
    return os.path.join(PROJECT_ROOT, _PUBLIC_EXPORT_DIR_NAME)


def _public_planet_dir():
    return os.path.join(_public_export_dir(), PLANET_NAME)


def pack_planet_recipes():
    """Pack <planet>_chunks/base_*/*.recipe.bin + chunk_manifest.json into
    assets/qgis/export/<planet>.planetpack.
    """
    import importlib.util

    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    if not os.path.isdir(chunks_dir):
        print(f"  [pack] No chunks dir at {chunks_dir}, skipping.")
        return

    pack_script = os.path.join(PROJECT_ROOT, "tools", "qgis", "pack_planet.py")
    spec = importlib.util.spec_from_file_location("ds_pack_planet", pack_script)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load packer module from {pack_script}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    output_pack = os.path.join(
        _public_export_dir(), f"{PLANET_NAME}.planetpack"
    )

    # Safety-net collision mesh metadata.
    # Server builds a coarse triangulated sphere from these parameters and
    # keeps it always-resident as a fall-through backstop for dynamic bodies
    # over chunks not currently loaded. Tiny JSON, ~120 bytes — actual
    # vertex data is computed at server startup with HEALPix.pix2vec_nest.
    elev_min_safe = float(ELEV_MIN) if ELEV_MIN is not None else 0.0
    safety_mesh_meta = {
        "nside": 4,
        "radius_m": float(PLANET_RADIUS),
        "elev_min_m": elev_min_safe,
        "safety_margin_m": 200.0,
    }
    extra_entries = {
        "safety_mesh.json": json.dumps(
            safety_mesh_meta, separators=(",", ":")
        ).encode("utf-8"),
    }

    stats = mod.pack_planet(
        PLANET_NAME, chunks_dir, output_pack, extra_entries=extra_entries)
    mb = stats["pack_bytes"] / (1024 * 1024)
    print(
        f"  [pack] {stats['entry_count']} entries, {mb:.1f} MiB → {stats['output']}"
    )


def publish_loose_assets():
    """Copy the per-planet JSON + PNG outputs from the hidden authoring dir
    (assets/qgis/.export/) to the public Godot-visible dir
    (assets/qgis/export/<planet>/) under short, planet-scoped filenames.

    Recipe binaries are NOT copied — they live inside the .planetpack.
    The source files under .export/ are preserved for debugging.
    """
    import shutil

    dest_dir = _public_planet_dir()
    os.makedirs(dest_dir, exist_ok=True)

    prefix = f"{PLANET_NAME}_"

    copied = 0
    skipped = 0
    total_bytes = 0
    for fname in sorted(os.listdir(EXPORT_DIR)):
        src = os.path.join(EXPORT_DIR, fname)
        if not os.path.isfile(src):
            continue
        if not fname.startswith(prefix):
            continue
        # Drop the planet prefix so paths become predictable inside
        # export/<planet>/: e.g. biomes.json, roads_buffered.json, planet.json
        short = fname[len(prefix):]
        # Keep TIFs out of the public dir — Godot can't read them and the
        # pipeline always produces PNG siblings.
        if short.endswith(".tif"):
            skipped += 1
            continue
        dst = os.path.join(dest_dir, short)
        try:
            shutil.copy2(src, dst)
            copied += 1
            total_bytes += os.path.getsize(dst)
        except OSError as exc:
            print(f"  [publish] copy failed: {src} → {dst}: {exc}")

    print(
        f"  [publish] copied {copied} file(s) ({total_bytes / (1024 * 1024):.1f} MiB) "
        f"to {dest_dir}"
    )
    if skipped:
        print(f"  [publish] skipped {skipped} .tif file(s) (PNG siblings are used instead)")


def run_export():
    """Run the full export pipeline."""
    # Clear previous log and write header
    try:
        with open(_MEMLOG_PATH, "w") as f:
            f.write(f"=== QGIS Planet Export Memory Log: {PLANET_NAME} ==="
                    f" started {_time_mod.strftime('%Y-%m-%d %H:%M:%S')}\n")
    except Exception:
        pass

    print("=" * 60)
    print(f"  QGIS Planet Export: {PLANET_NAME}")
    print(f"  Radius: {PLANET_RADIUS}m")
    print(f"  Max quadtree depth: {MAX_QUADTREE_DEPTH}")
    print(f"  Export dir: {EXPORT_DIR}")
    print("=" * 60)

    memlog("run_export() START")

    ensure_dir(EXPORT_DIR)

    print("\n[0/7] Scanning elevation range from contour data...")
    scan_elevation_range()
    memlog("after scan_elevation_range")

    print("\n[1/7] Exporting vector layers to GeoJSON...")
    print("  (Note: biome GeoJSON merge skipped — biome data is now in recipes)")
    export_all_vector_layers()
    memlog("after export_all_vector_layers")
    gc.collect()
    memlog("after export_all_vector_layers + gc.collect")

    print("\n[2/7] Generating global heightmap from contours...")
    heightmap_path = generate_heightmap_from_contours()
    memlog("after generate_heightmap_from_contours")
    gc.collect()
    memlog("after generate_heightmap_from_contours + gc.collect")

    print("\n[3/7] Generating chunk recipes for runtime heightmap generation...")
    # Export per-chunk JSON recipes containing contour vertices, craters,
    # linear features, radial features, and noise parameters.  Heightmaps
    # are generated at runtime in Godot at any desired resolution.
    chunks_result = generate_chunk_recipes(heightmap_path)
    memlog("after generate_chunk_recipes")
    gc.collect()
    memlog("after generate_chunk_recipes + gc.collect")

    if chunks_result is None:
        print("  ✗ Chunk recipe generation failed — no terrain data available.")

    # Convert the JSON recipes we just wrote to Godot-native binary (.recipe.bin)
    # and drop the .json originals. Keeps the packable footprint small and
    # removes the need for a separate manual headless conversion step.
    print("\n[3b/8] Converting chunk recipes JSON → binary ...")
    convert_and_cleanup_recipes_binary()
    memlog("after convert_and_cleanup_recipes_binary")
    gc.collect()

    # Crater baking is no longer needed — craters are listed in each recipe
    # and applied at runtime during heightmap generation.

    print("\n[4/7] Generating biome raster map...")
    biomemap_path = generate_biome_raster()
    memlog("after generate_biome_raster")

    # ── Convert TIF → PNG for Godot (Godot can't load .tif natively) ──
    if heightmap_path and os.path.exists(heightmap_path):
        print("\n  Converting heightmap TIF → 16-bit PNG...")
        tif_to_png(heightmap_path, normalize_to_16bit=True)
    if biomemap_path and os.path.exists(biomemap_path):
        print("\n  Converting biomemap TIF → 8-bit PNG...")
        tif_to_png(biomemap_path, normalize_to_16bit=False)
    memlog("after TIF→PNG conversions")

    print("\n[5/7] Generating far-LOD color map...")
    generate_color_map()
    memlog("after generate_color_map")
    gc.collect()
    memlog("after generate_color_map + gc.collect")

    print("\n[6/8] Splitting oversized GeoJSON files (>90 MB)...")
    _split_all_oversized_geojson()
    memlog("after _split_all_oversized_geojson")
    gc.collect()
    memlog("after _split_all_oversized_geojson + gc.collect")

    # ── Remove intermediate .json.geojson files ──
    # QGIS's writeAsVectorFormatV3 appends ".geojson" to the output path,
    # producing files like "tarsis_5_1_elevation.json.geojson".  These are
    # intermediate artefacts used only during the export pipeline; Godot
    # loads the processed .json outputs (spatial tiles, recipes, etc.).
    print("\n[7/8] Cleaning up intermediate .json.geojson files...")
    _geojson_removed = 0
    _geojson_bytes = 0
    for _gj_name in os.listdir(EXPORT_DIR):
        if _gj_name.endswith(".json.geojson"):
            _gj_path = os.path.join(EXPORT_DIR, _gj_name)
            _geojson_bytes += os.path.getsize(_gj_path)
            os.remove(_gj_path)
            _geojson_removed += 1
    if _geojson_removed:
        print(f"  Removed {_geojson_removed} intermediate .json.geojson file(s) "
              f"({_geojson_bytes / (1024 * 1024):.1f} MB)")
    else:
        print("  No intermediate .json.geojson files to clean up.")
    memlog("after cleanup intermediate geojson")

    print("\n[8/8] Generating planet metadata JSON...")
    generate_combined_planet_json()

    print("\n[9/10] Packing recipe binaries into .planetpack ...")
    pack_planet_recipes()
    memlog("after pack_planet_recipes")

    print("\n[10/10] Publishing loose assets (JSON + PNG) to assets/qgis/export/ ...")
    publish_loose_assets()
    memlog("after publish_loose_assets")

    memlog("run_export() END")
    print("\n" + "=" * 60)
    print("  Export complete!")
    print(f"  Files in: {EXPORT_DIR}")
    print(f"  Memory log: {_MEMLOG_PATH}")
    print("=" * 60)
    print("\nNext step: In Godot, the planet will generate heightmaps from recipes at runtime.")


# Run when executed
run_export()
