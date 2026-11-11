using Godot;
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using GDict = Godot.Collections.Dictionary;

/// <summary>One box of a configured network (Configure), meshed on its own: what a village mine (MineMesher) streams
/// cell by cell. The lattice is the WORLD lattice of the given step (sample i sits at i × step), so two neighbouring
/// boxes read the very same densities on their shared face and their surfaces meet exactly. A volume is applied to a
/// sample by the same global index range in every box, so no box can see a volume its neighbour does not.
/// Vertex normals come from the density gradient, one sample past the box: the shading is continuous across boxes.
/// Thread safe once configured: it only reads the volumes, so several boxes may be built at once.</summary>
public partial class CaveNetworkMesher
{
    /// <summary>The surfaces of the network inside [region] (its corners on multiples of [step], in m), every
    /// triangle above [topY] cut away (the ground a mine shaft opens through). Returns wall and floor triangle
    /// soups with their vertex normals; floor = faces turned up by more than ~49°, as in Build.</summary>
    public GDict BuildRegion(Aabb region, double step, double topY)
    {
        int gx = (int)Math.Round(region.Position.X / step) - 1;
        int gy = (int)Math.Round(region.Position.Y / step) - 1;
        int gz = (int)Math.Round(region.Position.Z / step) - 1;
        int nx = (int)Math.Round(region.Size.X / step) + 3;
        int ny = (int)Math.Round(region.Size.Y / step) + 3;
        int nz = (int)Math.Round(region.Size.Z / step) + 3;
        var result = new GDict
        {
            ["wall"] = Array.Empty<Vector3>(), ["wall_normals"] = Array.Empty<Vector3>(),
            ["floor"] = Array.Empty<Vector3>(), ["floor_normals"] = Array.Empty<Vector3>(),
        };
        // A box wholly above the cut keeps nothing but slivers lying flat on it, which Jolt refuses as a mesh.
        if (region.Position.Y >= topY) return result;
        // Every volume reaching the lattice, with its sample range as GLOBAL indices (the same in every box).
        var reach = new List<(int I, int X0, int Y0, int Z0, int X1, int Y1, int Z1)>();
        for (int i = 0; i < _volumes.Length; i++)
        {
            var lo = _volumes[i].Bounds.Position;
            var hi = _volumes[i].Bounds.End;
            int x0 = Math.Max((int)Math.Floor(lo.X / step), gx), x1 = Math.Min((int)Math.Ceiling(hi.X / step), gx + nx - 1);
            int y0 = Math.Max((int)Math.Floor(lo.Y / step), gy), y1 = Math.Min((int)Math.Ceiling(hi.Y / step), gy + ny - 1);
            int z0 = Math.Max((int)Math.Floor(lo.Z / step), gz), z1 = Math.Min((int)Math.Ceiling(hi.Z / step), gz + nz - 1);
            if (x0 > x1 || y0 > y1 || z0 > z1) continue;
            reach.Add((i, x0 - gx, y0 - gy, z0 - gz, x1 - gx, y1 - gy, z1 - gz));
        }
        if (reach.Count == 0) return result;
        var values = new float[nx * ny * nz];
        Array.Fill(values, -4f);
        // Densities, one z slice per worker: each sample applies its volumes in their original order, a gallery's
        // consecutive segments gathered (exact max) then blended in once, as Build and Sample do.
        Parallel.For(0, nz, z =>
        {
            int plane = nx * ny;
            var group = new float[plane];
            Array.Fill(group, float.NaN);
            int current = -1;
            void Flush()
            {
                for (int k = 0; k < plane; k++)
                {
                    if (float.IsNaN(group[k])) continue;
                    values[z * plane + k] = (float)Combine(values[z * plane + k], group[k], false);
                    group[k] = float.NaN;
                }
            }
            foreach (var r in reach)
            {
                if (z < r.Z0 || z > r.Z1) continue;
                bool subtract = _volumes[r.I].Pillar || _volumes[r.I].Bridge;
                if (subtract || _group[r.I] != current)
                {
                    Flush();
                    current = subtract ? -1 : _group[r.I];
                }
                for (int y = r.Y0; y <= r.Y1; y++)
                for (int x = r.X0; x <= r.X1; x++)
                {
                    var p = new Vector3((gx + x) * step, (gy + y) * step, (gz + z) * step);
                    double density = Density(r.I, p);
                    int k = x + nx * y;
                    if (subtract)
                        values[z * plane + k] = (float)Combine(values[z * plane + k], density, true);
                    else
                        group[k] = float.IsNaN(group[k]) ? (float)density : Math.Max(group[k], (float)density);
                }
            }
            Flush();
        });
        // Triangles of the cubes inside the region (lattice 1 .. n-2), one z slice per worker, gathered in order.
        var slices = new RegionSurface[nz];
        Parallel.For(1, nz - 2, z =>
        {
            var piece = new RegionSurface();
            var positions = new Vector3[8];
            var normals = new Vector3[8];
            var densities = new double[8];
            for (int y = 1; y < ny - 2; y++)
            for (int x = 1; x < nx - 2; x++)
            {
                bool positive = false, negative = false;
                for (int c = 0; c < 8; c++)
                {
                    var corner = Corners[c];
                    densities[c] = values[(x + corner.X) + nx * ((y + corner.Y) + ny * (z + corner.Z))];
                    positive |= densities[c] > 0;
                    negative |= densities[c] <= 0;
                }
                if (!positive || !negative) continue;
                for (int c = 0; c < 8; c++)
                {
                    var corner = Corners[c];
                    int cx = x + corner.X, cy = y + corner.Y, cz = z + corner.Z;
                    positions[c] = new Vector3((gx + cx) * step, (gy + cy) * step, (gz + cz) * step);
                    normals[c] = Gradient(values, nx, ny, cx, cy, cz);
                }
                for (int t = 0; t < 6; t++)
                    PolygonizeRegion(positions, normals, densities, t, piece, topY);
            }
            slices[z] = piece;
        });
        var wall = new List<Vector3>();
        var wallNormals = new List<Vector3>();
        var floor = new List<Vector3>();
        var floorNormals = new List<Vector3>();
        foreach (var piece in slices)
        {
            if (piece == null) continue;
            wall.AddRange(piece.Wall);
            wallNormals.AddRange(piece.WallNormals);
            floor.AddRange(piece.Floor);
            floorNormals.AddRange(piece.FloorNormals);
        }
        result["wall"] = wall.ToArray();
        result["wall_normals"] = wallNormals.ToArray();
        result["floor"] = floor.ToArray();
        result["floor_normals"] = floorNormals.ToArray();
        return result;
    }

