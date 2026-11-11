using Godot;
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using GArray = Godot.Collections.Array;
using GDict = Godot.Collections.Dictionary;

/// <summary>A layer of a village mine's face broken into blocks (MineFracture). The layer is the rock that is solid
/// in this network (the gallery dug to d) and air in [after] (the same gallery dug to d + layer): its outer face is
/// the very wall the cells show, its back face the new face. It is cut by two Voronoi diagrams, one on each side of
/// the fault plane, each clipped by that plane: the fault is one of the cracks.
///
/// Every block is the zero set of max(layer, its Voronoi cell, its side of the fault), polygonised on a lattice in
/// the face frame. The cracks are planes, so the lattice renders them exactly. A [gap] shrinks every block across its
/// cracks, so neighbouring blocks never overlap (two rigid bodies spawned interpenetrating fly apart).</summary>
public partial class CaveNetworkMesher
{
    /// <summary>The blocks of a layer. [after]: the network with the gallery dug one layer further. [frame]: face
    /// frame -> network frame (origin on the floor at the face, -Z along the gallery). [box]: the lattice's box in the
    /// face frame. [seeds] / [sides]: the Voronoi sites (face frame) and the side of the fault each one lies on (1 =
    /// positive). The fault: points p with p.xy · [faultNormal] = [faultOffset]. Returns one dictionary per site, in
    /// the seeds' order: index, side, wall / wall_normals and crack / crack_normals (triangle soups in the network
    /// frame, wound as BuildRegion's), centroid (network frame), volume (m³) and size (largest extent, m). A site
    /// whose cell misses the layer comes back with no triangles and a volume of 0.</summary>
    public GArray BuildFragments(CaveNetworkMesher after, Transform3D frame, Aabb box, double step, Vector3[] seeds,
        int[] sides, Vector2 faultNormal, double faultOffset, double gap)
    {
        int nx = (int)Math.Ceiling(box.Size.X / step) + 1;
        int ny = (int)Math.Ceiling(box.Size.Y / step) + 1;
        int nz = (int)Math.Ceiling(box.Size.Z / step) + 1;
        var origin = box.Position;
        int plane = nx * ny;
        // The layer: > 0 out of it (air before, or rock still after).
        var slab = new float[plane * nz];
        // The site each sample in the layer belongs to (nearest on its side of the fault), -1 outside it.
        var label = new int[plane * nz];
        Parallel.For(0, nz, z =>
        {
            for (int y = 0; y < ny; y++)
            for (int x = 0; x < nx; x++)
            {
                var local = origin + new Vector3(x * step, y * step, z * step);
                var world = frame * local;
                // Air already before the layer: out of it whatever [after] says (half the box, the gallery's air).
                double before = Sample(world);
                double value = before > step * 2.0 ? before : Math.Max(before, -after.Sample(world));
                int at = x + nx * y + plane * z;
                slab[at] = (float)value;
                label[at] = value <= step * 2.0 ? Nearest(local, seeds, sides, Side(local, faultNormal, faultOffset)) : -1;
            }
        });
        // Each site's box of samples, grown so its surface closes and its gradients have neighbours.
        int count = seeds.Length;
        var low = new Vector3I[count];
        var high = new Vector3I[count];
        for (int i = 0; i < count; i++)
        {
            low[i] = new Vector3I(int.MaxValue, int.MaxValue, int.MaxValue);
            high[i] = new Vector3I(int.MinValue, int.MinValue, int.MinValue);
        }
        for (int z = 0; z < nz; z++)
        for (int y = 0; y < ny; y++)
        for (int x = 0; x < nx; x++)
        {
            int i = label[x + nx * y + plane * z];
            if (i < 0) continue;
            low[i] = new Vector3I(Math.Min(low[i].X, x), Math.Min(low[i].Y, y), Math.Min(low[i].Z, z));
            high[i] = new Vector3I(Math.Max(high[i].X, x), Math.Max(high[i].Y, y), Math.Max(high[i].Z, z));
        }
        var pieces = new GDict[count];
        var lattice = new Lattice(slab, nx, ny, nz, origin, step);
        Parallel.For(0, count, i =>
        {
            pieces[i] = low[i].X == int.MaxValue
                ? EmptyFragment(i, sides[i])
                : Fragment(i, seeds, sides, faultNormal, faultOffset, gap * 0.5, lattice, low[i], high[i], frame);
        });
        var result = new GArray();
        foreach (var piece in pieces) result.Add(piece);
        return result;
    }

