using System;
using System.Collections.Generic;
using Godot;

/// <summary>
/// The height sampler's hot path in C# — PlanetData.sample_height_for_direction
/// and sample_height_boundary for a chunk that samples through a TileFrame.
///
/// It is the C# half of a PlanetData.TileFrame, and holds what that frame holds:
/// the tiles the chunk has touched, each with its face, its position in the face
/// and its eight neighbours, registered by GDScript as the frame first meets
/// them (AddTile), plus where a pruned tile was resolved to (Redirect). From those
/// it does the whole sample — local UV, the cross-tile bilinear kernel, the
/// metres, the procedural mountains, the corundum cracks — in one call, where
/// GDScript spent some twenty microseconds a sample walking five functions.
///
/// It answers ONLY what it can answer exactly as GDScript would, and returns NaN
/// for anything else: a tile not registered yet, a pruned tile whose ancestor has
/// not been resolved, the equirect fallback. The caller then takes the GDScript
/// path, which registers what was missing, so the next sample of that tile comes
/// here. Every value it returns equals the GDScript one bit for bit —
/// test/unit/test_tile_frame_native.gd holds the two equal, and the GDScript path
/// stays the reference and the fallback when the assembly is absent.
///
/// One per chunk, used by one thread: no locking.
/// </summary>
public partial class TileFrameNative : RefCounted
{
    private sealed class Tile
    {
        public float[] Floats = Array.Empty<float>();
        public long Nside;
        public int Side;
        public int Face;
        public long Ix;
        public long Iy;
        /// <summary>N, NE, E, SE, S, SW, W, NW; -1 where HEALPix has none.</summary>
        public long[] Neighbours = Array.Empty<long>();
        /// <summary>For a tile with no data: the id of the ancestor the sampler reads instead, or -1.</summary>
        public long Redirect = -1;
    }

    private readonly Dictionary<long, Tile> _tiles = new();
    private double _maxHeight;
    private double _heightOffset;
    private double _exaggeration;
    private double _radius;
    private double _finestSpacing;
    private MountainSetNative _mountains;
    private bool _hasRock;
    /// <summary>A mountain planet's tile with no feature: the GDScript adds 0.0, and so must this.</summary>
    private bool _addZero;

    // The corundum crack network (PlanetData._crack_carve), cracks mode as PlanetData.CRACKS_*.
    private const int CracksNone = 0;
    private const int CracksAuto = 1;
    private bool _cracksOn;
    private double _crackSpacing;
    private double _crackWidth;
    private double _crackDepth;
    private bool _mountainPlanet;
    private double _mountainFade;
    /// <summary>The planet's CrackNoise twin (seed, meander, rim): the distance to the rim.</summary>
    private CrackVoronoiNative _crackNoise;
    /// <summary>prepare_crack_frame has run: the POI subset below is the frame's.</summary>
    private bool _crackPrepared;
    private double[] _poiX = Array.Empty<double>();
    private double[] _poiY = Array.Empty<double>();
    private double[] _poiZ = Array.Empty<double>();
    private double[] _poiR = Array.Empty<double>();
    private double _poiMargin;
    /// <summary>CRACKS_AUTO's zone rule over the export tile _zoneIpix: 1 carved, 0 not, -1 ask GDScript.</summary>
    private int _crackZone = -1;
    private long _zoneIpix = -1;
    private long _zoneNside;

    public void Configure(double maxHeight, double heightOffset, double exaggeration, double radius)
    {
        _maxHeight = maxHeight;
        _heightOffset = heightOffset;
        _exaggeration = exaggeration;
        _radius = radius;
    }

    /// <summary>
    /// The planet's crack network: on = corundum_default_biome; mountainPlanet = _has_mountains == 1,
    /// under which crack_factor fades the carve over the massifs.
    /// </summary>
    public void SetCracks(bool on, double spacing, double width, double depth, bool mountainPlanet,
        double mountainFade, GodotObject noise)
    {
        _crackNoise = noise as CrackVoronoiNative;
        _cracksOn = on;
        _crackSpacing = spacing;
        _crackWidth = width;
        _crackDepth = depth;
        _mountainPlanet = mountainPlanet;
        _mountainFade = mountainFade;
    }

