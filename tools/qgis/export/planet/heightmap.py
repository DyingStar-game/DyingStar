"""
Heightmap generation from QGIS contour layers.
Extracted from export_planet.py for modularity.
"""
import os
import math
import numpy as np
from qgis.core import QgsVectorLayer


def _thin_by_cell_and_level(pts, bin_w, bin_h):
    """Keep one real vertex per (equirectangular grid cell, contour elevation).

    Returns a SUBSET of [param pts] — actual input rows, never a synthesised
    position and never an averaged elevation. Grouping by elevation as well as by
    cell is the whole point: vertices sharing a cell AND a contour level lie on the
    same line and are genuinely redundant, whereas vertices sharing only a cell
    belong to different lines, and averaging those invents a height nobody drew.
    """
    col = np.clip(((pts[:, 0] + 180.0) * (bin_w / 360.0)).astype(np.int64), 0, bin_w - 1)
    row = np.clip(((90.0 - pts[:, 1]) * (bin_h / 180.0)).astype(np.int64), 0, bin_h - 1)
    levels, level_idx = np.unique(pts[:, 2], return_inverse=True)
    # Composite (cell, level) key: cells top out at 16384*8192 and contour levels
    # number in the hundreds, so the product stays far inside int64.
    key = (row * bin_w + col) * len(levels) + level_idx
    _, first = np.unique(key, return_index=True)
    return pts[first]


