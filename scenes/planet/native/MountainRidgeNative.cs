using System;
using Godot;

/// <summary>
/// One ridge line (MountainRelief.Ridge) evaluated in C# — the arithmetic of
/// MountainRelief.ridge_height, in the same order. Configure once, then
/// Height() is read-only and called from every chunk worker.
/// </summary>
public partial class MountainRidgeNative : RefCounted
{
    private double[] _cx = Array.Empty<double>(), _cy = Array.Empty<double>(), _cum = Array.Empty<double>();
    private double _length;
    private double _bx0, _by0, _bx1, _by1;
    private double _height = 300.0, _width = 800.0, _sharpness = 0.5, _roughness = 0.3, _warp;
    private double _asymmetry, _terraceStep, _terraceWidth = 0.15;
    private long _seed;
    /// <summary>MountainRelief.Ridge.impurity — scales Core().</summary>
    private double _impurity = 1.0;

    public void Configure(Vector2[] centerline, double heightM, double widthM, double sharpness,
                          double roughness, double warpM, double asymmetry, double terraceStepM,
                          double terraceWidth, long seed, double mPerDeg, double impurity = 1.0)
    {
        _impurity = impurity;
        _height = heightM;
        _width = widthM;
        _sharpness = sharpness;
        _roughness = roughness;
        _warp = warpM;
        _asymmetry = asymmetry;
        _terraceStep = terraceStepM;
        _terraceWidth = terraceWidth;
        _seed = seed;
        int n = centerline == null ? 0 : centerline.Length;
        _cx = new double[n];
        _cy = new double[n];
        _cum = new double[n];
        double acc = 0.0;
        for (int i = 0; i < n; i++)
        {
            _cx[i] = centerline[i].X;
            _cy[i] = centerline[i].Y;
            if (i > 0)
            {
                // MountainRelief._seg_len_m
                double latScale = Math.Cos(MountainNoiseCore.DegToRad(
                    MountainNoiseCore.Clamp((_cy[i - 1] + _cy[i]) * 0.5, -89.5, 89.5)));
                double dx = (_cx[i] - _cx[i - 1]) * latScale;
                double dy = _cy[i] - _cy[i - 1];
                acc += Math.Sqrt(dx * dx + dy * dy) * mPerDeg;
            }
            _cum[i] = acc;
        }
        _length = acc;
        if (n >= 2)
        {
            double latC = Math.Cos(MountainNoiseCore.DegToRad(MountainNoiseCore.Clamp(_cy[0], -89.5, 89.5)));
            double pad = Reach() / mPerDeg / Math.Max(latC, 0.05);
            _bx0 = _by0 = double.PositiveInfinity;
            _bx1 = _by1 = double.NegativeInfinity;
            for (int i = 0; i < n; i++)
            {
                if (_cx[i] < _bx0) _bx0 = _cx[i];
                if (_cy[i] < _by0) _by0 = _cy[i];
                if (_cx[i] > _bx1) _bx1 = _cx[i];
                if (_cy[i] > _by1) _by1 = _cy[i];
            }
            _bx0 -= pad; _by0 -= pad; _bx1 += pad; _by1 += pad;
        }
    }

    public double Reach() => _width * (1.0 + Math.Abs(_asymmetry)) + _warp;
    public double WidthM() => _width;
    public double LengthM() => _length;

    /// <summary>Height (m) the ridge adds at dir; 0 past its reach or when the
    /// pitch is at least its width.</summary>
    public double Height(Vector3 dir, double radius, double effSpacing)
        => HeightD(dir.X, dir.Y, dir.Z, radius, effSpacing, double.NaN, double.NaN);

    internal double HeightD(double dx, double dy, double dz, double radius, double effSpacing,
                            double lon, double lat)
    {
        if (effSpacing >= _width) return 0.0;
        if (!ProfileD(dx, dy, dz, radius, lon, lat, out double prof, out double taper, out _))
            return 0.0;
        double h = _height * prof * taper;
        if (_roughness > 0.0)
        {
            double f = radius / (2.0 * _width);
            h *= 1.0 + _roughness * MountainNoiseCore.Snoise(dx * f, dy * f, dz * f, _seed + 11);
        }
        return MountainNoiseCore.Terrace(h, _terraceStep, _terraceWidth);
    }