    private readonly record struct Lattice(float[] Slab, int Nx, int Ny, int Nz, Vector3 Origin, double Step)
    {
        /// <summary>The layer's density at a face-frame point, trilinear (the edge samples beyond the box).</summary>
        public double At(Vector3 p)
        {
            double fx = Math.Clamp((p.X - Origin.X) / Step, 0, Nx - 1.000001);
            double fy = Math.Clamp((p.Y - Origin.Y) / Step, 0, Ny - 1.000001);
            double fz = Math.Clamp((p.Z - Origin.Z) / Step, 0, Nz - 1.000001);
            int x = (int)fx, y = (int)fy, z = (int)fz;
            double tx = fx - x, ty = fy - y, tz = fz - z;
            var slab = Slab;
            int nx = Nx, ny = Ny;
            double V(int dx, int dy, int dz) => slab[(x + dx) + nx * ((y + dy) + ny * (z + dz))];
            double c00 = V(0, 0, 0) + (V(1, 0, 0) - V(0, 0, 0)) * tx;
            double c10 = V(0, 1, 0) + (V(1, 1, 0) - V(0, 1, 0)) * tx;
            double c01 = V(0, 0, 1) + (V(1, 0, 1) - V(0, 0, 1)) * tx;
            double c11 = V(0, 1, 1) + (V(1, 1, 1) - V(0, 1, 1)) * tx;
            double c0 = c00 + (c10 - c00) * ty;
            double c1 = c01 + (c11 - c01) * ty;
            return c0 + (c1 - c0) * tz;
        }

        /// <summary>Where the layer's density grows (out of the rock), at a face-frame point.</summary>
        public Vector3 Gradient(Vector3 p)
        {
            double h = Step * 0.5;
            return new Vector3(
                At(p + new Vector3(h, 0, 0)) - At(p - new Vector3(h, 0, 0)),
                At(p + new Vector3(0, h, 0)) - At(p - new Vector3(0, h, 0)),
                At(p + new Vector3(0, 0, h)) - At(p - new Vector3(0, 0, h)));
        }
    }

    private static int Side(Vector3 p, Vector2 normal, double offset)
        => p.X * normal.X + p.Y * normal.Y - offset >= 0 ? 1 : 0;

    private static int Nearest(Vector3 p, Vector3[] seeds, int[] sides, int side)
    {
        int best = -1;
        double bestDistance = double.MaxValue;
        for (int i = 0; i < seeds.Length; i++)
        {
            if (sides[i] != side) continue;
            double distance = p.DistanceSquaredTo(seeds[i]);
            if (distance < bestDistance)
            {
                bestDistance = distance;
                best = i;
            }
        }
        return best;
    }

    /// <summary>How far [p] is out of site [i]'s Voronoi cell (exact distance to the nearest bisector, negative
    /// inside) and out of its side of the fault: the larger of the two, the block's crack term.</summary>
    private static double CrackTerm(Vector3 p, int i, Vector3[] seeds, int[] sides, Vector2 normal, double offset)
    {
        var own = seeds[i];
        double ownDistance = p.DistanceSquaredTo(own);
        double cell = -8.0;
        for (int j = 0; j < seeds.Length; j++)
        {
            if (j == i || sides[j] != sides[i]) continue;
            double between = own.DistanceTo(seeds[j]);
            if (between < 1e-9) continue;
            cell = Math.Max(cell, (ownDistance - p.DistanceSquaredTo(seeds[j])) / (2.0 * between));
        }
        double fault = p.X * normal.X + p.Y * normal.Y - offset;
        return Math.Max(cell, sides[i] == 1 ? -fault : fault);
    }

    private static GDict EmptyFragment(int index, int side) => new()
    {
        ["index"] = index, ["side"] = side,
        ["vertices"] = Array.Empty<Vector3>(), ["normals"] = Array.Empty<Vector3>(),
        ["wall"] = Array.Empty<int>(), ["crack"] = Array.Empty<int>(),
        ["centroid"] = Vector3.Zero, ["volume"] = 0.0, ["size"] = 0.0,
    };

