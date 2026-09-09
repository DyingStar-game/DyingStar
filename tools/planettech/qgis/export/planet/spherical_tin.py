"""
Spherical TIN interpolation of scattered (lon, lat, value) contour samples.

Why not scipy.interpolate.griddata: it triangulates in the (lon, lat) PLANE. On a
whole planet that breaks three ways — points at lon -179.9 and +179.9 are 20 km
apart on the ground but 359.8 degrees apart in the plane, so no triangle ever
spans the antimeridian; the poles are single points smeared across the full raster
width; and anything outside the convex hull of the input falls back to fill_value.

Here the samples are lifted onto the unit sphere and triangulated with a convex
hull, which for points on a sphere IS their Delaunay triangulation. No seam, no
pole singularity, and the triangulation tiles the sphere completely, so every
query direction pierces exactly one triangle.

The interpolant is barycentric inside that triangle, which makes it exact at every
input vertex and bounded by the input range everywhere else. That is the property
the mean-binning rasteriser lacks: averaging contour vertices per cell pulls peaks
toward the local mean (measured on tarsis_4: a 9000 m summit exported as 6196 m).

Pure numpy + scipy, no QGIS import, so it can be unit-tested outside QGIS.
"""
import numpy as np


def lonlat_to_unit_vectors(lon_deg, lat_deg):
    """(lon, lat) in degrees -> unit vectors, in healpix_utils' axis convention.

    healpix_utils.face_xy_to_vec returns (sin(theta)*cos(phi), z, sin(theta)*sin(phi))
    and face_xy_to_lonlat reads lat = asin(z), lon = degrees(phi) — i.e. Y is the
    polar axis and longitude runs in the X-Z plane. Any direction produced by
    healpix_utils can therefore be fed straight to SphericalTIN.sample_vec().
    """
    lon = np.radians(np.asarray(lon_deg, dtype=np.float64))
    lat = np.radians(np.asarray(lat_deg, dtype=np.float64))
    cos_lat = np.cos(lat)
    return np.stack([cos_lat * np.cos(lon), np.sin(lat), cos_lat * np.sin(lon)], axis=-1)


