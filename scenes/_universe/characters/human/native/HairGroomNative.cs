using System;
using System.Collections.Generic;
using Godot;

/// <summary>
/// The heavy loop of growing a head of hair (HairGroom._strands): roots drawn on the scalp, guide strands
/// grown and curled, kept out of the head, a tail or a bun, shuffled. ~50x faster than GDScript.
///
/// scenes/_universe/characters/human/hair_groom.gd is the reference and the fallback, and holds the rules'
/// reasons; test_hair_groom.gd holds the two equal. To match it, scalars and vectors are doubles (GDScript's float;
/// the engine is built with double-precision vectors), operated on in the same order; the random numbers are the same
/// integer stream, handed over in and out (state).
/// </summary>
public partial class HairGroomNative : RefCounted
{
    private int[] _scalpVertex = Array.Empty<int>();
    private Vector3[] _scalpPosition = Array.Empty<Vector3>();
    private Vector3[] _scalpNormal = Array.Empty<Vector3>();
    private int[] _triangles = Array.Empty<int>();
    private Vector3 _centre;
    private Vector3 _crown;
    private float[] _sdf = Array.Empty<float>();
    private Vector3 _sdfOrigin;
    private double _sdfCell;
    private int _sx, _sy, _sz;
    private long _state;

    // Style fields, in HairGroom.NATIVE_STYLE order.
    private const int Top = 0, Side = 1, StrandSeg = 2, Lift = 3, Gravity = 4, Comb = 5, CombReach = 6, Stiff = 7,
        Volume = 8, Frizz = 9, Curl = 10, Pitch = 11, Front = 12, Fringe = 13, Tail = 14, Bun = 15, Guides = 16,
        Clump = 17, ClumpTip = 18, KindFrizz = 19, Quiff = 20, Flyaways = 21, LooseLen = 22;
    // HairGroom.FLYAWAY_SHARE, FLYAWAY_EDGE, FLYAWAY_LIFT, FLYAWAY_GRAVITY, FLYAWAY_COMB, FLYAWAY_STIFF, FLYAWAY_FRIZZ, FLYAWAY_LENGTH.
    private const double FlyawayShare = 0.015, FlyawayEdge = 0.25, FlyawayLift = 0.2, FlyawayGravity = 0.9, FlyawayComb = 0.15,
        FlyawayStiff = 0.3, FlyawayFrizz = 0.35, FlyawayLengthMin = 0.25, FlyawayLengthMax = 0.8;
    // HairGroom.QUIFF_LIFT, QUIFF_STIFF, QUIFF_HOLD, QUIFF_COMB_DELAY, QUIFF_Z.
    private const double QuiffLift = 0.95, QuiffStiff = 0.95, QuiffHold = 1.0, QuiffCombDelay = 1.0;
    private const double QuiffFromZ = -0.01, QuiffToZ = 0.035;
    // Flow kinds, HairGroom.FLOWS order.
    private const int FlowCrown = 0, FlowCentre = 1, FlowLeft = 2, FlowRight = 3, FlowBack = 4, FlowTie = 5;
    private const int TieLoose = 0, TiePonytail = 1, TieTopBun = 3;
    private const int PartCrest = 5;
    private static readonly Vector3 TiePonytailAt = new Vector3(0.0, 0.035, -0.105);
    private static readonly Vector3 TieBunAt = new Vector3(0.0, 0.075, -0.085);
    private static readonly Vector3 TieTopBunAt = new Vector3(0.0, 0.112, -0.005);
    // HairGroom.TOP_BUN_RING, TOP_BUN_COIL, TOP_BUN_FLAT, TOP_BUN_HAIRS.
    private const double TopBunRing = 0.42, TopBunCoil = 0.58, TopBunFlat = 1.0;
    private const int TopBunHairs = 800;

    /// <summary>HairGroom._tie_point.</summary>
    private static Vector3 TiePoint(int tie) => tie == TiePonytail ? TiePonytailAt : (tie == TieTopBun ? TieTopBunAt : TieBunAt);

