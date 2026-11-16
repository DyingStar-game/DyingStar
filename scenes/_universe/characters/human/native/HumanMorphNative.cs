using System;
using Godot;

/// <summary>
/// The heavy loops of baking a MakeHuman body (HumanMorph): summing the target deltas, fitting the worn
/// assets, and the render surfaces (normals on the welded mesh, tangents re-orthogonalised). The bank's
/// target data is copied in once (Configure, ~32 MB, main thread) and only read afterwards, so one
/// instance serves every builder worker.
///
/// scenes/_universe/characters/human/human_morph.gd is the reference and the fallback, and holds the
/// rules' reasons; test_human_morph_native.gd holds the two equal.
/// </summary>
public partial class HumanMorphNative : RefCounted
{
    private Vector3[] _base = Array.Empty<Vector3>();
    private short[] _delta = Array.Empty<short>();
    private ushort[] _sparse = Array.Empty<ushort>();
    private int[] _start = Array.Empty<int>();
    private int[] _count = Array.Empty<int>();
    private byte[] _dense = Array.Empty<byte>();
    private int[] _sparseStart = Array.Empty<int>();
    private float[] _scale = Array.Empty<float>();

    /// <summary>The bank's base vertices and targets (HumanBank fields, the byte arrays little-endian).</summary>
    public void Configure(Vector3[] baseVerts, byte[] delta, byte[] sparseIndex, int[] deltaStart, int[] count,
        byte[] dense, int[] sparseStart, float[] scale)
    {
        _base = baseVerts;
        _delta = new short[delta.Length / 2];
        Buffer.BlockCopy(delta, 0, _delta, 0, _delta.Length * 2);
        _sparse = new ushort[sparseIndex.Length / 2];
        Buffer.BlockCopy(sparseIndex, 0, _sparse, 0, _sparse.Length * 2);
        _start = deltaStart;
        _count = count;
        _dense = dense;
        _sparseStart = sparseStart;
        _scale = scale;
    }

    public bool IsConfigured() => _base.Length > 0;

    /// <summary>Compact vertices of the body with the given targets (bank indices) at the given weights.</summary>
    public Vector3[] Morph(int[] targets, float[] weights)
    {
        int n = _base.Length;
        var x = new double[n];
        var y = new double[n];
        var z = new double[n];
        for (int i = 0; i < n; i++)
        {
            x[i] = _base[i].X;
            y[i] = _base[i].Y;
            z[i] = _base[i].Z;
        }
        for (int k = 0; k < targets.Length; k++)
        {
            int t = targets[k];
            double s = (double)_scale[t] * weights[k];
            int o = _start[t];
            int c = _count[t];
            if (_dense[t] != 0)
            {
                for (int i = 0; i < c; i++, o += 3)
                {
                    x[i] += _delta[o] * s;
                    y[i] += _delta[o + 1] * s;
                    z[i] += _delta[o + 2] * s;
                }
            }
            else
            {
                int si = _sparseStart[t];
                for (int i = 0; i < c; i++, o += 3)
                {
                    int v = _sparse[si + i];
                    x[v] += _delta[o] * s;
                    y[v] += _delta[o + 1] * s;
                    z[v] += _delta[o + 2] * s;
                }
            }
        }
        var result = new Vector3[n];
        for (int i = 0; i < n; i++)
            result[i] = new Vector3((float)x[i], (float)y[i], (float)z[i]);
        return result;
    }

    /// <summary>[param points] (a baked body) with one more target added at [param weight] (a face unit).</summary>
    public Vector3[] WithTarget(Vector3[] points, int target, float weight)
    {
        var result = (Vector3[])points.Clone();
        double s = (double)_scale[target] * weight;
        int o = _start[target];
        int c = _count[target];
        int si = _sparseStart[target];
        bool dense = _dense[target] != 0;
        for (int i = 0; i < c; i++, o += 3)
        {
            int v = dense ? i : _sparse[si + i];
            Vector3 p = result[v];
            result[v] = new Vector3((float)(p.X + _delta[o] * s), (float)(p.Y + _delta[o + 1] * s), (float)(p.Z + _delta[o + 2] * s));
        }
        return result;
    }

    /// <summary>
    /// An asset's vertices on a body: per vertex, the weighted sum of its 3 body references plus its offset
    /// scaled, per axis, by how much the body grew between that axis' 2 reference vertices.
    /// </summary>
    public Vector3[] Fit(Vector3[] body, int[] refs, float[] weights, Vector3[] offsets, int[] scalePairs, float[] scaleRef)
    {
        double sx = AxisSize(body, scalePairs, scaleRef, 0);
        double sy = AxisSize(body, scalePairs, scaleRef, 1);
        double sz = AxisSize(body, scalePairs, scaleRef, 2);
        var result = new Vector3[offsets.Length];
        for (int i = 0; i < offsets.Length; i++)
        {
            int r = i * 3;
            Vector3 a = body[refs[r]], b = body[refs[r + 1]], c = body[refs[r + 2]];
            double wa = weights[r], wb = weights[r + 1], wc = weights[r + 2];
            result[i] = new Vector3(
                (float)(a.X * wa + b.X * wb + c.X * wc + offsets[i].X * sx),
                (float)(a.Y * wa + b.Y * wb + c.Y * wc + offsets[i].Y * sy),
                (float)(a.Z * wa + b.Z * wb + c.Z * wc + offsets[i].Z * sz));
        }
        return result;
    }

