using System;
using Godot;

/// <summary>
/// The vertex loop of PlanetChunk.generate_mesh over a whole chunk, in C#. GDScript decides once what depends
/// on its tables (per populate zone: SetVertZones) and the C# does every vertex those rules cover, bit for
/// bit as the GDScript loop would — which stays the reference and does the rest:
///   · a zone it was told to leave (a liquid, a cliff, a cave... : VertGdscript), and a vertex a pad can
///     reach (SetVertPads): state VertGdscript;
///   · a sample it cannot answer (see Sample): tiles are registered lazily, by GDScript, as a chunk first
///     touches them. VertsRun stops there and returns the vertex, the caller samples it through GDScript,
///     which registers what was missing, and calls again. The chunk reads only the tiles it touches.
/// One per chunk, used by one thread, like the rest of this class.
/// </summary>
public partial class TileFrameNative
{
    private const byte VertPending = 0;
    private const byte VertServed = 1;
    private const byte VertGdscript = 2;

    // Per populate zone in the order first_zone finds them, the last entry being "no zone".
    private int[] _vzFull = Array.Empty<int>();
    private int[] _vzStart = Array.Empty<int>();
    private double[] _vzVerts = Array.Empty<double>();
    private double[] _vzBox = Array.Empty<double>();
    private int[] _vzServe = Array.Empty<int>();
    private int[] _vzCrack = Array.Empty<int>();
    private int[] _vzSlot = Array.Empty<int>();
    private int[] _vzRelief = Array.Empty<int>();
    private int[] _vzOverride = Array.Empty<int>();
    private int[] _vzColorFromDir = Array.Empty<int>();
    private Color[] _vzColor = Array.Empty<Color>();
    private Vector2[] _vzDetail = Array.Empty<Vector2>();

    private double[] _vRoadPts = Array.Empty<double>();
    private int[] _vRoadStart = Array.Empty<int>();
    private double[] _vRoadHalf = Array.Empty<double>();
    private double _vRoadMPerDeg;

    private double[] _vStitchEdge = Array.Empty<double>();
    private double[] _vStitchWeight = Array.Empty<double>();
    private double[] _vStitchHeight = Array.Empty<double>();

    private GradeCarveNative _vGrade;
    private bool _vHasGrade;
    private int _vGradeMode;
    private double _vGradeParam;
    private double _vGradeMPerDeg;
    /// <summary>lon, lat, reach (m from the pad's centre) of each pad of the chunk.</summary>
    private double[] _vPads = Array.Empty<double>();

    // The pass itself (VertsBegin), and what it fills.
    private Vector3[] _vGrid;
    private int _vRes;
    private long _vIpix, _vNside;
    private double _vSpacing, _vMaxMove, _vFoot;
    private bool _vMasked;
    private Vector3 _vOrigin;
    private int _vCursor;
    private byte[] _vState;
    private Vector3[] _vVertices, _vDirs;
    private Vector2[] _vUvs, _vUv2s;
    private Color[] _vColors;
    private float[] _vHeights, _vEdge, _vCore, _vCarve, _vWall, _vRoadW;
    private byte[] _vCarved, _vSnapped, _vBand, _vSlot, _vColorDir;
    private int[] _vReliefOut, _vOverrideOut;
    private double[] _vGradeH;