    /// <summary>HairGroom._loose_style: a flyaway's knobs.</summary>
    private static double[] LooseStyle(double[] style)
    {
        var s = (double[])style.Clone();
        s[Lift] = FlyawayLift;
        s[Gravity] = FlyawayGravity;
        s[Comb] = FlyawayComb;
        s[Stiff] = FlyawayStiff;
        s[Frizz] = style[Frizz] + FlyawayFrizz;
        s[Quiff] = 0.0;
        return s;
    }
    private const double ShellOnlyBelow = 0.012;
    private const double FaceHalfWidth = 0.072;
    private const double FaceTopFromCentre = 0.0306;
    private const double FringeTopFromCentre = 0.0166;

    /// <summary>The neutral head (HairHead's fields).</summary>
    public void Configure(int[] scalpVertex, Vector3[] scalpPosition, Vector3[] scalpNormal, int[] triangles,
        Vector3 centre, Vector3 crown, float[] sdf, Vector3 sdfOrigin, double sdfCell, Vector3I sdfSize)
    {
        _scalpVertex = scalpVertex;
        _scalpPosition = scalpPosition;
        _scalpNormal = scalpNormal;
        _triangles = triangles;
        _centre = centre;
        _crown = crown;
        _sdf = sdf;
        _sdfOrigin = sdfOrigin;
        _sdfCell = sdfCell;
        _sx = sdfSize.X;
        _sy = sdfSize.Y;
        _sz = sdfSize.Z;
    }

    public bool IsConfigured() => _scalpVertex.Length > 0;

    // --- random numbers (HairGroom._uniform...) ----------------------------------------------------------

    private double Uniform()
    {
        _state = (_state * 1664525L + 1013904223L) & 0xFFFFFFFFL;
        return _state / 4294967296.0;
    }

    private double Range(double a, double b) => a + (b - a) * Uniform();

    private double Normal() => (Uniform() + Uniform() + Uniform() + Uniform() - 2.0) * 1.7320508;

    private Vector3 Normal3()
    {
        double x = Normal();
        double y = Normal();
        double z = Normal();
        return new Vector3(x, y, z);
    }

    // --- GDScript's helpers on doubles -------------------------------------------------------------------