class SphericalTIN:
    """Barycentric interpolator over a Delaunay triangulation on the sphere.

    Build once from the contour vertices, then sample as many directions as
    needed. Sampling is batched and thread-parallel in the KD-tree query, so a
    full HEALPix pyramid (tens of millions of directions) costs minutes, not hours.
    """

    ## Candidate triangles pulled from the KD-tree per query direction. The
    ## pierced triangle is almost always the nearest centroid; 8 covers the
    ## sliver triangles that a contour-line point set inevitably produces.
    DEFAULT_NEIGHBOURS = 8
    ## Barycentric coordinates are exact to ~1e-15 here; this only absorbs the
    ## round-off on a direction that lands exactly on a shared edge.
    _INSIDE_EPS = 1e-9

    def __init__(self, lon, lat, values, neighbours=DEFAULT_NEIGHBOURS, verbose=True):
        from scipy.spatial import ConvexHull, cKDTree

        self.values = np.asarray(values, dtype=np.float64).ravel()
        self.xyz = lonlat_to_unit_vectors(lon, lat).reshape(-1, 3)
        if len(self.xyz) != len(self.values):
            raise ValueError("lon/lat and values must have the same length")
        if len(self.xyz) < 4:
            raise ValueError("a spherical triangulation needs at least 4 points")
        self.neighbours = int(neighbours)

        if verbose:
            print(f"    building spherical TIN from {len(self.xyz)} points…")
        try:
            hull = ConvexHull(self.xyz)
        except Exception:
            # Qhull can choke on exactly-cospherical inputs; joggling perturbs the
            # INPUT COPY only for connectivity purposes — interpolation still uses
            # the original coordinates below, so no elevation is displaced.
            if verbose:
                print("    (Qhull retry with joggled input)")
            hull = ConvexHull(self.xyz, qhull_options="QJ")
        self.triangles = np.asarray(hull.simplices, dtype=np.int64)

        # The ray-triangle solve below assumes the hull encloses the origin, which
        # holds iff the samples surround the sphere. Contours covering only part of
        # a planet still work (the gap becomes a few very large triangles) but the
        # interpolation across that gap is a smooth blend, not real data.
        if verbose and not np.all(hull.equations[:, 3] < 0.0):
            print("    ⚠ contour points do not enclose the sphere — "
                  "elevations in the uncovered region are extrapolated")

        # Per triangle, the matrix whose COLUMNS are its three vertex directions.
        # Solving M·w = d expresses the query direction d in that basis, and the
        # ray pierces the triangle's plane at t = 1/sum(w) with barycentric
        # coordinates w/sum(w) — so one precomputed inverse per triangle turns
        # every later query into a single 3x3 mat-vec.
        corners = self.xyz[self.triangles]                    # (M, 3, 3), rows = vertices
        basis = np.transpose(corners, (0, 2, 1))              # (M, 3, 3), cols = vertices
        det = np.linalg.det(basis)
        self._valid = np.abs(det) > 1e-12                     # degenerate slivers
        self._basis_inv = np.zeros_like(basis)
        self._basis_inv[self._valid] = np.linalg.inv(basis[self._valid])

        centroids = corners.mean(axis=1)
        centroids /= np.linalg.norm(centroids, axis=1, keepdims=True)
        self._tri_tree = cKDTree(centroids)
        self._vertex_tree = cKDTree(self.xyz)
        if verbose:
            n_bad = int((~self._valid).sum())
            print(f"    TIN ready: {len(self.triangles)} triangles"
                  + (f" ({n_bad} degenerate, skipped)" if n_bad else ""))

    @property
    def n_points(self):
        return len(self.xyz)

    @property
    def n_triangles(self):
        return len(self.triangles)

    def sample_vec(self, x, y, z, batch=250_000):
        """Interpolate at unit direction vectors. Returns an array shaped like x."""
        x = np.asarray(x, dtype=np.float64)
        dirs = np.stack([x.ravel(),
                         np.asarray(y, dtype=np.float64).ravel(),
                         np.asarray(z, dtype=np.float64).ravel()], axis=1)
        out = np.empty(len(dirs), dtype=np.float64)
        for start in range(0, len(dirs), batch):
            chunk = dirs[start:start + batch]
            out[start:start + batch] = self._sample_batch(chunk)
        return out.reshape(x.shape)

    def sample_lonlat(self, lon, lat, batch=250_000):
        """Interpolate at (lon, lat) in degrees. Returns an array shaped like lon."""
        v = lonlat_to_unit_vectors(lon, lat)
        return self.sample_vec(v[..., 0], v[..., 1], v[..., 2], batch=batch)

    def _sample_batch(self, dirs):
        _, candidates = self._tri_tree.query(dirs, k=self.neighbours, workers=-1)
        if candidates.ndim == 1:                      # k == 1
            candidates = candidates[:, None]

        result = np.full(len(dirs), np.nan, dtype=np.float64)
        pending = np.arange(len(dirs))
        # Test candidates nearest-first and retire the ones that resolve, so the
        # expensive gather only ever touches directions still looking for their
        # triangle — in practice the first candidate settles the vast majority.
        for rank in range(candidates.shape[1]):
            if pending.size == 0:
                break
            tri_idx = candidates[pending, rank]
            weights = np.einsum("nij,nj->ni", self._basis_inv[tri_idx], dirs[pending])
            total = weights.sum(axis=1)
            # total > 0 keeps the near-side triangle: the intersection sits at
            # t = 1/total along the ray, so a negative sum is the hull's far face.
            with np.errstate(invalid="ignore", divide="ignore"):
                bary = weights / total[:, None]
            hit = (self._valid[tri_idx] & (total > 1e-12)
                   & np.all(np.isfinite(bary), axis=1)
                   & np.all(bary >= -self._INSIDE_EPS, axis=1))
            if not hit.any():
                continue
            resolved = pending[hit]
            result[resolved] = np.einsum(
                "ni,ni->n", self.values[self.triangles[tri_idx[hit]]], bary[hit])
            pending = pending[~hit]

        if pending.size:
            # No candidate contained the direction (degenerate neighbourhood, or a
            # direction on a hull gap). Nearest sample is the honest answer here —
            # it is bounded by the data, unlike an extrapolated barycentric value.
            _, nearest = self._vertex_tree.query(dirs[pending], k=1, workers=-1)
            result[pending] = self.values[nearest]
        return result
