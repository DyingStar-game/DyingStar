using System;
using System.Collections.Generic;
using Godot;

/// <summary>
/// RockImpurity.tint over a whole chunk in one call: the impurity pass of PlanetChunk.generate_mesh, 33-41 ms
/// a chunk in GDScript and about 2 ms here (tarsis_3, 33² vertices). The catalogue is copied in once on the
/// main thread (RockImpurity.warm), then read by every chunk worker: no state changes after AddRock.
///
/// scenes/planet/rock_impurity.gd stays the reference and the fallback, and holds the rules' reasons; its
/// tuning constants are repeated below, and test_rock_impurity_native.gd holds the two equal bit for bit.
/// </summary>
public partial class RockImpurityNative : RefCounted
{
    /// <summary>Which rule of RockImpurity.element_field an element follows.</summary>
    private const int KindFluidMobile = 1;
    private const int KindSourceBound = 2;

    private const double CarveRefM = 150.0;
    private const double ValenceDepth = 1.0;
    private const double VeinHaloM = 40.0;
    private const double VeinGain = 0.35;
    private const double SrcBase = 0.55, SrcCore = 0.7, SrcCarve = 0.5;
    private const double FeBase = 0.75, FeCore = 0.25, FeCarve = 0.3;
    private const double PureBase = 0.5;
    private const double StrataThicknessM = 70.0, StrataBlend = 0.2, StrataAmp = 0.3;
    private const double StrataDipMinDeg = 4.0, StrataDipMaxDeg = 22.0, StrataCellM = 150000.0;
    private const long StrataSeed = 7919;
    private const double DustMax = 0.45, DustSlopeLo = 0.04, DustSlopeHi = 0.25;
    private const double DustCoreLo = 0.05, DustCoreHi = 0.4, DustMix = 0.6;
    private static readonly Color DustTone = new Color(0.86f, 0.82f, 0.74f);

    private sealed class Rock
    {
        public bool HasColors, HasDeep, Pair;
        public Color Light, Dark, DeepLight, DeepDark;
        public int[] Kinds = Array.Empty<int>();
        public double[] Weights = Array.Empty<double>();
    }

    private readonly List<Rock> _rocks = new();

    /// <summary>
    /// A catalogue rock: colors = RockCatalogue.colors_of (light, dark; empty = none), deep =
    /// core_colors_of, kinds and weights = its rule's elements (Kind* bits) and weights, pair = its rule's
    /// charge-transfer pair. Returns the rock's id for TintChunk.
    /// </summary>
    public int AddRock(Color[] colors, Color[] deep, int[] kinds, double[] weights, bool pair)
    {
        var rock = new Rock { Kinds = kinds ?? Array.Empty<int>(), Weights = weights ?? Array.Empty<double>(), Pair = pair };
        rock.HasColors = colors != null && colors.Length >= 2;
        if (rock.HasColors)
        {
            rock.Light = colors[0];
            rock.Dark = colors[1];
        }
        rock.HasDeep = deep != null && deep.Length >= 2;
        if (rock.HasDeep)
        {
            rock.DeepLight = deep[0];
            rock.DeepDark = deep[1];
        }
        _rocks.Add(rock);
        return _rocks.Count - 1;
    }

    /// <summary>
    /// The colours of a chunk's vertices. slots[i] = 0: not a rock vertex, colors[i] as it is; else
    /// rocks[slots[i] - 1] is the id (AddRock) of its rock, and the other arrays are what the vertex
    /// loop measured, as PlanetChunk passes them to RockImpurity.tint.
    /// </summary>
    public Color[] TintChunk(int[] rocks, byte[] slots, Vector3[] dirs, Vector3[] normals, double radius, float[] heights,
        float[] core, float[] carve, Color[] colors, float[] wall, double blotchM, double streakM)
    {
        var chunkRocks = new Rock[rocks.Length];
        for (int i = 0; i < rocks.Length; i++)
            chunkRocks[i] = _rocks[rocks[i]];
        var result = new Color[colors.Length];
        for (int i = 0; i < colors.Length; i++)
        {
            if (slots[i] == 0 || !chunkRocks[slots[i] - 1].HasColors)
            {
                result[i] = colors[i];
                continue;
            }
            result[i] = Tint(chunkRocks[slots[i] - 1], dirs[i], radius, heights[i], core[i], carve[i],
                1.0 - normals[i].Dot(dirs[i]), wall[i], blotchM, streakM);
        }
        return result;
    }

