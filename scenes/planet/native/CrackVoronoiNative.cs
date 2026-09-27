using System;
using Godot;

/// <summary>
/// The corundum crack network in C# — the twin of ArideDesertCorundumPlateauTerrain's
/// _voronoi_gd, _edge_distance and _snap and of CrackNoise's warp and rim, written in the
/// SAME order on IEEE doubles so it returns the GDScript's value bit for bit.
///
/// Why: the Voronoi is the expensive half of every crack query — two 3×3×3 passes, 54
/// lattice hashes — and the rim snap asks it about ten times per vertex near a wall.
///
/// No sine anywhere: the feature points are jittered by MountainNoiseCore's integer hash
/// and the meander and rim noise are its value noise, so every machine computes the same
/// network. One instance per planet network (Configure), read-only afterwards: safe from
/// any thread.
/// </summary>
public partial class CrackVoronoiNative : RefCounted
{
    private const int MeanderOctaves = 2;
    private const int RimOctaves = 3;
    private const double SnapProbeM = 0.5;
    private const int SnapIterations = 5;
    private const double SnapReachSlope = 2.0;
    private const double SnapMinGradientSq = 1.0e-4;
    private const double SnapToleranceM = 0.02;

    private long _seed;
    private double _meanderAmp;
    private double _meanderWavelength = 1500.0;
    private double _rimAmp;
    private double _rimWavelength = 400.0;
    private double _finest;

    /// <summary>CrackNoise's fields (already clamped there).</summary>
    public void Configure(long seed, double meanderAmp, double meanderWavelength, double rimAmp,
        double rimWavelength, double finest)
    {
        _seed = seed;
        _meanderAmp = meanderAmp;
        _meanderWavelength = meanderWavelength;
        _rimAmp = rimAmp;
        _rimWavelength = rimWavelength;
        _finest = finest;
    }

    /// <summary>_voronoi_edge_dn(x): nearest edge plane's unit normal in xyz, distance (cells) in w.</summary>
    public Vector4 EdgeDn(Vector3 x)
    {
        double edge = Edge(x.X, x.Y, x.Z, out double ex, out double ey, out double ez);
        return new Vector4(ex, ey, ez, edge);
    }

    /// <summary>_edge_distance(dir, radius, spacing, vtx): the rim distance in metres, before the width.</summary>
    public double EdgeDistance(Vector3 dir, double radius, double spacing, double vtxSpacing)
        => EdgeDistanceD(dir.X, dir.Y, dir.Z, radius, spacing, vtxSpacing);

    /// <summary>_snap(dir, radius, spacing, width, vtx, maxMove): the moved direction, and its declared distance.</summary>
    public Vector4 Snap(Vector3 dir, double radius, double spacing, double width, double vtxSpacing,
        double maxMove, double footInset)
    {
        double dx = dir.X, dy = dir.Y, dz = dir.Z;
        double d = EdgeDistanceD(dx, dy, dz, radius, spacing, vtxSpacing);
        if (maxMove <= 0.0)
            return new Vector4(dx, dy, dz, d);
        double half = width * 0.5;
        double target = d >= half ? half : half - footInset;
        double f = d - target;
        if (Math.Abs(f) > maxMove * SnapReachSlope)
            return new Vector4(dx, dy, dz, d);
        double xx = dx, xy = dy, xz = dz;
        double hr = SnapProbeM / radius;
        for (int it = 0; it < SnapIterations; it++)
        {
            // up_ref = UP if |x.y| < 0.99 else RIGHT; t1 = x.cross(up_ref).normalized(); t2 = x.cross(t1)
            double rx, ry, rz;
            if (Math.Abs(xy) < 0.99) { rx = 0.0; ry = 1.0; rz = 0.0; }
            else { rx = 1.0; ry = 0.0; rz = 0.0; }
            Cross(xx, xy, xz, rx, ry, rz, out double c1x, out double c1y, out double c1z);
            Normalize(c1x, c1y, c1z, out double t1x, out double t1y, out double t1z);
            Cross(xx, xy, xz, t1x, t1y, t1z, out double t2x, out double t2y, out double t2z);
            double here = f + target;
            double g1 = (Probe(xx, xy, xz, t1x * hr, t1y * hr, t1z * hr, radius, spacing, vtxSpacing) - here)
                / SnapProbeM;
            double g2 = (Probe(xx, xy, xz, t2x * hr, t2y * hr, t2z * hr, radius, spacing, vtxSpacing) - here)
                / SnapProbeM;
            double gl2 = g1 * g1 + g2 * g2;
            if (gl2 < SnapMinGradientSq)
                return new Vector4(dx, dy, dz, d);
            double step = -f / gl2;
            double sa = step * g1, sb = step * g2;
            double mx = (t1x * sa + t2x * sb) / radius;
            double my = (t1y * sa + t2y * sb) / radius;
            double mz = (t1z * sa + t2z * sb) / radius;
            Normalize(xx + mx, xy + my, xz + mz, out xx, out xy, out xz);
            f = EdgeDistanceD(xx, xy, xz, radius, spacing, vtxSpacing) - target;
            if (Math.Abs(f) <= SnapToleranceM)
                break;
        }
        double ddx = dx - xx, ddy = dy - xy, ddz = dz - xz;
        if (Math.Abs(f) > SnapToleranceM || Math.Sqrt(ddx * ddx + ddy * ddy + ddz * ddz) * radius > maxMove)
            return new Vector4(dx, dy, dz, d);
        return new Vector4(xx, xy, xz, target);
    }

