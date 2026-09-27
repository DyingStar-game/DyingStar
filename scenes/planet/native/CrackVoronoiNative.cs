using System;
using Godot;

/// <summary>
/// The corundum crack network's Voronoi — the C# twin of
/// ArideDesertCorundumPlateauTerrain._voronoi_edge_dn, written in the SAME order
/// on IEEE doubles so it returns the GDScript's value bit for bit.
///
/// Why: it is the expensive half of every crack query — two 3×3×3 passes, 54
/// lattice hashes of three sines each — and a fine chunk asks it once per vertex
/// for the rim snap and again for the gradient probes. Measured at ~100 ms of a
/// chunk in GDScript on every corundum ground of the planet.
///
/// The hash is SurfaceNoise.hash3: fract(sin(dot) × 43758.5453123), whose value
/// is extremely sensitive to the last bit of sin. Math.Sin reaches the same glibc
/// libm as the engine's sin on Linux; test/unit/test_crack_voronoi_native.gd holds
/// the two equal on the machine running it — run it on a platform before trusting
/// it there. Pure and stateless: safe from any thread.
/// </summary>
public partial class CrackVoronoiNative : RefCounted
{
    /// <summary>_voronoi_edge_dn(x): nearest edge plane's unit normal in xyz, distance (cells) in w.</summary>
    public Vector4 EdgeDn(Vector3 x)
    {
        double xx = x.X, xy = x.Y, xz = x.Z;
        double nx = Math.Floor(xx), ny = Math.Floor(xy), nz = Math.Floor(xz);
        double fx = xx - nx, fy = xy - ny, fz = xz - nz;

        // Pass 1: the closest feature point.
        double mrx = 0.0, mry = 0.0, mrz = 0.0;
        double mgx = 0.0, mgy = 0.0, mgz = 0.0;
        double md = 1.0e9;
        for (int k = -1; k < 2; k++)
        {
            for (int j = -1; j < 2; j++)
            {
                for (int i = -1; i < 2; i++)
                {
                    double gx = i, gy = j, gz = k;
                    Hash3(nx + gx, ny + gy, nz + gz, out double hx, out double hy, out double hz);
                    double rx = gx + hx - fx;
                    double ry = gy + hy - fy;
                    double rz = gz + hz - fz;
                    double d = rx * rx + ry * ry + rz * rz;
                    if (d < md)
                    {
                        md = d;
                        mrx = rx; mry = ry; mrz = rz;
                        mgx = gx; mgy = gy; mgz = gz;
                    }
                }
            }
        }

        // Pass 2: the distance to the edge between it and each neighbour.
        double edge = 1.0e9;
        double ex = 0.0, ey = 0.0, ez = 0.0;
        for (int k = -1; k < 2; k++)
        {
            for (int j = -1; j < 2; j++)
            {
                for (int i = -1; i < 2; i++)
                {
                    double gx = mgx + i, gy = mgy + j, gz = mgz + k;
                    Hash3(nx + gx, ny + gy, nz + gz, out double hx, out double hy, out double hz);
                    double rx = gx + hx - fx;
                    double ry = gy + hy - fy;
                    double rz = gz + hz - fz;
                    double dx = rx - mrx, dy = ry - mry, dz = rz - mrz;
                    if (dx * dx + dy * dy + dz * dz > 1.0e-5)
                    {
                        Normalize(dx, dy, dz, out double ndx, out double ndy, out double ndz);
                        double e = (0.5 * (mrx + rx)) * ndx + (0.5 * (mry + ry)) * ndy
                            + (0.5 * (mrz + rz)) * ndz;
                        if (e < edge)
                        {
                            edge = e;
                            ex = ndx; ey = ndy; ez = ndz;
                        }
                    }
                }
            }
        }
        return new Vector4(ex, ey, ez, edge);
    }

    /// <summary>SurfaceNoise.hash3: per-cell jitter in [0,1)³, fract(sin(dot) × 43758.5453123).</summary>
    private static void Hash3(double cx, double cy, double cz, out double hx, out double hy, out double hz)
    {
        double x = Math.Sin(cx * 127.1 + cy * 311.7 + cz * 74.7) * 43758.5453123;
        double y = Math.Sin(cx * 269.5 + cy * 183.3 + cz * 246.1) * 43758.5453123;
        double z = Math.Sin(cx * 113.5 + cy * 271.9 + cz * 124.6) * 43758.5453123;
        hx = x - Math.Floor(x);
        hy = y - Math.Floor(y);
        hz = z - Math.Floor(z);
    }

    /// <summary>Vector3.normalized() as Godot computes it.</summary>
    private static void Normalize(double x, double y, double z, out double nx, out double ny, out double nz)
    {
        double lengthsq = x * x + y * y + z * z;
        if (lengthsq == 0.0)
        {
            nx = 0.0; ny = 0.0; nz = 0.0;
            return;
        }
        double length = Math.Sqrt(lengthsq);
        nx = x / length;
        ny = y / length;
        nz = z / length;
    }
}