    /// <summary>
    /// What prepare_crack_frame resolved for the chunk: the POI spheres it can meet (planet-local unit
    /// directions, radii in m) and, for CRACKS_AUTO, the zone rule over its export tile.
    /// </summary>
    public void SetCrackFrame(Vector3[] poiDirs, double[] poiRadii, double margin, int zone,
        long zoneIpix, long zoneNside)
    {
        int n = Math.Min(poiDirs?.Length ?? 0, poiRadii?.Length ?? 0);
        _poiX = new double[n];
        _poiY = new double[n];
        _poiZ = new double[n];
        _poiR = new double[n];
        for (int i = 0; i < n; i++)
        {
            _poiX[i] = poiDirs[i].X;
            _poiY[i] = poiDirs[i].Y;
            _poiZ[i] = poiDirs[i].Z;
            _poiR[i] = poiRadii[i];
        }
        _poiMargin = margin;
        _crackZone = zone;
        _zoneIpix = zoneIpix;
        _zoneNside = zoneNside;
        _crackPrepared = true;
    }

    /// <summary>The frame's mountain set, and the floor of the mountains' LOD gate.</summary>
    public void SetMountains(GodotObject set, double finestSpacing)
    {
        _mountains = set as MountainSetNative;
        _addZero = _mountains == null;
        _hasRock = _mountains != null && _mountains.HasRock();
        _finestSpacing = finestSpacing;
    }

    /// <summary>A tile as the frame's entry() made it. neighbours: N, NE, E, SE, S, SW, W, NW.</summary>
    public void AddTile(long id, float[] floats, int face, long ix, long iy, long[] neighbours)
    {
        if (!_tiles.TryGetValue(id, out var tile))
        {
            tile = new Tile();
            _tiles[id] = tile;
        }
        tile.Floats = floats ?? Array.Empty<float>();
        tile.Nside = id >> 32;
        tile.Side = SideOf(tile.Floats.Length);
        tile.Face = face;
        tile.Ix = ix;
        tile.Iy = iy;
        tile.Neighbours = neighbours ?? Array.Empty<long>();
    }

    /// <summary>The data-less tile [id] is read from its ancestor [toId] (the climb, resolved once).</summary>
    public void Redirect(long id, long toId)
    {
        if (_tiles.TryGetValue(id, out var tile))
            tile.Redirect = toId;
    }

    public int TileCount() => _tiles.Count;

    /// <summary>
    /// sample_height_for_direction(dir, knownIpix, …, nside, frame, vtxSpacing, cracks).
    /// NaN when this frame cannot answer exactly — see the class summary.
    /// </summary>
    public double Sample(Vector3 dir, long knownIpix, long nside, double vtxSpacing, int cracks)
    {
        long ipix = knownIpix >= 0 ? knownIpix : HealpixNative.Vec2PixNest(nside, dir.X, dir.Y, dir.Z);
        double h = Base(dir, ipix, nside);
        if (double.IsNaN(h))
            return h;
        if (_mountains == null)
        {
            if (_addZero)
                h = h + 0.0;
        }
        else
        {
            double eff = Math.Max(vtxSpacing, _finestSpacing);
            h = h + _mountains.Offset(dir, _radius, eff);
            // The rocky terrain terraces the ground the mountains give (RockFieldRelief) —
            // PlanetData.sample_height_for_direction's order.
            if (_hasRock)
                h = h + _mountains.Rock(dir, _radius, eff, h);
        }
        if (cracks == CracksNone || !_cracksOn)
            return h;
        double carve = Crack(dir, vtxSpacing, cracks);
        if (double.IsNaN(carve))
            return carve;
        return h + carve;
    }

    /// <summary>
    /// PlanetData._crack_carve: the crack network's offset at dir (≤ 0), NaN where the frame cannot
    /// decide it as GDScript would (no prepare_crack_frame, or CRACKS_AUTO outside a tile whose zone
    /// rule it holds).
    /// </summary>
    private double Crack(Vector3 dir, double vtxSpacing, int cracks)
    {
        // ArideDesertCorundumPlateauTerrain.crack_edge_distance_m, then crack_offset_from_edge.
        if (_crackSpacing <= 0.0 || _crackWidth <= 0.0)
            return 0.0;
        if (vtxSpacing > 0.0 && vtxSpacing >= _crackWidth * 0.5)
            return 0.0;
        if (_crackDepth <= 0.0)
            return 0.0;
        if (_crackNoise == null)
            return double.NaN;
        double dM = _crackNoise.EdgeDistanceD(dir.X, dir.Y, dir.Z, _radius, _crackSpacing, vtxSpacing);
        if (dM >= _crackWidth * 0.5)
            return 0.0;
        double off = -_crackDepth;
        if (!_crackPrepared)
            return double.NaN;
        if (cracks == CracksAuto)
        {
            if (_crackZone < 0 || HealpixNative.Vec2PixNest(_zoneNside, dir.X, dir.Y, dir.Z) != _zoneIpix)
                return double.NaN;
            if (_crackZone == 0)
                return 0.0;
        }
        return off * Factor(dir);
    }

