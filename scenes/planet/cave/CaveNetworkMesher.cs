using Godot;
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using GDict = Godot.Collections.Dictionary;

/// <summary>CPU-only union of cave volumes (CaveLayoutV8), with solid pillars and bridges subtracted before
/// triangulation. One sparse density lattice feeds visible and physical surfaces, portal loops and the walkable
/// share. No nodes, resources or renderer calls.</summary>
public partial class CaveNetworkMesher : RefCounted
{
    private readonly record struct Volume(Vector3 A, Vector3 B, Vector3 Size, bool Room, bool Pillar, bool Shaft, bool Bridge, Aabb Bounds);
    /// <summary>Version 8 chamber and wall parameters. Rooms: yaw, footprint superellipse exponent, roof
    /// profile exponent, floor tilt and relief. Every volume: wall relief amplitude (m) and frequency (1/m).
    /// Version 9: gallery erosion at both segment ends (0..1), terrace step height (m), basin depth (m) and
    /// basin radius (share of the footprint). Rock bridges: the undulation (m) of their top.</summary>
    private readonly record struct Shape(double Cos, double Sin, double E, double K, double TiltX, double TiltZ,
        double FloorRough, double Amp, double Freq, double LowT, double HighT,
        double ErodeA, double ErodeB, double Terrace, double Basin, double BasinR, bool RimCalm, double Wave);
    /// <summary>Version 9 gallery erosion, mirrored by CaveLayoutV8 (ERODE_*): half-width variation, sideways
    /// drift of the section, roof rise and dissolution bells, and the narrowest half-width / height kept.</summary>
    private const double Widen = 0.35, Shift = 0.2, Rise = 0.3, RiseMax = 3.0, Bell = 0.6, BellMax = 4.0;
    private const double MinHalfWidth = 1.6, MinHeight = 2.6;
    /// <summary>The erosion fields vary in plan only, slowly (wavelengths of ~14 m, bells ~6 m): sampled once on
    /// this grid (m) over the network instead of several noise calls per sample and per overlapping segment.</summary>
    private const double FieldStep = 2.0, FieldFrequency = 1.0 / 14.0, BellFrequency = 1.0 / 6.0;
    private const int FieldChannels = 5;
    private float[] _fields = Array.Empty<float>();
    private int _fieldsX, _fieldsZ;
    private Vector2 _fieldsOrigin;
    private Volume[] _volumes = Array.Empty<Volume>();
    private Shape[] _shapes = Array.Empty<Shape>();
    private double _phase;
    /// <summary>A density this far below zero (m) is never next to a surface crossing.</summary>
    private double _far;
    /// <summary>Version 9 (graph "blend_m"): volumes are joined by a smooth union and solids subtracted by a smooth
    /// difference of this radius (m), so the rock left where two voids meet, or at a column's foot, is rounded
    /// instead of a knife edge. Zero (version 8) keeps the exact max / min.</summary>
    private double _blend;
    /// <summary>Each volume's feature: a gallery's consecutive segments share their first one's, so they join
    /// exactly (blending them would swell the gallery at every joint); different features blend.</summary>
    private int[] _group = Array.Empty<int>();
    private readonly int[] _perm = new int[512];
    /// <summary>Sparse lattice budget: allocated samples, not the bounding box.</summary>
    private const int MaxSparseSamples = 9000000;
    private const int Block = 16;
    /// <summary>Walkability: the player capsule is 1.8 m tall; floors steeper than about 45° slide.</summary>
    private const double StandHeight = 1.8, CrawlHeight = 0.9, StepHeight = 0.35, MaxSlopeTan = 0.84;
    private static readonly int[,] Tetrahedra = { {0,5,1,6}, {0,1,2,6}, {0,2,3,6}, {0,3,7,6}, {0,7,4,6}, {0,4,5,6} };
    private static readonly Vector3I[] Corners = { new(0,0,0), new(1,0,0), new(1,1,0), new(0,1,0),
        new(0,0,1), new(1,0,1), new(1,1,1), new(0,1,1) };

    public GDict Build(GDict graph)
    {
        Configure(graph);
        return BuildSparse(graph);
    }

    public void Configure(GDict graph)
    {
        _phase=graph["phase"].AsDouble();
        SeedNoise(graph["noise_seed"].AsInt64());
        _far = 2.5 * graph["cell_m"].AsDouble() + 1.0;
        // Kept under the early-out distance and the supports' 3 m margin: a far or absent volume never blends.
        _blend = Math.Clamp(Optional(graph, "blend_m", 0), 0, Math.Min(2.5, _far - 1.0));
        var source=graph["volumes"].AsGodotArray();
        _volumes=new Volume[source.Count];
        _shapes=new Shape[source.Count];
        _group=new int[source.Count];
        for (int i=0; i<source.Count; i++)
        {
            var v=source[i].AsGodotDictionary();
            string kind=v["kind"].AsString();
            bool continues = kind == "tunnel" && i > 0 && v.ContainsKey("continues_a") && v["continues_a"].AsBool();
            _group[i] = continues ? _group[i - 1] : i;
            var a = v["a"].AsVector3();
            var b = v["b"].AsVector3();
            var size = v["size"].AsVector3();
            var margin = new Vector3(size.X + 3, 3, (kind == "room" ? size.Z : size.X) + 3);
            var low = a.Min(b) - margin;
            var high = a.Max(b) + new Vector3(margin.X, size.Y + 3, margin.Z);
            if (kind == "shaft")
            {
                low = a.Min(b) - Vector3.One * (size.X + 3);
                high = a.Max(b) + Vector3.One * (size.X + 3);
            }
            if (kind == "rock_bridge")
            {
                low = a.Min(b) - new Vector3(size.X + 3, size.Y + 3, size.X + 3);
                high = a.Max(b) + new Vector3(size.X + 3, size.Z + 3, size.X + 3);
            }
            _shapes[i] = ReadShape(v, a, b, size);
            var box = ShapeBounds(a, b, size, kind, _shapes[i], new Aabb(low, high-low));
            _volumes[i]=new Volume(a, b, size, kind=="room", kind=="pillar", kind=="shaft", kind=="rock_bridge", box);
        }
        _fields = Array.Empty<float>();
        bool eroded = false;
        foreach (var s in _shapes) eroded |= s.ErodeA > 0 || s.ErodeB > 0;
        if (eroded) SampleFields(graph["bounds"].AsAabb());
    }

