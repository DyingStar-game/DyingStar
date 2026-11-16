using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;

/// <summary>
/// Hair that moves (HairMotion), the heavy parts:
/// - Bind: HairMotionBinding.build's loops (which guides are simulated, which two each guide follows), same order
///   and same float32 storage as the GDScript, which holds their reasons; test_hair_motion.gd holds the two equal.
/// - Step: every simulated avatar's strands, one frame (Verlet, in the frame of the avatar's parent: its planet,
///   building or vehicle). Each strand is SAMPLES points from its root; those within its fixed length ride the head,
///   the others fall under gravity, are dragged by the air going past them, keep their spacing, are pulled back
///   towards the cut's shape (less towards the tip) and are pushed out of the head (HairHead's distance field, in the
///   mesh's frame) and out of the capsules of the neck, chest, shoulders and arms (worn clothes included). Out come
///   the displacements from rest, in the mesh's frame, one texture row per avatar (the strands shader reads them).
/// No GDScript twin of Step: without this class the hair swings as a pendulum (HairMotion), or stays put.
/// </summary>
public partial class HairMotionNative : RefCounted
{
    /// <summary>Points along a simulated strand (HairMotionBinding.SAMPLES).</summary>
    public const int Samples = 8;
    private const double Rigid = 99.0;

    private float[] _sdf = Array.Empty<float>();
    private Vector3 _sdfOrigin;
    private double _sdfCell;
    private int _sx, _sy, _sz;
    private double _sdfMinY;

    // Tunables (HairMotion.KNOBS order).
    private double _damping = 0.96;
    private double _drag = 3.0;
    private double _shapeRoot = 0.3;
    private double _shapeTip = 0.03;
    private double _gravity = 1.0;
    private double _margin = 0.004;
    private int _iterations = 4;

    private sealed class Avatar
    {
        public int Sims;
        public Vector3[] Rest = Array.Empty<Vector3>();
        public double[] Free = Array.Empty<double>();
        public double[] Length = Array.Empty<double>();
        public Vector3[] Pos = Array.Empty<Vector3>();
        public Vector3[] Prev = Array.Empty<Vector3>();
        public Vector3[] Target = Array.Empty<Vector3>();
        public Vector3[] PreviousTarget = Array.Empty<Vector3>();
        public Vector3[] Sub = Array.Empty<Vector3>();
        // Per point, its rest distance to the point before (the mesh's: times Scale); per sample, its shape pull.
        public double[] Spacing = Array.Empty<double>();
        public double[] Pull = Array.Empty<double>();
        // Per point, how far from the head it lies at rest (m): pushed no further out than that, where a cut lies
        // closer to the skull than the margin.
        public double[] RestClear = Array.Empty<double>();
        // The mesh-to-parent transform's mean scale (the fit to this head): rest spacings are the mesh's.
        public double Scale = 1.0;
        public bool Fresh = true;
    }

    private readonly Dictionary<int, Avatar> _avatars = new();

    /// <summary>
    /// HairHead's distance field (sdf, sdf_origin, sdf_cell, its size), in the neutral head's frame -- a head of
    /// hair's mesh frame -- used above minY only: below it, the field's shoulders are the neutral pose's, not this
    /// avatar's (the capsules follow its skeleton).
    /// </summary>
    public void Configure(float[] sdf, Vector3 origin, double cell, Vector3I size, double minY)
    {
        _sdf = sdf;
        _sdfOrigin = origin;
        _sdfCell = cell;
        _sx = size.X;
        _sy = size.Y;
        _sz = size.Z;
        _sdfMinY = minY;
    }

    /// <summary>The tunables, in HairMotion.KNOBS order: damping, drag, shape_root, shape_tip, gravity, margin, iterations.</summary>
    public void Tune(double[] knobs)
    {
        _damping = knobs[0];
        _drag = knobs[1];
        _shapeRoot = knobs[2];
        _shapeTip = knobs[3];
        _gravity = knobs[4];
        _margin = knobs[5];
        _iterations = Math.Max(1, (int)knobs[6]);
        lock (_avatars)
        {
            foreach (Avatar a in _avatars.Values)
            {
                for (int j = 0; j < Samples; j++)
                    a.Pull[j] = _shapeRoot + (_shapeTip - _shapeRoot) * j / (Samples - 1);
            }
        }
    }