    /// <summary>_edge_distance((x + h).normalized(), …).</summary>
    private double Probe(double xx, double xy, double xz, double hx, double hy, double hz,
        double radius, double spacing, double vtxSpacing)
    {
        Normalize(xx + hx, xy + hy, xz + hz, out double nx, out double ny, out double nz);
        return EdgeDistanceD(nx, ny, nz, radius, spacing, vtxSpacing);
    }

    /// <summary>_edge_distance: the Voronoi at the warped point, less the rim noise.</summary>
    public double EdgeDistanceD(double dx, double dy, double dz, double radius, double spacing, double vtxSpacing)
    {
        double eff = Math.Max(vtxSpacing, _finest);
        // q = dir * radius, then the meander (CrackNoise.warp)
        double qx = dx * radius, qy = dy * radius, qz = dz * radius;
        if (_meanderAmp > 0.0)
        {
            double wx = 0.0, wy = 0.0, wz = 0.0;
            double lam = _meanderWavelength;
            double w = 1.0;
            double norm = 0.0;
            for (int o = 0; o < MeanderOctaves; o++)
            {
                norm += w;
                if (lam >= 2.0 * eff)
                {
                    double s = radius / lam;
                    double sx = dx * s, sy = dy * s, sz = dz * s;
                    long k = _seed * 16 + 5 + o * 3;
                    wx += w * MountainNoiseCore.Snoise(sx, sy, sz, k);
                    wy += w * MountainNoiseCore.Snoise(sx, sy, sz, k + 1);
                    wz += w * MountainNoiseCore.Snoise(sx, sy, sz, k + 2);
                }
                lam *= 0.5;
                w *= 0.5;
            }
            double a = _meanderAmp / norm;
            qx = qx + wx * a;
            qy = qy + wy * a;
            qz = qz + wz * a;
        }
        double d = Edge(qx / spacing, qy / spacing, qz / spacing, out double _, out double _, out double _)
            * spacing;
        return d - Rim(dx, dy, dz, radius, eff);
    }

    /// <summary>CrackNoise.rim.</summary>
    private double Rim(double dx, double dy, double dz, double radius, double eff)
    {
        if (_rimAmp <= 0.0)
            return 0.0;
        double total = 0.0;
        double lam = _rimWavelength;
        double w = 1.0;
        double norm = 0.0;
        for (int o = 0; o < RimOctaves; o++)
        {
            norm += w;
            if (lam >= 2.0 * eff)
            {
                double s = radius / lam;
                total += w * MountainNoiseCore.Snoise(dx * s, dy * s, dz * s, _seed * 16 + 11 + o);
            }
            lam *= 0.5;
            w *= 0.5;
        }
        return _rimAmp * total / norm;
    }

    /// <summary>_voronoi_gd: the distance in cells, the edge normal out.</summary>
    public double Edge(double xx, double xy, double xz, out double ex, out double ey, out double ez)
    {
        double nx = Math.Floor(xx), ny = Math.Floor(xy), nz = Math.Floor(xz);
        double fx = xx - nx, fy = xy - ny, fz = xz - nz;
        long ix = (long)nx, iy = (long)ny, iz = (long)nz;
        long s0 = _seed * 16 + 1, s1 = _seed * 16 + 2, s2 = _seed * 16 + 3;

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
                    long cx = ix + i, cy = iy + j, cz = iz + k;
                    double rx = gx + MountainNoiseCore.Cell(cx, cy, cz, s0) - fx;
                    double ry = gy + MountainNoiseCore.Cell(cx, cy, cz, s1) - fy;
                    double rz = gz + MountainNoiseCore.Cell(cx, cy, cz, s2) - fz;
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
        ex = 0.0; ey = 0.0; ez = 0.0;
        long mix = (long)mgx, miy = (long)mgy, miz = (long)mgz;
        for (int k = -1; k < 2; k++)
        {
            for (int j = -1; j < 2; j++)
            {
                for (int i = -1; i < 2; i++)
                {
                    double gx = mgx + i, gy = mgy + j, gz = mgz + k;
                    long cx = ix + mix + i, cy = iy + miy + j, cz = iz + miz + k;
                    double rx = gx + MountainNoiseCore.Cell(cx, cy, cz, s0) - fx;
                    double ry = gy + MountainNoiseCore.Cell(cx, cy, cz, s1) - fy;
                    double rz = gz + MountainNoiseCore.Cell(cx, cy, cz, s2) - fz;
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
        return edge;
    }

    /// <summary>Vector3.cross as Godot computes it.</summary>
    private static void Cross(double ax, double ay, double az, double bx, double by, double bz,
        out double cx, out double cy, out double cz)
    {
        cx = ay * bz - az * by;
        cy = az * bx - ax * bz;
        cz = ax * by - ay * bx;
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