    /// <summary>RockImpurity.tint, for a rock with colours.</summary>
    private static Color Tint(Rock rock, Vector3 dir, double radius, double heightM, double core, double carveM, double slope,
        double wallM, double blotchM, double streakM)
    {
        Color light = rock.Light;
        Color dark = rock.Dark;
        double carveN = MountainNoiseCore.Clamp(carveM / CarveRefM, 0.0, 1.0);
        if (rock.HasDeep)
        {
            double v = MountainNoiseCore.Clamp((Math.Max(core, 0.0) + carveN) / ValenceDepth, 0.0, 1.0);
            if (v > 0.0)
            {
                light = Lerp(light, rock.DeepLight, v);
                dark = Lerp(dark, rock.DeepDark, v);
            }
        }
        Color col = Lerp(light, dark, Concentration(rock, dir, radius, heightM, core, carveN, wallM, blotchM, streakM));
        double flat = 1.0 - MountainNoiseCore.Smoothstep(DustSlopeLo, DustSlopeHi, slope);
        double dust = DustMax * flat * MountainNoiseCore.Smoothstep(DustCoreLo, DustCoreHi, core);
        if (dust > 0.0)
            col = Lerp(col, Lerp(light, DustTone, DustMix), dust);
        return col;
    }

    /// <summary>RockImpurity.concentration.</summary>
    private static double Concentration(Rock rock, Vector3 dir, double radius, double heightM, double core, double carveN,
        double wallM, double blotchM, double streakM)
    {
        double mottle = SurfaceNoiseCore.Mottle(dir.X, dir.Y, dir.Z, radius, blotchM, streakM);
        double veinN = double.IsInfinity(wallM)
            ? 0.0 : 1.0 - MountainNoiseCore.Smoothstep(0.0, VeinHaloM, Math.Max(wallM, 0.0));
        double c;
        if (rock.Kinds.Length == 0)
        {
            c = PureBase * mottle;
        }
        else if (rock.Pair)
        {
            c = Math.Sqrt(ElementField(KindFluidMobile, mottle, core, carveN, veinN)
                * ElementField(KindSourceBound, mottle, core, carveN, veinN));
        }
        else
        {
            double num = 0.0, den = 0.0;
            for (int i = 0; i < rock.Kinds.Length; i++)
            {
                num += rock.Weights[i] * ElementField(rock.Kinds[i], mottle, core, carveN, veinN);
                den += rock.Weights[i];
            }
            c = num / den;
        }
        return MountainNoiseCore.Clamp(c * Strata(dir, radius, heightM), 0.0, 1.0);
    }

    /// <summary>RockImpurity.element_field; the pair above is Fe (mobile) and Ti (source-bound).</summary>
    private static double ElementField(int kind, double mottle, double core, double carveN, double veinN)
    {
        double c = MountainNoiseCore.Clamp(core, 0.0, 1.5);
        double v = (kind & KindFluidMobile) != 0 ? VeinGain * veinN : 0.0;
        if ((kind & KindSourceBound) != 0)
            return MountainNoiseCore.Clamp(SrcBase * mottle + SrcCore * c + SrcCarve * carveN + v, 0.0, 1.0);
        return MountainNoiseCore.Clamp(FeBase * mottle + FeCore * c + FeCarve * carveN + v, 0.0, 1.0);
    }

    /// <summary>RockImpurity.strata.</summary>
    private static double Strata(Vector3 dir, double radius, double heightM)
    {
        Vector3 cell = (dir * (radius / StrataCellM)).Floor();
        long cx = (long)cell.X, cy = (long)cell.Y, cz = (long)cell.Z;
        double az = MountainNoiseCore.Cell(cx, cy, cz, StrataSeed) * Math.Tau;
        double dip = MountainNoiseCore.DegToRad(MountainNoiseCore.Lerp(StrataDipMinDeg, StrataDipMaxDeg,
            MountainNoiseCore.Cell(cx, cy, cz, StrataSeed + 1)));
        Vector3 up = (cell + new Vector3(0.5, 0.5, 0.5)).Normalized();
        Vector3 tang = up.Cross(Vector3.Up);
        if (tang.LengthSquared() < 1e-6)
            tang = up.Cross(Vector3.Right);
        tang = tang.Normalized();
        Vector3 bitan = up.Cross(tang);
        Vector3 n = (up * Math.Cos(dip) + (tang * Math.Cos(az) + bitan * Math.Sin(az)) * Math.Sin(dip)).Normalized();
        double b = dir.Dot(n) * (radius + heightM) / StrataThicknessM;
        double k = Math.Floor(b);
        double f = b - k;
        long ki = (long)k;
        double v0 = MountainNoiseCore.Cell(ki, cx * 31 + cy, cz, StrataSeed + 2);
        double v1 = MountainNoiseCore.Cell(ki + 1, cx * 31 + cy, cz, StrataSeed + 2);
        double t = MountainNoiseCore.Smoothstep(1.0 - StrataBlend, 1.0, f);
        return MountainNoiseCore.Lerp(1.0 - StrataAmp, 1.0 + StrataAmp, MountainNoiseCore.Lerp(v0, v1, t));
    }

    /// <summary>Color.lerp as the engine does it: in floats, the weight rounded first.</summary>
    private static Color Lerp(Color a, Color b, double weight)
    {
        float w = (float)weight;
        return new Color(a.R + (b.R - a.R) * w, a.G + (b.G - a.G) * w, a.B + (b.B - a.B) * w, a.A + (b.A - a.A) * w);
    }
}