    /// <summary>One block, as an INDEXED closed surface: every crossing of a lattice edge is one vertex, shared by
    /// all the triangles round it, so the block is a watertight 2-manifold (a consistent tetrahedral split leaves no
    /// crack) that CSG can carve (RockMining cuts it with planes).</summary>
    private static GDict Fragment(int i, Vector3[] seeds, int[] sides, Vector2 normal, double offset, double halfGap,
        Lattice lattice, Vector3I low, Vector3I high, Transform3D frame)
    {
        const int Margin = 2;
        int x0 = Math.Max(low.X - Margin, 0), y0 = Math.Max(low.Y - Margin, 0), z0 = Math.Max(low.Z - Margin, 0);
        int x1 = Math.Min(high.X + Margin, lattice.Nx - 1);
        int y1 = Math.Min(high.Y + Margin, lattice.Ny - 1);
        int z1 = Math.Min(high.Z + Margin, lattice.Nz - 1);
        int sx = x1 - x0 + 1, sy = y1 - y0 + 1, sz = z1 - z0 + 1;
        double step = lattice.Step;
        var field = new double[sx * sy * sz];
        Vector3 At(int x, int y, int z) => lattice.Origin + new Vector3((x0 + x) * step, (y0 + y) * step, (z0 + z) * step);
        for (int z = 0; z < sz; z++)
        for (int y = 0; y < sy; y++)
        for (int x = 0; x < sx; x++)
        {
            int gx = x0 + x, gy = y0 + y, gz = z0 + z;
            double layer = lattice.Slab[gx + lattice.Nx * (gy + lattice.Ny * gz)];
            // The box's own rim reads as outside, so the block closes even where the box (or its margin) cuts it.
            bool rim = x == 0 || y == 0 || z == 0 || x == sx - 1 || y == sy - 1 || z == sz - 1;
            double crack = CrackTerm(At(x, y, z), i, seeds, sides, normal, offset) + halfGap;
            double value = rim ? Math.Max(Math.Max(layer, crack), step) : Math.Max(layer, crack);
            // Never exactly on the surface: a crossing at a sample would give a zero-length edge.
            field[x + sx * (y + sy * z)] = Math.Abs(value) < 1e-7 ? 1e-7 : value;
        }
        Vector3 FieldGradient(int x, int y, int z)
        {
            int xa = Math.Max(x - 1, 0), xb = Math.Min(x + 1, sx - 1);
            int ya = Math.Max(y - 1, 0), yb = Math.Min(y + 1, sy - 1);
            int za = Math.Max(z - 1, 0), zb = Math.Min(z + 1, sz - 1);
            double F(int ax, int ay, int az) => field[ax + sx * (ay + sy * az)];
            return new Vector3((F(xb, y, z) - F(xa, y, z)) / Math.Max(xb - xa, 1),
                (F(x, yb, z) - F(x, ya, z)) / Math.Max(yb - ya, 1), (F(x, y, zb) - F(x, y, za)) / Math.Max(zb - za, 1));
        }
        long total = (long)sx * sy * sz;
        var vertexOf = new Dictionary<long, int>();
        var vertices = new List<Vector3>();
        var normals = new List<Vector3>();
        int Vertex(int a, int b)
        {
            int lo = Math.Min(a, b), hi = Math.Max(a, b);
            long key = lo * total + hi;
            if (vertexOf.TryGetValue(key, out int found)) return found;
            // Always interpolated from the same end, so the crossing is the same whichever tetrahedron asks.
            int lx = lo % sx, ly = lo / sx % sy, lz = lo / (sx * sy);
            int hx = hi % sx, hy = hi / sx % sy, hz = hi / (sx * sy);
            double t = field[lo] / (field[lo] - field[hi]);
            vertices.Add(At(lx, ly, lz).Lerp(At(hx, hy, hz), t));
            normals.Add(FieldGradient(lx, ly, lz).Lerp(FieldGradient(hx, hy, hz), t));
            vertexOf[key] = vertices.Count - 1;
            return vertices.Count - 1;
        }
        var wall = new List<int>();
        var crackFaces = new List<int>();
        var corners = new int[8];
        var densities = new double[8];
        var positions = new Vector3[8];
        for (int z = 0; z < sz - 1; z++)
        for (int y = 0; y < sy - 1; y++)
        for (int x = 0; x < sx - 1; x++)
        {
            bool positive = false, negative = false;
            for (int c = 0; c < 8; c++)
            {
                var corner = Corners[c];
                corners[c] = (x + corner.X) + sx * ((y + corner.Y) + sy * (z + corner.Z));
                densities[c] = field[corners[c]];
                positions[c] = At(x + corner.X, y + corner.Y, z + corner.Z);
                positive |= densities[c] > 0;
                negative |= densities[c] <= 0;
            }
            if (!positive || !negative) continue;
            for (int t = 0; t < 6; t++)
            {
                foreach (var (a, b, c) in Tetra(positions, densities, corners, t, Vertex, vertices))
                {
                    var centre = (vertices[a] + vertices[b] + vertices[c]) / 3.0;
                    bool isCrack = CrackTerm(centre, i, seeds, sides, normal, offset) + halfGap >= lattice.At(centre);
                    var target = isCrack ? crackFaces : wall;
                    target.Add(a);
                    target.Add(b);
                    target.Add(c);
                }
            }
        }
        if (wall.Count + crackFaces.Count == 0) return EmptyFragment(i, sides[i]);
        // Divergence theorem on the closed surface: (a, c, b) is wound with its normal out of the block.
        double volume = 0;
        var moment = Vector3.Zero;
        var reference = seeds[i];
        foreach (var list in new[] { wall, crackFaces })
        {
            for (int k = 0; k < list.Count; k += 3)
            {
                var ra = vertices[list[k]] - reference;
                var rb = vertices[list[k + 1]] - reference;
                var rc = vertices[list[k + 2]] - reference;
                double tetra = ra.Dot(rc.Cross(rb)) / 6.0;
                volume += tetra;
                moment += (ra + rb + rc) * (tetra / 4.0);
            }
        }
        if (volume <= 1e-9) return EmptyFragment(i, sides[i]);
        var lowest = new Vector3(double.MaxValue, double.MaxValue, double.MaxValue);
        var highest = -lowest;
        var outVertices = new Vector3[vertices.Count];
        var outNormals = new Vector3[vertices.Count];
        for (int k = 0; k < vertices.Count; k++)
        {
            lowest = lowest.Min(vertices[k]);
            highest = highest.Max(vertices[k]);
            outVertices[k] = frame * vertices[k];
            var n = normals[k];
            outNormals[k] = n.LengthSquared() > 1e-18 ? (frame.Basis * n).Normalized() : frame.Basis.Y;
        }
        var extent = highest - lowest;
        return new GDict
        {
            ["index"] = i, ["side"] = sides[i],
            ["vertices"] = outVertices, ["normals"] = outNormals,
            ["wall"] = wall.ToArray(), ["crack"] = crackFaces.ToArray(),
            ["centroid"] = frame * (reference + moment / volume), ["volume"] = volume,
            ["size"] = Math.Max(extent.X, Math.Max(extent.Y, extent.Z)),
        };
    }