    /// <summary>Version 9 erosion fields on a plan grid covering the network (and a margin for the galleries'
    /// swell): sideways drift (x, z), width and roof variation, and dissolution bells, each in −1..1 (bells 0..1).
    /// Points beyond the grid read its edge, identically in the lattice and in Sample.</summary>
    private void SampleFields(Aabb bounds)
    {
        const double margin = 40.0;
        _fieldsOrigin = new Vector2(bounds.Position.X - margin, bounds.Position.Z - margin);
        _fieldsX = (int)Math.Ceiling((bounds.Size.X + 2 * margin) / FieldStep) + 1;
        _fieldsZ = (int)Math.Ceiling((bounds.Size.Z + 2 * margin) / FieldStep) + 1;
        _fields = new float[_fieldsX * _fieldsZ * FieldChannels];
        for (int z=0; z<_fieldsZ; z++) for (int x=0; x<_fieldsX; x++)
        {
            double px = _fieldsOrigin.X + x * FieldStep, pz = _fieldsOrigin.Y + z * FieldStep;
            double fx = px * FieldFrequency, fz = pz * FieldFrequency;
            double bx = px * BellFrequency, bz = pz * BellFrequency;
            int at = (x + _fieldsX * z) * FieldChannels;
            _fields[at] = (float)Signed(fx + 13.1, 2.7, fz - 7.7);
            _fields[at + 1] = (float)Signed(fx - 21.4, 9.3, fz + 4.6);
            _fields[at + 2] = (float)Signed(fx + 3.3, -15.2, fz + 28.9);
            _fields[at + 3] = (float)Signed(fx * 1.3 - 6.6, 1.9, fz * 1.3 - 30.2);
            double pocket = Math.Clamp((Noise(bx + 44.4, -3.1, bz + 12.8) * 1.4 - 0.3) / 0.7, 0, 1);
            _fields[at + 4] = (float)(pocket * pocket * (3 - 2 * pocket));
        }
    }

    /// <summary>Bilinear read of one erosion field channel at a point's plan position.</summary>
    private double Field(Vector3 p, int channel)
    {
        double gx = Math.Clamp((p.X - _fieldsOrigin.X) / FieldStep, 0, _fieldsX - 1.000001);
        double gz = Math.Clamp((p.Z - _fieldsOrigin.Y) / FieldStep, 0, _fieldsZ - 1.000001);
        int x = (int)gx, z = (int)gz;
        double u = gx - x, w = gz - z;
        int a = (x + _fieldsX * z) * FieldChannels + channel, b = a + FieldChannels;
        int c = a + _fieldsX * FieldChannels, d = c + FieldChannels;
        return (_fields[a] * (1 - u) + _fields[b] * u) * (1 - w) + (_fields[c] * (1 - u) + _fields[d] * u) * w;
    }

    private static double Optional(GDict v, string key, double fallback) => v.ContainsKey(key) ? v[key].AsDouble() : fallback;

    private static Shape ReadShape(GDict v, Vector3 a, Vector3 b, Vector3 size)
    {
        double yaw = Optional(v, "yaw", 0);
        var tilt = v.ContainsKey("tilt") ? v["tilt"].AsVector2() : Vector2.Zero;
        // A gallery segment continued by another keeps its floor grade past that end (see Density). Version 9
        // continues it as far as the segment's rounded end reaches: on a wide passage a shorter run left a flat
        // landing under the neighbouring segment, and the floor became a staircase of ~2 m steps.
        bool before = v.ContainsKey("continues_a") && v["continues_a"].AsBool();
        bool after = v.ContainsKey("continues_b") && v["continues_b"].AsBool();
        double extend = 0.5;
        double run = Math.Sqrt((b.X-a.X)*(b.X-a.X) + (b.Z-a.Z)*(b.Z-a.Z));
        if (v.ContainsKey("grade_reach") && v["grade_reach"].AsBool() && run > 1e-6 && Math.Abs(b.Y-a.Y) <= run)
            extend = Math.Max(0.5, (size.X * (1 + Widen + Shift) + Math.Abs(Optional(v, "amp", 0)) * FbmPeak) / run);
        return new Shape(Math.Cos(yaw), Math.Sin(yaw), Optional(v, "e", 2), Optional(v, "k", 2), tilt.X, tilt.Y,
            Optional(v, "floor_rough", 0), Optional(v, "amp", 0), Optional(v, "freq", 0.2),
            before ? -extend : 0, after ? 1 + extend : 1,
            Optional(v, "erode_a", 0), Optional(v, "erode_b", 0), Optional(v, "terrace", 0), Optional(v, "basin", 0),
            Optional(v, "basin_r", 0.55), v.ContainsKey("rim_calm") && v["rim_calm"].AsBool(), Optional(v, "wave", 0.7));
    }