def extract_contour_points(heightmap_size, find_layers_func, memlog_func):
    """
    Read every contour vertex out of the QGIS project and decimate it.

    Returns an (N, 3) float64 array of (lon, lat, elevation), or None when the
    project holds no usable contour data.

    Split out of generate_heightmap_from_contours so that a caller which
    interpolates the points itself — export_elevation's spherical TIN — works
    from exactly the same source samples as the equirectangular raster, without
    a second pass over the layer.

    Parameters
    ----------
    heightmap_size : tuple[int, int]
        (width, height) of the target raster. Only used to size the decimation
        bins, which are expressed relative to the output resolution.
    find_layers_func : callable
        Function(keyword) → list of QGIS layers whose name contains *keyword*.
    memlog_func : callable
        Function(label, *extra) for memory/progress logging.
    """
    contour_layers = find_layers_func("contour") + find_layers_func("elevation")

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
    memlog_func("heightmap: contour vertices extracted", f"count={len(pts)}")
    print(f"  {len(pts)} vertices, elevation range "
          f"[{pts[:, 2].min():.1f}, {pts[:, 2].max():.1f}]m")

    w, h = heightmap_size

    # ── Thin redundant contour vertices ──
    # QGIS contour lines are densely sampled along their curves (often millions of
    # vertices), far more than any interpolator needs. Keep one representative
    # vertex per (grid cell, contour level) and halve the grid until the count fits
    # the budget.
    #
    # This deliberately never AVERAGES elevations. The previous version took the
    # mean elevation per cell, mixing vertices from DIFFERENT contour lines. On
    # tarsis_4 it bottomed out at a 1024×512 grid — 39 km cells — so a summit whose
    # 50 m contours are packed into a few kilometres collapsed to the local mean and
    # reached the tiles as ~6200 m instead of the 9000 m that was drawn. Grouping by
    # level as well makes the thinning lossless in elevation: it only ever drops
    # vertices lying on the same line inside the same cell.
    #
    # The budget is far above the old 500k because the consumer changed. That limit
    # existed for scipy.griddata, whose Delaunay stalls past ~500k; the spherical TIN
    # triangulates 438k points in ~7 s and scales near-linearly. Memory is the real
    # constraint now — the TIN keeps ~144 bytes per point of precomputed triangle
    # inverses, so 1.2M points is roughly 350 MB resident and ~1 GB peak while
    # building. This pass is also much lighter than the one it replaces, which
    # allocated bincount arrays over the whole bin grid (~2 GB at 16384×8192).
    DECIMATION_THRESHOLD = 1_200_000
    if len(pts) > DECIMATION_THRESHOLD:
        bin_w, bin_h = w * 4, h * 4
        while True:
            pts = _thin_by_cell_and_level(pts, bin_w, bin_h)
            print(f"  Thinning pass (bin grid {bin_w}×{bin_h}): → {len(pts)} vertices, "
                  f"range [{pts[:, 2].min():.1f}, {pts[:, 2].max():.1f}]m")
            if len(pts) <= DECIMATION_THRESHOLD or bin_w <= 64:
                break
            bin_w = max(bin_w // 2, 64)
            bin_h = max(bin_h // 2, 32)
        print(f"  ✓ Thinned to {len(pts)} vertices "
              f"(elevations preserved exactly — no cross-level averaging)")
        memlog_func("heightmap: decimation done", f"count={len(pts)}")

    return pts


def generate_heightmap_from_contours(planet_name, export_dir, heightmap_size,
                                      find_layers_func, memlog_func, points=None):
    """
    Generate a heightmap GeoTIFF from contour lines.

    Instead of using QGIS's built-in TIN interpolation (which freezes the GUI
    on large rasters), this extracts vertices directly from contour features
    and interpolates with scipy (fast Delaunay) or a numpy IDW fallback.

    NOTE on fidelity: methods 1 and 3-4 average source vertices (per coarse cell
    or per neighbourhood), so isolated peaks are pulled toward the local mean and
    the result never reaches the input extremes. Callers that need the contour
    values preserved exactly should interpolate the points themselves with
    export.planet.spherical_tin instead — see export_elevation.

    Parameters
    ----------
    planet_name : str
        Name of the planet (used for the output file name).
    export_dir : str
        Directory where the heightmap GeoTIFF will be saved.
    heightmap_size : tuple[int, int]
        (width, height) of the output raster in pixels.
    find_layers_func : callable
        Function(keyword) → list of QGIS layers whose name contains *keyword*.
    memlog_func : callable
        Function(label, *extra) for memory/progress logging.
    points : np.ndarray, optional
        Pre-extracted (N, 3) contour points from extract_contour_points(). Pass
        this to avoid walking the QGIS layer a second time.
    """
    pts = extract_contour_points(heightmap_size, find_layers_func, memlog_func) \
        if points is None else np.asarray(points, dtype=np.float64)
    if pts is None or len(pts) == 0:
        return None

    output_path = os.path.join(export_dir, f"{planet_name}_heightmap.tif")
    w, h = heightmap_size

    # Build output grid (pixel centres)
    lon_vals = np.linspace(-180.0, 180.0, w, endpoint=False) + (360.0 / w / 2.0)
    lat_vals = np.linspace(90.0, -90.0, h, endpoint=False) - (180.0 / h / 2.0)
    grid_lon, grid_lat = np.meshgrid(lon_vals, lat_vals)  # both (h, w)

    grid_data = None
    import time as _time
    _t0 = _time.time()
    memlog_func("heightmap: before interpolation", f"grid={w}x{h} verts={len(pts)}")

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
        memlog_func("heightmap: rasterize+fill+upsample done")
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
            memlog_func("heightmap: scipy interpolation done")
            print(f"  ✓ scipy interpolation complete ({_time.time() - _t0:.1f}s)")
        except ImportError:
            print("  ⚠ scipy not available, falling back to KD-tree IDW...")

    # ── Method 3: KD-tree IDW (no scipy.interpolate, but scipy.spatial) ──
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

    # ── Method 4: pure numpy IDW fallback (last resort, no scipy at all) ──
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

    return save_heightmap_geotiff(output_path, grid_data)


def save_heightmap_geotiff(output_path, grid_data):
    """Write an equirectangular elevation grid as a WGS84 GeoTIFF.

    Returns the path actually written — the .tif, or a .npy sidecar when GDAL is
    not importable. Shared with export_elevation so a TIN-sampled raster lands on
    disk in exactly the same format as an interpolated one.
    """
    h, w = grid_data.shape
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
