"""
Named regions (the `region` layer: lore names, map labels) for <planet>_poi.json.
================================================================================

A region is NOT a biome: it changes nothing on the ground, it only names a part
of the map ("Rox Planum Centralis"). It used to ride in the terrain-modifier
pack as a POPULATE zone, and since a region spans thousands of km it was
written FULL into every tile it covers at every level — 6.4 M records, 180 MB
on tarsis_3 for ~95 names. Here it is one simplified outline per region in the
static POI file, which the star map reads whole (StarMapPoi.regions_for).

Pure stdlib + modifier_geom, no QGIS import, so it is unit-testable with plain
python3 (test/unit/test_modifier_pack_py.py).
"""

from . import modifier_geom as mg

#: Douglas-Peucker tolerance of an outline, in degrees (~5.5 km on tarsis_3).
#: A label and a "you are in X" lookup need the shape, not the coastline.
REGION_EPS_DEG = 0.05

#: Decimals kept on a coordinate: 1e-5 degree is ~1 m, far below the tolerance.
COORD_DECIMALS = 5


def outer_rings(geojson):
    """Outer ring(s) of a GeoJSON (Multi)Polygon dict as [[(lon, lat), …], …].

    Holes are dropped (an enclave is another region drawn on top), the closing
    vertex is removed, and rings of fewer than 3 points are skipped.
    """
    gtype = geojson.get("type")
    if gtype == "Polygon":
        polys = [geojson.get("coordinates", [])]
    elif gtype == "MultiPolygon":
        polys = geojson.get("coordinates", [])
    else:
        return []
    rings = []
    for rings_of_poly in polys:
        if not rings_of_poly:
            continue
        ring = [(float(p[0]), float(p[1])) for p in rings_of_poly[0]]
        if len(ring) > 1 and ring[0] == ring[-1]:
            ring.pop()
        if len(ring) >= 3:
            rings.append(ring)
    return rings


def ring_area_deg2(ring):
    """Unsigned shoelace area of a lon/lat ring, in square degrees."""
    s = 0.0
    n = len(ring)
    for i in range(n):
        x0, y0 = ring[i]
        x1, y1 = ring[(i + 1) % n]
        s += x0 * y1 - x1 * y0
    return abs(0.5 * s)


def build_regions(features, eps_deg=REGION_EPS_DEG):
    """The `regions` array of <planet>_poi.json.

    features: [{"name": str, "rings": [[(lon, lat), …], …]}, …] — one entry per
              QGIS feature, rings already reduced to their outer boundary.

    Returns [{"name", "rings": [[[lon, lat], …], …], "bbox": [lon0, lat0, lon1, lat1]}],
    sorted by area, smallest first: the runtime takes the FIRST region holding
    a point, so a region drawn inside another one wins over its host.
    Features with no name or no usable ring are dropped.
    """
    out = []
    for f in features:
        name = str(f.get("name") or "").strip()
        if not name:
            continue
        rings = []
        area = 0.0
        for ring in f.get("rings", []):
            simple = mg.simplify_ring([(float(p[0]), float(p[1])) for p in ring], eps_deg)
            if len(simple) < 3:
                continue
            area += ring_area_deg2(simple)
            rings.append([[round(lon, COORD_DECIMALS), round(lat, COORD_DECIMALS)]
                          for lon, lat in simple])
        if not rings:
            continue
        lons = [p[0] for r in rings for p in r]
        lats = [p[1] for r in rings for p in r]
        out.append({
            "name": name,
            "rings": rings,
            "bbox": [min(lons), min(lats), max(lons), max(lats)],
            "_area": area,
        })
    out.sort(key=lambda r: (r["_area"], r["name"]))
    for r in out:
        del r["_area"]
    return out