    /// <summary>The ridge's term of MountainRelief.core: flank profile × end
    /// taper × impurity — no pitch gate, no roughness, no terrace.</summary>
    public double Core(Vector3 dir, double radius)
        => CoreD(dir.X, dir.Y, dir.Z, radius, double.NaN, double.NaN);

    internal double CoreD(double dx, double dy, double dz, double radius, double lon, double lat)
    {
        if (_impurity <= 0.0) return 0.0;
        if (!ProfileD(dx, dy, dz, radius, lon, lat, out double prof, out double taper, out _))
            return 0.0;
        return prof * taper * _impurity;
    }

    /// <summary>MountainRelief.mask term: a fadeM ramp from the foot of the flank × end taper.</summary>
    internal double MaskD(double dx, double dy, double dz, double radius, double lon, double lat, double fadeM)
    {
        if (!ProfileD(dx, dy, dz, radius, lon, lat, out double prof, out double taper, out double footM))
            return 0.0;
        if (prof <= 0.0) return 0.0;
        return MountainNoiseCore.Smoothstep(0.0, fadeM, footM) * taper;
    }

    /// <summary>MountainRelief._ridge_profile: the flank profile and the end
    /// taper at dir, false past the reach. lon/lat NaN → computed here.</summary>
    private bool ProfileD(double dx, double dy, double dz, double radius, double lon, double lat,
                          out double prof, out double taper, out double footM)
    {
        prof = 0.0;
        taper = 0.0;
        footM = 0.0;
        int n = _cx.Length;
        if (n < 2) return false;
        if (double.IsNaN(lon))
            MountainNoiseCore.ToLonLat(dx, dy, dz, out lon, out lat);
        if (lon < _bx0 || lat < _by0 || lon >= _bx1 || lat >= _by1) return false;
        double mPerDeg = radius * Math.PI / 180.0;
        double latScale = Math.Cos(MountainNoiseCore.DegToRad(MountainNoiseCore.Clamp(lat, -89.5, 89.5)));
        if (latScale < 1e-6) latScale = 1e-6;
        double bestSq = double.PositiveInfinity;
        int bestI = 0;
        for (int i = 0; i < n - 1; i++)
        {
            double dsq = MountainNoiseCore.DistSqToSegment(lon, lat, _cx[i], _cy[i], _cx[i + 1], _cy[i + 1], latScale);
            if (dsq < bestSq) { bestSq = dsq; bestI = i; }
        }
        double dM = Math.Sqrt(bestSq) * mPerDeg;
        if (dM >= Reach()) return false;
        double ax = _cx[bestI], ay = _cy[bestI], bx = _cx[bestI + 1], by = _cy[bestI + 1];
        double ex = (bx - ax) * latScale, ey = by - ay;
        double px = (lon - ax) * latScale, py = lat - ay;
        double cross = ex * py - ey * px;
        double wSide = cross > 0.0 ? _width * (1.0 + _asymmetry) : _width * (1.0 - _asymmetry);
        if (_warp > 0.0)
        {
            double f = radius / (4.0 * _width);
            dM = Math.Max(dM + _warp * MountainNoiseCore.Snoise(dx * f, dy * f, dz * f, _seed + 7), 0.0);
        }
        double t = dM / wSide;
        if (t >= 1.0) return false;
        footM = wSide - dM;
        double bell = 1.0 - MountainNoiseCore.Smoothstep(0.0, 1.0, t);
        double knife = 1.0 - t;
        prof = MountainNoiseCore.Lerp(bell, knife, _sharpness);
        double segSq = ex * ex + ey * ey;
        double ts = 0.0;
        if (segSq > 1e-24)
            ts = MountainNoiseCore.Clamp((px * ex + py * ey) / segSq, 0.0, 1.0);
        double s = _cum[bestI] + ts * (_cum[bestI + 1] - _cum[bestI]);
        double endD = Math.Min(s, _length - s);
        taper = MountainNoiseCore.Smoothstep(0.0, Math.Min(_width, _length * 0.5), endD);
        return true;
    }
}