    /// <summary>
    /// The strands of the avatar in [slot]: their points at rest (HairMotionBinding.sim_rest: DENSE per strand, evenly
    /// along it, mesh frame), their fixed length's codes and their lengths; [fixedLength] what a negative code
    /// multiplies. Each strand is simulated as SAMPLES points over its free part: the first where it stops staying put
    /// (pinned to the head), the last its tip. It starts at rest.
    /// </summary>
    public void SetAvatar(int slot, Vector3[] simRest, float[] simFree, float[] simLength, double fixedLength)
    {
        int sims = simFree.Length;
        int dense = sims > 0 ? simRest.Length / sims : 0;
        var a = new Avatar
        {
            Sims = sims,
            Rest = new Vector3[sims * Samples],
            Free = new double[sims],
            Length = new double[sims],
            Pos = new Vector3[sims * Samples],
            Prev = new Vector3[sims * Samples],
            Target = new Vector3[sims * Samples],
            PreviousTarget = new Vector3[sims * Samples],
            Sub = new Vector3[sims * Samples],
            Spacing = new double[sims * Samples],
            Pull = new double[Samples],
        };
        for (int j = 0; j < Samples; j++)
            a.Pull[j] = _shapeRoot + (_shapeTip - _shapeRoot) * j / (Samples - 1);
        for (int s = 0; s < sims; s++)
        {
            double code = simFree[s];
            double length = simLength[s];
            double free = Math.Min(code < 0.0 ? fixedLength * -code : code, length);
            a.Free[s] = free;
            a.Length[s] = length;
            for (int j = 0; j < Samples; j++)
            {
                // Along the dense points (evenly spaced over the whole strand), at this sample's arc.
                double at = (free + (length - free) * j / (Samples - 1)) / Math.Max(length, 1e-9) * (dense - 1);
                int i = Math.Clamp((int)at, 0, Math.Max(dense - 2, 0));
                double t = Math.Clamp(at - i, 0.0, 1.0);
                a.Rest[s * Samples + j] = dense > 1 ? simRest[s * dense + i].Lerp(simRest[s * dense + i + 1], t) : simRest[s * dense];
            }
            for (int j = 1; j < Samples; j++)
                a.Spacing[s * Samples + j] = a.Rest[s * Samples + j].DistanceTo(a.Rest[s * Samples + j - 1]);
        }
        lock (_avatars)
            _avatars[slot] = a;
    }

    public void RemoveAvatar(int slot)
    {
        lock (_avatars)
            _avatars.Remove(slot);
    }