    private static double Smoothstep(double from, double to, double s)
    {
        if (Mathf.IsEqualApprox(from, to))
            return from;
        double t = Math.Clamp((s - from) / (to - from), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    private static double Lerp(double a, double b, double t) => a + (b - a) * t;

    private static Vector3 Mul(Vector3 v, double s) => v * s;

    private static Vector3 Div(Vector3 v, double s) => v / s;

    // --- the head --------------------------------------------------------------------------------------

    /// <summary>HairHead.surface: signed distance (m) and outward normal.</summary>
    private (double d, Vector3 n) Surface(Vector3 p)
    {
        Vector3 g = Div(p - _sdfOrigin, _sdfCell);
        int x0 = (int)Math.Floor((double)g.X);
        int y0 = (int)Math.Floor((double)g.Y);
        int z0 = (int)Math.Floor((double)g.Z);
        if (x0 < 0 || y0 < 0 || z0 < 0 || x0 >= _sx - 1 || y0 >= _sy - 1 || z0 >= _sz - 1)
            return (1.0, (p - _centre).Normalized());
        double fx = (double)g.X - x0;
        double fy = (double)g.Y - y0;
        double fz = (double)g.Z - z0;
        int sy = _sx;
        int sz = _sx * _sy;
        int i = x0 + y0 * sy + z0 * sz;
        double c000 = _sdf[i], c100 = _sdf[i + 1], c010 = _sdf[i + sy], c110 = _sdf[i + 1 + sy];
        double c001 = _sdf[i + sz], c101 = _sdf[i + 1 + sz], c011 = _sdf[i + sy + sz], c111 = _sdf[i + 1 + sy + sz];
        double c00 = Lerp(c000, c100, fx), c10 = Lerp(c010, c110, fx), c01 = Lerp(c001, c101, fx), c11 = Lerp(c011, c111, fx);
        double c0 = Lerp(c00, c10, fy), c1 = Lerp(c01, c11, fy);
        double d = Lerp(c0, c1, fz);
        double dx = Lerp(Lerp(c100 - c000, c110 - c010, fy), Lerp(c101 - c001, c111 - c011, fy), fz);
        double dy = Lerp(c10 - c00, c11 - c01, fz);
        double dz = c1 - c0;
        var grad = new Vector3(dx, dy, dz);
        return (d, grad.LengthSquared() > 1e-12 ? grad.Normalized() : (p - _centre).Normalized());
    }

    private Vector3 ClearOfHead(Vector3 p, double clear)
    {
        var (d, n) = Surface(p);
        return d < clear ? p + Mul(n, clear - d) : p;
    }

    private Vector3 Flow(int kind, Vector3 p, double[] style, int tie)
    {
        Vector3 rel = p - _centre;
        Vector3 f;
        switch (kind)
        {
            case FlowBack:
                f = new Vector3(0.0, -0.25, -1.0);
                break;
            case FlowTie:
                f = _centre + TiePoint(tie) - p;
                break;
            case FlowCentre:
            case FlowLeft:
            case FlowRight:
            {
                double partX = kind == FlowCentre ? 0.0 : (kind == FlowLeft ? 0.028 : -0.028);
                double side = rel.X >= partX ? 1.0 : -1.0;
                f = new Vector3((side * 0.95), -0.7, -0.2);
                if (style[Fringe] > 0.0)
                {
                    double front = Smoothstep(0.03, 0.07, rel.Z) * (Math.Abs((double)rel.X) < 0.06 ? 1.0 : 0.0);
                    f = Mul(f, 1.0 - front) + Mul(new Vector3(0.0, -0.8, 0.75), front);
                }
                break;
            }
            default:
            {
                Vector3 away = (p - _crown).Normalized();
                f = away + Mul(Vector3.Up.Cross(away), 0.3);
                break;
            }
        }
        if (style[Fringe] <= 0.0 && kind != FlowBack && kind != FlowTie)
        {
            double front = Smoothstep(0.02, 0.06, rel.Z) * (Math.Abs((double)rel.X) < 0.07 ? 1.0 : 0.0);
            f = Mul(f, 1.0 - front) + Mul(new Vector3((rel.X >= 0.0 ? 1.0 : -1.0) * 0.6, 0.25, -0.8), front);
        }
        return f.Normalized();
    }

    // --- growing ---------------------------------------------------------------------------------------

    /// <summary>
    /// HairGroom._strands, from the random state after the shell. Returns [points (Vector3[]), colours (Color[]),
    /// refs (int[]), weights (float[]), offsets (Vector3[]), state (long)], the guides already shuffled; empty
    /// arrays when no hair grows.
    /// </summary>
    public Godot.Collections.Array Strands(long state, float[] density, double[] style, int flow, int part, int tie)
    {
        _state = state;
        int triCount = _triangles.Length / 3;
        var cumulative = new double[triCount];
        double total = 0.0;
        for (int t = 0; t < triCount; t++)
        {
            Vector3 a = _scalpPosition[_triangles[t * 3]];
            Vector3 b = _scalpPosition[_triangles[t * 3 + 1]];
            Vector3 c = _scalpPosition[_triangles[t * 3 + 2]];
            double dens = ((double)density[_triangles[t * 3]] + density[_triangles[t * 3 + 1]] + density[_triangles[t * 3 + 2]]) / 3.0;
            total += (double)(b - a).Cross(c - a).Length() * dens;
            cumulative[t] = total;
        }
        if (total <= 0.0)
            return new Godot.Collections.Array { Array.Empty<Vector3>(), Array.Empty<Color>(), Array.Empty<int>(), Array.Empty<float>(), Array.Empty<Vector3>(), _state };
        int count = (int)style[Guides];
        int n = (int)style[StrandSeg] + 1;
        double top = style[Top];
        double sideLen = style[Side];
        double fringe = style[Fringe];
        var points = new List<Vector3>(count * n);
        var colours = new List<Color>(count);
        var refs = new List<int>(count * 3);
        var weights = new List<float>(count * 3);
        double faceTop = (double)_centre.Y + (fringe > 0.0 ? FringeTopFromCentre : FaceTopFromCentre);
        for (int s = 0; s < count; s++)
        {
            int t = Math.Min(LowerBound(cumulative, Uniform() * total), triCount - 1);
            double r1 = Math.Sqrt(Uniform());
            double r2 = Uniform();
            var bary = new Vector3(1.0 - r1, r1 * (1.0 - r2), r1 * r2);
            int i0 = _triangles[t * 3], i1 = _triangles[t * 3 + 1], i2 = _triangles[t * 3 + 2];
            Vector3 root = _scalpPosition[i0] * bary.X + _scalpPosition[i1] * bary.Y + _scalpPosition[i2] * bary.Z;
            Vector3 normal = (_scalpNormal[i0] * bary.X + _scalpNormal[i1] * bary.Y + _scalpNormal[i2] * bary.Z).Normalized();
            double rootDensity = (double)density[i0] * bary.X + (double)density[i1] * bary.Y + (double)density[i2] * bary.Z;
            Vector3 rel = root - _centre;
            double height = Math.Clamp((double)rel.Normalized().Y, 0.0, 1.0);
            double onTop = Smoothstep(0.25, 0.85, height);
            if (part == PartCrest)
                onTop = Smoothstep(0.66, 0.74, height) * Smoothstep(0.04, 0.03, Math.Abs((double)rel.X));
            double length = (sideLen + (top - sideLen) * onTop) * Range(0.8, 1.1);
            length *= 1.0 + (style[Front] - 1.0) * Smoothstep(0.035, 0.07, rel.Z) * (Math.Abs((double)rel.X) < 0.07 ? 1.0 : 0.0);
            if (fringe > 0.0 && rel.Z > 0.045 && Math.Abs((double)rel.X) < 0.06)
                length = fringe * Range(0.85, 1.1);
            double layer = Uniform();
            if (length < ShellOnlyBelow)
                continue;
            double reach = style[CombReach];
            if (fringe <= 0.0 && rel.Z > 0.03 && Math.Abs((double)rel.X) < 0.07)
                reach = 2.0;
            double[] growStyle = style;
            int growFlow = flow;
            bool loose = false;
            if (style[Flyaways] > 0.0 && Uniform() < style[Flyaways] * (FlyawayShare + FlyawayEdge * (1.0 - rootDensity)))
            {
                loose = true;
                length = style[LooseLen] * Range(FlyawayLengthMin, FlyawayLengthMax);
                growStyle = LooseStyle(style);
                growFlow = FlowCrown;
            }
            Vector3[] strand = GrowOne(root, normal, length, layer, growStyle, growFlow, tie, reach);
            if (style[Curl] > 0.0)
                strand = CurlStrand(strand, style, 0.0015 + style[Volume] * layer);
            double aside = (root.X >= 0.0 ? 1.0 : -1.0) * FaceHalfWidth * (1.0 + 0.12 * layer);
            bool ended = false;
            for (int k = 0; k < strand.Length; k++)
            {
                Vector3 q = strand[k];
                if (ended)
                    strand[k] = strand[k - 1];
                else if ((double)q.Z - (double)_centre.Z > 0.04 && q.Y < faceTop && Math.Abs((double)q.X - (double)_centre.X) < FaceHalfWidth)
                {
                    if (k > 0 && Math.Abs((double)strand[k - 1].X - (double)_centre.X) < FaceHalfWidth * 0.8)
                    {
                        ended = true;
                        strand[k] = strand[k - 1];
                    }
                    else
                        strand[k] = new Vector3(aside, q.Y, q.Z);
                }
            }
            points.AddRange(strand);
            double g = Uniform();
            colours.Add(new Color(loose || tie == TieLoose ? 1.0f : 0.0f, (float)g, (float)layer, (float)rootDensity));
            refs.Add(_scalpVertex[i0]);
            refs.Add(_scalpVertex[i1]);
            refs.Add(_scalpVertex[i2]);
            weights.Add((float)bary.X);
            weights.Add((float)bary.Y);
            weights.Add((float)bary.Z);
        }
        if (tie != TieLoose)
        {
            List<Vector3[]> extra = Gathered(style, n, tie);
            Vector3 tiePoint = _centre + TiePoint(tie);
            int[] near = NearestScalp(tiePoint);
            foreach (Vector3[] e in extra)
            {
                points.AddRange(e);
                double g = Uniform();
                double l = Uniform();
                colours.Add(new Color(tie == TiePonytail ? 1.0f : 0.0f, (float)g, (float)l, 1.0f));
                refs.AddRange(near);
                for (int j = 0; j < 3; j++)
                    weights.Add((float)(1.0 / 3.0));
            }
        }
        return Shuffled(points, colours, refs, weights, n);
    }

    private static int LowerBound(double[] a, double value)
    {
        int lo = 0, hi = a.Length;
        while (lo < hi)
        {
            int mid = (lo + hi) >> 1;
            if (a[mid] < value)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }

    private Vector3[] GrowOne(Vector3 root, Vector3 normal, double length, double layer, double[] style, int flow, int tie, double reach)
    {
        int n = (int)style[StrandSeg] + 1;
        int seg = n - 1;
        double step = length / seg;
        double clear = 0.0015 + style[Volume] * layer;
        Vector3 comb = Flow(flow, root, style, tie);
        comb -= Mul(normal, comb.Dot(normal));
        Vector3 rel = root - _centre;
        double quiff = style[Quiff] * Smoothstep(QuiffFromZ, QuiffToZ, rel.Z) * (Math.Abs((double)rel.X) < 0.07 ? 1.0 : 0.0);
        double lift = style[Lift] + (QuiffLift - style[Lift]) * quiff;
        double stiff = style[Stiff] + (QuiffStiff - style[Stiff]) * quiff;
        double gravity = style[Gravity] * (1.0 - QuiffHold * quiff);
        Vector3 direction = (Mul(normal, lift) + Mul(comb.Normalized(), 1.0 - lift)).Normalized();
        Vector3 point = root;
        var output = new Vector3[n];
        output[0] = root;
        for (int k = 0; k < seg; k++)
        {
            double t = (double)(k + 1) / seg;
            Vector3 want = Mul(direction, stiff) + Mul(Mul(Vector3.Down, gravity), 0.4 + 0.6 * t)
                + Mul(Mul(Mul(Flow(flow, point, style, tie), style[Comb]), Math.Max(0.0, 1.0 - t / reach)),
                    1.0 - QuiffCombDelay * quiff * (1.0 - t))
                + Mul(Normal3(), style[Frizz]);
            Vector3 previous = point;
            point += Mul(want.Normalized(), step);
            for (int pass = 0; pass < 2; pass++)
                point = ClearOfHead(point, clear * Math.Min(1.0, 0.5 + 0.5 * t * seg));
            direction = (point - previous).Normalized();
            output[k + 1] = point;
        }
        return output;
    }

    private Vector3[] CurlStrand(Vector3[] strand, double[] style, double clear)
    {
        int n = strand.Length;
        double phase = Range(0.0, Math.Tau);
        double turns = Math.Tau / style[Pitch] * Range(0.8, 1.25);
        double radiusScale = style[Curl] * Range(0.6, 1.3);
        var output = (Vector3[])strand.Clone();
        double arc = 0.0;
        for (int k = 1; k < n; k++)
        {
            arc += strand[k].DistanceTo(strand[k - 1]);
            Vector3 tangent = (strand[Math.Min(k + 1, n - 1)] - strand[k - 1]).Normalized();
            Vector3 e1 = tangent.Cross(new Vector3(0.001, 1.001, 0.001)).Normalized();
            Vector3 e2 = tangent.Cross(e1);
            double angle = arc * turns + phase;
            double radius = radiusScale * Smoothstep(0.0, 0.03, arc);
            output[k] = ClearOfHead(strand[k] + Mul(Mul(e1, Math.Cos(angle)), radius) + Mul(Mul(e2, Math.Sin(angle)), radius), clear * 0.5);
        }
        return output;
    }

    /// <summary>HairGroom._top_bun: hairs spiralling round a flattened ring on the tie, messy with the flyaways.</summary>
    private List<Vector3[]> TopBun(double[] style, int n, Vector3 tie, Vector3 outward)
    {
        double radius = style[Bun];
        double mess = style[Flyaways];
        Vector3 e1 = outward.Cross(new Vector3(0.0, 0.0, 1.0)).Normalized();
        Vector3 e2 = outward.Cross(e1);
        double ring = radius * TopBunRing;
        double coil = radius * TopBunCoil;
        Vector3 centre = tie + Mul(Mul(outward, coil), 0.9);
        var strands = new List<Vector3[]>();
        for (int s = 0; s < TopBunHairs; s++)
        {
            double u0 = Range(0.0, Math.Tau);
            double sweep = Range(1.5, 3.5);
            double v0 = Range(0.0, Math.Tau);
            double twist = Range(1.5, 3.0);
            double thick = Range(1.0 - 0.15 * mess, 1.0 + 0.2 * mess);
            double loop = Uniform() < 0.04 + 0.08 * mess ? Range(1.3, 1.6) : 1.0;
            double end = Uniform() < 0.03 + 0.1 * mess ? Range(0.3, 0.8) * radius : 0.0;
            var strand = new Vector3[n];
            for (int k = 0; k < n; k++)
            {
                double t = (double)k / (n - 1);
                double u = u0 + sweep * t;
                double v = v0 + twist * sweep * t;
                double r = coil * thick * (1.0 + (loop - 1.0) * Math.Sin(Math.PI * t));
                Vector3 around = Mul(e1, Math.Cos(u)) + Mul(e2, Math.Sin(u));
                Vector3 p = centre + Mul(around, ring + r * Math.Cos(v)) + Mul(outward, r * Math.Sin(v) * TopBunFlat);
                if (end > 0.0 && t > 0.7)
                    p += Mul((Mul(around, 0.7) + Mul(outward, 0.3)).Normalized(), end * ((t - 0.7) / 0.3));
                p += Mul(Normal3(), 0.0015 * mess);
                strand[k] = ClearOfHead(p, 0.003);
            }
            strands.Add(strand);
        }
        return strands;
    }

    private List<Vector3[]> Gathered(double[] style, int n, int tie)
    {
        bool ponytail = tie == TiePonytail;
        Vector3 tiePoint = _centre + TiePoint(tie);
        Vector3 outward = (tiePoint - _centre).Normalized();
        var strands = new List<Vector3[]>();
        if (ponytail)
        {
            for (int s = 0; s < 420; s++)
            {
                Vector3 point = ClearOfHead(tiePoint + Mul(Normal3(), 0.008), 0.004);
                Vector3 direction = (Mul(outward, 0.9) + new Vector3(0.0, 0.25, 0.0) + Mul(Normal3(), 0.12)).Normalized();
                double length = style[Tail] * Range(0.75, 1.05);
                var strand = new Vector3[n];
                strand[0] = point;
                for (int k = 0; k < n - 1; k++)
                {
                    double t = (double)(k + 1) / (n - 1);
                    Vector3 want = Mul(direction, 0.55) + Mul(Vector3.Down, 0.35 + 0.9 * t) + Mul(Normal3(), 0.05);
                    Vector3 previous = point;
                    point = ClearOfHead(point + Div(Mul(want.Normalized(), length), n - 1), 0.012);
                    direction = (point - previous).Normalized();
                    strand[k + 1] = point;
                }
                strands.Add(strand);
            }
            return strands;
        }
        if (tie == TieTopBun)
            return TopBun(style, n, tiePoint, outward);
        double radius = style[Bun];
        Vector3 centre = tiePoint + Mul(Mul(outward, radius), 0.6);
        for (int s = 0; s < 400; s++)
        {
            Vector3 axis = (outward + Mul(Normal3(), 0.35)).Normalized();
            Vector3 e1 = axis.Cross(Normal3()).Normalized();
            Vector3 e2 = axis.Cross(e1);
            double shift = Range(-0.75, 0.75) * radius;
            double ring = Math.Sqrt(Math.Max(radius * radius - shift * shift, 1e-8)) * Range(0.95, 1.08);
            double start = Range(0.0, Math.Tau);
            double sweep = Range(1.6, 3.2);
            var strand = new Vector3[n];
            for (int k = 0; k < n; k++)
            {
                double angle = start + sweep * k / (n - 1);
                strand[k] = ClearOfHead(centre + Mul(axis, shift) + Mul(Mul(e1, Math.Cos(angle)), ring) + Mul(Mul(e2, Math.Sin(angle)), ring), 0.003);
            }
            strands.Add(strand);
        }
        return strands;
    }

    private int[] NearestScalp(Vector3 p)
    {
        var best = new (double d, int v)[] { (double.PositiveInfinity, 0), (double.PositiveInfinity, 0), (double.PositiveInfinity, 0) };
        for (int v = 0; v < _scalpPosition.Length; v++)
        {
            double d = p.DistanceSquaredTo(_scalpPosition[v]);
            if (d < best[2].d)
            {
                best[2] = (d, v);
                Array.Sort(best, (x, y) => x.d.CompareTo(y.d));
            }
        }
        return new[] { _scalpVertex[best[0].v], _scalpVertex[best[1].v], _scalpVertex[best[2].v] };
    }

    private Vector3 ScalpPoint(int compact)
    {
        int at = Array.BinarySearch(_scalpVertex, compact);
        return at >= 0 ? _scalpPosition[at] : Vector3.Zero;
    }

    /// <summary>HairGroom._strand_asset's shuffle and root offsets.</summary>
    private Godot.Collections.Array Shuffled(List<Vector3> points, List<Color> colours, List<int> refs, List<float> weights, int n)
    {
        int count = colours.Count;
        var order = new int[count];
        for (int k = 0; k < count; k++)
            order[k] = k;
        for (int k = count - 1; k > 0; k--)
        {
            int j = (int)(Uniform() * (k + 1));
            (order[k], order[j]) = (order[j], order[k]);
        }
        var outPoints = new Vector3[count * n];
        var outColours = new Color[count];
        var outRefs = new int[count * 3];
        var outWeights = new float[count * 3];
        var outOffsets = new Vector3[count];
        for (int s = 0; s < count; s++)
        {
            int k = order[s];
            points.CopyTo(k * n, outPoints, s * n, n);
            outColours[s] = colours[k];
            Vector3 bound = Vector3.Zero;
            for (int j = 0; j < 3; j++)
            {
                outRefs[s * 3 + j] = refs[k * 3 + j];
                outWeights[s * 3 + j] = weights[k * 3 + j];
                bound += Mul(ScalpPoint(refs[k * 3 + j]), weights[k * 3 + j]);
            }
            outOffsets[s] = points[k * n] - bound;
        }
        return new Godot.Collections.Array { outPoints, outColours, outRefs, outWeights, outOffsets, _state };
    }

    // --- the hairs around the guides (HairStrands.build) -------------------------------------------------

    /// <summary>
    /// HairStrands.build's loops: [positions (Vector3[]), normals (Vector3[]), tangents (float[]), UVs (Vector2[]),
    /// colours (Color[]), indices (int[])] of a style's hairs, made with the engine's own random generator
    /// seeded as the GDScript seeds it, in the same order.
    /// </summary>
    public Godot.Collections.Array Hairs(Vector3[] points, Color[] guideColours, int size, int children, double clump,
        double clumpTip, double frizz, double longest, Vector3 centre, long seed)
    {
        var rng = new Pcg((ulong)seed);
        int guides = points.Length / Math.Max(size, 1);
        int hairs = guides * children;
        int vertexCount = hairs * size * 2;
        var pos = new Vector3[vertexCount];
        var nrm = new Vector3[vertexCount];
        var tan = new float[vertexCount * 4];
        var uv = new Vector2[vertexCount];
        var col = new Color[vertexCount];
        var index = new int[hairs * (size - 1) * 6];
        var hairPoints = new Vector3[size];
        int v = 0, t = 0;
        double last = size - 1;
        for (int child = 0; child < children; child++)
        {
            for (int k = 0; k < guides; k++)
            {
                int first = k * size;
                Vector3 root = points[first];
                Vector3 along = (points[first + 1] - root).Normalized();
                Vector3 outward = (root - centre).Normalized();
                Vector3 lateral = outward.Cross(along);
                lateral = lateral.LengthSquared() > 1e-6 ? lateral.Normalized() : outward.Cross(Vector3.Up).Normalized();
                Vector3 forward = lateral.Cross(outward);
                double angle = rng.Randf() * Math.Tau;
                double reach = child > 0 ? clump * Math.Sqrt(rng.Randf()) : 0.0;
                Vector3 offset = Mul(Mul(lateral, Math.Cos(angle)) + Mul(forward, Math.Sin(angle)), reach);
                double lengthShare = child > 0 ? 0.78 + 0.26 * rng.Randf() : 1.0;
                double sx = rng.Randf() - 0.5;
                double sy = rng.Randf() - 0.5;
                Vector3 stray = Mul(Mul(Mul(lateral, sx) + Mul(outward, sy), 2.0), frizz);
                double phase = rng.Randf() * Math.Tau;
                double waves = 1.5 + 2.5 * rng.Randf();
                double guideLength = 0.0;
                for (int i = 0; i < size - 1; i++)
                    guideLength += points[first + i].DistanceTo(points[first + i + 1]);
                Color info = k < guideColours.Length ? guideColours[k] : new Color(1.0f, 0.5f, 0.5f, 1.0f);
                double ident = rng.Randf();
                for (int i = 0; i < size; i++)
                {
                    double share = i / last;
                    double at = share * lengthShare * last;
                    int lower = Math.Min((int)at, size - 2);
                    Vector3 p = points[first + lower].Lerp(points[first + lower + 1], at - lower);
                    hairPoints[i] = p + Mul(offset, Lerp(1.0, clumpTip, share)) + Mul(Mul(stray, share), Math.Sin(phase + share * waves));
                }
                for (int i = 0; i < size; i++)
                {
                    double share = i / last;
                    Vector3 p = hairPoints[i];
                    Vector3 direction = (hairPoints[Math.Min(i + 1, size - 1)] - hairPoints[Math.Max(i - 1, 0)]).Normalized();
                    Vector3 normal = (p - centre).Normalized();
                    var colour = new Color((float)(info.R * share * lengthShare * guideLength / longest), (float)ident, info.B, info.A);
                    for (int side = 0; side < 2; side++)
                    {
                        pos[v] = p;
                        nrm[v] = normal;
                        tan[v * 4] = (float)direction.X;
                        tan[v * 4 + 1] = (float)direction.Y;
                        tan[v * 4 + 2] = (float)direction.Z;
                        tan[v * 4 + 3] = 1.0f;
                        uv[v] = new Vector2(side, (float)share);
                        col[v] = colour;
                        v++;
                    }
                    if (i < size - 1)
                    {
                        int a = v - 2;
                        index[t] = a;
                        index[t + 1] = a + 2;
                        index[t + 2] = a + 1;
                        index[t + 3] = a + 1;
                        index[t + 4] = a + 2;
                        index[t + 5] = a + 3;
                        t += 6;
                    }
                }
            }
        }
        return new Godot.Collections.Array { pos, nrm, tan, uv, col, index };
    }

    /// <summary>Godot's RandomNumberGenerator (core/math/random_pcg.h): PCG32 on its default stream; randf
    /// takes the exponent from the leading zeros of one draw and the significand from the next. Made here
    /// rather than through the engine: these loops run on workers.</summary>
    private sealed class Pcg
    {
        private ulong _state;
        private readonly ulong _inc;

        public Pcg(ulong seed)
        {
            _state = 0;
            _inc = (1442695040888963407UL << 1) | 1UL;
            Next();
            _state += seed;
            Next();
        }

        public uint Next()
        {
            ulong old = _state;
            _state = old * 6364136223846793005UL + _inc;
            uint xorshifted = (uint)(((old >> 18) ^ old) >> 27);
            int rot = (int)(old >> 59);
            return (xorshifted >> rot) | (xorshifted << ((-rot) & 31));
        }

        public float Randf()
        {
            uint proto = Next();
            if (proto == 0)
                return 0.0f;
            return MathF.ScaleB((float)(Next() | 0x80000001u), -32 - System.Numerics.BitOperations.LeadingZeroCount(proto));
        }
    }
}