    /// <summary>Support of a volume: rotation, floor tilt and relief included, so that every
    /// sample whose density can be positive lies inside it with at least 3 m of solid margin.</summary>
    private static Aabb ShapeBounds(Vector3 a, Vector3 b, Vector3 size, string kind, Shape s, Aabb legacy)
    {
        double relief = Math.Abs(s.Amp) * FbmPeak + 3;
        if (kind == "room")
        {
            double reach = Math.Sqrt(size.X*size.X + size.Z*size.Z);
            double drop = (Math.Abs(s.TiltX) + Math.Abs(s.TiltZ)) * reach + Math.Abs(s.FloorRough) * FbmPeak
                + s.Terrace + s.Basin;
            var low = a - new Vector3(reach + relief, drop + relief, reach + relief);
            var high = a + new Vector3(reach + relief, size.Y + drop + relief, reach + relief);
            return new Aabb(low, high - low);
        }
        if (kind == "pillar" || kind == "rock_bridge") return legacy;
        var grown = legacy.Grow(Math.Abs(s.Amp) * FbmPeak);
        if (kind != "tunnel") return grown;
        // Version 9: a floor grade continued further than half a segment lowers (or lifts) the rounded ends.
        double run = Math.Sqrt((b.X-a.X)*(b.X-a.X) + (b.Z-a.Z)*(b.Z-a.Z));
        double extend = Math.Max(-s.LowT, s.HighT - 1);
        double lift = extend > 0.5 ? Math.Abs(b.Y-a.Y) * (extend - 0.5) : 0;
        double erode = Math.Max(s.ErodeA, s.ErodeB);
        // Version 9 erosion swells the section sideways and up; the drifting section shifts the floor grade.
        var (side, up) = erode > 0 ? ErosionGrowth(size, erode) : (0.0, 0.0);
        if (lift <= 0 && erode <= 0) return grown;
        var start = grown.Position - new Vector3(side, side * 0.7 + lift, side);
        return new Aabb(start, grown.End + new Vector3(side, up + lift, side) - start);
    }

    /// <summary>Largest outward reach (m) erosion adds to a gallery section: sideways, and up.</summary>
    private static (double, double) ErosionGrowth(Vector3 size, double erode)
        => (erode * (Widen + Shift) * size.X,
            erode * (Math.Min(Rise * size.Y, RiseMax) + Math.Min(Bell * size.Y, BellMax)));

    public double Sample(Vector3 point)
    {
        double value=-4, group=double.NaN;
        int current=-1;
        for (int i=0; i<_volumes.Length; i++)
        {
            var v=_volumes[i];
            if (!v.Bounds.HasPoint(point)) continue;
            bool subtract = v.Pillar || v.Bridge;
            if (subtract || _group[i] != current)
            {
                // A feature is complete: blend it in, as the lattice does (BuildSparse, pass 2).
                if (!double.IsNaN(group)) value=Combine(value, group, false);
                group=double.NaN;
                current=subtract ? -1 : _group[i];
            }
            double d=Density(i, point);
            if (subtract) value=Combine(value, d, true);
            else group=double.IsNaN(group) ? d : Math.Max(group, d);
        }
        return double.IsNaN(group) ? value : Combine(value, group, false);
    }

    /// <summary>A volume's density applied to the running value: union of voids, difference of solids, smooth
    /// over _blend (polynomial smooth maximum: it only ever adds air to a union, rock to a difference).</summary>
    private double Combine(double value, double density, bool subtract)
    {
        // A difference is the union of the complements: min(value, -density) = -max(-value, density).
        double a = subtract ? -value : value;
        double high = Math.Max(a, density);
        if (_blend > 0)
        {
            double h = Math.Max(_blend - Math.Abs(a - density), 0) / _blend;
            high += h * h * _blend * 0.25;
        }
        return subtract ? -high : high;
    }

    // ---------------------------------------------------------------- lattice

