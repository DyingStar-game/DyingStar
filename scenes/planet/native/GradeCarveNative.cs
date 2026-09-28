using System;
using System.Collections.Generic;
using Godot;

/// <summary>
/// The line part of GradeBed.apply in C#: the nearest point on a chunk's
/// profiled pieces (GradeGeom.nearest_on_pieces) and the cutting rule of the
/// line found there (GradeBed.carved_height / shaved_height, through
/// GradeProfile.segment_at / z_track_at / hw_at), in the SAME order of
/// operations on IEEE doubles, so a carved height is bit-identical to the
/// GDScript one (test/unit/test_grade_carve_native.gd).
///
/// Why: a refined cell re-samples and re-carves 64 sub-vertices, and the carve
/// was 32 µs of GDScript each — the bulk of a chunk under a lava flow or a
/// cutting (0.5–1.2 s). Built once per chunk context (GradeBed._gather_ctx),
/// read-only afterwards.
/// </summary>
public partial class GradeCarveNative : RefCounted
{
    // GradeSettings constants.
    private const double TunnelMinCover = 10.0;
    private const double GorgeBandMargin = 2.0;
    private const int KindGround = 0;
    private const int KindGorge = 1;

    private sealed class Piece
    {
        public double[] X = Array.Empty<double>(), Y = Array.Empty<double>(), Cum = Array.Empty<double>();
        public long Fid;
    }

    private sealed class Prof
    {
        public double[] Ka = Array.Empty<double>(), Kz = Array.Empty<double>(), SegLo = Array.Empty<double>();
        public int[] SegKind = Array.Empty<int>();
        public double[] SegDepth = Array.Empty<double>();
        public double HwM, Hw0, Hw1, Along0, Along1, WallSlope, FloorK, Sink, Overlap;
        public bool VaryingHw;
    }

    private readonly List<Piece> _pieces = new();
    private readonly Dictionary<long, Prof> _profiles = new();

    public void AddPiece(Vector2[] centerline, double[] cum, long fid)
    {
        int n = centerline == null ? 0 : centerline.Length;
        var p = new Piece { X = new double[n], Y = new double[n], Cum = cum ?? Array.Empty<double>(), Fid = fid };
        for (int i = 0; i < n; i++) { p.X[i] = centerline[i].X; p.Y[i] = centerline[i].Y; }
        _pieces.Add(p);
    }

    public void AddProfile(long fid, double[] knotsAlong, double[] knotsZ, double[] segLo, int[] segKind,
                           double[] segDepth, double hwM, bool varyingHw, double hw0, double hw1,
                           double along0, double along1, double wallSlope, double floorK, double sink,
                           double overlap)
    {
        _profiles[fid] = new Prof
        {
            Ka = knotsAlong, Kz = knotsZ, SegLo = segLo, SegKind = segKind, SegDepth = segDepth,
            HwM = hwM, VaryingHw = varyingHw, Hw0 = hw0, Hw1 = hw1, Along0 = along0, Along1 = along1,
            WallSlope = wallSlope, FloorK = floorK, Sink = sink, Overlap = overlap,
        };
    }

    public int PieceCount() => _pieces.Count;

    /// <summary>GradeBed.apply's line part. mode 0 = carve (param = floor margin),
    /// 1 = coarse shave (param = band). Returns h when nothing applies.</summary>
    public double Apply(double h, Vector2 lonlat, double mPerDeg, int mode, double param)
    {
        if (!Nearest(lonlat.X, lonlat.Y, mPerDeg, out double along, out double latM, out long fid))
            return h;
        if (!_profiles.TryGetValue(fid, out Prof prof))
            return h;
        return mode == 1 ? Shaved(h, prof, along, latM, param) : Carved(h, prof, along, latM, param);
    }

