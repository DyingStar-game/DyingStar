using System;
using Godot;

/// <summary>
/// The first pass of NovaScatter.lay_chunk in C#: which cells of one layer on one chunk hold an object
/// at all — the cell's hash against the layer's density, then its clump — and that object's uniform
/// numbers. The twin of NovaScatter.cell_survivors (cell_hash, unit, clump_weight), written in the SAME
/// order on 64-bit integers and IEEE doubles so it returns the GDScript's numbers bit for bit. No sine,
/// no square root: nothing that differs between machines.
///
/// Why: a small layer seen from 60 m walks 65 536 cells per chunk, and in GDScript the hash and the
/// clump were ~60 % of a village chunk's 8-28 s of laying (2026-11-27, test/perf/nova_lay_probe).
/// Stateless: safe from any thread.
/// </summary>
public partial class NovaCellsNative : RefCounted
{
    /// <summary>NovaScatter.CELL_ROW: doubles per surviving cell.</summary>
    public const int Row = 11;
    private const long M32 = 0xFFFFFFFFL;
    private const long ClumpSalt = 0x5BD1E995L;
    private const double ClumpSoft = 0.07;
    private const double CmpEpsilon = 0.00001;

    /// <summary>
    /// The cells (cx, cy) of the r × r block at face position (x0, y0) that hold an object of the layer,
    /// row by row: [cx, cy, fx, fy, u_mesh, u_yaw, u_scale, u_edge, u_spill_turn, u_spill_far, u_keep] each.
    /// clumpCells ≤ 1: no clumps. Only within the blocks of mask (blocks × blocks of them, bit
    /// bx + by × blocks, bx = cx × blocks / r; -1: all).
    /// </summary>
    public double[] CellsInBlocks(long layerSeed, double density, long face, long x0, long y0, long r, long clumpCells,
        double clumpShare, long blocks, long mask)
    {
        // A quarter of the cells to start with: a dense layer keeps about a third, a clumped one less.
        var buffer = new double[Math.Max(Row * 64, (int)Math.Min(r * r * Row / 4, 1L << 24))];
        int n = 0;
        for (long cy = 0; cy < r; cy++)
        {
            long rowBlock = (cy * blocks / r) * blocks;
            for (long cx = 0; cx < r; cx++)
            {
                if (((mask >> (int)(rowBlock + cx * blocks / r)) & 1L) == 0)
                    continue;
                long ix = x0 + cx;
                long iy = y0 + cy;
                long h = CellHash(layerSeed, face, ix, iy);
                if (Unit(h, 0) >= density)
                    continue;
                double fx = (double)ix + Unit(h, 1);
                double fy = (double)iy + Unit(h, 2);
                double uEdge = Unit(h, 6);
                if (clumpCells > 1 && uEdge >= ClumpWeight(layerSeed, face, fx, fy, clumpCells, clumpShare))
                    continue;
                if (n + Row > buffer.Length)
                    Array.Resize(ref buffer, buffer.Length * 2);
                buffer[n] = cx;
                buffer[n + 1] = cy;
                buffer[n + 2] = fx;
                buffer[n + 3] = fy;
                buffer[n + 4] = Unit(h, 3);
                buffer[n + 5] = Unit(h, 4);
                buffer[n + 6] = Unit(h, 5);
                buffer[n + 7] = uEdge;
                buffer[n + 8] = Unit(h, 7);
                buffer[n + 9] = Unit(h, 8);
                buffer[n + 10] = Unit(h, 9);
                n += Row;
            }
        }
        Array.Resize(ref buffer, n);
        return buffer;
    }

    /// <summary>NovaScatter.mix32.</summary>
    public static long Mix32(long x)
    {
        unchecked
        {
            x &= M32;
            x = ((x ^ (x >> 16)) * 0x7feb352dL) & M32;
            x = ((x ^ (x >> 15)) * 0x2c1b3c6dL) & M32;
            return (x ^ (x >> 16)) & M32;
        }
    }

    /// <summary>NovaScatter.cell_hash.</summary>
    public static long CellHash(long layerSeed, long face, long ix, long iy)
    {
        long h = Mix32(layerSeed ^ 0x9e3779b9L);
        h = Mix32(h ^ face);
        h = Mix32(h ^ (ix & M32));
        h = Mix32(h ^ ((ix >> 32) & M32));
        h = Mix32(h ^ (iy & M32));
        return Mix32(h ^ ((iy >> 32) & M32));
    }

    /// <summary>NovaScatter.unit.</summary>
    public static double Unit(long h, long k)
    {
        unchecked
        {
            return (double)Mix32(h + k * 0x632be5abL) / 4294967296.0;
        }
    }

    /// <summary>NovaScatter.clump_weight.</summary>
    public static double ClumpWeight(long layerSeed, long face, double fx, double fy, long cells, double share)
    {
        double gx = fx / cells;
        double gy = fy / cells;
        long gx0 = (long)Math.Floor(gx);
        long gy0 = (long)Math.Floor(gy);
        double tx = Smoothstep(0.0, 1.0, gx - gx0);
        double ty = Smoothstep(0.0, 1.0, gy - gy0);
        long s = layerSeed ^ ClumpSalt;
        double noise = Lerp(
            Lerp(Unit(CellHash(s, face, gx0, gy0), 0), Unit(CellHash(s, face, gx0 + 1, gy0), 0), tx),
            Lerp(Unit(CellHash(s, face, gx0, gy0 + 1), 0), Unit(CellHash(s, face, gx0 + 1, gy0 + 1), 0), tx), ty);
        noise = Clamp((noise - 0.5) * 1.8 + 0.5, 0.0, 1.0);
        return Smoothstep(1.0 - share - ClumpSoft, 1.0 - share + ClumpSoft, noise);
    }

    /// <summary>Math::lerp (core/math/math_funcs.h).</summary>
    private static double Lerp(double from, double to, double weight) => from + (to - from) * weight;

    /// <summary>CLAMP as the engine writes it.</summary>
    private static double Clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

    /// <summary>Math::smoothstep (core/math/math_funcs.h, 4.7).</summary>
    private static double Smoothstep(double from, double to, double x)
    {
        if (IsEqualApprox(from, to))
            return from <= to ? (x <= from ? 0.0 : 1.0) : (x <= to ? 1.0 : 0.0);
        double s = Clamp((x - from) / (to - from), 0.0, 1.0);
        return s * s * (3.0 - 2.0 * s);
    }

    /// <summary>Math::is_equal_approx(double, double).</summary>
    private static bool IsEqualApprox(double a, double b)
    {
        if (a == b)
            return true;
        double tolerance = CmpEpsilon * Math.Abs(a);
        if (tolerance < CmpEpsilon)
            tolerance = CmpEpsilon;
        return Math.Abs(a - b) < tolerance;
    }
}