    /// <summary>Sparse 16³ blocks allocated only where a volume reaches, so a network spread in
    /// three dimensions does not pay for its empty bounding box. Tetrahedral surface extraction, entrance and
    /// exit portals, roof cover, and the walkable share of the floor.</summary>
    private GDict BuildSparse(GDict graph)
    {
        var bounds = graph["bounds"].AsAabb();
        double step = graph["cell_m"].AsDouble();
        var origin = bounds.Position;
        int nx = (int)Math.Ceiling(bounds.Size.X / step) + 1;
        int ny = (int)Math.Ceiling(bounds.Size.Y / step) + 1;
        int nz = (int)Math.Ceiling(bounds.Size.Z / step) + 1;
        double dz = bounds.Size.Z / (nz-1);
        var grid = new SparseGrid(nx, ny, nz);
        // Pass 1, sequential: allocate the blocks each volume reaches, listing the volumes per block in order.
        var ranges = new (int X0, int Y0, int Z0, int X1, int Y1, int Z1)[_volumes.Length];
        var work = new List<List<int>>();
        for (int i=0; i<_volumes.Length; i++)
        {
            var lo = _volumes[i].Bounds.Position;
            var hi = _volumes[i].Bounds.End;
            var range = (Math.Clamp((int)Math.Floor((lo.X-origin.X)/step), 0, nx-1),
                Math.Clamp((int)Math.Floor((lo.Y-origin.Y)/step), 0, ny-1),
                Math.Clamp((int)Math.Floor((lo.Z-origin.Z)/dz), 0, nz-1),
                Math.Clamp((int)Math.Ceiling((hi.X-origin.X)/step), 0, nx-1),
                Math.Clamp((int)Math.Ceiling((hi.Y-origin.Y)/step), 0, ny-1),
                Math.Clamp((int)Math.Ceiling((hi.Z-origin.Z)/dz), 0, nz-1));
            ranges[i] = range;
            for (int bz=range.Item3/Block; bz<=range.Item6/Block; bz++)
            for (int by=range.Item2/Block; by<=range.Item5/Block; by++)
            for (int bx=range.Item1/Block; bx<=range.Item4/Block; bx++)
            {
                int index = grid.Create(bx, by, bz);
                if (grid.Samples > MaxSparseSamples)
                    return new GDict { ["error"] = "Réseau trop volumineux : réduire l’étendue ou les salles." };
                if (index == work.Count) work.Add(new List<int>());
                work[index].Add(i);
            }
        }
        // Pass 2, parallel: each block applies its volumes in their original order (unions, then the pillars and
        // bridges subtracted last), so every sample gets exactly the value a sequential pass would give it.
        Parallel.For(0, grid.Keys.Count, index =>
        {
            var (bx, by, bz) = grid.Keys[index];
            var values = grid.Values(index);
            // The feature being gathered (a gallery's segments join exactly), blended in once complete (Sample).
            var group = new float[values.Length];
            Array.Fill(group, float.NaN);
            int current = -1;
            void Flush()
            {
                for (int k = 0; k < group.Length; k++)
                {
                    if (float.IsNaN(group[k])) continue;
                    values[k] = (float)Combine(values[k], group[k], false);
                    group[k] = float.NaN;
                }
            }
            foreach (int i in work[index])
            {
                var r = ranges[i];
                bool subtract = _volumes[i].Pillar || _volumes[i].Bridge;
                if (subtract || _group[i] != current)
                {
                    Flush();
                    current = subtract ? -1 : _group[i];
                }
                int zs=Math.Max(r.Z0,bz*Block), ze=Math.Min(r.Z1,bz*Block+Block-1);
                int ys=Math.Max(r.Y0,by*Block), ye=Math.Min(r.Y1,by*Block+Block-1);
                int xs=Math.Max(r.X0,bx*Block), xe=Math.Min(r.X1,bx*Block+Block-1);
                for (int z=zs; z<=ze; z++) for (int y=ys; y<=ye; y++) for (int x=xs; x<=xe; x++)
                {
                    int key = (x&(Block-1)) + Block*((y&(Block-1)) + Block*(z&(Block-1)));
                    var p = origin + new Vector3(x*step, y*step, z*dz);
                    double density = Density(i, p);
                    if (subtract)
                        values[key] = (float)Combine(values[key], density, true);
                    else
                        group[key] = float.IsNaN(group[key]) ? (float)density : Math.Max(group[key], (float)density);
                }
            }
            Flush();
        });
        double endZ = origin.Z + bounds.Size.Z;
        // Pass 3, parallel: triangles per block, gathered afterwards in block order (the sequential order).
        // Air never touches an unallocated block: every support keeps 3 m of solid margin, more than a cell.
        // So visiting the cells whose lowest corner lies in an allocated block finds every crossing.
        var pieces = new BlockSurface[grid.Keys.Count];
        Parallel.For(0, grid.Keys.Count, index =>
        {
            var (bx, by, bz) = grid.Keys[index];
            var piece = new BlockSurface();
            var positions = new Vector3[8];
            var densities = new double[8];
            for (int z=bz*Block; z<Math.Min(bz*Block+Block, nz-1); z++)
            for (int y=by*Block; y<Math.Min(by*Block+Block, ny-1); y++)
            for (int x=bx*Block; x<Math.Min(bx*Block+Block, nx-1); x++)
            {
                bool positive=false, negative=false;
                for (int i=0; i<8; i++)
                {
                    var c=Corners[i];
                    densities[i]=grid.Get(x+c.X, y+c.Y, z+c.Z);
                    positive |= densities[i]>0;
                    negative |= densities[i]<=0;
                    positions[i]=origin + new Vector3((x+c.X)*step, (y+c.Y)*step, (z+c.Z)*dz);
                }
                if (!positive || !negative) continue;
                for (int t=0; t<6; t++)
                    Polygonize(positions, densities, t, piece.Wall, piece.Floor, piece.Entry, piece.Exit, origin.Z, endZ);
            }
            pieces[index] = piece;
        });
        var wall = new List<Vector3>();
        var floor = new List<Vector3>();
        var entry = new HashSet<Vector3>();
        var exit = new HashSet<Vector3>();
        foreach (var piece in pieces)
        {
            wall.AddRange(piece.Wall);
            floor.AddRange(piece.Floor);
            entry.UnionWith(piece.Entry);
            exit.UnionWith(piece.Exit);
        }
        var walls = wall.ToArray();
        var floors = floor.ToArray();
        Vector3? start = graph.ContainsKey("walk_start") ? graph["walk_start"].AsVector3() : null;
        var result = Walkability(grid, origin, step, dz, graph["entry_end"].AsDouble(), start);
        // Surface assembly, portal ordering, cover and shading belong to GDScript.
        result["error"] = "";
        result["wall_vertices"] = walls;
        result["floor_vertices"] = floors;
        result["entry"] = new List<Vector3>(entry).ToArray();
        result["exit"] = new List<Vector3>(exit).ToArray();
        result["cells"] = grid.Samples;
        result["top_y"] = origin.Y + (ny - 1) * step;
        return result;
    }

    /// <summary>Triangles and portal vertices extracted from one block, gathered in block order afterwards.</summary>
    private sealed class BlockSurface
    {
        public readonly List<Vector3> Wall = new(), Floor = new();
        public readonly HashSet<Vector3> Entry = new(), Exit = new();
    }

    /// <summary>16³ sample blocks, allocated on demand (sequentially), then read and filled concurrently, each
    /// block by one worker.</summary>
    private sealed class SparseGrid
    {
        private readonly int _nx, _ny, _nz, _bx, _by;
        private readonly Dictionary<int, float[]> _blocks = new();
        private readonly Dictionary<int, int> _order = new();
        private readonly List<float[]> _values = new();
        public readonly List<(int, int, int)> Keys = new();
        public long Samples => (long)_blocks.Count * Block * Block * Block;

        public SparseGrid(int nx, int ny, int nz)
        {
            _nx = nx; _ny = ny; _nz = nz;
            _bx = (nx + Block - 1) / Block;
            _by = (ny + Block - 1) / Block;
        }

