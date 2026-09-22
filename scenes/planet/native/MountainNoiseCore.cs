using System;

/// <summary>
/// Shared arithmetic of the procedural mountains — the C# twin of
/// scenes/planet/mountain_noise.gd, kept in the SAME order on IEEE doubles so
/// a value computed here equals the GDScript one bit for bit
/// (test/unit/test_mountain_noise.gd pins both on the Python golden values).
///
/// Why C#: one GDScript call per sample instead of ~120 (seven octaves × eight
/// lattice hashes × the call overhead) — measured 5.8 µs against 75 µs.
/// No FMA contraction (RyuJIT never fuses a*b+c on its own), Math.Floor /
/// Math.Sqrt correctly rounded everywhere; Math.Pow is reached only for an
/// exponent outside the exact set (PowFast).
/// </summary>
internal static class MountainNoiseCore
{
    public const long M32 = 0xFFFFFFFFL;
    public const int MaxOctaves = 12;
    public const double Lacunarity = 2.0;

    public static long HashI(long ix, long iy, long iz, long seed)
    {
        unchecked
        {
            long h = ((ix * 0x8DA6B343L) ^ (iy * 0xD8163841L) ^ (iz * 0xCB1AB31FL)
                      ^ (seed * 0x9E3779B1L) ^ 0x27D4EB2FL) & M32;
            h ^= h >> 16;
            h = (h * 0x7FEB352DL) & M32;
            h ^= h >> 15;
            h = (h * 0x846CA68BL) & M32;
            h ^= h >> 16;
            return h;
        }
    }

    public static double Cell(long ix, long iy, long iz, long seed)
        => (double)(HashI(ix, iy, iz, seed) >> 8) / 16777216.0;

    public static double Lerp(double a, double b, double t) => a + (b - a) * t;

    public static double Vnoise(double x, double y, double z, long seed)
    {
        double fx = Math.Floor(x), fy = Math.Floor(y), fz = Math.Floor(z);
        long ix = (long)fx, iy = (long)fy, iz = (long)fz;
        double tx = x - fx, ty = y - fy, tz = z - fz;
        double wx = tx * tx * tx * (tx * (tx * 6.0 - 15.0) + 10.0);
        double wy = ty * ty * ty * (ty * (ty * 6.0 - 15.0) + 10.0);
        double wz = tz * tz * tz * (tz * (tz * 6.0 - 15.0) + 10.0);
        double x00 = Lerp(Cell(ix, iy, iz, seed), Cell(ix + 1, iy, iz, seed), wx);
        double x10 = Lerp(Cell(ix, iy + 1, iz, seed), Cell(ix + 1, iy + 1, iz, seed), wx);
        double x01 = Lerp(Cell(ix, iy, iz + 1, seed), Cell(ix + 1, iy, iz + 1, seed), wx);
        double x11 = Lerp(Cell(ix, iy + 1, iz + 1, seed), Cell(ix + 1, iy + 1, iz + 1, seed), wx);
        return Lerp(Lerp(x00, x10, wy), Lerp(x01, x11, wy), wz);
    }

    public static double Snoise(double x, double y, double z, long seed)
        => Vnoise(x, y, z, seed) * 2.0 - 1.0;

    public static double PowFast(double x, double e)
    {
        if (e == 1.0) return x;
        if (e == 2.0) return x * x;
        if (e == 3.0) return x * x * x;
        if (e == 1.5) return x * Math.Sqrt(x);
        if (e == 0.5) return Math.Sqrt(x);
        return Math.Pow(x, e);
    }

    /// <summary>Godot's smoothstep(from, to, x) — same edge handling.</summary>
    public static double Smoothstep(double from, double to, double x)
    {
        if (from == to) return x < from ? 0.0 : 1.0;
        double s = (x - from) / (to - from);
        if (s < 0.0) s = 0.0; else if (s > 1.0) s = 1.0;
        return s * s * (3.0 - 2.0 * s);
    }

    public static double Terrace(double hM, double stepM, double width)
    {
        if (stepM <= 0.0) return hM;
        double q = hM / stepM;
        double k = Math.Floor(q);
        double f = q - k;
        double f2 = Smoothstep(1.0 - width, 1.0, f);
        return (k + f2) * stepM;
    }

    /// <summary>HEALPix.vec2lonlat: degrees, lon in (-180, 180], lat in [-90, 90].
    /// Same formula (asin of y, atan2(z, x) of the NORMALISED vector).</summary>
    public static void ToLonLat(double x, double y, double z, out double lon, out double lat)
    {
        double len = Math.Sqrt(x * x + y * y + z * z);
        double nx = x / len, ny = y / len, nz = z / len;
        if (ny < -1.0) ny = -1.0; else if (ny > 1.0) ny = 1.0;
        lat = Math.Asin(ny) * (180.0 / Math.PI);
        lon = Math.Atan2(nz, nx) * (180.0 / Math.PI);
    }

    public static double DegToRad(double d) => d * (Math.PI / 180.0);

    /// <summary>RoadTerrain._dist_sq_to_segment — squared distance in lat-degree
    /// units, longitudes scaled by latScale.</summary>
    public static double DistSqToSegment(double px, double py, double ax, double ay,
                                         double bx, double by, double latScale)
    {
        double sax = ax * latScale, sbx = bx * latScale, spx = px * latScale;
        double dx = sbx - sax, dy = by - ay;
        double segSq = dx * dx + dy * dy;
        double t = 0.0;
        if (segSq > 1e-24)
        {
            t = ((spx - sax) * dx + (py - ay) * dy) / segSq;
            if (t < 0.0) t = 0.0; else if (t > 1.0) t = 1.0;
        }
        double cx = spx - (sax + t * dx), cy = py - (ay + t * dy);
        return cx * cx + cy * cy;
    }

    public static double Clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);
}
