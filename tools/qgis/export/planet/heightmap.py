"""
Heightmap generation from QGIS contour layers.
Extracted from export_planet.py for modularity.
"""
import os
import math
import numpy as np
from qgis.core import QgsVectorLayer


def generate_heightmap_from_contours(planet_name, export_dir, heightmap_size,
                                      find_layers_func, memlog_func):
    """
    Generate a heightmap GeoTIFF from contour lines.

    Instead of using QGIS's built-in TIN interpolation (which freezes the GUI
    on large rasters), this extracts vertices directly from contour features
    and interpolates with scipy (fast Delaunay) or a numpy IDW fallback.

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

    output_path = os.path.join(export_dir, f"{planet_name}_heightmap.tif")
    w, h = heightmap_size

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
        memlog_func("heightmap: decimation done", f"count={len(pts)}")

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