    private static double AxisSize(Vector3[] body, int[] pairs, float[] reference, int axis)
    {
        int a = pairs[axis * 2], b = pairs[axis * 2 + 1];
        if (a < 0 || b < 0)
            return 1.0;
        return Math.Abs((double)body[a][axis] - body[b][axis]) / reference[axis];
    }

    /// <summary>
    /// A render surface from source points: per render vertex its position (points[map[i]] + shift), its
    /// normal -- area-weighted face normals accumulated on the SOURCE vertices, so UV seams stay smooth --
    /// and its reference tangent made perpendicular to that normal. index is clockwise (Godot's front
    /// faces). Returns [positions, normals, tangents].
    /// </summary>
    public Godot.Collections.Array Surface(Vector3[] points, int[] map, int[] index, float[] tangentRef, Vector3 shift)
    {
        var acc = new Vector3[points.Length];
        for (int t = 0; t + 2 < index.Length; t += 3)
        {
            int a = map[index[t]], b = map[index[t + 1]], c = map[index[t + 2]];
            Vector3 face = (points[c] - points[a]).Cross(points[b] - points[a]);
            acc[a] += face;
            acc[b] += face;
            acc[c] += face;
        }
        int n = map.Length;
        var pos = new Vector3[n];
        var nrm = new Vector3[n];
        var tan = new float[n * 4];
        for (int i = 0; i < n; i++)
        {
            int s = map[i];
            pos[i] = points[s] + shift;
            Vector3 nv = acc[s];
            var len = nv.Length();
            nv = len > 1e-20 ? nv / len : Vector3.Up;
            nrm[i] = nv;
            var tv = new Vector3(tangentRef[i * 4], tangentRef[i * 4 + 1], tangentRef[i * 4 + 2]);
            tv -= nv * nv.Dot(tv);
            var tl = tv.Length();
            tv = tl > 1e-12 ? tv / tl : Perpendicular(nv);
            tan[i * 4] = (float)tv.X;
            tan[i * 4 + 1] = (float)tv.Y;
            tan[i * 4 + 2] = (float)tv.Z;
            tan[i * 4 + 3] = tangentRef[i * 4 + 3];
        }
        return new Godot.Collections.Array { pos, nrm, tan };
    }

    /// <summary>
    /// Surface() over the whole mesh (its normals as the whole mesh shapes them), returned for the render
    /// vertices of [param picks] only, in that order: a face unit's blend shape for the face mesh.
    /// </summary>
    public Godot.Collections.Array SurfacePicked(Vector3[] points, int[] map, int[] index, float[] tangentRef,
        Vector3 shift, int[] picks)
    {
        var full = Surface(points, map, index, tangentRef, shift);
        var pos = full[0].AsVector3Array();
        var nrm = full[1].AsVector3Array();
        var tan = full[2].AsFloat32Array();
        var outPos = new Vector3[picks.Length];
        var outNrm = new Vector3[picks.Length];
        var outTan = new float[picks.Length * 4];
        for (int i = 0; i < picks.Length; i++)
        {
            int r = picks[i];
            outPos[i] = pos[r];
            outNrm[i] = nrm[r];
            Array.Copy(tan, r * 4, outTan, i * 4, 4);
        }
        return new Godot.Collections.Array { outPos, outNrm, outTan };
    }

    private static Vector3 Perpendicular(Vector3 n)
    {
        Vector3 other = Math.Abs(n.X) < 0.9 ? Vector3.Right : Vector3.Up;
        return other.Cross(n).Normalized();
    }

    /// <summary>The triangles of index none of whose source vertices (map) is hidden (hidden[source] != 0).</summary>
    public int[] VisibleTriangles(int[] index, int[] map, byte[] hidden)
    {
        var keep = new int[index.Length];
        int k = 0;
        for (int t = 0; t + 2 < index.Length; t += 3)
        {
            int a = index[t], b = index[t + 1], c = index[t + 2];
            if (hidden[map[a]] != 0 || hidden[map[b]] != 0 || hidden[map[c]] != 0)
                continue;
            keep[k++] = a;
            keep[k++] = b;
            keep[k++] = c;
        }
        Array.Resize(ref keep, k);
        return keep;
    }
}