    /// <summary>Density gradient at a lattice sample (central differences): it points into the air, which is
    /// where a surface faces.</summary>
    private static Vector3 Gradient(float[] values, int nx, int ny, int x, int y, int z)
    {
        int at = x + nx * (y + ny * z);
        double dx = values[at + 1] - values[at - 1];
        double dy = values[at + nx] - values[at - nx];
        double dz = values[at + nx * ny] - values[at - nx * ny];
        return new Vector3(dx, dy, dz);
    }

    private sealed class RegionSurface
    {
        public readonly List<Vector3> Wall = new(), WallNormals = new(), Floor = new(), FloorNormals = new();
    }

    private static void PolygonizeRegion(Vector3[] p, Vector3[] n, double[] d, int tetra, RegionSurface piece, double topY)
    {
        Span<int> ins = stackalloc int[4];
        Span<int> outs = stackalloc int[4];
        int ni = 0, no = 0;
        var inside = Vector3.Zero;
        for (int i = 0; i < 4; i++)
        {
            int v = Tetrahedra[tetra, i];
            if (d[v] > 0) { ins[ni++] = v; inside += p[v]; } else outs[no++] = v;
        }
        if (ni == 0 || ni == 4) return;
        inside /= ni;
        (Vector3, Vector3) Cross(int a, int b)
        {
            double t = d[a] / (d[a] - d[b]);
            return (p[a].Lerp(p[b], t), n[a].Lerp(n[b], t));
        }
        if (ni == 1 || ni == 3)
        {
            int center = ni == 1 ? ins[0] : outs[0];
            var other = ni == 1 ? outs : ins;
            EmitRegion(Cross(center, other[0]), Cross(center, other[1]), Cross(center, other[2]), inside, piece, topY);
        }
        else
        {
            var a = Cross(ins[0], outs[0]);
            var b = Cross(ins[0], outs[1]);
            var c = Cross(ins[1], outs[1]);
            var e = Cross(ins[1], outs[0]);
            EmitRegion(a, b, c, inside, piece, topY);
            EmitRegion(a, c, e, inside, piece, topY);
        }
    }

    /// <summary>One triangle, wound as Build's Emit does (facing the air), cut at [topY].</summary>
    private static void EmitRegion((Vector3 P, Vector3 N) a, (Vector3 P, Vector3 N) b, (Vector3 P, Vector3 N) c,
        Vector3 inside, RegionSurface piece, double topY)
    {
        var normal = -(b.P - a.P).Cross(c.P - a.P);
        if (normal.LengthSquared() < 1e-18) return;
        if (normal.Dot(inside - a.P) < 0) { (b, c) = (c, b); normal = -normal; }
        bool isFloor = normal.Normalized().Y > 0.65;
        var points = isFloor ? piece.Floor : piece.Wall;
        var normals = isFloor ? piece.FloorNormals : piece.WallNormals;
        if (a.P.Y <= topY && b.P.Y <= topY && c.P.Y <= topY)
        {
            Append(points, normals, a, b, c);
            return;
        }
        // Sutherland-Hodgman against y <= topY, then a fan.
        var poly = new List<(Vector3 P, Vector3 N)>(4);
        var input = new[] { a, b, c };
        for (int i = 0; i < 3; i++)
        {
            var from = input[i];
            var to = input[(i + 1) % 3];
            bool fromIn = from.P.Y <= topY, toIn = to.P.Y <= topY;
            if (fromIn) poly.Add(from);
            if (fromIn != toIn)
            {
                double t = (topY - from.P.Y) / (to.P.Y - from.P.Y);
                poly.Add((from.P.Lerp(to.P, t), from.N.Lerp(to.N, t)));
            }
        }
        for (int i = 1; i + 1 < poly.Count; i++)
        {
            // A corner of the triangle grazing the cut leaves a sliver of no area: no wall there.
            if ((poly[i].P - poly[0].P).Cross(poly[i + 1].P - poly[0].P).LengthSquared() < 1e-8) continue;
            Append(points, normals, poly[0], poly[i], poly[i + 1]);
        }
    }

    private static void Append(List<Vector3> points, List<Vector3> normals,
        (Vector3 P, Vector3 N) a, (Vector3 P, Vector3 N) b, (Vector3 P, Vector3 N) c)
    {
        foreach (var v in new[] { a, b, c })
        {
            points.Add(v.P);
            normals.Add(v.N.LengthSquared() > 1e-18 ? v.N.Normalized() : Vector3.Up);
        }
    }
}