        /// <summary>Allocates the block if needed; returns its index in allocation order (Keys).</summary>
        public int Create(int bx, int by, int bz)
        {
            int key = bx + _bx * (by + _by * bz);
            if (_order.TryGetValue(key, out int index)) return index;
            var values = new float[Block * Block * Block];
            Array.Fill(values, -4f);
            _blocks[key] = values;
            _order[key] = _values.Count;
            _values.Add(values);
            Keys.Add((bx, by, bz));
            return _values.Count - 1;
        }

        public float[] Values(int index) => _values[index];

        public float Get(int x, int y, int z)
        {
            if (x < 0 || y < 0 || z < 0 || x >= _nx || y >= _ny || z >= _nz) return -4f;
            int key = x / Block + _bx * (y / Block + _by * (z / Block));
            return _blocks.TryGetValue(key, out var values)
                ? values[(x & (Block-1)) + Block * ((y & (Block-1)) + Block * (z & (Block-1)))] : -4f;
        }
    }

    private double Density(int index, Vector3 p)
    {
        var v = _volumes[index];
        var s = _shapes[index];
        if (v.Bridge || v.Pillar) return SolidDensity(v, s, p);
        if (v.Shaft)
        {
            var axis = v.B - v.A;
            double t = Math.Clamp((p-v.A).Dot(axis) / Math.Max(1e-9, axis.LengthSquared()), 0, 1);
            double pipe = v.Size.X - p.DistanceTo(v.A.Lerp(v.B, t));
            if (pipe < -(Math.Abs(s.Amp) * FbmPeak + _far)) return pipe;
            return pipe + s.Amp * Fbm(p.X*s.Freq, p.Y*s.Freq, p.Z*s.Freq);
        }
        if (v.Room)
        {
            var q = p - v.A;
            // Inverse of Basis(Vector3.UP, yaw): back into the chamber's own frame.
            double lx = q.X*s.Cos - q.Z*s.Sin;
            double lz = q.X*s.Sin + q.Z*s.Cos;
            double hx = v.Size.X, hy = v.Size.Y, hz = v.Size.Z;
            double ex = Math.Abs(lx)/hx, ez = Math.Abs(lz)/hz;
            double r = s.E == 2 ? Math.Sqrt(ex*ex + ez*ez) : Math.Pow(Math.Pow(ex, s.E) + Math.Pow(ez, s.E), 1.0/s.E);
            double side = (1 - r) * Math.Min(hx, hz);
            double relief = Math.Abs(s.Amp) * FbmPeak;
            // Deep in the rock (beyond any relief and a few cells from the surface) the exact value never
            // reaches a zero crossing: skip the noise there. Every early value keeps the sign and stays far.
            if (side < -(relief + _far)) return side;
            double floorY = s.TiltX*lx + s.TiltZ*lz;
            double floorRelief = Math.Abs(s.FloorRough) * FbmPeak + s.Terrace + s.Basin;
            if (q.Y - floorY < -(floorRelief + _far)) return q.Y - floorY + floorRelief + 0.015;
            if (s.FloorRough > 0)
            {
                double f = s.Freq * 1.2;
                double bumps = s.FloorRough * Fbm(p.X*f + 31.7, 7.3, p.Z*f - 11.1);
                // Version 9: galleries cross the wall and reach their doorway (82 % of the radius) on the tilted
                // plane (CaveLayoutV8._landing). The relief calms down on that ring, so they never open onto a ledge.
                if (s.RimCalm) bumps *= 1 - 0.85 * (1 - SmoothStep(0.12, 0.22, Math.Abs(r - 0.9)));
                floorY += bumps;
            }
            // The vault keeps the plain floor's frame: terraces and a basin reshape the floor, never the roof.
            double vaultY = q.Y - floorY;
            if (s.Terrace > 0) floorY = Terraced(floorY, r, p, s);
            if (s.Basin > 0 && r < s.BasinR)
            {
                double u = r / s.BasinR, bowl = 1 - u*u;
                floorY -= s.Basin * bowl * bowl;
            }
            double y = q.Y - floorY;
            double rr = Math.Min(r, 1.0);
            double roof = s.K == 2 ? hy * Math.Sqrt(1 - rr*rr) : hy * Math.Pow(Math.Max(0, 1 - Math.Pow(rr, s.K)), 1.0/s.K);
            double wall = Math.Min(side, roof - vaultY);
            if (y > 0 && wall > -(relief + _far))
                wall += s.Amp * Fbm(p.X*s.Freq, p.Y*s.Freq, p.Z*s.Freq) * Math.Clamp(y/2, 0, 1);
            return Math.Min(wall, y + 0.015);
        }
        var delta=v.B-v.A;
        double horizontal=delta.X*delta.X+delta.Z*delta.Z;
        double erodeMax = Math.Max(s.ErodeA, s.ErodeB);
        if (erodeMax > 0) return ErodedTunnel(v, s, p, delta, horizontal, erodeMax);
        double along=horizontal>1e-9 ? ((p.X-v.A.X)*delta.X+(p.Z-v.A.Z)*delta.Z)/horizontal : 0;
        var local=p-v.A.Lerp(v.B,Math.Clamp(along,0,1));
        // Where another segment continues the gallery, the floor keeps its grade past that end: consecutive
        // segments then share one floor instead of each extending a flat landing the next one undercuts into
        // ~2 m steps. Ends that open into a chamber keep a flat landing, so no trench forms on arrival.
        local.Y=p.Y-(v.A.Y+delta.Y*Math.Clamp(along,s.LowT,s.HighT));
        double x=local.X/v.Size.X, z=local.Z/v.Size.X, yy=local.Y/v.Size.Y;
        double tunnel=(1-Math.Sqrt(x*x+yy*yy+z*z))*Math.Min(v.Size.X,v.Size.Y);
        if (local.Y > 0 && tunnel > -(Math.Abs(s.Amp) * FbmPeak + _far))
            tunnel += s.Amp * Fbm(p.X*s.Freq, p.Y*s.Freq, p.Z*s.Freq) * Math.Clamp(local.Y/2,0,1);
        return Math.Min(tunnel, local.Y+0.015);
    }

