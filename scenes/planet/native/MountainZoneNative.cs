using System;
using Godot;

/// <summary>
/// One mountain_range zone (MountainRelief.Zone) evaluated in C#: the noise
/// shape of MountainNoise.shape plus the feathered polygon envelope of
/// MountainRelief.envelope, in the same arithmetic. Configure once (main or
/// decode thread), then Offset() is read-only and called from every chunk worker.
/// </summary>
public partial class MountainZoneNative : RefCounted
{
    private double _wavelength = 6000.0, _persistence = 0.45, _ridge, _exponent = 1.0, _warp;
    private int _octaves = 6;
    private long _seed;
    private double _norm = 1.0;
    private double _lift, _amplitude = 300.0, _terraceStep, _terraceWidth = 0.15, _feather = 250.0;
    private bool _full = true;
    private double[] _px = Array.Empty<double>(), _py = Array.Empty<double>();
    private double _bx0, _by0, _bx1, _by1;
    /// <summary>MountainRelief.Zone.impurity — scales Core().</summary>
    private double _impurity = 1.0;
    /// <summary>MountainRelief.CORE_PITCH_DIV.</summary>
    private const double CorePitchDiv = 8.0;

    public void Configure(double wavelength, int octaves, double persistence, double ridge,
                          double exponent, double warp, long seed, double liftM, double amplitudeM,
                          double terraceStepM, double terraceWidth, double featherM,
                          Vector2[] polygon, double impurity = 1.0)
    {
        _impurity = impurity;
        _wavelength = wavelength;
        _octaves = Math.Clamp(octaves, 1, MountainNoiseCore.MaxOctaves);
        _persistence = persistence;
        _ridge = ridge;
        _exponent = exponent;
        _warp = warp;
        _seed = seed;
        double a = 1.0, s = 0.0;
        for (int k = 0; k < _octaves; k++) { s += a; a *= _persistence; }
        _norm = s > 0.0 ? s : 1.0;
        _lift = liftM;
        _amplitude = amplitudeM;
        _terraceStep = terraceStepM;
        _terraceWidth = terraceWidth;
        _feather = featherM;
        _full = polygon == null || polygon.Length < 3;
        if (!_full)
        {
            int n = polygon.Length;
            _px = new double[n];
            _py = new double[n];
            _bx0 = _by0 = double.PositiveInfinity;
            _bx1 = _by1 = double.NegativeInfinity;
            for (int i = 0; i < n; i++)
            {
                _px[i] = polygon[i].X;
                _py[i] = polygon[i].Y;
                if (_px[i] < _bx0) _bx0 = _px[i];
                if (_py[i] < _by0) _by0 = _py[i];
                if (_px[i] > _bx1) _bx1 = _px[i];
                if (_py[i] > _by1) _by1 = _py[i];
            }
        }
    }

    /// <summary>MountainNoise.shape: normalised height in [0, 1], -1 when the
    /// pitch cannot carry the first octave.</summary>
    public double Shape(Vector3 dir, double radius, double effSpacing)
        => ShapeD(dir.X, dir.Y, dir.Z, radius, effSpacing);

    internal double ShapeD(double dx, double dy, double dz, double radius, double effSpacing)
    {
        double wl = _wavelength;
        if (effSpacing >= wl * 0.5)
            return -1.0;
        double s = radius / wl;
        double px = dx * s, py = dy * s, pz = dz * s;
        if (_warp > 0.0)
        {
            double w = _warp;
            double nx = px + w * MountainNoiseCore.Snoise(px, py, pz, _seed + 101);
            double ny = py + w * MountainNoiseCore.Snoise(px, py, pz, _seed + 202);
            double nz = pz + w * MountainNoiseCore.Snoise(px, py, pz, _seed + 303);
            px = nx; py = ny; pz = nz;
        }
        double sum = 0.0, amp = 1.0, freq = 1.0;
        long seed = _seed;
        double ridge = _ridge;
        for (int k = 0; k < _octaves; k++)
        {
            if (k > 0 && effSpacing >= (wl / freq) * 0.5)
                break;
            double n = MountainNoiseCore.Vnoise(px * freq, py * freq, pz * freq, seed + k);
            double v = n * 2.0 - 1.0;
            if (ridge > 0.0)
            {
                double r = 1.0 - Math.Abs(v);
                r = r * r * 2.0 - 1.0;
                v = MountainNoiseCore.Lerp(v, r, ridge);
            }
            sum += v * amp;
            amp *= _persistence;
            freq *= MountainNoiseCore.Lacunarity;
        }
        double h = MountainNoiseCore.Clamp(0.5 + 0.5 * sum / _norm, 0.0, 1.0);
        return MountainNoiseCore.PowFast(h, _exponent);
    }