    /// <summary>The triangles (vertex indices) of tetrahedron [tetra] of a cube, wound as BuildRegion's:
    /// -(b-a)×(c-a) points out of the solid (density <= 0), into the air. [vertex] maps a lattice edge (two sample
    /// indices) to its shared crossing vertex.</summary>
    private static List<(int, int, int)> Tetra(Vector3[] p, double[] d, int[] sample, int tetra, Func<int, int, int> vertex,
        List<Vector3> vertices)
    {
        var result = new List<(int, int, int)>(2);
        Span<int> ins = stackalloc int[4];
        Span<int> outs = stackalloc int[4];
        int ni = 0, no = 0;
        var air = Vector3.Zero;
        for (int k = 0; k < 4; k++)
        {
            int v = Tetrahedra[tetra, k];
            if (d[v] > 0) { ins[ni++] = v; air += p[v]; } else outs[no++] = v;
        }
        if (ni == 0 || ni == 4) return result;
        air /= ni;
        int Cross(int a, int b) => vertex(sample[a], sample[b]);
        (int, int, int) Wind(int a, int b, int c)
        {
            var pa = vertices[a];
            return -(vertices[b] - pa).Cross(vertices[c] - pa).Dot(air - pa) < 0 ? (a, c, b) : (a, b, c);
        }
        if (ni == 1 || ni == 3)
        {
            int centre = ni == 1 ? ins[0] : outs[0];
            int o0 = ni == 1 ? outs[0] : ins[0], o1 = ni == 1 ? outs[1] : ins[1], o2 = ni == 1 ? outs[2] : ins[2];
            result.Add(Wind(Cross(centre, o0), Cross(centre, o1), Cross(centre, o2)));
        }
        else
        {
            int a = Cross(ins[0], outs[0]);
            int b = Cross(ins[0], outs[1]);
            int c = Cross(ins[1], outs[1]);
            int e = Cross(ins[1], outs[0]);
            result.Add(Wind(a, b, c));
            result.Add(Wind(a, c, e));
        }
        return result;
    }
}
