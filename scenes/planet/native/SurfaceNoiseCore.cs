using System;

/// <summary>
/// The arithmetic of scenes/planet/surface_noise.gd, in the SAME order on IEEE doubles, for the C# passes
/// of a chunk: a value computed here equals the GDScript one bit for bit on Linux, where both call glibc's
/// sin. Elsewhere see test_rock_impurity_native.gd: the Windows engine's sin is not glibc's, .NET's nearly.
/// </summary>
internal static class SurfaceNoiseCore
{
    /// <summary>SurfaceNoise.hash1 at the lattice point (x, y, z).</summary>
    private static double Hash1(double x, double y, double z)
    {
        double v = Math.Sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453123;
        return v - Math.Floor(v);
    }

    /// <summary>SurfaceNoise.vnoise.</summary>
    public static double Vnoise(double px, double py, double pz)
    {
        double ix = Math.Floor(px), iy = Math.Floor(py), iz = Math.Floor(pz);
        double fx = px - ix, fy = py - iy, fz = pz - iz;
        double wx = fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0);
        double wy = fy * fy * fy * (fy * (fy * 6.0 - 15.0) + 10.0);
        double wz = fz * fz * fz * (fz * (fz * 6.0 - 15.0) + 10.0);
        double x00 = MountainNoiseCore.Lerp(Hash1(ix, iy, iz), Hash1(ix + 1.0, iy, iz), wx);
        double x10 = MountainNoiseCore.Lerp(Hash1(ix, iy + 1.0, iz), Hash1(ix + 1.0, iy + 1.0, iz), wx);
        double x01 = MountainNoiseCore.Lerp(Hash1(ix, iy, iz + 1.0), Hash1(ix + 1.0, iy, iz + 1.0), wx);
        double x11 = MountainNoiseCore.Lerp(Hash1(ix, iy + 1.0, iz + 1.0), Hash1(ix + 1.0, iy + 1.0, iz + 1.0), wx);
        return MountainNoiseCore.Lerp(MountainNoiseCore.Lerp(x00, x10, wy), MountainNoiseCore.Lerp(x01, x11, wy), wz);
    }

    /// <summary>SurfaceNoise.mottle at the point (x, y, z) of a sphere of the given radius.</summary>
    public static double Mottle(double x, double y, double z, double radius, double blotchM, double streakM)
    {
        double sb = radius / blotchM, ss = radius / streakM;
        double blotch = Vnoise(x * sb, y * sb, z * sb);
        double streak = Vnoise(x * ss, y * ss, z * ss);
        return MountainNoiseCore.Clamp(blotch * 0.7 + streak * 0.3, 0.0, 1.0);
    }
}