    /// <summary>
    /// The zones: full[i] = 1 holds everywhere, else the outline starts[i] .. starts[i + 1] (lon/lat pairs) of
    /// verts. The other arrays have one entry more, for "no zone": serve = 0 leaves its vertices to GDScript,
    /// crack = PlanetData.cracks_apply_to_zone, slot = 1 + index of its rock (0 none), relief = k of its visible
    /// relief biome (0 none, see SetNormalRelief's tables), over = surface override k, then the fallback colour
    /// and UV2 (detail layer, scale) of the vertex loop. colorFromDir = 1: no zone or rock gives the colour,
    /// PlanetData.sample_biome_at does, per direction: GDScript's to set after the pass (VertsResult).
    /// </summary>
    public void SetVertZones(int[] full, int[] starts, double[] verts, int[] serve, int[] crack, int[] slot, int[] relief,
        int[] over, Color[] color, Vector2[] detail, int[] colorFromDir)
    {
        _vzFull = full ?? Array.Empty<int>();
        _vzStart = starts ?? Array.Empty<int>();
        _vzVerts = verts ?? Array.Empty<double>();
        _vzServe = serve;
        _vzCrack = crack;
        _vzSlot = slot;
        _vzRelief = relief;
        _vzOverride = over;
        _vzColor = color;
        _vzDetail = detail;
        _vzColorFromDir = colorFromDir;
        _vzBox = new double[_vzFull.Length * 4];
        for (int i = 0; i < _vzFull.Length; i++)
        {
            double minLon = double.PositiveInfinity, minLat = double.PositiveInfinity;
            double maxLon = double.NegativeInfinity, maxLat = double.NegativeInfinity;
            for (int k = _vzStart[i]; k < _vzStart[i + 1]; k++)
            {
                minLon = Math.Min(minLon, _vzVerts[2 * k]);
                maxLon = Math.Max(maxLon, _vzVerts[2 * k]);
                minLat = Math.Min(minLat, _vzVerts[2 * k + 1]);
                maxLat = Math.Max(maxLat, _vzVerts[2 * k + 1]);
            }
            _vzBox[4 * i] = minLon - 2.0 * ClipEdgeTolDeg;
            _vzBox[4 * i + 1] = minLat - 2.0 * ClipEdgeTolDeg;
            _vzBox[4 * i + 2] = maxLon + 2.0 * ClipEdgeTolDeg;
            _vzBox[4 * i + 3] = maxLat + 2.0 * ClipEdgeTolDeg;
        }
    }

    /// <summary>What BiomeRelief.road_weight walks: lon/lat pairs per road and each road's half width (m).</summary>
    public void SetVertRoads(double[] points, int[] starts, double[] halfWidth, double mPerDeg)
    {
        _vRoadPts = points ?? Array.Empty<double>();
        _vRoadStart = starts ?? Array.Empty<int>();
        _vRoadHalf = halfWidth ?? Array.Empty<double>();
        _vRoadMPerDeg = mPerDeg;
    }

    /// <summary>The LOD stitch, per vertex: its forced height (NaN none), and blend weight with parent height (NaN none).</summary>
    public void SetVertStitch(double[] edge, double[] weight, double[] height)
    {
        _vStitchEdge = edge ?? Array.Empty<double>();
        _vStitchWeight = weight ?? Array.Empty<double>();
        _vStitchHeight = height ?? Array.Empty<double>();
    }

    /// <summary>GradeBed.apply's C# half for this chunk, as GradeBed.native_args gives it. Pads: SetVertPads.</summary>
    public void SetVertGrade(GodotObject grade, double mPerDeg, int mode, double param)
    {
        _vGrade = grade as GradeCarveNative;
        _vHasGrade = true;
        _vGradeMPerDeg = mPerDeg;
        _vGradeMode = mode;
        _vGradeParam = param;
    }

    /// <summary>Where a pad can change a height (PadBed.apply_reach_m): lon, lat, reach triples, GDScript's vertices.</summary>
    public void SetVertPads(double[] lonLatReach) => _vPads = lonLatReach ?? Array.Empty<double>();

    /// <summary>Starts the pass over the grid dirs (flat, (res + 1)² directions).</summary>
    public void VertsBegin(Vector3[] grid, int res, long ipix, long nside, double vtxSpacing, double maxMove, double footInset,
        bool masked, Vector3 origin)
    {
        int n = grid.Length;
        _vGrid = grid;
        _vRes = res;
        _vIpix = ipix;
        _vNside = nside;
        _vSpacing = vtxSpacing;
        _vMaxMove = maxMove;
        _vFoot = footInset;
        _vMasked = masked;
        _vOrigin = origin;
        _vCursor = 0;
        _vState = new byte[n];
        _vVertices = new Vector3[n];
        _vDirs = new Vector3[n];
        _vUvs = new Vector2[n];
        _vUv2s = new Vector2[n];
        _vColors = new Color[n];
        _vHeights = new float[n];
        _vEdge = new float[n];
        _vCore = new float[n];
        _vCarve = new float[n];
        _vWall = new float[n];
        Array.Fill(_vWall, float.PositiveInfinity);
        _vRoadW = new float[n];
        _vCarved = new byte[n];
        _vSnapped = new byte[n];
        _vBand = new byte[n];
        _vSlot = new byte[n];
        _vColorDir = new byte[n];
        _vReliefOut = new int[n];
        _vOverrideOut = new int[n];
        _vGradeH = new double[n];
    }

