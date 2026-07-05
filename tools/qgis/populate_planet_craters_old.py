"""
QGIS Populate Planet Surface Script for StarDeception
=====================================================
Run this in QGIS Python Console **after** setup_planet_project.py.

This script:
  1. Fills the entire terrain layer with a single lunar ground polygon covering
     the full planet surface (lon −180..180, lat −90..90).
  2. Randomly generates craters across the entire planet, with radii ranging
     from CRATER_MIN_RADIUS_M to CRATER_MAX_RADIUS_M.  Craters follow a
     power-law size distribution (many small ones, few large ones), matching
     real crater populations.

The number of craters is controlled by MAX_CRATERS.  On a planet with
radius ~2 million metres, even 100 000 craters only cover a tiny fraction
of the surface, so the main tuning knob is the crater count rather than
a coverage percentage.

Usage:
    1. Open QGIS with the planet project already set up
    2. Open Python Console (Ctrl+Alt+P)
    3. Run:
       exec(open('/path/to/StarDeception/tools/qgis/populate_planet_surface.py').read())
"""

import math
import random

from qgis.core import (
    QgsProject,
    QgsFeature,
    QgsGeometry,
    QgsPointXY,
    QgsExpressionContextUtils,
)
from PyQt5.QtCore import QVariant


# ============================================================
# CONFIGURATION
# ============================================================
# Planet identity is read automatically from the QGIS project variables
# set by setup_planet_project.py.  No need to edit PLANET_NAME or
# PLANET_RADIUS_M manually here.

# ── Lunar Ground ───────────────────────────────────────────────
LUNAR_GROUND_BIOME_TYPE = "spatial-lunar_ground"

# ── Craters ────────────────────────────────────────────────────
# Maximum number of craters to generate.
# QGIS handles ~100k points comfortably.  Increase for denser coverage.
MAX_CRATERS = 6_000_000

# Crater radius range (metres).
CRATER_MIN_RADIUS_M = 15.0
CRATER_MAX_RADIUS_M = 5000.0

# Power-law exponent for the size distribution.
# Higher values → more small craters relative to large ones.
# ~2.0 approximates real lunar/asteroid crater populations.
CRATER_SIZE_EXPONENT = 1.0

# Biome type for craters (must match BIOME_CATALOGUE in setup_planet_project.py).
CRATER_BIOME_TYPE = "spatial-crater"

# Biome type for the full-planet base ground layer.
LUNAR_GROUND_BIOME_TYPE = "spatial-lunar_ground"

# Random seed for reproducibility (set to None for different results each run).
RANDOM_SEED = None


# ============================================================
# HELPERS
# ============================================================

def _find_biome_layer(biome_type):
    """Find a project layer by its 'biome_type' custom property.

    setup_planet_project.py stores the biome type as a QGIS layer custom
    property on each individual biome layer.  This is more reliable than
    matching on the source URI or display name, which differ between the
    old GeoJSON and new PostGIS storage backends.
    """
    for layer in QgsProject.instance().mapLayers().values():
        if layer.customProperty("biome_type") == biome_type:
            return layer
    return None


def _power_law_sample(r_min, r_max, exponent, rng):
    """
    Sample a value from a truncated power-law distribution.
    PDF ∝ r^(-exponent) between r_min and r_max.
    Uses inverse-CDF sampling.
    """
    e = 1.0 - exponent
    if abs(e) < 1e-9:
        # Log-uniform when exponent ≈ 1
        return r_min * math.exp(rng.random() * math.log(r_max / r_min))
    lo = r_min ** e
    hi = r_max ** e
    return (lo + rng.random() * (hi - lo)) ** (1.0 / e)


def _random_sphere_point(rng):
    """
    Return a uniformly distributed (lon, lat) in degrees on the sphere.
    """
    lon = rng.uniform(-180.0, 180.0)
    # Uniform in sin(lat) for area-correct distribution.
    lat = math.degrees(math.asin(rng.uniform(-1.0, 1.0)))
    return lon, lat


# Required field definitions per layer type.
# These must match the fields defined in INDIVIDUAL_BIOME_LAYERS in
# setup_planet_project.py.  biome_type / biome_index / color_hex are
# stored as QGIS layer custom properties, NOT per-feature fields.


# ============================================================
# MAIN
# ============================================================

