using System;

/// <summary>
/// The HEALPix arithmetic the height sampler's hot path needs — the C# twin of
/// the matching functions of scenes/planet/healpix.gd, written in the SAME order
/// on IEEE doubles so every result equals the GDScript one bit for bit.
///
/// Only what the sampler reaches per sample: a direction to its nested pixel,
/// and a direction to its continuous position inside a base face. Nothing here
/// allocates.
///
/// The one dependency on the platform is Math.Atan2: on Linux CoreCLR calls the
/// same glibc libm the engine's atan2 does; on Windows both go to the UCRT.
/// test/unit/test_tile_frame_native.gd pins the two paths equal on the machine
/// running it — run it on a platform before trusting it there.
/// </summary>
internal static class HealpixNative
{
    private static readonly int[] Jrll = { 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4 };
    private static readonly int[] Jpll = { 1, 3, 5, 7, 0, 2, 4, 6, 1, 3, 5, 7 };
    private const double Tau = Math.PI * 2.0;

    /// <summary>Vector3.normalized() as Godot computes it.</summary>
    public static void Normalize(double x, double y, double z,
        out double nx, out double ny, out double nz)
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

    /// <summary>HEALPix.vec2pix_nest — y is up.</summary>
    public static long Vec2PixNest(long nside, double x, double y, double z)
    {
        Normalize(x, y, z, out double dx, out double dy, out double dz);
        double zz = dy;
        double phi = Math.Atan2(dz, dx);
        if (phi < 0.0)
            phi += Tau;
        return Vec2PixNestFromZPhi(nside, zz, phi);
    }

    /// <summary>HEALPix.vec2pix_nest_from_zphi.</summary>
    public static long Vec2PixNestFromZPhi(long nside, double z, double phi)
    {
        double za = Math.Abs(z);
        double tt = phi / (Math.PI * 0.5);
        while (tt < 0.0)
            tt += 4.0;
        while (tt >= 4.0)
            tt -= 4.0;

        long npface = nside * nside;
        long face, ix, iy;

        if (za <= 2.0 / 3.0)
        {
            double temp1 = (double)nside * (0.5 + tt);
            double temp2 = (double)nside * z * 0.75;
            long jp = (long)(temp1 - temp2);
            long jm = (long)(temp1 + temp2);
            long ifp = jp / nside;
            long ifm = jm / nside;
            if (ifp == ifm)
                face = ifp | 4;
            else if (ifp < ifm)
                face = ifp;
            else
                face = ifm + 8;
            ix = jm & (nside - 1);
            iy = nside - (jp & (nside - 1)) - 1;
        }
        else
        {
            double tp = tt - Math.Floor(tt);
            double tmp = (double)nside * Math.Sqrt(3.0 * (1.0 - za));
            long jp = (long)(tp * tmp);
            long jm = (long)((1.0 - tp) * tmp);
            jp = Math.Min(jp, nside - 1);
            jm = Math.Min(jm, nside - 1);
            if (z > 0)
            {
                face = (long)tt;
                if (face >= 4)
                    face = 3;
                ix = nside - jm - 1;
                iy = nside - jp - 1;
            }
            else
            {
                face = (long)tt + 8;
                if (face >= 12)
                    face = 11;
                ix = jp;
                iy = jm;
            }
        }
        return face * npface + Xy2Nest(ix, iy);
    }

    /// <summary>HEALPix._vec_to_face_xy: continuous (fx, fy) of dir within base face [face].</summary>
    public static void VecToFaceXY(double x, double y, double z, int face, long nside,
        out double fx, out double fy)
    {
        Normalize(x, y, z, out double dx, out double dy, out double dz);
        double zz = dy;
        double phi = Math.Atan2(dz, dx);
        if (phi < 0.0)
            phi += Tau;

        double ns = (double)nside;
        double za = Math.Abs(zz);
        double jr, kp, scale;
        if (za <= 2.0 / 3.0)
        {
            jr = ns * (2.0 - zz * 1.5);
            scale = ns;
            kp = phi * 4.0 * ns / Math.PI;
        }
        else if (zz > 0.0)
        {
            scale = ns * Math.Sqrt(3.0 * (1.0 - za));
            jr = scale;
            kp = phi * 4.0 * scale / Math.PI;
        }
        else
        {
            scale = ns * Math.Sqrt(3.0 * (1.0 + zz));
            jr = 4.0 * ns - scale;
            kp = phi * 4.0 * scale / Math.PI;
        }

        double kpFace = (double)Jpll[face] * scale;
        if (kp - kpFace > 4.0 * scale)
            kp -= 8.0 * scale;
        else if (kp - kpFace < -4.0 * scale)
            kp += 8.0 * scale;

        double sumFxFy = (double)Jrll[face] * ns - jr;
        double diffFxFy = kp - kpFace;
        fx = (sumFxFy + diffFxFy) * 0.5;
        fy = (sumFxFy - diffFxFy) * 0.5;
    }

    /// <summary>HEALPix.xy2nest: interleave the bits of x (even) and y (odd).</summary>
    public static long Xy2Nest(long x, long y)
    {
        return Spread(x) | (Spread(y) << 1);
    }

    /// <summary>HEALPix.nest2xy.</summary>
    public static void Nest2Xy(long ipixInFace, out long x, out long y)
    {
        x = Compress(ipixInFace);
        y = Compress(ipixInFace >> 1);
    }

    private static long Spread(long v)
    {
        long result = 0;
        for (int bit = 0; bit < 32; bit++)
            result |= ((v >> bit) & 1L) << (2 * bit);
        return result;
    }

    private static long Compress(long v)
    {
        long result = 0;
        for (int bit = 0; bit < 32; bit++)
            result |= ((v >> (2 * bit)) & 1L) << bit;
        return result;
    }
}