    /// <summary>Version 9 eroded gallery segment. Plan fields (SampleFields, shared by every segment, so a gallery
    /// stays one continuous passage) widen and narrow it, drift its section sideways, raise or lower its roof and
    /// open dissolution bells in it. The floor keeps the segment's grade; walking width and headroom never drop
    /// under MinHalfWidth and MinHeight unless the gallery was authored narrower or lower.</summary>
    private double ErodedTunnel(Volume v, Shape s, Vector3 p, Vector3 delta, double horizontal, double erodeMax)
    {
        double hw = v.Size.X, h = v.Size.Y;
        double rise = Math.Min(Rise * h, RiseMax), bell = Math.Min(Bell * h, BellMax);
        double along0 = horizontal > 1e-9 ? ((p.X-v.A.X)*delta.X + (p.Z-v.A.Z)*delta.Z) / horizontal : 0;
        // Early out: the drift moves a point by at most driftMax sideways (and its floor by grade × driftMax), the
        // section is at most hwMax wide and hMax high, and never thinner than hwMin × hMin. Beyond that bound the
        // exact value cannot approach a crossing either.
        double driftMax = Shift * erodeMax * hw;
        double hwMax = hw * (1 + erodeMax * Widen), hMax = h + erodeMax * (rise + bell);
        double hwMin = Math.Max(hw * (1 - erodeMax * Widen), Math.Min(hw, MinHalfWidth));
        double hMin = Math.Max(h - erodeMax * rise, Math.Min(h, MinHeight));
        double grade = horizontal > 1e-9 ? Math.Abs(delta.Y) / Math.Sqrt(horizontal) : 0;
        var near = p - v.A.Lerp(v.B, Math.Clamp(along0, 0, 1));
        double rawY = p.Y - (v.A.Y + delta.Y * Math.Clamp(along0, s.LowT, s.HighT));
        double eh = Math.Max(0, Math.Sqrt(near.X*near.X + near.Z*near.Z) - driftMax) / hwMax;
        double ey = Math.Max(0, Math.Abs(rawY) - grade * driftMax) / hMax;
        double bound = (1 - Math.Sqrt(eh*eh + ey*ey)) * Math.Min(hwMin, hMin);
        double relief = Math.Abs(s.Amp) * FbmPeak;
        if (bound < -(relief + _far)) return bound;
        // Likewise deep inside the smallest section and well above the floor: positive and far from any crossing.
        double ih = (Math.Sqrt(near.X*near.X + near.Z*near.Z) + driftMax) / hwMin;
        double iy = (Math.Abs(rawY) + grade * driftMax) / hMin;
        double inner = (1 - Math.Sqrt(ih*ih + iy*iy)) * Math.Min(hwMin, hMin);
        double clear = rawY - grade * driftMax;
        if (clear > relief + _far && inner > relief + _far) return Math.Min(inner, clear);
        double erode = s.ErodeA + (s.ErodeB - s.ErodeA) * Math.Clamp(along0, 0, 1);
        double drift = Shift * erode * hw;
        var q = new Vector3(p.X - drift * Field(p, 0), p.Y, p.Z - drift * Field(p, 1));
        double along = horizontal > 1e-9 ? ((q.X-v.A.X)*delta.X + (q.Z-v.A.Z)*delta.Z) / horizontal : 0;
        var local = q - v.A.Lerp(v.B, Math.Clamp(along, 0, 1));
        local.Y = q.Y - (v.A.Y + delta.Y * Math.Clamp(along, s.LowT, s.HighT));
        double width = Math.Max(hw * (1 + Widen * erode * Field(p, 2)), Math.Min(hw, MinHalfWidth));
        double height = Math.Max(h + erode * rise * Field(p, 3), Math.Min(h, MinHeight)) + erode * bell * Field(p, 4);
        double x = local.X / width, z = local.Z / width, yy = local.Y / height;
        double tunnel = (1 - Math.Sqrt(x*x + yy*yy + z*z)) * Math.Min(width, height);
        if (local.Y > 0 && tunnel > -(relief + _far))
            tunnel += s.Amp * Fbm(p.X*s.Freq, p.Y*s.Freq, p.Z*s.Freq) * Math.Clamp(local.Y/2, 0, 1);
        return Math.Min(tunnel, local.Y + 0.015);
    }

    /// <summary>Gradient noise stretched to fill −1..1.</summary>
    private double Signed(double x, double y, double z) => Math.Clamp(Noise(x, y, z) * 1.4, -1, 1);

    /// <summary>Version 9 terraced floor: flat shelves one step apart, joined by risers whose steepness varies
    /// along them, so some stay walkable ramps. Fades out towards the rim, which stays a continuous slope.</summary>
    private double Terraced(double floorY, double r, Vector3 p, Shape s)
    {
        double blend = 1 - SmoothStep(0.55, 0.75, r);
        if (blend <= 0) return floorY;
        double level = floorY / s.Terrace;
        double step = Math.Floor(level);
        double riser = 0.12 + 0.4 * Math.Clamp(0.5 + 0.7 * Noise(p.X*s.Freq*0.8 + 5.1, 3.3, p.Z*s.Freq*0.8 - 2.2), 0, 1);
        double stair = s.Terrace * (step + SmoothStep(1 - riser, 1, level - step));
        return floorY + (stair - floorY) * blend;
    }

    private static double SmoothStep(double from, double to, double x)
    {
        double t = Math.Clamp((x - from) / (to - from), 0, 1);
        return t * t * (3 - 2 * t);
    }

