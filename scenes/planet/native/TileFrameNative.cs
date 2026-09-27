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
/// metres, the procedural mountains — in one call, where GDScript spent some
/// twenty microseconds a sample walking five functions.
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
    /// <summary>A mountain planet's tile with no feature: the GDScript adds 0.0, and so must this.</summary>
    private bool _addZero;

    public void Configure(double maxHeight, double heightOffset, double exaggeration, double radius)
    {
        _maxHeight = maxHeight;
        _heightOffset = heightOffset;
        _exaggeration = exaggeration;
        _radius = radius;
    }

    /// <summary>The frame's mountain set, and the floor of the mountains' LOD gate.</summary>
    public void SetMountains(GodotObject set, double finestSpacing)
    {
        _mountains = set as MountainSetNative;
        _addZero = _mountains == null;
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
    /// sample_height_for_direction(dir, knownIpix, …, nside, frame, vtxSpacing).
    /// NaN when this frame cannot answer exactly — see the class summary.
    /// </summary>
    public double Sample(Vector3 dir, long knownIpix, long nside, double vtxSpacing)
    {
        long ipix = knownIpix >= 0 ? knownIpix : HealpixNative.Vec2PixNest(nside, dir.X, dir.Y, dir.Z);
        double h = Base(dir, ipix, nside);
        if (double.IsNaN(h))
            return h;
        if (_mountains == null)
            return _addZero ? h + 0.0 : h;
        return h + _mountains.Offset(dir, _radius, Math.Max(vtxSpacing, _finestSpacing));
    }

    /// <summary>sample_height_boundary(dir, chainIpix, …, nside, frame, vtxSpacing).</summary>
    public double SampleBoundary(Vector3 dir, long chainIpix, long nside, double vtxSpacing)
    {
        long vecIpix = HealpixNative.Vec2PixNest(nside, dir.X, dir.Y, dir.Z);
        if (vecIpix == chainIpix)
            return Sample(dir, chainIpix, nside, vtxSpacing);
        // The canonical tile when it is loaded, the chain's otherwise: the GDScript asks the cache
        // whether vec_ipix has data. A tile registered here has been asked already; one that has not
        // cannot be told apart from a missing one, so it goes back to GDScript.
        if (!_tiles.TryGetValue(Id(vecIpix, nside), out var canonical))
            return double.NaN;
        return Sample(dir, canonical.Floats.Length > 0 ? vecIpix : chainIpix, nside, vtxSpacing);
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