    /// <summary>PlanetData.crack_factor over the frame's POI subset and mountain set.</summary>
    private double Factor(Vector3 dir)
    {
        // crack_clearance
        double w = 1.0;
        for (int i = 0; i < _poiR.Length; i++)
        {
            double dx = dir.X - _poiX[i];
            double dy = dir.Y - _poiY[i];
            double dz = dir.Z - _poiZ[i];
            double dM = Math.Sqrt(dx * dx + dy * dy + dz * dz) * _radius;
            double r = _poiR[i];
            if (dM <= r)
                return 0.0;
            double s = SmoothStep(r, r + _poiMargin, dM);
            w = w < s ? w : s;
        }
        if (w <= 0.0 || !_mountainPlanet)
            return w;
        double mask = _mountains != null ? _mountains.Mask(dir, _radius, _mountainFade) : 0.0;
        return w * (1.0 - mask);
    }

    /// <summary>The engine's smoothstep (Math::smoothstep, Godot 4.3+).</summary>
    private static double SmoothStep(double from, double to, double s)
    {
        if (IsEqualApprox(from, to))
        {
            if (from <= to)
                return s <= from ? 0.0 : 1.0;
            return s <= to ? 1.0 : 0.0;
        }
        double x = (s - from) / (to - from);
        x = x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x);
        return x * x * (3.0 - 2.0 * x);
    }

    /// <summary>The engine's is_equal_approx(double, double).</summary>
    private static bool IsEqualApprox(double a, double b)
    {
        if (a == b)
            return true;
        double tolerance = 1e-5 * Math.Abs(a);
        if (tolerance < 1e-5)
            tolerance = 1e-5;
        return Math.Abs(a - b) < tolerance;
    }

    /// <summary>sample_height_boundary(dir, chainIpix, …, nside, frame, vtxSpacing, cracks).</summary>
    public double SampleBoundary(Vector3 dir, long chainIpix, long nside, double vtxSpacing, int cracks)
    {
        long vecIpix = HealpixNative.Vec2PixNest(nside, dir.X, dir.Y, dir.Z);
        if (vecIpix == chainIpix)
            return Sample(dir, chainIpix, nside, vtxSpacing, cracks);
        // The canonical tile when it is loaded, the chain's otherwise: the GDScript asks the cache
        // whether vec_ipix has data. A tile registered here has been asked already; one that has not
        // cannot be told apart from a missing one, so it goes back to GDScript.
        if (!_tiles.TryGetValue(Id(vecIpix, nside), out var canonical))
            return double.NaN;
        // A pruned canonical tile reads from its ancestor (Base follows the redirect): it is there
        // for both sides, not missing. Not redirected yet (or a guessed climb): the GDScript decides,
        // as it does for the chain tile's own climb.
        if (canonical.Floats.Length > 0 || canonical.Redirect >= 0)
            return Sample(dir, vecIpix, nside, vtxSpacing, cracks);
        return double.NaN;
    }

    /// <summary>
    /// The four gradient probes of a vertex in one call — what a chunk's normals ask for every vertex:
    /// Sample (or SampleBoundary on the chunk's rim) for each. A NaN component means that probe has to
    /// go through the GDScript; the caller then asks for all four the usual way.
    /// </summary>
    public Vector4 Sample4(Vector3 a, Vector3 b, Vector3 c, Vector3 d, long ipix, long nside,
        double vtxSpacing, bool boundary, int cracks)
    {
        if (boundary)
            return new Vector4(SampleBoundary(a, ipix, nside, vtxSpacing, cracks),
                SampleBoundary(b, ipix, nside, vtxSpacing, cracks),
                SampleBoundary(c, ipix, nside, vtxSpacing, cracks),
                SampleBoundary(d, ipix, nside, vtxSpacing, cracks));
        return new Vector4(Sample(a, ipix, nside, vtxSpacing, cracks), Sample(b, ipix, nside, vtxSpacing, cracks),
            Sample(c, ipix, nside, vtxSpacing, cracks), Sample(d, ipix, nside, vtxSpacing, cracks));
    }

    private double Base(Vector3 dir, long ipix, long ns)
    {
        if (!_tiles.TryGetValue(Id(ipix, ns), out var tile))
            return double.NaN;
        if (tile.Floats.Length == 0)
        {
            // A pruned tile: read from the ancestor the GDScript climb settled on, once it has.
            if (tile.Redirect < 0 || !_tiles.TryGetValue(tile.Redirect, out var ancestor)
                || ancestor.Floats.Length == 0)
                return double.NaN;
            tile = ancestor;
            ns = ancestor.Nside;
        }
        if (tile.Side <= 0)
            return double.NaN;

        // _direction_to_pixel_uv
        HealpixNative.VecToFaceXY(dir.X, dir.Y, dir.Z, tile.Face, ns, out double fcx, out double fcy);
        double u = Clamp01(fcx - (double)tile.Ix);
        double v = Clamp01(fcy - (double)tile.Iy);

        // _sample_image_bilinear_healpix
        int w = tile.Side;
        int hgt = tile.Side;
        double fpx = u * (double)w - 0.5;
        double fpy = v * (double)hgt - 0.5;
        int x0 = (int)Math.Floor(fpx);
        int y0 = (int)Math.Floor(fpy);
        int x1 = x0 + 1;
        int y1 = y0 + 1;
        double fx = Clamp01(fpx - Math.Floor(fpx));
        double fy = Clamp01(fpy - Math.Floor(fpy));

        double h;
        if (x0 >= 0 && x1 < w && y0 >= 0 && y1 < hgt)
        {
            float[] f = tile.Floats;
            double a00 = f[y0 * w + x0];
            double a10 = f[y0 * w + x1];
            double a01 = f[y1 * w + x0];
            double a11 = f[y1 * w + x1];
            h = a00 * (1.0 - fx) * (1.0 - fy)
                + a10 * fx * (1.0 - fy)
                + a01 * (1.0 - fx) * fy
                + a11 * fx * fy;
        }
        else
        {
            if (!Texel(tile, ns, x0, y0, w, hgt, out double v00)
                || !Texel(tile, ns, x1, y0, w, hgt, out double v10)
                || !Texel(tile, ns, x0, y1, w, hgt, out double v01)
                || !Texel(tile, ns, x1, y1, w, hgt, out double v11))
                return double.NaN;
            h = v00 * (1.0 - fx) * (1.0 - fy)
                + v10 * fx * (1.0 - fy)
                + v01 * (1.0 - fx) * fy
                + v11 * fx * fy;
        }
        return (h * _maxHeight + _heightOffset) * _exaggeration;
    }

    /// <summary>_get_pixel_healpix. False when a neighbour tile the kernel needs is not registered.</summary>
    private bool Texel(Tile tile, long ns, int px, int py, int w, int h, out double value)
    {
        if (px >= 0 && px < w && py >= 0 && py < h)
        {
            value = tile.Floats[py * w + px];
            return true;
        }
        int nbPx = px;
        int nbPy = py;
        int ew = 0; // -1 W, +1 E
        int sn = 0; // -1 S, +1 N
        if (px < 0) { ew = -1; nbPx = w + px; }
        else if (px >= w) { ew = 1; nbPx = px - w; }
        if (py < 0) { sn = -1; nbPy = h + py; }
        else if (py >= h) { sn = 1; nbPy = py - h; }
        long nbIpix = NeighbourOf(tile, sn, ew);
        if (nbIpix >= 0)
        {
            if (!_tiles.TryGetValue(Id(nbIpix, ns), out var nb))
            {
                value = 0.0;
                return false; // GDScript would load it: let it, and register it on the way
            }
            if (nb.Floats.Length == w * h)
            {
                nbPx = Math.Clamp(nbPx, 0, w - 1);
                nbPy = Math.Clamp(nbPy, 0, h - 1);
                value = nb.Floats[nbPy * w + nbPx];
                return true;
            }
        }
        value = tile.Floats[Math.Clamp(py, 0, h - 1) * w + Math.Clamp(px, 0, w - 1)];
        return true;
    }

    private static long NeighbourOf(Tile tile, int sn, int ew)
    {
        // N, NE, E, SE, S, SW, W, NW
        int index = (sn, ew) switch
        {
            (1, 0) => 0,
            (1, 1) => 1,
            (0, 1) => 2,
            (-1, 1) => 3,
            (-1, 0) => 4,
            (-1, -1) => 5,
            (0, -1) => 6,
            (1, -1) => 7,
            _ => -1,
        };
        if (index < 0 || index >= tile.Neighbours.Length)
            return -1;
        return tile.Neighbours[index];
    }

    private static double Clamp01(double x) => x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x);

    private static long Id(long ipix, long nside) => (nside << 32) | ipix;

    private static int SideOf(int count)
    {
        if (count <= 0)
            return -1;
        int side = (int)Math.Round(Math.Sqrt((double)count));
        return side * side == count ? side : -1;
    }
}