    // GradeGeom.nearest_on_pieces
    private bool Nearest(double lon, double lat, double mPerDeg, out double bestAlong, out double bestLat,
                         out long bestFid)
    {
        double bestSq = double.PositiveInfinity;
        bestAlong = 0.0; bestLat = 0.0; bestFid = -1;
        bool hit = false;
        double ls = Math.Max(Math.Cos(MountainNoiseCore.DegToRad(MountainNoiseCore.Clamp(lat, -89.5, 89.5))), 1e-6);
        double px = lon * ls;
        double py = lat;
        for (int pi = 0; pi < _pieces.Count; pi++)
        {
            Piece r = _pieces[pi];
            int n = r.X.Length;
            if (n < 2 || r.Cum.Length != n) continue;
            for (int i = 0; i < n - 1; i++)
            {
                double ax = r.X[i] * ls;
                double dx = r.X[i + 1] * ls - ax;
                double dy = r.Y[i + 1] - r.Y[i];
                double segSq = dx * dx + dy * dy;
                double t = 0.0;
                if (segSq > 1e-24)
                    t = MountainNoiseCore.Clamp(((px - ax) * dx + (py - r.Y[i]) * dy) / segSq, 0.0, 1.0);
                double cx = px - (ax + t * dx);
                double cy = py - (r.Y[i] + t * dy);
                double dSq = cx * cx + cy * cy;
                if (dSq < bestSq)
                {
                    bestSq = dSq;
                    bestAlong = r.Cum[i] + t * (r.Cum[i + 1] - r.Cum[i]);
                    if (segSq > 1e-24)
                        bestLat = (dx * cy - dy * cx) / Math.Sqrt(segSq) * mPerDeg;
                    else
                        bestLat = Math.Sqrt(dSq) * mPerDeg;
                    bestFid = r.Fid;
                    hit = true;
                }
            }
        }
        return hit;
    }

    // GradeProfile.segment_at → index
    private static int SegmentAt(Prof p, double along)
    {
        int n = p.SegLo.Length;
        if (n == 0) return -1;
        int lo = 0, hi = n;
        while (lo + 1 < hi)
        {
            int mid = (lo + hi) / 2;
            if (p.SegLo[mid] <= along) lo = mid; else hi = mid;
        }
        return lo;
    }

    // GradeProfile.z_track_at
    private static double ZTrackAt(Prof p, double along)
    {
        double[] ka = p.Ka, kz = p.Kz;
        int n = ka.Length;
        if (n == 0) return 0.0;
        if (along <= ka[0]) return kz[0];
        if (along >= ka[n - 1]) return kz[n - 1];
        int lo = 0, hi = n - 1;
        while (lo + 1 < hi)
        {
            int mid = (lo + hi) / 2;
            if (ka[mid] <= along) lo = mid; else hi = mid;
        }
        double seg = ka[hi] - ka[lo];
        if (seg <= 1e-9) return kz[lo];
        return MountainNoiseCore.Lerp(kz[lo], kz[hi], (along - ka[lo]) / seg);
    }

    // GradeProfile.hw_at
    private static double HwAt(Prof p, double along)
    {
        if (!p.VaryingHw) return p.HwM;
        double t = 0.0;
        if (p.Along1 - p.Along0 > 1e-9)
            t = MountainNoiseCore.Clamp((along - p.Along0) / (p.Along1 - p.Along0), 0.0, 1.0);
        return MountainNoiseCore.Lerp(p.Hw0, p.Hw1, t);
    }

    // GradeBed.shaved_height
    private static double Shaved(double h, Prof p, double along, double latM, double band)
    {
        int s = SegmentAt(p, along);
        if (s < 0) return h;
        int kind = p.SegKind[s];
        if (kind != KindGround && kind != KindGorge) return h;
        if (Math.Abs(latM) > HwAt(p, along) + p.Overlap + band) return h;
        return Math.Min(h, ZTrackAt(p, along));
    }

    // GradeBed.carved_height
    private static double Carved(double h, Prof p, double along, double latM, double floorMargin)
    {
        int s = SegmentAt(p, along);
        if (s < 0) return h;
        int kind = p.SegKind[s];
        if (kind != KindGround && kind != KindGorge) return h;
        double wallSlope = p.WallSlope;
        double hwFloor = HwAt(p, along) + floorMargin * p.FloorK;
        double sink = p.Sink;
        double depth = Math.Max(TunnelMinCover, p.SegDepth[s]) + sink;
        double band = hwFloor + depth / wallSlope + GorgeBandMargin;
        double d = Math.Abs(latM);
        if (d > band) return h;
        double zt = ZTrackAt(p, along) - sink;
        double wall = zt + Math.Max(0.0, d - hwFloor) * wallSlope;
        return Math.Min(h, wall);
    }
}
