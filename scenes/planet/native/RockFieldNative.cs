using System;
using Godot;

/// <summary>
/// One rocky_terrain field (RockFieldRelief.Field) evaluated in C#: the Voronoi
/// blocks terraced over the ground, the joints, the buttes, and the feathered
/// polygon envelope of MountainRelief.envelope — the same arithmetic in the
/// same order as scenes/planet/rock_field_relief.gd, pinned bit-exact by
/// test_rock_field_relief.gd. Configure once (main or decode thread), then
/// Offset() is read-only and called from every chunk worker.
/// </summary>
public partial class RockFieldNative : RefCounted
{
    private const double GateDiv = 3.0;
    private const long SeedJx = 1, SeedJy = 2, SeedJz = 3, SeedPhase = 31;
    private const long SeedBjx = 41, SeedBjy = 42, SeedBjz = 43;
    private const long SeedBpick = 59, SeedBradius = 61, SeedBheight = 63;
    private const long SeedWx = 71, SeedWy = 72, SeedWz = 73;
    private const long SeedLump = 81, SeedLump2 = 82;
    /// <summary>RockFieldRelief.WARP_AMP / WARP_WAVELENGTH.</summary>
    private const double WarpAmp = 0.25, WarpWavelength = 2.0;

    private bool _full = true;
    private double[] _px = Array.Empty<double>(), _py = Array.Empty<double>();
    private double _bx0, _by0, _bx1, _by1;
    private double _feather = 250.0;
    private double _cell = 120.0, _step, _riser = 0.25, _jointDepth, _jointWidth = 30.0, _jointMean;
    private double _butteRate, _butteHeight, _butteCell = 600.0, _butteWall = 40.0, _butteMean;
    private long _seed;
    private double _cx, _cy = 1.0, _cz, _wx = 1.0, _wy, _wz, _k, _dpx, _dpy, _dpz;
    private double _intensity, _detail = 6.0;
    /// <summary>Soft knobs (chalk): height and wavelength (m); 0 = none.</summary>
    private double _lump, _lumpWl = 160.0;

