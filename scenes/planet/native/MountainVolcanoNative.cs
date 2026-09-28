using System;
using Godot;

/// <summary>
/// One volcano (VolcanoRelief.Volcano) evaluated in C# — the arithmetic of
/// VolcanoRelief.offset / core / mask in the same order, on IEEE doubles, so
/// a value computed here equals the GDScript one bit for bit
/// (test/unit/test_volcano_relief.gd). Configure once, then read-only from
/// every chunk worker. The centre arrives already computed (the record's
/// cx/cy/cz): nothing here calls a trigonometric function.
/// </summary>
public partial class MountainVolcanoNative : RefCounted
{
    // VolcanoRelief constants.
    private const double GullyFreq = 14.0;
    private const double GullyDepth = 0.35;
    private const double LobeFreq = 3.0;
    private const double CraterCoreBonus = 0.4;

    private double _cx, _cy = 1.0, _cz;
    private double _rb = 6000.0, _h = 2500.0, _rc = 300.0, _dc = 200.0, _floor = 0.3, _e = 2.0;
    private double _rough, _gullies, _irr, _impurity = 1.0;
    private long _seed;
    /// <summary>Rim tilt toward the flow leaving the lake (VolcanoRelief.Volcano.tilt / f).</summary>
    private double _tilt, _fx, _fy, _fz;
    /// <summary>The flank detail fBm — a full-coverage zone of lift 0, amplitude 1:
    /// only its Shape is read.</summary>
    private readonly MountainZoneNative _detail = new();

    public void Configure(Vector3 centre, double rb, double h, double rc, double dc, double floorFrac,
                          double e, double roughness, double gullies, double irregularity, long seed,
                          double impurity, double detailWavelength, int detailOctaves,
                          double detailPersistence, double detailRidge, long detailSeed,
                          Vector3 flowDir, double tilt)
    {
        _fx = flowDir.X; _fy = flowDir.Y; _fz = flowDir.Z; _tilt = tilt;
        _cx = centre.X; _cy = centre.Y; _cz = centre.Z;
        _rb = rb; _h = h; _rc = rc; _dc = dc; _floor = floorFrac; _e = e;
        _rough = roughness; _gullies = gullies; _irr = irregularity;
        _seed = seed; _impurity = impurity;
        _detail.Configure(detailWavelength, detailOctaves, detailPersistence, detailRidge, 1.0, 0.0,
                          detailSeed, 0.0, 1.0, 0.0, 0.15, 250.0, null, 0.0);
    }

    public double Offset(Vector3 dir, double radius, double effSpacing)
        => OffsetD(dir.X, dir.Y, dir.Z, radius, effSpacing);

    public double Core(Vector3 dir, double radius) => CoreD(dir.X, dir.Y, dir.Z, radius);

    public double Mask(Vector3 dir, double radius, double fadeM) => MaskD(dir.X, dir.Y, dir.Z, radius, fadeM);

    internal double OffsetD(double x, double y, double z, double radius, double effSpacing)
    {
        if (effSpacing >= 0.5 * _rb) return 0.0;
        double dx = x - _cx, dy = y - _cy, dz = z - _cz;
        double dl = Math.Sqrt(dx * dx + dy * dy + dz * dz);
        double r = dl * radius;
        if (r >= _rb * (1.0 + _irr)) return 0.0;
        double ux = 0.0, uy = 0.0, uz = 0.0;
        if (dl > 1e-12) { ux = dx / dl; uy = dy / dl; uz = dz / dl; }
        double ht = _h, drop = _dc;
        if (_tilt > 0.0)
        {
            double q = (1.0 + (ux * _fx + uy * _fy + uz * _fz)) * 0.5;
            ht = _h - _tilt * (q * q);
            drop = ht - (_h - _dc);
        }
        if (r < _rc)
        {
            if (effSpacing >= _rc) return ht;
            return ht - drop * (1.0 - MountainNoiseCore.Smoothstep(_rc * _floor, _rc, r));
        }
        double rbEff = _rb;
        if (_irr > 0.0)
            rbEff = _rb * (1.0 + _irr * MountainNoiseCore.Snoise(ux * LobeFreq, uy * LobeFreq, uz * LobeFreq, _seed + 5));
        rbEff = Math.Max(rbEff, _rc + 1.0);
        double s = (r - _rc) / (rbEff - _rc);
        if (s >= 1.0) return 0.0;
        double hh = ht * MountainNoiseCore.PowFast(1.0 - s, _e);
        double mid = 4.0 * s * (1.0 - s);
        if (_gullies > 0.0 && r > 0.0)
        {
            double gw = 1.0 - MountainNoiseCore.Smoothstep(0.25, 0.5, effSpacing * GullyFreq / r);
            if (gw > 0.0)
            {
                double g = 1.0 - Math.Abs(MountainNoiseCore.Snoise(ux * GullyFreq, uy * GullyFreq, uz * GullyFreq, _seed + 17));
                g = g * g * g * g;
                hh = hh * (1.0 - _gullies * GullyDepth * g * mid * gw);
            }
        }
        if (_rough > 0.0)
        {
            double sh = _detail.ShapeD(x, y, z, radius, effSpacing);
            if (sh >= 0.0)
                hh = hh + _h * _rough * (2.0 * sh - 1.0) * mid;
        }
        return hh;
    }

    internal double CoreD(double x, double y, double z, double radius)
    {
        if (_impurity <= 0.0) return 0.0;
        double dx = x - _cx, dy = y - _cy, dz = z - _cz;
        double dl = Math.Sqrt(dx * dx + dy * dy + dz * dz);
        double r = dl * radius;
        if (r >= _rb * (1.0 + _irr)) return 0.0;
        if (r < _rc) return _impurity * (1.0 + CraterCoreBonus);
        double rbEff = RbEff(dx, dy, dz, dl);
        double s = (r - _rc) / (rbEff - _rc);
        if (s >= 1.0) return 0.0;
        return _impurity * (1.0 - s);
    }

    internal double MaskD(double x, double y, double z, double radius, double fadeM)
    {
        double dx = x - _cx, dy = y - _cy, dz = z - _cz;
        double dl = Math.Sqrt(dx * dx + dy * dy + dz * dz);
        double r = dl * radius;
        if (r >= _rb * (1.0 + _irr)) return 0.0;
        double rbEff = RbEff(dx, dy, dz, dl);
        return MountainNoiseCore.Smoothstep(0.0, fadeM, rbEff - r);
    }

    private double RbEff(double dx, double dy, double dz, double dl)
    {
        double rbEff = _rb;
        if (_irr > 0.0)
        {
            double ux = 0.0, uy = 0.0, uz = 0.0;
            if (dl > 1e-12) { ux = dx / dl; uy = dy / dl; uz = dz / dl; }
            rbEff = _rb * (1.0 + _irr * MountainNoiseCore.Snoise(ux * LobeFreq, uy * LobeFreq, uz * LobeFreq, _seed + 5));
        }
        return Math.Max(rbEff, _rc + 1.0);
    }
}