    /// <summary>
    /// One frame of [dt] s for the avatars in [inputs], written as [rows] texture rows of [width] RGBA float texels
    /// (a row per slot, SAMPLES texels per strand: its points' displacements from rest, mesh frame). Per avatar,
    /// doubles: slot, reset (1 = start at rest: a teleport, a new cut), amount (0..1, how much of its motion is shown),
    /// the mesh-to-parent transform (basis x, y, z columns, origin: 12), gravity (m/s², parent frame: 3), the wind
    /// (m/s, parent frame: 3), its capsules' count, then per capsule a, b (parent frame) and radius (7 each).
    /// </summary>
    public byte[] Step(double dt, double[] inputs, int rows, int width)
    {
        var jobs = new List<(Avatar a, int slot, int at)>();
        int i = 0;
        lock (_avatars)
        {
            while (i < inputs.Length)
            {
                int slot = (int)inputs[i];
                int caps = (int)inputs[i + 21];
                if (_avatars.TryGetValue(slot, out Avatar a) && slot >= 0 && slot < rows)
                    jobs.Add((a, slot, i));
                i += 22 + caps * 7;
            }
        }
        var output = new float[rows * width * 4];
        double h = Math.Clamp(dt, 0.0, 1.0 / 15.0);
        Parallel.For(0, jobs.Count, j =>
        {
            var (a, slot, at) = jobs[j];
            Transform3D toParent = TransformAt(inputs, at + 3);
            int caps = (int)inputs[at + 21];
            var capA = new Vector3[caps];
            var capB = new Vector3[caps];
            var capR = new double[caps];
            for (int c = 0; c < caps; c++)
            {
                int o = at + 22 + c * 7;
                capA[c] = new Vector3(inputs[o], inputs[o + 1], inputs[o + 2]);
                capB[c] = new Vector3(inputs[o + 3], inputs[o + 4], inputs[o + 5]);
                capR[c] = inputs[o + 6];
            }
            Simulate(a, h, inputs[at + 1] > 0.5, toParent, new Vector3(inputs[at + 15], inputs[at + 16], inputs[at + 17]),
                new Vector3(inputs[at + 18], inputs[at + 19], inputs[at + 20]), capA, capB, capR);
            Write(a, inputs[at + 2], toParent, output, slot * width * 4, width);
        });
        var bytes = new byte[output.Length * 4];
        Buffer.BlockCopy(output, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    private static Transform3D TransformAt(double[] v, int at)
    {
        var basis = new Basis(new Vector3(v[at], v[at + 1], v[at + 2]), new Vector3(v[at + 3], v[at + 4], v[at + 5]),
            new Vector3(v[at + 6], v[at + 7], v[at + 8]));
        return new Transform3D(basis, new Vector3(v[at + 9], v[at + 10], v[at + 11]));
    }

    private void Simulate(Avatar a, double dt, bool reset, Transform3D toParent, Vector3 gravityIn, Vector3 wind,
        Vector3[] capsA, Vector3[] capsB, double[] capsR)
    {
        Transform3D toMesh = toParent.AffineInverse();
        a.Scale = toParent.Basis.Scale.Length() / Math.Sqrt(3.0);
        if (a.RestClear.Length != a.Rest.Length)
        {
            a.RestClear = new double[a.Rest.Length];
            for (int k = 0; k < a.Rest.Length; k++)
                a.RestClear[k] = Math.Min(_margin, _sdf.Length > 0 && a.Rest[k].Y >= _sdfMinY ? Surface(a.Rest[k]).Item1 : 1.0);
        }
        Vector3 gravity = gravityIn * _gravity;
        int count = a.Sims * Samples;
        // The capsules (parent frame): a, a to b, 1 / |ab|², radius with the margin.
        int caps = capsA.Length;
        var capA = capsA;
        var capAb = new Vector3[caps];
        var capInv = new double[caps];
        var capR = new double[caps];
        for (int c = 0; c < caps; c++)
        {
            capAb[c] = capsB[c] - capA[c];
            capInv[c] = 1.0 / Math.Max(capAb[c].LengthSquared(), 1e-12);
            capR[c] = capsR[c] + _margin;
        }
        (a.PreviousTarget, a.Target) = (a.Target, a.PreviousTarget);
        for (int k = 0; k < count; k++)
            a.Target[k] = toParent * a.Rest[k];
        // A jump (a teleport, a reparent the frame missed) or a fresh start: at rest, no swing out of it.
        if (reset || a.Fresh || (count > 0 && a.PreviousTarget[0].DistanceTo(a.Target[0]) > 1.0))
        {
            Array.Copy(a.Target, a.Pos, count);
            Array.Copy(a.Target, a.Prev, count);
            a.Fresh = false;
            return;
        }
        if (dt <= 0.0)
            return;
        int subs = dt > 1.0 / 45.0 ? 2 : 1;
        double h = dt / subs;
        double keep = Math.Pow(_damping, h * 60.0);
        double drag = 1.0 - Math.Exp(-_drag * h);
        Vector3 windStep = wind * h;
        Vector3 fall = gravity * (h * h);
        double shapeStep = 1.0 / _iterations;
        for (int sub = 1; sub <= subs; sub++)
        {
            double f = (double)sub / subs;
            Vector3[] target = a.Target;
            if (subs > 1)
            {
                target = a.Sub;
                for (int k = 0; k < count; k++)
                    target[k] = a.PreviousTarget[k].Lerp(a.Target[k], f);
            }
            for (int k = 0; k < count; k++)
            {
                if (k % Samples == 0)  // where the strand stops staying put: it rides the head
                {
                    a.Pos[k] = target[k];
                    a.Prev[k] = target[k];
                    continue;
                }
                Vector3 vel = (a.Pos[k] - a.Prev[k]) * keep;
                // The air drags the hair towards its own speed: the wind minus how fast the hair goes.
                vel += (windStep - vel) * drag;
                a.Prev[k] = a.Pos[k];
                a.Pos[k] += vel + fall;
            }
            for (int it = 0; it < _iterations; it++)
            {
                for (int k = 0; k < count; k++)
                {
                    int j = k % Samples;
                    if (j == 0)
                        continue;
                    // Spacing: as far from the point before as at rest (the chord, not the arc: a curl's points are
                    // closer than its length between them); the first free point alone moves, its root rides the head.
                    Vector3 d = a.Pos[k] - a.Pos[k - 1];
                    double len = d.Length();
                    if (len > 1e-9)
                    {
                        Vector3 fix = d * ((len - a.Spacing[k] * a.Scale) / len);
                        if (j == 1)
                            a.Pos[k] -= fix;
                        else
                        {
                            a.Pos[k] -= fix * 0.5;
                            a.Pos[k - 1] += fix * 0.5;
                        }
                    }
                    // Shape: back towards the cut, the less the further past the fixed length.
                    a.Pos[k] += (target[k] - a.Pos[k]) * (a.Pull[j] * shapeStep);
                }
            }
            // Collisions once the constraints are met: out of the capsules, then out of the head.
            for (int k = 0; k < count; k++)
            {
                if (k % Samples == 0)
                    continue;
                Vector3 p = a.Pos[k];
                for (int c = 0; c < caps; c++)
                {
                    double t = Math.Clamp((p - capA[c]).Dot(capAb[c]) * capInv[c], 0.0, 1.0);
                    Vector3 q = capA[c] + capAb[c] * t;
                    Vector3 off = p - q;
                    double dist = off.LengthSquared();
                    if (dist < capR[c] * capR[c] && dist > 1e-18)
                        p = q + off * (capR[c] / Math.Sqrt(dist));
                }
                if (_sdf.Length > 0)
                {
                    Vector3 m = toMesh * p;
                    if (m.Y >= _sdfMinY)
                    {
                        var (dist, normal) = Surface(m);
                        if (dist < a.RestClear[k])
                            p = toParent * (m + normal * (a.RestClear[k] - dist));
                    }
                }
                a.Pos[k] = p;
            }
        }
    }

    /// <summary>HairHead.surface: signed distance (m, > 0 outside) and outward normal, trilinear; far outside the grid.</summary>
    private (double, Vector3) Surface(Vector3 p)
    {
        Vector3 g = (p - _sdfOrigin) / _sdfCell;
        int ix = (int)Math.Floor(g.X), iy = (int)Math.Floor(g.Y), iz = (int)Math.Floor(g.Z);
        if (ix < 0 || iy < 0 || iz < 0 || ix >= _sx - 1 || iy >= _sy - 1 || iz >= _sz - 1)
            return (1.0, Vector3.Up);
        double fx = g.X - ix, fy = g.Y - iy, fz = g.Z - iz;
        double S(int x, int y, int z) => _sdf[x + y * _sx + z * _sx * _sy];
        double c000 = S(ix, iy, iz), c100 = S(ix + 1, iy, iz), c010 = S(ix, iy + 1, iz), c110 = S(ix + 1, iy + 1, iz);
        double c001 = S(ix, iy, iz + 1), c101 = S(ix + 1, iy, iz + 1), c011 = S(ix, iy + 1, iz + 1), c111 = S(ix + 1, iy + 1, iz + 1);
        double x00 = c000 + (c100 - c000) * fx, x10 = c010 + (c110 - c010) * fx;
        double x01 = c001 + (c101 - c001) * fx, x11 = c011 + (c111 - c011) * fx;
        double y0 = x00 + (x10 - x00) * fy, y1 = x01 + (x11 - x01) * fy;
        double d = y0 + (y1 - y0) * fz;
        double gx = ((c100 - c000) * (1 - fy) + (c110 - c010) * fy) * (1 - fz) + ((c101 - c001) * (1 - fy) + (c111 - c011) * fy) * fz;
        double gy = ((c010 - c000) * (1 - fx) + (c110 - c100) * fx) * (1 - fz) + ((c011 - c001) * (1 - fx) + (c111 - c101) * fx) * fz;
        double gz = ((c001 - c000) * (1 - fx) + (c101 - c100) * fx) * (1 - fy) + ((c011 - c010) * (1 - fx) + (c111 - c110) * fx) * fy;
        var n = new Vector3(gx, gy, gz);
        return (d, n.LengthSquared() > 1e-18 ? n.Normalized() : Vector3.Up);
    }

    private static void Write(Avatar a, double amountIn, Transform3D toParent, float[] output, int rowAt, int width)
    {
        double amount = Math.Clamp(amountIn, 0.0, 1.0);
        Basis toMesh = toParent.Basis.Inverse();
        int count = Math.Min(a.Sims * Samples, width);
        for (int k = 0; k < count; k++)
        {
            Vector3 d = toMesh * (a.Pos[k] - a.Target[k]) * amount;
            int o = rowAt + k * 4;
            output[o] = (float)d.X;
            output[o + 1] = (float)d.Y;
            output[o + 2] = (float)d.Z;
        }
    }

    // --- the avatars followed (HairMotion's frame loop) -----------------------------------------------------------

    private const int Still = 0, Swing = 1, Sim = 2;  // HairMotion.Tier

    private sealed class Tracked
    {
        public Skeleton3D Skeleton;
        public MeshInstance3D Hair, Head, Double;
        public Node3D Frame;
        public int HeadBone = -1;
        public int[] CapBone = Array.Empty<int>();
        public Vector3[] CapA = Array.Empty<Vector3>(), CapB = Array.Empty<Vector3>();
        public double[] CapR = Array.Empty<double>();
        public double BeardLength;
        public Vector3[] SimRest = Array.Empty<Vector3>();
        public float[] SimFree = Array.Empty<float>(), SimLength = Array.Empty<float>();
        public int Tier = Still, Want = Still, Row = -1;
        public double Amount;
        public bool Reset = true, StillSet, HasLast;
        public Vector3 Swing, SwingSpeed, Last, Speed, Accel, Wind;
        public Vector4 HairValue = new(-1, 0, 0, 0), HeadValue = new(-1, 0, 0, 0);
        public bool Moves => SimFree.Length > 0 && GodotObject.IsInstanceValid(Hair);
    }

    private readonly Dictionary<int, Tracked> _tracked = new();
    private readonly List<int> _freeRows = new();
    private Image _image;
    private ImageTexture _texture;
    private int _rows, _width;
    private double _fade = 0.3, _maxSwing = 0.08, _lever = 0.33, _air = 0.5, _accelSmoothing = 0.3, _g = 9.81;
    private double _swingStiffness = 40.0, _swingDamping = 4.0, _fixedLength = 0.07;
    private static readonly StringName HairMotionName = "hair_motion";

    /// <summary>
    /// The texture the rows go to ([rows] of [width] RGBA float texels), and HairMotion's constants: fade (s), max
    /// swing (m), lever, air, acceleration smoothing, gravity (m/s²).
    /// </summary>
    public void Setup(Image image, ImageTexture texture, int rows, int width, double[] constants)
    {
        _image = image;
        _texture = texture;
        _rows = rows;
        _width = width;
        _freeRows.Clear();
        for (int r = 0; r < rows; r++)
            _freeRows.Add(r);
        _fade = constants[0];
        _maxSwing = constants[1];
        _lever = constants[2];
        _air = constants[3];
        _accelSmoothing = constants[4];
        _g = constants[5];
    }

    /// <summary>HairMotion's swing knobs and fixed length.</summary>
    public void TuneSwing(double stiffness, double damping, double fixedLength)
    {
        _swingStiffness = stiffness;
        _swingDamping = damping;
        _fixedLength = fixedLength;
    }

    /// <summary>
    /// Follow avatar [id] (again: a new body, a new cut): its skeleton and Head bone, its hair and head meshes, its
    /// capsules (bone, a, b in the bone's space, radius), its beard's length (m, 0 = none) and its style's simulated
    /// strands (HairMotionBinding; empty = its hair does not move). Starts still.
    /// </summary>
    public void Track(int id, Skeleton3D skeleton, MeshInstance3D hair, MeshInstance3D head, int headBone, int[] capBone,
        Vector3[] capA, Vector3[] capB, float[] capR, double beardLength, Vector3[] simRest, float[] simFree, float[] simLength)
    {
        Untrack(id);
        var t = new Tracked
        {
            Skeleton = skeleton, Hair = hair, Head = head, HeadBone = headBone, CapBone = capBone, CapA = capA, CapB = capB,
            CapR = Array.ConvertAll(capR, r => (double)r), BeardLength = beardLength, SimRest = simRest, SimFree = simFree,
            SimLength = simLength,
        };
        _tracked[id] = t;
    }

    public void Untrack(int id)
    {
        if (_tracked.TryGetValue(id, out Tracked t))
        {
            Release(t);
            _tracked.Remove(id);
        }
    }

    /// <summary>
    /// What HairMotion chose for avatar [id] (four times a second): the tier it wants, its frame (its planet, or null),
    /// the air going past it (m/s, frame space) and its mirror double's hair (or null).
    /// </summary>
    public void Steer(int id, int want, Node3D frame, Vector3 wind, MeshInstance3D doubleHair)
    {
        if (!_tracked.TryGetValue(id, out Tracked t))
            return;
        t.Want = want;
        t.Frame = frame;
        t.Wind = wind;
        t.Double = doubleHair;
    }

    /// <summary>The texture row avatar [id]'s strands are written to, or -1.</summary>
    public int RowOf(int id) => _tracked.TryGetValue(id, out Tracked t) ? t.Row : -1;

    /// <summary>
    /// One frame of [dt] s for every avatar followed (main thread): its head's motion, its tier's easing, its swing,
    /// its shader parameters, and its strands when simulated -- their rows uploaded to the texture.
    /// </summary>
    public void Frame(double dt)
    {
        var jobs = new List<(Tracked t, Avatar a, Transform3D toParent, Vector3 down, Vector3[] capA, Vector3[] capB)>();
        foreach (Tracked t in _tracked.Values)
        {
            if (!GodotObject.IsInstanceValid(t.Skeleton) || t.HeadBone < 0)
                continue;
            if (t.Tier == Still && t.Want == Still)
            {
                if (!t.StillSet)
                {
                    SetHead(t, Vector4.Zero);
                    SetHair(t, Vector4.Zero);
                    t.StillSet = true;
                }
                t.HasLast = false;
                continue;
            }
            t.StillSet = false;
            Node3D frame = GodotObject.IsInstanceValid(t.Frame) ? t.Frame : null;
            Transform3D toFrame = frame != null ? frame.GlobalTransform.AffineInverse() : Transform3D.Identity;
            Transform3D pose = t.Skeleton.GetBoneGlobalPose(t.HeadBone);
            pose.Basis = pose.Basis.Orthonormalized();
            Transform3D headWorld = t.Skeleton.GlobalTransform * pose;
            Vector3 head = toFrame * headWorld.Origin;
            Vector3 accel = Vector3.Zero;
            if (t.HasLast && dt > 0.0)
            {
                Vector3 speed = (head - t.Last) / dt;
                if ((head - t.Last).Length() > 1.0)
                {
                    speed = Vector3.Zero;
                    t.Reset = true;
                }
                t.Accel = t.Accel.Lerp((speed - t.Speed) / dt, _accelSmoothing);
                accel = t.Accel;
                t.Speed = speed;
            }
            t.Last = head;
            t.HasLast = true;
            double step = dt / _fade;
            if (t.Want != t.Tier)
            {
                t.Amount = Math.Max(t.Amount - step, 0.0);
                if (t.Amount <= 0.0)
                {
                    Release(t);
                    t.Tier = t.Want;
                    if (t.Tier == Sim && t.Moves && _freeRows.Count > 0)
                    {
                        t.Row = _freeRows[0];
                        _freeRows.RemoveAt(0);
                        SetAvatar(t.Row, t.SimRest, t.SimFree, t.SimLength, _fixedLength);
                        t.Reset = true;
                    }
                    else if (t.Tier == Sim)
                        t.Tier = Swing;
                }
            }
            else
                t.Amount = Math.Min(t.Amount + step, 1.0);
            // The swing as one (the beard always; the hair when not simulated): a damped spring the head drags along.
            Vector3 force = (-accel + (t.Wind - t.Speed) * _air) * _lever;
            t.SwingSpeed += (force - t.Swing * _swingStiffness - t.SwingSpeed * _swingDamping) * dt;
            t.Swing += t.SwingSpeed * dt;
            if (t.Swing.Length() > _maxSwing)
            {
                t.Swing = t.Swing.LimitLength(_maxSwing);
                t.SwingSpeed *= 0.5;
            }
            if (t.Reset && t.Tier != Sim)
            {
                t.Swing = Vector3.Zero;
                t.SwingSpeed = Vector3.Zero;
            }
            Vector3 shown = t.Swing * (t.Tier != Still ? t.Amount : 0.0);
            Basis frameBasis = frame != null ? frame.GlobalBasis : Basis.Identity;
            if (GodotObject.IsInstanceValid(t.Head) && t.BeardLength > 0.0)
            {
                Vector3 beard = t.Head.GlobalBasis.Inverse() * (frameBasis * shown);
                SetHead(t, new Vector4((float)beard.X, (float)beard.Y, (float)beard.Z, (float)t.BeardLength));
            }
            if (!t.Moves)
            {
                t.Reset = false;
                continue;
            }
            Transform3D toParent = toFrame * headWorld * t.Hair.Transform;
            if (t.Tier == Sim && t.Row >= 0 && _avatars.TryGetValue(t.Row, out Avatar a))
            {
                SetHair(t, new Vector4(t.Row + 1, 0, 0, 0));
                Vector3 down = toFrame.Basis * (-t.Skeleton.GlobalBasis.Y.Normalized()) * _g;
                Transform3D skeletonToFrame = toFrame * t.Skeleton.GlobalTransform;
                var capA = new Vector3[t.CapBone.Length];
                var capB = new Vector3[t.CapBone.Length];
                for (int c = 0; c < t.CapBone.Length; c++)
                {
                    Transform3D bone = skeletonToFrame * t.Skeleton.GetBoneGlobalPose(t.CapBone[c]);
                    capA[c] = bone * t.CapA[c];
                    capB[c] = bone * t.CapB[c];
                }
                jobs.Add((t, a, toParent, down, capA, capB));
            }
            else if (t.Tier == Swing)
            {
                Vector3 mesh = toParent.Basis.Inverse() * shown;
                SetHair(t, new Vector4(0, (float)mesh.X, (float)mesh.Y, (float)mesh.Z));
            }
            else
            {
                SetHair(t, Vector4.Zero);
                t.Reset = false;
            }
        }
        if (jobs.Count == 0 || _image == null)
            return;
        var output = new float[_rows * _width * 4];
        double h = Math.Clamp(dt, 0.0, 1.0 / 15.0);
        Parallel.For(0, jobs.Count, j =>
        {
            var (t, a, toParent, down, capA, capB) = jobs[j];
            Simulate(a, h, t.Reset, toParent, down, t.Wind, capA, capB, t.CapR);
            Write(a, t.Amount, toParent, output, t.Row * _width * 4, _width);
        });
        foreach (var job in jobs)
            job.t.Reset = false;
        var bytes = new byte[output.Length * 4];
        Buffer.BlockCopy(output, 0, bytes, 0, bytes.Length);
        _image.SetData(_width, _rows, false, Image.Format.Rgbaf, bytes);
        _texture.Update(_image);
    }

    private void SetHair(Tracked t, Vector4 value)
    {
        if (!GodotObject.IsInstanceValid(t.Hair) || t.SimFree.Length == 0 || value == t.HairValue)
            return;
        t.HairValue = value;
        t.Hair.SetInstanceShaderParameter(HairMotionName, value);
        if (GodotObject.IsInstanceValid(t.Double))
            t.Double.SetInstanceShaderParameter(HairMotionName, value);
    }

    private static void SetHead(Tracked t, Vector4 value)
    {
        if (!GodotObject.IsInstanceValid(t.Head) || t.BeardLength <= 0.0 || value == t.HeadValue)
            return;
        t.HeadValue = value;
        t.Head.SetInstanceShaderParameter(HairMotionName, value);
    }

    private void Release(Tracked t)
    {
        if (t.Row < 0)
            return;
        RemoveAvatar(t.Row);
        _freeRows.Add(t.Row);
        t.Row = -1;
    }

    // --- HairMotionBinding.build's twin ---------------------------------------------------------------------------

    /// <summary>
    /// HairMotionBinding.build: [sims (int[]), sim_rest (Vector3[]: [dense] points each), sim_free (float[]), sim_length (float[]),
    /// binding (float[])] of a style's guides ([points], [n] per guide, their strand_free [free]); empty when none of
    /// them may move.
    /// </summary>
    public Godot.Collections.Array Bind(Vector3[] points, int n, float[] free, int simGuides, double fixedLength, int dense)
    {
        int count = n > 1 ? points.Length / n : 0;
        if (count == 0 || free.Length != count)
            return new Godot.Collections.Array();
        var length = new float[count];
        var features = new Vector3[count * 3];
        var movable = new List<int>();
        for (int k = 0; k < count; k++)
        {
            var line = new Vector3[n];
            Array.Copy(points, k * n, line, 0, n);
            Vector3[] along = Resample(line, 3);
            length[k] = (float)LineLength(line);
            for (int j = 0; j < 3; j++)
                features[k * 3 + j] = along[j];
            if (length[k] > FreeLength(free[k], fixedLength * 0.5) + 0.01)
                movable.Add(k);
        }
        if (movable.Count == 0)
            return new Godot.Collections.Array();
        int[] sims = Farthest(features, movable, length, simGuides);
        var simRest = new Vector3[sims.Length * dense];
        var simFree = new float[sims.Length];
        var simLength = new float[sims.Length];
        for (int i = 0; i < sims.Length; i++)
        {
            var line = new Vector3[n];
            Array.Copy(points, sims[i] * n, line, 0, n);
            Array.Copy(Resample(line, dense), 0, simRest, i * dense, dense);
            simFree[i] = free[sims[i]];
            simLength[i] = length[sims[i]];
        }
        var binding = new float[count * 4];
        for (int k = 0; k < count; k++)
        {
            binding[k * 4] = length[k];
            binding[k * 4 + 1] = free[k];
            if (free[k] >= Rigid)
            {
                binding[k * 4 + 3] = 1.0f;
                continue;
            }
            double bestD = double.PositiveInfinity, secondD = double.PositiveInfinity;
            int best = 0, second = 0;
            for (int i = 0; i < sims.Length; i++)
            {
                double d = FeatureDistance(features, k, sims[i]);
                if (d < bestD)
                {
                    secondD = bestD;
                    second = best;
                    bestD = d;
                    best = i;
                }
                else if (d < secondD)
                {
                    secondD = d;
                    second = i;
                }
            }
            if (double.IsPositiveInfinity(secondD))
            {
                secondD = bestD;
                second = best;
            }
            double da = Math.Sqrt(bestD), db = Math.Sqrt(secondD);
            binding[k * 4 + 2] = best * 64 + second;
            binding[k * 4 + 3] = (float)(da + db > 1e-9 ? db / (da + db) : 1.0);
        }
        return new Godot.Collections.Array { sims, simRest, simFree, simLength, binding };
    }

    private static double FreeLength(double code, double fixedLength) => code < 0.0 ? fixedLength * -code : code;

    private static double LineLength(Vector3[] line)
    {
        double total = 0.0;
        for (int i = 0; i < line.Length - 1; i++)
            total += line[i].DistanceTo(line[i + 1]);
        return total;
    }

    private static Vector3[] Resample(Vector3[] line, int count)
    {
        double total = LineLength(line);
        var output = new Vector3[count];
        int seg = 0;
        double walked = 0.0;
        for (int j = 0; j < count; j++)
        {
            double want = total * j / (count - 1);
            while (seg < line.Length - 2 && walked + line[seg].DistanceTo(line[seg + 1]) < want)
            {
                walked += line[seg].DistanceTo(line[seg + 1]);
                seg++;
            }
            double span = line[seg].DistanceTo(line[seg + 1]);
            double t = span > 1e-9 ? Math.Clamp((want - walked) / span, 0.0, 1.0) : 0.0;
            output[j] = line[seg].Lerp(line[seg + 1], t);
        }
        return output;
    }

    private static double FeatureDistance(Vector3[] features, int a, int b)
    {
        double d = 0.0;
        for (int j = 0; j < 3; j++)
            d += features[a * 3 + j].DistanceSquaredTo(features[b * 3 + j]);
        return d;
    }

    private static int[] Farthest(Vector3[] features, List<int> movable, float[] length, int simGuides)
    {
        if (movable.Count <= simGuides)
            return movable.ToArray();
        var taken = new List<int>();
        int first = movable[0];
        foreach (int k in movable)
        {
            if (length[k] > length[first])
                first = k;
        }
        taken.Add(first);
        var nearest = new float[movable.Count];
        for (int i = 0; i < movable.Count; i++)
            nearest[i] = (float)FeatureDistance(features, movable[i], first);
        while (taken.Count < simGuides)
        {
            int far = 0;
            for (int i = 0; i < movable.Count; i++)
            {
                if (nearest[i] > nearest[far])
                    far = i;
            }
            int pick = movable[far];
            taken.Add(pick);
            for (int i = 0; i < movable.Count; i++)
                nearest[i] = (float)Math.Min(nearest[i], FeatureDistance(features, movable[i], pick));
        }
        return taken.ToArray();
    }
}