    // Improved gradient noise (Perlin 2002) on a seeded permutation: no period visible at cave scale,
    // a different field for every cave instead of one shared sine pattern.
    private void SeedNoise(long seed)
    {
        var rng = new RandomNumberGenerator { Seed = (ulong)seed };
        var source = new int[256];
        for (int i=0; i<256; i++) source[i]=i;
        for (int i=255; i>0; i--)
        {
            int j = (int)rng.RandiRange(0, i);
            (source[i], source[j]) = (source[j], source[i]);
        }
        for (int i=0; i<512; i++) _perm[i]=source[i & 255];
    }

    /// <summary>Upper bound of |Fbm|: supports grow by amplitude × this, never less.</summary>
    private const double FbmPeak = 1.6;

    private double Fbm(double x, double y, double z)
        => (Noise(x, y, z) + 0.5*Noise(x*2.03 + 17.1, y*2.03 - 4.7, z*2.03 + 9.2)
            + 0.25*Noise(x*4.11 - 8.3, y*4.11 + 2.9, z*4.11 - 13.4)) / 1.75 * FbmPeak;

    private double Noise(double x, double y, double z)
    {
        int X=(int)Math.Floor(x) & 255, Y=(int)Math.Floor(y) & 255, Z=(int)Math.Floor(z) & 255;
        x-=Math.Floor(x); y-=Math.Floor(y); z-=Math.Floor(z);
        double u=Fade(x), v=Fade(y), w=Fade(z);
        int A=_perm[X]+Y, AA=_perm[A]+Z, AB=_perm[A+1]+Z, B=_perm[X+1]+Y, BA=_perm[B]+Z, BB=_perm[B+1]+Z;
        return Lerp(w, Lerp(v, Lerp(u, Grad(_perm[AA], x, y, z), Grad(_perm[BA], x-1, y, z)),
                Lerp(u, Grad(_perm[AB], x, y-1, z), Grad(_perm[BB], x-1, y-1, z))),
            Lerp(v, Lerp(u, Grad(_perm[AA+1], x, y, z-1), Grad(_perm[BA+1], x-1, y, z-1)),
                Lerp(u, Grad(_perm[AB+1], x, y-1, z-1), Grad(_perm[BB+1], x-1, y-1, z-1))));
    }

    private static double Fade(double t) => t*t*t*(t*(t*6-15)+10);
    private static double Lerp(double t, double a, double b) => a + t*(b-a);

    private static double Grad(int hash, double x, double y, double z)
    {
        int h = hash & 15;
        double u = h<8 ? x : y, v = h<4 ? y : (h==12 || h==14 ? x : z);
        return ((h&1)==0 ? u : -u) + ((h&2)==0 ? v : -v);
    }

    /// <summary>Share of the floor a standing player reaches from the entrance. A floor is air above solid
    /// in a lattice column; neighbouring floors connect when the step stays under a ~45° slope plus a small
    /// step and the shared headroom fits the 1.8 m capsule. Floors under 0.9 m of headroom are not counted.</summary>
    private static GDict Walkability(SparseGrid grid, Vector3 origin, double step, double dz, double entryEnd,
        Vector3? landing = null)
    {
        var columns = new Dictionary<long, List<int>>();
        var floorY = new List<double>();
        var ceilY = new List<double>();
        var cellX = new List<int>();
        var cellZ = new List<int>();
        const int maxScan = 160;
        foreach (var (bx, by, bz) in grid.Keys)
        {
            for (int z=bz*Block; z<bz*Block+Block; z++)
            for (int x=bx*Block; x<bx*Block+Block; x++)
            for (int y=Math.Max(1, by*Block); y<by*Block+Block; y++)
            {
                float d = grid.Get(x, y, z);
                if (d <= 0) continue;
                float below = grid.Get(x, y-1, z);
                if (below > 0) continue;
                double fy = origin.Y + (y-1)*step + step * (-below) / (d - below);
                int top = y;
                while (top - y < maxScan && grid.Get(x, top, z) > 0) top++;
                double cy = double.PositiveInfinity;
                if (top - y < maxScan)
                {
                    float air = grid.Get(x, top-1, z), rock = grid.Get(x, top, z);
                    cy = origin.Y + (top-1)*step + step * air / (air - rock);
                }
                if (cy - fy < CrawlHeight) continue;
                long column = x + 100000L * z;
                if (!columns.TryGetValue(column, out var list)) columns[column] = list = new List<int>();
                list.Add(floorY.Count);
                floorY.Add(fy); ceilY.Add(cy); cellX.Add(x); cellZ.Add(z);
            }
        }
        int total = floorY.Count;
        var reached = new bool[total];
        int start = -1;
        double best = double.PositiveInfinity;
        for (int i=0; i<total; i++)
        {
            double px = origin.X + cellX[i]*step, pz = origin.Z + cellZ[i]*dz;
            if (ceilY[i] - floorY[i] < StandHeight) continue;
            double score;
            if (landing is Vector3 at)
                score = new Vector3(px, floorY[i], pz).DistanceTo(at);  // a doline's landing under its throat
            else if (pz > entryEnd + 6)
                continue;
            else
                score = Math.Abs(px) + Math.Abs(floorY[i]) + Math.Abs(pz - entryEnd);
            if (score < best) { best = score; start = i; }
        }
        int count = 0;
        double rise = MaxSlopeTan * Math.Max(step, dz) + StepHeight;
        if (start >= 0)
        {
            var queue = new Queue<int>();
            queue.Enqueue(start);
            reached[start] = true;
            Span<(int, int)> around = stackalloc (int, int)[] { (1, 0), (-1, 0), (0, 1), (0, -1) };
            while (queue.Count > 0)
            {
                int f = queue.Dequeue();
                count++;
                foreach (var (ox, oz) in around)
                {
                    if (!columns.TryGetValue(cellX[f]+ox + 100000L*(cellZ[f]+oz), out var list)) continue;
                    foreach (int g in list)
                    {
                        if (reached[g] || Math.Abs(floorY[g]-floorY[f]) > rise) continue;
                        // The capsule stands in both columns and, halfway across, between the floors' mean and the
                        // lower ceiling: on a slope the higher floor under the lower ceiling understated the room.
                        if (ceilY[g] - floorY[g] < StandHeight) continue;
                        if (Math.Min(ceilY[f], ceilY[g]) - 0.5 * (floorY[f] + floorY[g]) < StandHeight) continue;
                        reached[g] = true;
                        queue.Enqueue(g);
                    }
                }
            }
        }
        var reach = new List<Vector3>();
        var blocked = new List<Vector3>();
        for (int i=0; i<total; i++)
        {
            var point = new Vector3(origin.X + cellX[i]*step, floorY[i], origin.Z + cellZ[i]*dz);
            (reached[i] ? reach : blocked).Add(point);
        }
        return new GDict { ["walkable_ratio"] = total > 0 ? (double)count / total : 0.0,
            ["reach_points"] = reach.ToArray(), ["blocked_points"] = blocked.ToArray() };
    }

