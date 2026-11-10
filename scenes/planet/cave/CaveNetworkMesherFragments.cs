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
        ["wall"] = Array.Empty<Vector3>(), ["wall_normals"] = Array.Empty<Vector3>(),
        ["crack"] = Array.Empty<Vector3>(), ["crack_normals"] = Array.Empty<Vector3>(),
        ["centroid"] = Vector3.Zero, ["volume"] = 0.0, ["size"] = 0.0,
    };

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
        for (int z = 0; z < sz; z++)
        for (int y = 0; y < sy; y++)
        for (int x = 0; x < sx; x++)
        {
            int gx = x0 + x, gy = y0 + y, gz = z0 + z;
            var p = lattice.Origin + new Vector3(gx * step, gy * step, gz * step);
            double layer = lattice.Slab[gx + lattice.Nx * (gy + lattice.Ny * gz)];
            // A sample on the box's rim reads as outside, so the block closes even where the box cuts it.
            bool rim = gx == 0 || gy == 0 || gz == 0 || gx == lattice.Nx - 1 || gy == lattice.Ny - 1 || gz == lattice.Nz - 1;
            double crack = CrackTerm(p, i, seeds, sides, normal, offset) + halfGap;
            field[x + sx * (y + sy * z)] = rim ? Math.Max(Math.Max(layer, crack), step) : Math.Max(layer, crack);
        }
        var wall = new List<Vector3>();
        var wallNormals = new List<Vector3>();
        var crackFaces = new List<Vector3>();
        var crackNormals = new List<Vector3>();
        var positions = new Vector3[8];
        var densities = new double[8];
        double volume = 0;
        var moment = Vector3.Zero;
        var lowest = new Vector3(double.MaxValue, double.MaxValue, double.MaxValue);
        var highest = -lowest;
        var reference = seeds[i];
        for (int z = 0; z < sz - 1; z++)
        for (int y = 0; y < sy - 1; y++)
        for (int x = 0; x < sx - 1; x++)
        {
            bool positive = false, negative = false;
            for (int c = 0; c < 8; c++)
            {
                var corner = Corners[c];
                densities[c] = field[(x + corner.X) + sx * ((y + corner.Y) + sy * (z + corner.Z))];
                positive |= densities[c] > 0;
                negative |= densities[c] <= 0;
                positions[c] = lattice.Origin + new Vector3((x0 + x + corner.X) * step, (y0 + y + corner.Y) * step,
                    (z0 + z + corner.Z) * step);
            }
            if (!positive || !negative) continue;
            for (int t = 0; t < 6; t++)
            {
                foreach (var (a, b, c) in Tetra(positions, densities, t))
                {
                    var centre = (a + b + c) / 3.0;
                    bool isCrack = CrackTerm(centre, i, seeds, sides, normal, offset) + halfGap >= lattice.At(centre);
                    var flat = (c - a).Cross(b - a);
                    if (flat.LengthSquared() < 1e-14) continue;
                    flat = flat.Normalized();
                    var target = isCrack ? crackFaces : wall;
                    var normals = isCrack ? crackNormals : wallNormals;
                    foreach (var v in new[] { a, b, c })
                    {
                        target.Add(frame * v);
                        var n = isCrack ? flat : lattice.Gradient(v);
                        if (n.LengthSquared() < 1e-12 || n.Dot(flat) <= 0) n = flat;
                        normals.Add((frame.Basis * n.Normalized()).Normalized());
                        lowest = lowest.Min(v);
                        highest = highest.Max(v);
                    }
                    // Divergence theorem: (a, c, b) is wound with its normal out of the block.
                    var ra = a - reference;
                    var rb = b - reference;
                    var rc = c - reference;
                    double tetra = ra.Dot(rc.Cross(rb)) / 6.0;
                    volume += tetra;
                    moment += (ra + rb + rc) * (tetra / 4.0);
                }
            }
        }
        if (wall.Count + crackFaces.Count == 0 || volume <= 1e-9) return EmptyFragment(i, sides[i]);
        var centroid = reference + moment / volume;
        var extent = highest - lowest;
        return new GDict
        {
            ["index"] = i, ["side"] = sides[i],
            ["wall"] = wall.ToArray(), ["wall_normals"] = wallNormals.ToArray(),
            ["crack"] = crackFaces.ToArray(), ["crack_normals"] = crackNormals.ToArray(),
            ["centroid"] = frame * centroid, ["volume"] = volume,
            ["size"] = Math.Max(extent.X, Math.Max(extent.Y, extent.Z)),
        };
    }

    /// <summary>The triangles of tetrahedron [tetra] of a cube, wound as BuildRegion's: -(b-a)×(c-a) points out of
    /// the solid (density <= 0), into the air.</summary>
    private static IEnumerable<(Vector3, Vector3, Vector3)> Tetra(Vector3[] p, double[] d, int tetra)
    {
        var ins = new int[4];
        var outs = new int[4];
        int ni = 0, no = 0;
        var air = Vector3.Zero;
        for (int k = 0; k < 4; k++)
        {
            int v = Tetrahedra[tetra, k];
            if (d[v] > 0) { ins[ni++] = v; air += p[v]; } else outs[no++] = v;
        }
        if (ni == 0 || ni == 4) yield break;
        air /= ni;
        Vector3 Cross(int a, int b) => p[a].Lerp(p[b], d[a] / (d[a] - d[b]));
        (Vector3, Vector3, Vector3) Wind(Vector3 a, Vector3 b, Vector3 c)
            => -(b - a).Cross(c - a).Dot(air - a) < 0 ? (a, c, b) : (a, b, c);
        if (ni == 1 || ni == 3)
        {
            int centre = ni == 1 ? ins[0] : outs[0];
            var other = ni == 1 ? outs : ins;
            yield return Wind(Cross(centre, other[0]), Cross(centre, other[1]), Cross(centre, other[2]));
        }
        else
        {
            var a = Cross(ins[0], outs[0]);
            var b = Cross(ins[0], outs[1]);
            var c = Cross(ins[1], outs[1]);
            var e = Cross(ins[1], outs[0]);
            yield return Wind(a, b, c);
            yield return Wind(a, c, e);
        }
    }
}