    /// <summary>
    /// Goes on from where it stopped. Returns -1 at the end of the grid, or a vertex whose sample it could not
    /// answer: the caller samples VertsDir(i) through GDScript, then calls again. stopOnMissing = false leaves
    /// such a vertex to GDScript instead (a climb that is only a guess never comes back to the C#).
    /// </summary>
    public int VertsRun(bool stopOnMissing)
    {
        int n = _vGrid.Length;
        while (_vCursor < n)
        {
            if (!Vertex(_vCursor))
            {
                if (stopOnMissing)
                    return _vCursor;
                _vState[_vCursor] = VertGdscript;
            }
            _vCursor++;
        }
        return -1;
    }

    /// <summary>The direction, after the rim snap, the vertex VertsRun stopped on samples at.</summary>
    public Vector3 VertsDir(int idx) => _vDirs[idx];

    /// <summary>
    /// The pass' arrays, in the order PlanetChunk unpacks them: state, vertices, directions, uvs, uv2s, colours,
    /// heights, crack edge, core, carve, wall, road weight, carved, snapped, band, slot, relief, override, graded h,
    /// colour from direction.
    /// </summary>
    public Godot.Collections.Array VertsResult()
    {
        return new Godot.Collections.Array
        {
            _vState, _vVertices, _vDirs, _vUvs, _vUv2s, _vColors, _vHeights, _vEdge, _vCore, _vCarve, _vWall, _vRoadW,
            _vCarved, _vSnapped, _vBand, _vSlot, _vReliefOut, _vOverrideOut, _vGradeH, _vColorDir,
        };
    }