    /// <summary>MountainRelief.envelope at (lon, lat) degrees.</summary>
    public double Envelope(double lon, double lat, double mPerDeg)
    {
        if (_full) return 1.0;
        // Rect2.has_point: lower bound inclusive, upper exclusive.
        if (lon < _bx0 || lat < _by0 || lon >= _bx1 || lat >= _by1) return 0.0;
        if (!PointInPolygon(lon, lat)) return 0.0;
        double latScale = Math.Cos(MountainNoiseCore.DegToRad(MountainNoiseCore.Clamp(lat, -89.5, 89.5)));
        if (latScale < 1e-6) latScale = 1e-6;
        double featherDeg = _feather / mPerDeg;
        double bestSq = double.PositiveInfinity;
        int n = _px.Length;
        int j = n - 1;
        for (int i = 0; i < n; i++)
        {
            double d = MountainNoiseCore.DistSqToSegment(lon, lat, _px[j], _py[j], _px[i], _py[i], latScale);
            if (d < bestSq) bestSq = d;
            j = i;
        }
        if (bestSq >= featherDeg * featherDeg) return 1.0;
        return MountainNoiseCore.Smoothstep(0.0, _feather, Math.Sqrt(bestSq) * mPerDeg);
    }

    private bool PointInPolygon(double x, double y)
    {
        int n = _px.Length;
        bool inside = false;
        int j = n - 1;
        for (int i = 0; i < n; i++)
        {
            double vix = _px[i], viy = _py[i], vjx = _px[j], vjy = _py[j];
            if (((viy > y) != (vjy > y)) && (x < (vjx - vix) * (y - viy) / (vjy - viy) + vix))
                inside = !inside;
            j = i;
        }
        return inside;
    }

    /// <summary>The zone's contribution (m) at dir — envelope × (lift + terraced
    /// amplitude·shape). lon/lat are computed here only for a partial zone.</summary>
    public double Offset(Vector3 dir, double radius, double effSpacing)
        => OffsetD(dir.X, dir.Y, dir.Z, radius, effSpacing, double.NaN, double.NaN);

    internal double OffsetD(double dx, double dy, double dz, double radius, double effSpacing,
                            double lon, double lat)
    {
        double env = 1.0;
        if (!_full)
        {
            if (double.IsNaN(lon))
                MountainNoiseCore.ToLonLat(dx, dy, dz, out lon, out lat);
            env = Envelope(lon, lat, radius * Math.PI / 180.0);
            if (env <= 0.0) return 0.0;
        }
        double h = _lift;
        double s = ShapeD(dx, dy, dz, radius, effSpacing);
        if (s >= 0.0)
            h += MountainNoiseCore.Terrace(_amplitude * s, _terraceStep, _terraceWidth);
        return env * h;
    }

    /// <summary>The zone's term of MountainRelief.core: envelope × the two
    /// coarsest octaves of the shape × impurity (0 for a sterile zone).</summary>
    public double Core(Vector3 dir, double radius)
        => CoreD(dir.X, dir.Y, dir.Z, radius, double.NaN, double.NaN);

    internal double CoreD(double dx, double dy, double dz, double radius, double lon, double lat)
    {
        if (_impurity <= 0.0) return 0.0;
        double env = 1.0;
        if (!_full)
        {
            if (double.IsNaN(lon))
                MountainNoiseCore.ToLonLat(dx, dy, dz, out lon, out lat);
            env = Envelope(lon, lat, radius * Math.PI / 180.0);
            if (env <= 0.0) return 0.0;
        }
        double s = ShapeD(dx, dy, dz, radius, _wavelength / CorePitchDiv);
        if (s <= 0.0) return 0.0;
        return env * s * _impurity;
    }

    public bool IsFull() => _full;
}