    /// <summary>Solids subtracted after every void: a rock bridge spanning a chamber or a gallery's pit (with a
    /// near-flat top to walk on), or a column.</summary>
    private double SolidDensity(Volume v, Shape s, Vector3 p)
    {
        if (v.Bridge)
        {
            var axis = v.B - v.A;
            double t = Math.Clamp((p-v.A).Dot(axis) / Math.Max(1e-9, axis.LengthSquared()), 0, 1);
            var center = v.A.Lerp(v.B, t);
            center.Z += Math.Sin(t*Math.PI)*Math.Sin(t*Math.PI*2+_phase)*v.Size.X*0.35*(s.Wave/0.7);
            double top = center.Y + Math.Sin(t*Math.PI)*(v.Size.Z + s.Wave*Math.Sin(t*Math.PI*7+_phase));
            double side = Math.Sqrt(Math.Pow(p.X-center.X,2) + Math.Pow(p.Z-center.Z,2));
            double width = v.Size.X*(0.88 + 0.12*Math.Cos(t*Math.PI*5 + _phase));
            double thickness = v.Size.Y*(0.85 + 0.15*Math.Sin(t*Math.PI*3));
            double lateral = side/width;
            double vertical = (p.Y-(top-thickness*0.5))/(thickness*0.5);
            return Math.Min(width,thickness*0.5)*(1-Math.Sqrt(lateral*lateral+vertical*vertical));
        }
        var q=p-v.A;
        double taper=1.0 + 0.16*Math.Cos(q.Y / Math.Max(1,v.Size.Y)*Math.PI*2);
        double radial=v.Size.X*taper-Math.Sqrt(q.X*q.X+q.Z*q.Z);
        // Version 9 columns carry the walls' relief (amp, freq): fluted and irregular, not turned cylinders.
        if (s.Amp != 0) radial += s.Amp * Fbm(p.X*s.Freq, p.Y*s.Freq, p.Z*s.Freq);
        return Math.Min(radial, Math.Min(q.Y, v.Size.Y-q.Y));
    }

    private static Vector3 Intersect(Vector3 a, Vector3 b, double va, double vb)
        => a.Lerp(b, va/(va-vb));

    private static void Polygonize(Vector3[] p, double[] d, int tetra, List<Vector3> wall, List<Vector3> floor,
        HashSet<Vector3> entry, HashSet<Vector3> exit, double startZ, double endZ)
    {
        Span<int> ins=stackalloc int[4];
        Span<int> outs=stackalloc int[4];
        int ni=0,no=0;
        var inside=Vector3.Zero;
        for(int i=0;i<4;i++)
        {
            int v=Tetrahedra[tetra,i];
            if(d[v]>0) { ins[ni++]=v; inside+=p[v]; } else outs[no++]=v;
        }
        if(ni==0 || ni==4) return;
        inside/=ni;
        if(ni==1 || ni==3)
        {
            int center=ni==1 ? ins[0] : outs[0];
            var other=ni==1 ? outs : ins;
            var a=Intersect(p[center],p[other[0]],d[center],d[other[0]]);
            var b=Intersect(p[center],p[other[1]],d[center],d[other[1]]);
            var c=Intersect(p[center],p[other[2]],d[center],d[other[2]]);
            Emit(a,b,c,inside,wall,floor,entry,exit,startZ,endZ);
        }
        else
        {
            var a=Intersect(p[ins[0]],p[outs[0]],d[ins[0]],d[outs[0]]);
            var b=Intersect(p[ins[0]],p[outs[1]],d[ins[0]],d[outs[1]]);
            var c=Intersect(p[ins[1]],p[outs[1]],d[ins[1]],d[outs[1]]);
            var e=Intersect(p[ins[1]],p[outs[0]],d[ins[1]],d[outs[0]]);
            Emit(a,b,c,inside,wall,floor,entry,exit,startZ,endZ);
            Emit(a,c,e,inside,wall,floor,entry,exit,startZ,endZ);
        }
    }

    private static void Emit(Vector3 a,Vector3 b,Vector3 c,Vector3 inside,List<Vector3> wall,List<Vector3> floor,
        HashSet<Vector3> entry,HashSet<Vector3> exit,double startZ,double endZ)
    {
        var normal=-(b-a).Cross(c-a);
        if(normal.LengthSquared()<1e-18) return;
        if(normal.Dot(inside-a)<0) { (b,c)=(c,b); normal=-normal; }
        var output=normal.Normalized().Y>0.65 ? floor : wall;
        output.Add(a); output.Add(b); output.Add(c);
        foreach(var v in new[]{a,b,c})
        {
            if(Math.Abs(v.Z-startZ)<1e-7) entry.Add(v);
            if(Math.Abs(v.Z-endZ)<1e-7) exit.Add(v);
        }
    }

}