    /// <summary>One vertex: false when a sample came back NaN, nothing else about the vertex having been kept.</summary>
    private bool Vertex(int idx)
    {
        Vector3 dir = _vGrid[idx];
        int zone = VertZone(dir);
        if (_vzServe[zone] == 0)
        {
            _vState[idx] = VertGdscript;
            return true;
        }
        int res1 = _vRes + 1;
        int xi = idx % res1, yi = idx / res1;
        bool border = xi == 0 || xi == _vRes || yi == 0 || yi == _vRes;
        bool crackHere = _vzCrack[zone] != 0;
        bool crackLod = _crackSpacing > 0.0 && _crackWidth > 0.0 && !(_vSpacing > 0.0 && _vSpacing >= _crackWidth * 0.5);
        if (crackHere && crackLod && _crackNoise == null)
        {
            _vState[idx] = VertGdscript;
            return true;
        }
        bool stitched = _vStitchEdge.Length > 0 && !double.IsNaN(_vStitchEdge[idx]);

        // Rim snap: ArideDesertCorundumPlateauTerrain.crack_rim_snap, _snap_lands_on_wall.
        double crackD = double.PositiveInfinity;
        byte snapped = 0;
        if (crackHere)
        {
            Vector4 snap = crackLod
                ? _crackNoise.Snap(dir, _radius, _crackSpacing, _crackWidth, _vSpacing, stitched ? 0.0 : _vMaxMove, _vFoot)
                : new Vector4(dir.X, dir.Y, dir.Z, double.PositiveInfinity);
            if (_vMasked && !(snap.X == dir.X && snap.Y == dir.Y && snap.Z == dir.Z)
                && !(Factor(new Vector3(snap.X, snap.Y, snap.Z)) > 0.0))
                snap = new Vector4(dir.X, dir.Y, dir.Z, double.PositiveInfinity);
            var moved = new Vector3(snap.X, snap.Y, snap.Z);
            if (moved != dir)
                snapped = 1;
            dir = moved;
            crackD = snap.W;
        }
        _vDirs[idx] = dir;

        double lon = 0.0, lat = 0.0;
        bool lonLat = false;
        if (_vPads.Length > 0)
        {
            MountainNoiseCore.ToLonLat(dir.X, dir.Y, dir.Z, out lon, out lat);
            lonLat = true;
            if (PadCanReach(lon, lat))
            {
                _vState[idx] = VertGdscript;
                return true;
            }
        }

        double height;
        if (stitched)
        {
            height = _vStitchEdge[idx];
        }
        else if (border)
        {
            height = SampleBoundary(dir, _vIpix, _vNside, _vSpacing, CracksNone);
            if (double.IsNaN(height))
                return false;
        }
        else
        {
            height = Sample(dir, _vIpix, _vNside, _vSpacing, CracksNone);
            if (double.IsNaN(height))
                return false;
            if (_vStitchWeight.Length > 0 && !double.IsNaN(_vStitchWeight[idx]))
                height = MountainNoiseCore.Lerp(height, _vStitchHeight[idx], _vStitchWeight[idx]);
        }
        double hSampled = height;

        // Biome relief: BiomeRelief.visible_at was asked per zone, road_weight, offset.
        int relief = _vzRelief[zone];
        if (relief > 0)
        {
            if (!lonLat)
            {
                MountainNoiseCore.ToLonLat(dir.X, dir.Y, dir.Z, out lon, out lat);
                lonLat = true;
            }
            double w = RoadWeight(lon, lat);
            if (w > 0.0)
            {
                height += w * ReliefOffset(dir, relief - 1, _vSpacing);
                _vReliefOut[idx] = relief;
                _vRoadW[idx] = (float)w;
            }
        }

        // The crack network: crack_factor, crack_offset_from_edge.
        double crackOff = 0.0;
        if (crackHere)
        {
            double cw = _vMasked ? Factor(dir) : 1.0;
            if (cw > 0.0)
            {
                double edgeOff = (_crackDepth <= 0.0 || _crackWidth <= 0.0 || crackD >= _crackWidth * 0.5) ? 0.0 : -_crackDepth;
                crackOff = edgeOff * cw;
                height += crackOff;
            }
            else
            {
                crackD = double.PositiveInfinity;
            }
        }
        _vEdge[idx] = (float)crackD;
        if (crackOff < 0.0)
            _vCarved[idx] = 1;
        _vSnapped[idx] = snapped;

        // GradeBed.apply, the pads aside.
        if (_vHasGrade)
        {
            if (_vGrade != null)
            {
                if (!lonLat)
                {
                    MountainNoiseCore.ToLonLat(dir.X, dir.Y, dir.Z, out lon, out lat);
                    lonLat = true;
                }
                double carved = _vGrade.Apply(height, new Vector2(lon, lat), _vGradeMPerDeg, _vGradeMode, _vGradeParam);
                if (carved != height)
                {
                    height = carved;
                    _vBand[idx] = 1;
                }
            }
            _vGradeH[idx] = height;
        }

        _vHeights[idx] = (float)height;
        // PlanetChunk._world_to_local: the chunk-local position rounded to float32.
        Vector3 local = dir * (_radius + height) - _vOrigin;
        _vVertices[idx] = new Vector3((float)local.X, (float)local.Y, (float)local.Z);
        // PlanetData.direction_to_uv.
        Vector3 d = dir.Normalized();
        _vUvs[idx] = new Vector2(0.5 + Math.Atan2(-d.Z, d.X) / Math.Tau,
            0.5 - Math.Asin(MountainNoiseCore.Clamp(d.Y, -1.0, 1.0)) / Math.PI);
        _vColors[idx] = _vzColor[zone];
        _vColorDir[idx] = (byte)_vzColorFromDir[zone];
        _vUv2s[idx] = _vzDetail[zone];
        _vOverrideOut[idx] = _vzOverride[zone];

        // The rock's provenance, for the impurity pass.
        int slot = _vzSlot[zone];
        if (slot > 0)
        {
            _vSlot[idx] = (byte)slot;
            _vCore[idx] = _mountains != null ? (float)_mountains.Core(dir, _radius) : 0f;
            _vCarve[idx] = (float)(hSampled > height ? hSampled - height : 0.0);
            double impD = crackD;
            if (double.IsInfinity(impD) && !crackHere && _cracksOn && crackLod)
                impD = _crackNoise.EdgeDistanceD(dir.X, dir.Y, dir.Z, _radius, _crackSpacing, _vSpacing);
            if (!double.IsInfinity(impD))
                _vWall[idx] = (float)(impD - _crackWidth * 0.5);
        }
        _vState[idx] = VertServed;
        return true;
    }