    public void Configure(Vector2[] polygon, double featherM, double cellM, double stepM,
                          double riser, double jointDepthM, double jointWidthM, double jointMeanM,
                          double butteRate, double butteHeightM, double butteCellM,
                          double butteWallM, double butteMeanM, long seed, Vector3 c, Vector3 w,
                          double k, Vector3 dp, double intensity, double detailM,
                          double lumpM = 0.0, double lumpWavelengthM = 160.0)
    {
        _lump = lumpM;
        _lumpWl = lumpWavelengthM;
        _feather = featherM;
        _cell = cellM;
        _step = stepM;
        _riser = riser;
        _jointDepth = jointDepthM;
        _jointWidth = jointWidthM;
        _jointMean = jointMeanM;
        _butteRate = butteRate;
        _butteHeight = butteHeightM;
        _butteCell = butteCellM;
        _butteWall = butteWallM;
        _butteMean = butteMeanM;
        _seed = seed;
        _cx = c.X; _cy = c.Y; _cz = c.Z;
        _wx = w.X; _wy = w.Y; _wz = w.Z;
        _k = k;
        _dpx = dp.X; _dpy = dp.Y; _dpz = dp.Z;
        _intensity = intensity;
        _detail = detailM;
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

    public bool IsFull() => _full;
    /// <summary>RockFieldRelief.shader_code (level + 8 × type) — set by Configure's caller.</summary>
    public int Level { get; set; }

    /// <summary>The field's contribution (m) at dir over a ground at hBelow —
    /// envelope × FieldOffset. Tests call it directly.</summary>
    public double Offset(Vector3 dir, double radius, double effSpacing, double hBelow)
        => OffsetD(dir.X, dir.Y, dir.Z, radius, effSpacing, hBelow, double.NaN, double.NaN);

    internal double OffsetD(double dx, double dy, double dz, double radius, double effSpacing,
                            double hBelow, double lon, double lat)
    {
        double env = 1.0;
        if (!_full)
        {
            if (double.IsNaN(lon))
                MountainNoiseCore.ToLonLat(dx, dy, dz, out lon, out lat);
            env = Envelope(lon, lat, radius * Math.PI / 180.0);
            if (env <= 0.0) return 0.0;
        }
        return env * FieldOffsetD(dx, dy, dz, radius, effSpacing, hBelow);
    }

    /// <summary>RockFieldRelief.surface for this field alone: (intensity × envelope,
    /// small-block size, 0).</summary>
    public Vector3 Surface(Vector3 dir, double radius)
    {
        double env = 1.0;
        if (!_full)
        {
            MountainNoiseCore.ToLonLat(dir.X, dir.Y, dir.Z, out double lon, out double lat);
            env = Envelope(lon, lat, radius * Math.PI / 180.0);
        }
        return new Vector3(env * _intensity, _detail, 0.0);
    }

    /// <summary>RockFieldRelief.field_offset — the offset without the envelope.</summary>
    public double FieldOffset(Vector3 dir, double radius, double effSpacing, double hBelow)
        => FieldOffsetD(dir.X, dir.Y, dir.Z, radius, effSpacing, hBelow);

    internal double FieldOffsetD(double dx, double dy, double dz, double radius, double effSpacing,
                                 double hBelow)
    {
        double cellM = _cell;
        double bcell = _butteCell;
        bool blocksOn = effSpacing < cellM / GateDiv;
        bool buttesOn = _butteRate > 0.0 && _butteHeight > 0.0 && effSpacing < bcell / GateDiv;
        double lumpWl = _lumpWl;
        bool lumpsOn = _lump > 0.0 && effSpacing < lumpWl * 0.5;
        if (!blocksOn && !buttesOn && !lumpsOn)
            return 0.0;
        double px = dx * radius, py = dy * radius, pz = dz * radius;
        double wx = _wx, wy = _wy, wz = _wz;
        double kd = _k * (px * wx + py * wy + pz * wz);
        double qx = px - wx * kd, qy = py - wy * kd, qz = pz - wz * kd;
        {
            // RockFieldRelief.warp: the block edges meander.
            double lam = cellM * WarpWavelength;
            double amp = cellM * WarpAmp;
            double sx = qx / lam, sy = qy / lam, sz = qz / lam;
            double nx = qx + amp * MountainNoiseCore.Snoise(sx, sy, sz, _seed + SeedWx);
            double ny = qy + amp * MountainNoiseCore.Snoise(sx, sy, sz, _seed + SeedWy);
            double nz = qz + amp * MountainNoiseCore.Snoise(sx, sy, sz, _seed + SeedWz);
            qx = nx; qy = ny; qz = nz;
        }
        double bump = 0.0;
        double outV = 0.0;
        if (buttesOn)
        {
            bump = Buttes(qx / bcell, qy / bcell, qz / bcell, effSpacing);
            outV = bump - _butteMean;
        }
        if (lumpsOn)
        {
            // Soft knobs (chalk): RockFieldRelief.field_offset's two octaves.
            double sx = qx / lumpWl, sy = qy / lumpWl, sz = qz / lumpWl;
            double nl = MountainNoiseCore.Snoise(sx, sy, sz, _seed + SeedLump);
            if (effSpacing < lumpWl * 0.25)
                nl = nl + 0.5 * MountainNoiseCore.Snoise(sx * 2.0, sy * 2.0, sz * 2.0, _seed + SeedLump2);
            outV = outV + _lump * nl;
        }
        if (!blocksOn)
            return outV;
        double step = _step;
        double jd = _jointDepth;
        if (step <= 0.0 && jd <= 0.0)
            return outV;
        long sd = _seed;
        Voronoi(qx / cellM, qy / cellM, qz / cellM, sd,
                out long c1x, out long c1y, out long c1z,
                out long c2x, out long c2y, out long c2z, out double edge);
        double eM = edge * cellM;
        double jw = _jointWidth;
        if (step > 0.0)
        {
            double s = ((dx - _cx) * _dpx + (dy - _cy) * _dpy + (dz - _cz) * _dpz) * radius;
            double x0 = hBelow + bump + s;
            double riser = _riser;
            double lift = step * (1.0 - riser) * 0.5;
            double x1 = x0 + (MountainNoiseCore.Cell(c1x, c1y, c1z, sd + SeedPhase) - 0.5) * step;
            double x2 = x0 + (MountainNoiseCore.Cell(c2x, c2y, c2z, sd + SeedPhase) - 0.5) * step;
            double g1 = MountainNoiseCore.Terrace(x1, step, riser) - x1 + lift;
            double g2 = MountainNoiseCore.Terrace(x2, step, riser) - x2 + lift;
            double bw = Math.Max(jw, effSpacing);
            double t = 0.5 * (1.0 - MountainNoiseCore.Smoothstep(0.0, bw, eM));
            outV = outV + (g1 + (g2 - g1) * t);
        }
        if (jd > 0.0 && effSpacing < jw)
            outV = outV - (jd * (1.0 - MountainNoiseCore.Smoothstep(0.0, jw, eM)) - _jointMean);
        return outV;
    }

    /// <summary>RockFieldRelief.voronoi: nearest feature cell, the cell across its
    /// nearest edge, the distance to that edge (cell units). The first pass's jitters
    /// are kept and reused by the second pass (the same values, so the same bits):
    /// the two 3×3×3 neighbourhoods overlap by 8 to 27 cells.</summary>
    internal static void Voronoi(double x, double y, double z, long sd,
                                 out long c1x, out long c1y, out long c1z,
                                 out long c2x, out long c2y, out long c2z, out double edge)
    {
        double fx0 = Math.Floor(x), fy0 = Math.Floor(y), fz0 = Math.Floor(z);
        long ix = (long)fx0, iy = (long)fy0, iz = (long)fz0;
        double fx = x - fx0, fy = y - fy0, fz = z - fz0;
        Span<double> jx = stackalloc double[27];
        Span<double> jy = stackalloc double[27];
        Span<double> jz = stackalloc double[27];
        double md = 1.0e9;
        double mrx = 0.0, mry = 0.0, mrz = 0.0;
        long mgx = 0, mgy = 0, mgz = 0;
        for (long k = -1; k <= 1; k++)
            for (long j = -1; j <= 1; j++)
                for (long i = -1; i <= 1; i++)
                {
                    int s = (int)((i + 1) + (j + 1) * 3 + (k + 1) * 9);
                    jx[s] = MountainNoiseCore.Cell(ix + i, iy + j, iz + k, sd + SeedJx);
                    jy[s] = MountainNoiseCore.Cell(ix + i, iy + j, iz + k, sd + SeedJy);
                    jz[s] = MountainNoiseCore.Cell(ix + i, iy + j, iz + k, sd + SeedJz);
                    double rx = (double)i + jx[s] - fx;
                    double ry = (double)j + jy[s] - fy;
                    double rz = (double)k + jz[s] - fz;
                    double d = rx * rx + ry * ry + rz * rz;
                    if (d < md)
                    {
                        md = d;
                        mrx = rx; mry = ry; mrz = rz;
                        mgx = i; mgy = j; mgz = k;
                    }
                }
        edge = 1.0e9;
        long nbx = mgx, nby = mgy, nbz = mgz;
        for (long k = -1; k <= 1; k++)
            for (long j = -1; j <= 1; j++)
                for (long i = -1; i <= 1; i++)
                {
                    long gx = mgx + i, gy = mgy + j, gz = mgz + k;
                    double cx, cy, cz;
                    if (gx >= -1 && gx <= 1 && gy >= -1 && gy <= 1 && gz >= -1 && gz <= 1)
                    {
                        int s = (int)((gx + 1) + (gy + 1) * 3 + (gz + 1) * 9);
                        cx = jx[s]; cy = jy[s]; cz = jz[s];
                    }
                    else
                    {
                        cx = MountainNoiseCore.Cell(ix + gx, iy + gy, iz + gz, sd + SeedJx);
                        cy = MountainNoiseCore.Cell(ix + gx, iy + gy, iz + gz, sd + SeedJy);
                        cz = MountainNoiseCore.Cell(ix + gx, iy + gy, iz + gz, sd + SeedJz);
                    }
                    double rx = (double)gx + cx - fx;
                    double ry = (double)gy + cy - fy;
                    double rz = (double)gz + cz - fz;
                    double ddx = rx - mrx, ddy = ry - mry, ddz = rz - mrz;
                    double dd = ddx * ddx + ddy * ddy + ddz * ddz;
                    if (dd > 1.0e-5)
                    {
                        double e = ((0.5 * (mrx + rx)) * ddx + (0.5 * (mry + ry)) * ddy
                                    + (0.5 * (mrz + rz)) * ddz) / Math.Sqrt(dd);
                        if (e < edge)
                        {
                            edge = e;
                            nbx = gx; nby = gy; nbz = gz;
                        }
                    }
                }
        c1x = ix + mgx; c1y = iy + mgy; c1z = iz + mgz;
        c2x = ix + nbx; c2y = iy + nby; c2z = iz + nbz;
    }

    /// <summary>RockFieldRelief.buttes: height (m) of the tallest butte reaching
    /// (x, y, z) — butte-cell units.</summary>
    private double Buttes(double x, double y, double z, double effSpacing)
    {
        double fx0 = Math.Floor(x), fy0 = Math.Floor(y), fz0 = Math.Floor(z);
        long ix = (long)fx0, iy = (long)fy0, iz = (long)fz0;
        double fx = x - fx0, fy = y - fy0, fz = z - fz0;
        long sd = _seed;
        double bc = _butteCell;
        double wall = Math.Max(_butteWall, effSpacing);
        double best = 0.0;
        for (long k = -1; k <= 1; k++)
            for (long j = -1; j <= 1; j++)
                for (long i = -1; i <= 1; i++)
                {
                    long cx = ix + i, cy = iy + j, cz = iz + k;
                    if (MountainNoiseCore.Cell(cx, cy, cz, sd + SeedBpick) >= _butteRate)
                        continue;
                    double rx = (double)i + MountainNoiseCore.Cell(cx, cy, cz, sd + SeedBjx) - fx;
                    double ry = (double)j + MountainNoiseCore.Cell(cx, cy, cz, sd + SeedBjy) - fy;
                    double rz = (double)k + MountainNoiseCore.Cell(cx, cy, cz, sd + SeedBjz) - fz;
                    double dM = Math.Sqrt(rx * rx + ry * ry + rz * rz) * bc;
                    double r0 = bc * (0.12 + 0.13 * MountainNoiseCore.Cell(cx, cy, cz, sd + SeedBradius));
                    if (dM >= r0 + wall)
                        continue;
                    double hgt = _butteHeight * (0.6 + 0.4 * MountainNoiseCore.Cell(cx, cy, cz, sd + SeedBheight));
                    double b = hgt * (1.0 - MountainNoiseCore.Smoothstep(r0, r0 + wall, dM));
                    if (b > best)
                        best = b;
                }
        return best;
    }

    /// <summary>MountainRelief.envelope with the field's own feather.</summary>
    private double Envelope(double lon, double lat, double mPerDeg)
    {
        if (_full) return 1.0;
        // Rect2.has_point: lower bound inclusive, upper exclusive.
        if (lon < _bx0 || lat < _by0 || lon >= _bx1 || lat >= _by1) return 0.0;
        if (!PointInPolygon(lon, lat)) return 0.0;
        double latScale = Math.Cos(MountainNoiseCore.DegToRad(MountainNoiseCore.Clamp(lat, -89.5, 89.5)));
        if (latScale < 1e-6) latScale = 1e-6;
        double feather = _feather;
        double featherDeg = feather / mPerDeg;
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
        return MountainNoiseCore.Smoothstep(0.0, feather, Math.Sqrt(bestSq) * mPerDeg);
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
}