def populate_planet():
    print("=" * 60)
    print("Populate Planet Surface")
    print("=" * 60)

    project = QgsProject.instance()
    scope = QgsExpressionContextUtils.projectScope(project)
    PLANET_NAME = scope.variable("planet_name")
    PLANET_RADIUS_M = scope.variable("planet_radius_m")
    if not PLANET_NAME:
        print("  ✗ Project variable 'planet_name' not set."
              " Run setup_planet_project.py first.")
        return
    PLANET_RADIUS_M = float(PLANET_RADIUS_M) if PLANET_RADIUS_M else 1000000.0
    print(f"  Planet: {PLANET_NAME}  radius: {PLANET_RADIUS_M:.0f} m")

    print("\n[1/2] Adding full-surface lunar ground polygon...")
    terrain_layer = _find_biome_layer(LUNAR_GROUND_BIOME_TYPE)
    if terrain_layer is None:
        print(f"  ✗ Could not find layer with biome_type='{LUNAR_GROUND_BIOME_TYPE}'.\n"
              "  Run setup_planet_project.py first.")
        return
    print(f"  ✓ Found: {terrain_layer.name()} ({terrain_layer.featureCount()} existing features)")

    # Check if a lunar_ground feature already exists.
    if terrain_layer.featureCount() > 0:
        print(f"  ⚠ Layer already has {terrain_layer.featureCount()} feature(s) — skipping.")
    else:
        # Full planet rectangle in EPSG:4326 (lon/lat degrees).
        rect_wkt = (
            "POLYGON((-180 -90, 180 -90, 180 90, -180 90, -180 -90))"
        )
        geom = QgsGeometry.fromWkt(rect_wkt)

        feat = QgsFeature(terrain_layer.fields())
        feat.setGeometry(geom)
        # 'name' is the only field on spatial-lunar_ground.
        name_idx = terrain_layer.fields().indexOf("name")
        if name_idx >= 0:
            feat.setAttribute(name_idx, "planetary surface")

        terrain_layer.startEditing()
        terrain_layer.addFeature(feat)
        terrain_layer.commitChanges()
        print(f"  ✓ Added lunar_ground polygon covering full planet surface.")

    # ── 2. Generate random craters ────────────────────────────
    print(f"\n[2/2] Generating {MAX_CRATERS:,} craters...")
    point_layer = _find_biome_layer(CRATER_BIOME_TYPE)
    if point_layer is None:
        print(f"  ✗ Could not find layer with biome_type='{CRATER_BIOME_TYPE}'.\n"
              "  Run setup_planet_project.py first.")
        return
    print(f"  ✓ Found: {point_layer.name()} ({point_layer.featureCount()} existing features)")

    rng = random.Random(RANDOM_SEED)

    # Total planet surface area (for reporting).
    total_area_m2 = 4.0 * math.pi * PLANET_RADIUS_M ** 2

    # Generate craters with power-law distributed radii.
    craters = []
    accumulated_area = 0.0
    for _ in range(MAX_CRATERS):
        radius_m = round(_power_law_sample(
            CRATER_MIN_RADIUS_M, CRATER_MAX_RADIUS_M,
            CRATER_SIZE_EXPONENT, rng), 2)
        lon, lat = _random_sphere_point(rng)
        craters.append((lon, lat, radius_m))
        accumulated_area += math.pi * radius_m * radius_m

    print(f"  Generated {len(craters):,} craters "
          f"(area coverage: {accumulated_area / total_area_m2 * 100:.4f}%)")

    # Build all features in memory first, then batch-insert.
    # spatial-crater has fields: name (string), radius (double).
    print("  Building features...")
    fields = point_layer.fields()
    idx_name = fields.indexOf("name")
    idx_radius = fields.indexOf("radius")
    if idx_radius < 0:
        print("  ✗ 'radius' field not found on crater layer. Available: "
              + ", ".join(f.name() for f in fields))
        return

    features = []
    for lon, lat, radius_m in craters:
        feat = QgsFeature(fields)
        feat.setGeometry(QgsGeometry.fromPointXY(QgsPointXY(lon, lat)))
        if idx_name >= 0:
            feat.setAttribute(idx_name, None)
        feat.setAttribute(idx_radius, radius_m)
        features.append(feat)

    print(f"  Inserting {len(features):,} features (batch)...")
    point_layer.startEditing()
    point_layer.dataProvider().addFeatures(features)
    point_layer.commitChanges()

    print(f"  ✓ Added {len(craters):,} crater points to {point_layer.name()}")

    # Size distribution summary.
    small = sum(1 for _, _, r in craters if r < 50)
    medium = sum(1 for _, _, r in craters if 50 <= r < 500)
    large = sum(1 for _, _, r in craters if r >= 500)
    print(f"    Size breakdown: <50m: {small}, 50–500m: {medium}, >500m: {large}")
    if craters:
        radii = [r for _, _, r in craters]
        print(f"    Radius range: {min(radii):.1f}m – {max(radii):.1f}m, "
              f"median: {sorted(radii)[len(radii) // 2]:.1f}m")

    print("\n✓ Done. You can now run export_planet.py to export.")


# ── Auto-run when exec'd in QGIS console ──────────────────────
populate_planet()