    /// <summary>The index of the first zone holding dir (PlanetChunk._query_zones_at_direction), or the last entry.</summary>
    private int VertZone(Vector3 dir)
    {
        int n = _vzFull.Length;
        if (n == 0)
            return 0;
        double lon = double.NaN, lat = double.NaN;
        for (int i = 0; i < n; i++)
        {
            if (_vzFull[i] == 0)
            {
                if (double.IsNaN(lon))
                {
                    // BiomeQuery._dir_to_lonlat
                    Vector3 d = dir.Normalized();
                    lon = Math.Atan2(-(double)d.Z, (double)d.X) * (180.0 / Math.PI);
                    double y = d.Y;
                    lat = Math.Asin(y < -1.0 ? -1.0 : (y > 1.0 ? 1.0 : y)) * (180.0 / Math.PI);
                }
                if (lon < _vzBox[4 * i] || lat < _vzBox[4 * i + 1] || lon > _vzBox[4 * i + 2] || lat > _vzBox[4 * i + 3])
                    continue;
                int a = _vzStart[i];
                int count = _vzStart[i + 1] - a;
                if (!PointInPolygon(_vzVerts, lon, lat, a, count) && !OnClipEdge(_vzVerts, lon, lat, a, count))
                    continue;
            }
            return i;
        }
        return n;
    }

    /// <summary>Within a pad's reach, on the tangent plane the pad's own distance is measured on (PadBed.sdf_m)?</summary>
    private bool PadCanReach(double lon, double lat)
    {
        for (int i = 0; i + 2 < _vPads.Length; i += 3)
        {
            double lat0 = _vPads[i + 1];
            double dLon = lon - _vPads[i];
            if (dLon > 180.0)
                dLon -= 360.0;
            else if (dLon < -180.0)
                dLon += 360.0;
            double ls = Math.Max(Math.Cos(MountainNoiseCore.DegToRad(MountainNoiseCore.Clamp(lat0, -89.5, 89.5))), 1e-6);
            double e = dLon * ls * _vRoadMPerDeg;
            double north = (lat - lat0) * _vRoadMPerDeg;
            if (e * e + north * north <= _vPads[i + 2] * _vPads[i + 2])
                return true;
        }
        return false;
    }

    /// <summary>BiomeRelief.road_weight.</summary>
    private double RoadWeight(double lon, double lat)
    {
        if (_vRoadHalf.Length == 0)
            return 1.0;
        double flatMargin = Math.Max(ReliefFlatMarginM, ReliefFlatPitches * _vSpacing);
        double fullMargin = Math.Max(ReliefBlendMarginM, ReliefBlendPitches * _vSpacing);
        double latScale = Math.Cos(MountainNoiseCore.DegToRad(MountainNoiseCore.Clamp(lat, -89.5, 89.5)));
        if (latScale < 1e-6)
            latScale = 1e-6;
        double w = 1.0;
        for (int r = 0; r < _vRoadHalf.Length; r++)
        {
            int a = _vRoadStart[r], count = _vRoadStart[r + 1] - a;
            if (count < 2)
                continue;
            double flatM = _vRoadHalf[r] + flatMargin;
            double fullM = _vRoadHalf[r] + fullMargin;
            double fullDeg = fullM / _vRoadMPerDeg;
            double best = double.PositiveInfinity;
            for (int i = 0; i < count - 1; i++)
            {
                double dq = MountainNoiseCore.DistSqToSegment(lon, lat, _vRoadPts[2 * (a + i)], _vRoadPts[2 * (a + i) + 1],
                    _vRoadPts[2 * (a + i + 1)], _vRoadPts[2 * (a + i + 1) + 1], latScale);
                best = best < dq ? best : dq;
                if (best <= 0.0)
                    break;
            }
            if (best >= fullDeg * fullDeg)
                continue;
            double dM = Math.Sqrt(best) * _vRoadMPerDeg;
            if (dM <= flatM)
                return 0.0;
            double s = SmoothStep(flatM, fullM, dM);
            w = w < s ? w : s;
        }
        return w;
    }

    /// <summary>BiomeRelief's FLAT_MARGIN_M, FLAT_PITCHES, BLEND_MARGIN_M, BLEND_PITCHES.</summary>
    private const double ReliefFlatMarginM = 2.0, ReliefFlatPitches = 1.5, ReliefBlendMarginM = 10.0, ReliefBlendPitches = 3.0;
}
