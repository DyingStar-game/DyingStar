using System;
using Godot;

/// <summary>
/// A face's shape from its landmarks on one or more photos (FaceFit, the game's photo-to-character): the weights of a
/// few shape keys (FLAME's identity directions, some of the creator's sliders) that make our head's landmarks land
/// on the photos' -- the method of tools/character/face_survey/fit.py, without Python. Rounds alternate:
///   1. each photo's pose (scale, rotation, shift) by a weighted similarity fit of our head's landmarks onto the
///      photo's (Horn's quaternion method, in 3D with MediaPipe's depth);
///   2. the weights, every photo at once, by regularised least squares in the cameras' frames (MediaPipe's depth
///      counts DepthWeight of x and y), each key held to its bounds.
/// The landmarks' model (their positions on the base head and each key's displacement of them) comes from the
/// bank (FaceFit.gd samples it); this only solves.
/// </summary>
public partial class FaceFitNative : RefCounted
{
    private const double DepthWeight = 0.15;
    /// <summary>A landmark counts on a photo as its skin faces the camera: none under this cosine, all over the second
    /// (on a profile, the hidden half's landmarks are MediaPipe's guesses).</summary>
    private const double HiddenBelow = 0.05, SeenAbove = 0.35;

    /// <summary>
    /// [baseLandmarks]: our head's N landmarks (m, +Y up, the face looking along +Z), [normals]: their skin's normals.
    /// [deltas]: K x N x 3, each key's
    /// displacement of them at weight 1. [lower] / [upper]: each key's bounds; [prior]: each key's ridge (m^2 a unit
    /// of weight squared, per unit of landmark weight). [landmarkWeights]: per landmark (0 to leave it out).
    /// [views]: per photo a Dictionary { "points": Vector3[] N (photo pixels: x right, y down, z MediaPipe's: towards
    /// the camera negative), "weight": float }. Returns { "weights": float[] K, "poses": Array of { "scale", "basis",
    /// "origin" } (photo = scale * basis * head + origin, in (x, -y, -z) pixels), "rms": residual (m, on the head) }.
    /// [priorMean]: per key, the weight its ridge pulls it towards (the learned shape's, Predict + FitShape), or
    /// null / empty for none (0).
    /// </summary>
    public Godot.Collections.Dictionary Fit(Vector3[] baseLandmarks, Vector3[] normals, float[] deltas, float[] lower, float[] upper,
        float[] prior, float[] landmarkWeights, Godot.Collections.Array views, int rounds, float[] priorMean = null)
    {
        int n = baseLandmarks.Length;
        int k = prior.Length;
        var w = new double[k];
        for (int j = 0; priorMean != null && j < Math.Min(k, priorMean.Length); j++)
            w[j] = priorMean[j];
        var poses = new (double s, Basis r, Vector3 t)[views.Count];
        var obs = new Vector3[views.Count][];
        var viewWeight = new double[views.Count];
        for (int v = 0; v < views.Count; v++)
        {
            var view = (Godot.Collections.Dictionary)views[v];
            Vector3[] pts = (Vector3[])view["points"];
            obs[v] = new Vector3[n];
            for (int i = 0; i < n; i++)
                obs[v][i] = new Vector3(pts[i].X, -pts[i].Y, -pts[i].Z);
            viewWeight[v] = view.ContainsKey("weight") ? (double)view["weight"] : 1.0;
        }
        var head = new Vector3[n];
        var seen = new float[views.Count][];
        double rms = 0.0;
        for (int round = 0; round < rounds; round++)
        {
            for (int i = 0; i < n; i++)
            {
                double x = baseLandmarks[i].X, y = baseLandmarks[i].Y, z = baseLandmarks[i].Z;
                for (int j = 0; j < k; j++)
                {
                    int at = (j * n + i) * 3;
                    x += w[j] * deltas[at];
                    y += w[j] * deltas[at + 1];
                    z += w[j] * deltas[at + 2];
                }
                head[i] = new Vector3((float)x, (float)y, (float)z);
            }
            for (int v = 0; v < views.Count; v++)
            {
                // Twice: the pose from every landmark, then from those it shows only.
                poses[v] = Similarity(head, obs[v], landmarkWeights);
                seen[v] = Visible(normals, landmarkWeights, poses[v].r);
                poses[v] = Similarity(head, obs[v], seen[v]);
                seen[v] = Visible(normals, landmarkWeights, poses[v].r);
            }
            w = SolveWeights(baseLandmarks, deltas, lower, upper, prior, priorMean, seen, obs, poses, viewWeight, out rms);
        }
        var weights = new float[k];
        for (int j = 0; j < k; j++)
            weights[j] = (float)w[j];
        var poseArray = new Godot.Collections.Array();
        foreach (var (s, r, t) in poses)
            poseArray.Add(new Godot.Collections.Dictionary { ["scale"] = s, ["basis"] = r, ["origin"] = t });
        return new Godot.Collections.Dictionary { ["weights"] = weights, ["poses"] = poseArray, ["rms"] = rms };
    }

    /// <summary>Per landmark, its weight on a photo seen from [r]: as its skin faces the camera.</summary>
    private static float[] Visible(Vector3[] normals, float[] weights, Basis r)
    {
        Vector3 camera = r.Transposed() * new Vector3(0.0f, 0.0f, 1.0f);  // the camera's direction, in the head's frame
        var out_ = new float[weights.Length];
        for (int i = 0; i < weights.Length; i++)
        {
            double facing = normals[i].Dot(camera);
            double t = Math.Clamp((facing - HiddenBelow) / (SeenAbove - HiddenBelow), 0.0, 1.0);
            out_[i] = (float)(weights[i] * t * t * (3.0 - 2.0 * t));
        }
        return out_;
    }

    // --- pose: obs ~= s R head + t ---------------------------------------------------------------------

    private static (double, Basis, Vector3) Similarity(Vector3[] head, Vector3[] obs, float[] weights)
    {
        double sw = 0.0;
        Vector3 mh = Vector3.Zero, mo = Vector3.Zero;
        for (int i = 0; i < head.Length; i++)
        {
            double wi = weights[i];
            if (wi <= 0.0)
                continue;
            sw += wi;
            mh += head[i] * (float)wi;
            mo += obs[i] * (float)wi;
        }
        mh /= (float)sw;
        mo /= (float)sw;
        // Cross-covariance S = sum w (h - mh)(o - mo)^T, then Horn's 4 x 4 matrix.
        var S = new double[3, 3];
        double hh = 0.0;
        for (int i = 0; i < head.Length; i++)
        {
            double wi = weights[i];
            if (wi <= 0.0)
                continue;
            Vector3 a = head[i] - mh, b = obs[i] - mo;
            double[] av = { a.X, a.Y, a.Z }, bv = { b.X, b.Y, b.Z };
            for (int r = 0; r < 3; r++)
                for (int c = 0; c < 3; c++)
                    S[r, c] += wi * av[r] * bv[c];
            hh += wi * a.LengthSquared();
        }
        double sxx = S[0, 0], sxy = S[0, 1], sxz = S[0, 2], syx = S[1, 0], syy = S[1, 1], syz = S[1, 2], szx = S[2, 0], szy = S[2, 1], szz = S[2, 2];
        var N = new double[4, 4]
        {
            { sxx + syy + szz, syz - szy, szx - sxz, sxy - syx },
            { syz - szy, sxx - syy - szz, sxy + syx, szx + sxz },
            { szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy },
            { sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz },
        };
        double[] q = LargestEigenvector(N);
        var quat = new Quaternion((float)q[1], (float)q[2], (float)q[3], (float)q[0]).Normalized();
        var basis = new Basis(quat);
        double num = 0.0;
        for (int i = 0; i < head.Length; i++)
        {
            double wi = weights[i];
            if (wi <= 0.0)
                continue;
            num += wi * (obs[i] - mo).Dot(basis * (head[i] - mh));
        }
        double s = num / hh;
        Vector3 t = mo - basis * mh * (float)s;
        return (s, basis, t);
    }

    /// <summary>The eigenvector of the largest eigenvalue of a symmetric 4 x 4 matrix (Jacobi rotations).</summary>
    private static double[] LargestEigenvector(double[,] m)
    {
        var a = (double[,])m.Clone();
        var v = new double[4, 4];
        for (int i = 0; i < 4; i++)
            v[i, i] = 1.0;
        for (int sweep = 0; sweep < 50; sweep++)
        {
            double off = 0.0;
            for (int p = 0; p < 4; p++)
                for (int q = p + 1; q < 4; q++)
                    off += a[p, q] * a[p, q];
            if (off < 1e-24)
                break;
            for (int p = 0; p < 4; p++)
                for (int q = p + 1; q < 4; q++)
                {
                    if (Math.Abs(a[p, q]) < 1e-300)
                        continue;
                    double theta = (a[q, q] - a[p, p]) / (2.0 * a[p, q]);
                    double t = Math.Sign(theta) / (Math.Abs(theta) + Math.Sqrt(theta * theta + 1.0));
                    if (theta == 0.0)
                        t = 1.0;
                    double c = 1.0 / Math.Sqrt(t * t + 1.0), s = t * c;
                    for (int r = 0; r < 4; r++)
                    {
                        double arp = a[r, p], arq = a[r, q];
                        a[r, p] = c * arp - s * arq;
                        a[r, q] = s * arp + c * arq;
                    }
                    for (int r = 0; r < 4; r++)
                    {
                        double apr = a[p, r], aqr = a[q, r];
                        a[p, r] = c * apr - s * aqr;
                        a[q, r] = s * apr + c * aqr;
                    }
                    for (int r = 0; r < 4; r++)
                    {
                        double vrp = v[r, p], vrq = v[r, q];
                        v[r, p] = c * vrp - s * vrq;
                        v[r, q] = s * vrp + c * vrq;
                    }
                }
        }
        int best = 0;
        for (int i = 1; i < 4; i++)
            if (a[i, i] > a[best, best])
                best = i;
        return new[] { v[0, best], v[1, best], v[2, best], v[3, best] };
    }

    // --- weights: regularised least squares in the cameras' frames ---------------------------------------

    private static double[] SolveWeights(Vector3[] baseLandmarks, float[] deltas, float[] lower, float[] upper, float[] prior,
        float[] priorMean, float[][] landmarkWeights, Vector3[][] obs, (double s, Basis r, Vector3 t)[] poses, double[] viewWeight, out double rms)
    {
        int n = baseLandmarks.Length, k = prior.Length;
        var ata = new double[k, k];
        var atb = new double[k];
        double total = 0.0;
        var row = new double[k];
        double[] axisWeight = { 1.0, 1.0, DepthWeight };
        for (int v = 0; v < obs.Length; v++)
        {
            var (s, r, t) = poses[v];
            for (int i = 0; i < n; i++)
            {
                double wi = landmarkWeights[v][i] * viewWeight[v];
                if (wi <= 0.0)
                    continue;
                // In the camera's frame, at the head's scale: (obs - t) / s against R (base + sum w delta).
                Vector3 target = (obs[v][i] - t) / (float)s;
                Vector3 b0 = r * baseLandmarks[i];
                var dk = new Vector3[k];
                for (int j = 0; j < k; j++)
                {
                    int at = (j * n + i) * 3;
                    dk[j] = r * new Vector3(deltas[at], deltas[at + 1], deltas[at + 2]);
                }
                for (int axis = 0; axis < 3; axis++)
                {
                    double aw = wi * axisWeight[axis];
                    double b = target[axis] - b0[axis];
                    for (int j = 0; j < k; j++)
                        row[j] = dk[j][axis];
                    for (int j = 0; j < k; j++)
                    {
                        atb[j] += aw * row[j] * b;
                        for (int l = j; l < k; l++)
                            ata[j, l] += aw * row[j] * row[l];
                    }
                    total += aw;
                }
            }
        }
        for (int j = 0; j < k; j++)
            for (int l = 0; l < j; l++)
                ata[j, l] = ata[l, j];
        for (int j = 0; j < k; j++)
        {
            ata[j, j] += prior[j] * total;
            if (priorMean != null && j < priorMean.Length)
                atb[j] += prior[j] * total * priorMean[j];
        }
        double[] w = SolveBounded(ata, atb, lower, upper);
        // The residual, for the report (m on the head, all views and axes weighted).
        double err = 0.0;
        for (int v = 0; v < obs.Length; v++)
        {
            var (s, r, t) = poses[v];
            for (int i = 0; i < n; i++)
            {
                double wi = landmarkWeights[v][i] * viewWeight[v];
                if (wi <= 0.0)
                    continue;
                Vector3 p = baseLandmarks[i];
                for (int j = 0; j < k; j++)
                {
                    int at = (j * n + i) * 3;
                    p += new Vector3(deltas[at], deltas[at + 1], deltas[at + 2]) * (float)w[j];
                }
                Vector3 d = r * p - (obs[v][i] - t) / (float)s;
                err += wi * (d.X * d.X + d.Y * d.Y + DepthWeight * d.Z * d.Z);
            }
        }
        rms = Math.Sqrt(err / Math.Max(total, 1e-12) * 3.0 / (2.0 + DepthWeight));
        return w;
    }

    /// <summary>Bounds: solve, hold the keys past theirs at the bound, solve the others again.</summary>
    private static double[] SolveBounded(double[,] ata, double[] atb, float[] lower, float[] upper)
    {
        int k = atb.Length;
        var fixedAt = new double?[k];
        double[] w = new double[k];
        for (int pass = 0; pass < 4; pass++)
        {
            w = SolveFixed(ata, atb, fixedAt);
            bool changed = false;
            for (int j = 0; j < k; j++)
                if (fixedAt[j] == null && (w[j] < lower[j] || w[j] > upper[j]))
                {
                    fixedAt[j] = Math.Clamp(w[j], lower[j], upper[j]);
                    changed = true;
                }
            if (!changed)
                break;
        }
        return w;
    }

    // --- the learned shape: landmarks -> dense face (tools/character/face_survey/regress.py apply) -------

    /// <summary>
    /// The face's dense shape predicted from photos' landmarks by a learned linear map (FaceFitData's shape_*), the
    /// method of tools/character/face_survey/regress.py: per view of [views] (Vector3[] 478 each: pixels, x right,
    /// y down, MediaPipe's depth), its landmarks turned to (x, -y, -z) and aligned by a similarity on that view's
    /// mean landmarks ([meanLandmarks], the views' one after another); all of them, standardised by [featureMean] /
    /// [featureStd], times [beta] (features x C) give C coefficients of the shape's [components] (C x V x 3) about
    /// [meanShape] (V x 3), drawn back to [maxSpread] deviations rms (of [coeffStd]) when further. Returns V points
    /// (m, our head's frame, the size of the training heads').
    /// </summary>
    public Vector3[] Predict(Godot.Collections.Array views, float[] meanLandmarks, float[] featureMean, float[] featureStd,
        float[] beta, float[] meanShape, float[] components, float[] coeffStd = null, float maxSpread = 0.0f)
    {
        int features = featureMean.Length;
        int c = beta.Length / features;
        int v = meanShape.Length / 3;
        double[] coeffs = Linear(views, meanLandmarks, featureMean, featureStd, beta, c);
        // A photo unlike the training renders makes the map extrapolate: the coefficients, over their spread on the
        // training faces ([coeffStd]), are drawn back to an rms of [maxSpread] at most.
        if (coeffStd != null && coeffStd.Length == c && maxSpread > 0.0f)
        {
            double sum = 0.0;
            for (int j = 0; j < c; j++)
                sum += coeffs[j] * coeffs[j] / Math.Max((double)coeffStd[j] * coeffStd[j], 1e-30);
            double spread = Math.Sqrt(sum / c);
            if (spread > maxSpread)
                for (int j = 0; j < c; j++)
                    coeffs[j] *= maxSpread / spread;
        }
        var out_ = new Vector3[v];
        for (int i = 0; i < v; i++)
        {
            double x = meanShape[i * 3], y = meanShape[i * 3 + 1], z = meanShape[i * 3 + 2];
            for (int j = 0; j < c; j++)
            {
                int at = j * v * 3 + i * 3;
                x += coeffs[j] * components[at];
                y += coeffs[j] * components[at + 1];
                z += coeffs[j] * components[at + 2];
            }
            out_[i] = new Vector3((float)x, (float)y, (float)z);
        }
        return out_;
    }

    /// <summary>
    /// The creator's shape sliders read from photos' landmarks by a linear map learnt on real faces (FaceFitData's
    /// reader_*: tools/character/face_survey/ava/ava_learn.py, on Ava-256): the views' landmarks aligned and
    /// standardised as Predict's, times [beta] (features x K), plus [weightMean] (K). Returns the K weights.
    /// </summary>
    public float[] Read(Godot.Collections.Array views, float[] meanLandmarks, float[] featureMean, float[] featureStd,
        float[] beta, float[] weightMean)
    {
        int k = weightMean.Length;
        double[] w = Linear(views, meanLandmarks, featureMean, featureStd, beta, k);
        var out_ = new float[k];
        for (int j = 0; j < k; j++)
            out_[j] = (float)(w[j] + weightMean[j]);
        return out_;
    }

    /// <summary>Per view, its landmarks turned to (x, -y, -z) and aligned by a similarity on that view's mean
    /// ([meanLandmarks], one view after another), standardised, times [beta] (features x [c]).</summary>
    private static double[] Linear(Godot.Collections.Array views, float[] meanLandmarks, float[] featureMean, float[] featureStd,
        float[] beta, int c)
    {
        int features = featureMean.Length;
        var coeffs = new double[c];
        int f0 = 0;
        foreach (Variant item in views)
        {
            Vector3[] points = item.AsVector3Array();
            int n = points.Length;
            var p = new Vector3[n];
            var reference = new Vector3[n];
            var ones = new float[n];
            for (int i = 0; i < n; i++)
            {
                p[i] = new Vector3(points[i].X, -points[i].Y, -points[i].Z);
                int r0 = f0 + i * 3;
                reference[i] = new Vector3(meanLandmarks[r0], meanLandmarks[r0 + 1], meanLandmarks[r0 + 2]);
                ones[i] = 1.0f;
            }
            var (s, r, t) = Similarity(p, reference, ones);
            for (int i = 0; i < n; i++)
            {
                Vector3 q = r * p[i] * (float)s + t;
                for (int axis = 0; axis < 3; axis++)
                {
                    int f = f0 + i * 3 + axis;
                    double x = (q[axis] - featureMean[f]) / featureStd[f];
                    int row = f * c;
                    for (int j = 0; j < c; j++)
                        coeffs[j] += x * beta[row + j];
                }
            }
            f0 += n * 3;
        }
        if (f0 != features)
            GD.PushError($"FaceFitNative: {f0} landmark features for a linear map of {features}");
        return coeffs;
    }

    /// <summary>
    /// The keys' weights whose head is nearest a dense [target] shape (Predict's), the target aligned on the head by a
    /// similarity each round: [baseShape] V points, [deltas] K x V x 3 (each key at weight 1), [prior] each key's
    /// ridge (m^2 a unit of weight squared, absolute), [lower] / [upper] its bounds. Returns { "weights": float[] K,
    /// "rms": the head's distance to the aligned target (m) }.
    /// </summary>
    public Godot.Collections.Dictionary FitShape(Vector3[] baseShape, float[] deltas, float[] lower, float[] upper, float[] prior,
        Vector3[] target, int rounds)
    {
        int n = baseShape.Length, k = prior.Length;
        var ata = new double[k, k];
        var column = new double[k];
        for (int i = 0; i < n * 3; i++)
        {
            for (int j = 0; j < k; j++)
                column[j] = deltas[j * n * 3 + i];
            for (int j = 0; j < k; j++)
            {
                double a = column[j];
                if (a == 0.0)
                    continue;
                for (int l = j; l < k; l++)
                    ata[j, l] += a * column[l];
            }
        }
        for (int j = 0; j < k; j++)
        {
            for (int l = 0; l < j; l++)
                ata[j, l] = ata[l, j];
            ata[j, j] += prior[j];
        }
        var ones = new float[n];
        Array.Fill(ones, 1.0f);
        var w = new double[k];
        var head = new Vector3[n];
        var aligned = new Vector3[n];
        double rms = 0.0;
        for (int round = 0; round <= rounds; round++)
        {
            for (int i = 0; i < n; i++)
            {
                double x = baseShape[i].X, y = baseShape[i].Y, z = baseShape[i].Z;
                for (int j = 0; j < k; j++)
                {
                    if (w[j] == 0.0)
                        continue;
                    int at = (j * n + i) * 3;
                    x += w[j] * deltas[at];
                    y += w[j] * deltas[at + 1];
                    z += w[j] * deltas[at + 2];
                }
                head[i] = new Vector3((float)x, (float)y, (float)z);
            }
            var (s, r, t) = Similarity(target, head, ones);
            double err = 0.0;
            for (int i = 0; i < n; i++)
            {
                aligned[i] = r * target[i] * (float)s + t;
                err += (aligned[i] - head[i]).LengthSquared();
            }
            rms = Math.Sqrt(err / Math.Max(n, 1));
            if (round == rounds)
                break;  // the last pass only measures
            var atb = new double[k];
            for (int i = 0; i < n; i++)
            {
                Vector3 d = aligned[i] - baseShape[i];
                for (int j = 0; j < k; j++)
                {
                    int at = (j * n + i) * 3;
                    atb[j] += deltas[at] * d.X + deltas[at + 1] * d.Y + deltas[at + 2] * d.Z;
                }
            }
            w = SolveBounded(ata, atb, lower, upper);
        }
        var weights = new float[k];
        for (int j = 0; j < k; j++)
            weights[j] = (float)w[j];
        return new Godot.Collections.Dictionary { ["weights"] = weights, ["rms"] = rms };
    }

    /// <summary>Solves ata w = atb with some weights held (Cholesky on the free ones).</summary>
    private static double[] SolveFixed(double[,] ata, double[] atb, double?[] fixedAt)
    {
        int k = atb.Length;
        var free = new System.Collections.Generic.List<int>();
        for (int j = 0; j < k; j++)
            if (fixedAt[j] == null)
                free.Add(j);
        int m = free.Count;
        var a = new double[m, m];
        var b = new double[m];
        for (int x = 0; x < m; x++)
        {
            int j = free[x];
            b[x] = atb[j];
            for (int l = 0; l < k; l++)
                if (fixedAt[l] != null)
                    b[x] -= ata[j, l] * fixedAt[l].Value;
            for (int y = 0; y < m; y++)
                a[x, y] = ata[j, free[y]];
        }
        // Cholesky: a = L L^T.
        for (int x = 0; x < m; x++)
        {
            for (int y = 0; y <= x; y++)
            {
                double sum = a[x, y];
                for (int z = 0; z < y; z++)
                    sum -= a[x, z] * a[y, z];
                a[x, y] = x == y ? Math.Sqrt(Math.Max(sum, 1e-18)) : sum / a[y, y];
            }
        }
        var u = new double[m];
        for (int x = 0; x < m; x++)
        {
            double sum = b[x];
            for (int z = 0; z < x; z++)
                sum -= a[x, z] * u[z];
            u[x] = sum / a[x, x];
        }
        var sol = new double[m];
        for (int x = m - 1; x >= 0; x--)
        {
            double sum = u[x];
            for (int z = x + 1; z < m; z++)
                sum -= a[z, x] * sol[z];
            sol[x] = sum / a[x, x];
        }
        var w = new double[k];
        for (int j = 0; j < k; j++)
            w[j] = fixedAt[j] ?? 0.0;
        for (int x = 0; x < m; x++)
            w[free[x]] = sol[x];
        return w;
    }

    // --- the profile photo: the bridge's sliders from the face's outline (tools/character/face_survey/profile_fit.py) ---

    private const double ProfileBin = 0.5;  // mm: the outlines' height steps
    private const double ProfileTrim = 0.8;  // the share of the photo's outline points (nearest ours) each laying step follows
    // Our face's height (mm) per detector box height to start from: the box's size on a profile varies (0.5 on our renders,
    // about 1 on NoW's photos).
    private static readonly double[] ProfileStarts = { 0.7, 0.9, 1.1, 1.3 };
    private const int ProfileViewFrom = -25, ProfileViewTo = 10, ProfileViewStep = 5;  // degrees off a pure profile
    private const int ProfileLayIterations = 30;
    private const int ProfileLayRounds = 2;  // the rounds that lay the photo's outline again
    private const int ProfileFill = 2;  // height steps either side an outline step takes its furthest from

    /// <summary>
    /// The weights of a few shape keys (the bridge's) that make our head's outline seen from the side follow a profile
    /// photo's. [samples]: points on the front of our head as the other photos made it (mm, +Y up, the face looking
    /// along +Z); [deltas]: K x S x 3, each key's move of them at weight 1; [weights]: the keys' weights now (also
    /// what the ridge [ridge] pulls them back to), within [lower] / [upper]. [outline]: the photo's face edge, in
    /// detector box heights from the nose's tip, (forward, up). [noseLow] / [noseHigh]: our nose's heights (mm: its
    /// base, its root), what is fitted -- the rest of the outline (forehead, lips, chin) lays the photo's on ours: per
    /// view off a pure profile and starting scale, a trimmed ICP by a 2D similarity, the best kept. [fromY] / [toY]:
    /// our outline's heights; [faceHeight]: mm, forehead to chin. Returns { "weights": float[] K, "score": the laying's
    /// rms (mm, its best TRIM share), "view": degrees, "laid": Vector2[] the photo's outline as laid, "ours": Vector2[]
    /// our outline at the weights found (both (forward, up), mm) }.
    /// </summary>
    public Godot.Collections.Dictionary FitProfile(Vector3[] samples, float[] deltas, float[] weights, float[] lower, float[] upper,
        float ridge, Vector2[] outline, float noseLow, float noseHigh, float fromY, float toY, float faceHeight, int rounds)
    {
        int k = weights.Length, n = samples.Length;
        var w = new double[k];
        for (int j = 0; j < k; j++)
            w[j] = weights[j];
        var pts = new Vector3[n];
        // Laid by the forehead, lips and chin, which the bridge's keys leave where they are -- again after the first
        // round only, the nose's tip (where the laying starts) having moved (on NoW: laid once 1.384 mm, every round
        // 1.372, twice as well for two fifths of the cost).
        Current(samples, deltas, w, pts);
        var laid = Lay(pts, outline, noseLow, noseHigh, fromY, toY, faceHeight);
        var result = new float[k];
        if (laid.q == null)
        {
            Array.Copy(weights, result, k);
            return new Godot.Collections.Dictionary { ["weights"] = result, ["score"] = double.NaN, ["view"] = 0.0 };
        }
        for (int round = 0; round < rounds; round++)
        {
            if (round > 0)
                Current(samples, deltas, w, pts);
            if (round > 0 && round < ProfileLayRounds)
            {
                var again = Lay(pts, outline, noseLow, noseHigh, fromY, toY, faceHeight);
                if (again.q != null)
                    laid = again;
            }
            double hx = Math.Sin(laid.view * Math.PI / 180.0), hz = Math.Cos(laid.view * Math.PI / 180.0);
            // The photo's nose, root to base, against ours: how much further out it is, per point.
            double lo = noseLow - 2.0, hi = noseHigh + 4.0;
            var (zs, idx) = Envelope(pts, hx, hz, lo - ProfileBin, hi + ProfileBin);
            var ata = new double[k, k];
            var atb = new double[k];
            int rows = 0;
            foreach (Vector2 p in laid.q)
            {
                if (p.Y <= lo || p.Y >= hi)
                    continue;
                int b = (int)Math.Floor((p.Y - (lo - ProfileBin)) / ProfileBin);
                if (b < 0 || b >= idx.Length || idx[b] < 0)
                    continue;
                int s = idx[b];
                double r = p.X - zs[b];
                var jac = new double[k];
                for (int j = 0; j < k; j++)
                {
                    int at = (j * n + s) * 3;
                    jac[j] = deltas[at] * hx + deltas[at + 2] * hz;
                }
                for (int a = 0; a < k; a++)
                {
                    atb[a] += jac[a] * r;
                    for (int c = 0; c < k; c++)
                        ata[a, c] += jac[a] * jac[c];
                }
                rows++;
            }
            if (rows < 10)
                break;
            var shifted = new float[k * 2];
            for (int j = 0; j < k; j++)
            {
                ata[j, j] += ridge * rows;
                atb[j] += ridge * rows * (weights[j] - w[j]);
                shifted[j] = (float)(lower[j] - w[j]);
                shifted[k + j] = (float)(upper[j] - w[j]);
            }
            double[] step = SolveBounded(ata, atb, shifted[..k], shifted[k..]);
            for (int j = 0; j < k; j++)
                w[j] = Math.Clamp(w[j] + step[j], lower[j], upper[j]);
        }
        for (int j = 0; j < k; j++)
            result[j] = (float)w[j];
        // What was compared, for a look: the photo's outline as laid, ours (its final weights) seen from that view.
        Current(samples, deltas, w, pts);
        double vx = Math.Sin(laid.view * Math.PI / 180.0), vz = Math.Cos(laid.view * Math.PI / 180.0);
        var (finalFar, _) = Envelope(pts, vx, vz, fromY, toY);
        var ours = new System.Collections.Generic.List<Vector2>();
        for (int b = 0; b < finalFar.Length; b++)
            if (!double.IsNaN(finalFar[b]))
                ours.Add(new Vector2((float)finalFar[b], (float)(fromY + (b + 0.5) * ProfileBin)));
        return new Godot.Collections.Dictionary
        {
            ["weights"] = result, ["score"] = laid.score, ["view"] = laid.view, ["laid"] = laid.q, ["ours"] = ours.ToArray(),
        };
    }

    /// <summary>[pts] = [samples] moved by the keys at weights [w] ([deltas]: K x S x 3).</summary>
    private static void Current(Vector3[] samples, float[] deltas, double[] w, Vector3[] pts)
    {
        int n = samples.Length;
        for (int i = 0; i < n; i++)
        {
            double x = samples[i].X, y = samples[i].Y, z = samples[i].Z;
            for (int j = 0; j < w.Length; j++)
            {
                int at = (j * n + i) * 3;
                x += w[j] * deltas[at];
                y += w[j] * deltas[at + 1];
                z += w[j] * deltas[at + 2];
            }
            pts[i] = new Vector3((float)x, (float)y, (float)z);
        }
    }

    /// <summary>Our outline seen along (hx, 0, hz): per ProfileBin of height from [from], the furthest sample along it
    /// (NaN, -1 where none falls).</summary>
    private static (double[] far, int[] idx) Envelope(Vector3[] pts, double hx, double hz, double from, double to)
    {
        int bins = Math.Max(1, (int)Math.Ceiling((to - from) / ProfileBin));
        var far = new double[bins];
        var idx = new int[bins];
        for (int b = 0; b < bins; b++)
        {
            far[b] = double.NaN;
            idx[b] = -1;
        }
        for (int i = 0; i < pts.Length; i++)
        {
            int b = (int)Math.Floor((pts[i].Y - from) / ProfileBin);
            if (b < 0 || b >= bins)
                continue;
            double f = pts[i].X * hx + pts[i].Z * hz;
            if (idx[b] < 0 || f > far[b])
            {
                far[b] = f;
                idx[b] = i;
            }
        }
        // A height step no point of the face's front falls in takes one further back (the forehead's large
        // triangles): each step is the furthest of its neighbours', else the photo is laid on those dents.
        var outFar = new double[bins];
        var outIdx = new int[bins];
        for (int b = 0; b < bins; b++)
        {
            outFar[b] = double.NaN;
            outIdx[b] = -1;
            for (int c = Math.Max(0, b - ProfileFill); c <= Math.Min(bins - 1, b + ProfileFill); c++)
                if (idx[c] >= 0 && (outIdx[b] < 0 || far[c] > outFar[b]))
                {
                    outFar[b] = far[c];
                    outIdx[b] = idx[c];
                }
        }
        return (outFar, outIdx);
    }

    /// <summary>The photo's outline laid on ours (forward, up; mm) by its forehead, lips and chin.</summary>
    private static (Vector2[] q, double score, double view) Lay(Vector3[] pts, Vector2[] outline, double noseLow, double noseHigh,
        double fromY, double toY, double faceHeight)
    {
        (Vector2[] q, double score, double view) best = (null, double.MaxValue, 0.0);
        for (int deg = ProfileViewFrom; deg <= ProfileViewTo; deg += ProfileViewStep)
        {
            double hx = Math.Sin(deg * Math.PI / 180.0), hz = Math.Cos(deg * Math.PI / 180.0);
            var (far, _) = Envelope(pts, hx, hz, fromY, toY);
            var anchors = new System.Collections.Generic.List<Vector2>();
            Vector2 tip = Vector2.Zero;
            bool hasTip = false;
            double lowest = double.MaxValue, highest = double.MinValue;
            for (int b = 0; b < far.Length; b++)
            {
                if (double.IsNaN(far[b]))
                    continue;
                double y = fromY + (b + 0.5) * ProfileBin;
                lowest = Math.Min(lowest, y);
                highest = Math.Max(highest, y);
                var p = new Vector2((float)far[b], (float)y);
                if (y < noseLow - 4.0 || y > noseHigh + 4.0)
                    anchors.Add(p);
                if (y > noseLow && y < noseHigh && (!hasTip || p.X > tip.X))
                {
                    tip = p;
                    hasTip = true;
                }
            }
            if (!hasTip || anchors.Count < 10)
                continue;
            Vector2[] ours = anchors.ToArray();  // in height order: the nearest search walks out from a height
            foreach (double start in ProfileStarts)
            {
                var q = new Vector2[outline.Length];
                for (int i = 0; i < q.Length; i++)
                    q[i] = outline[i] * (float)(start * faceHeight) + tip;
                double score = double.MaxValue;
                for (int it = 0; it <= ProfileLayIterations; it++)
                {
                    var (d, j) = Nearest(q, ours);
                    // Only the photo's points within our outline's heights: its neck, the top of its head have nothing
                    // to match and would pull the laying (shrink it towards our ends).
                    var inside = new System.Collections.Generic.List<double>();
                    for (int i = 0; i < q.Length; i++)
                        if (q[i].Y > lowest - 1.0 && q[i].Y < highest + 1.0)
                            inside.Add(d[i]);
                    if (inside.Count < 10)
                        break;
                    var sorted = inside.ToArray();
                    Array.Sort(sorted);
                    int keepCount = Math.Max(1, (int)(ProfileTrim * sorted.Length));
                    double cut = sorted[keepCount - 1];
                    double sum = 0.0;
                    for (int i = 0; i < keepCount; i++)
                        sum += sorted[i] * sorted[i];
                    score = Math.Sqrt(sum / keepCount);
                    if (it == ProfileLayIterations)
                        break;
                    var src = new System.Collections.Generic.List<Vector2>();
                    var dst = new System.Collections.Generic.List<Vector2>();
                    for (int i = 0; i < q.Length; i++)
                        if (d[i] <= cut && q[i].Y > lowest - 1.0 && q[i].Y < highest + 1.0)
                        {
                            src.Add(q[i]);
                            dst.Add(ours[j[i]]);
                        }
                    q = Similarity2(src, dst, q);
                }
                if (score < best.score)
                    best = (q, score, deg);
            }
        }
        return best;
    }

    /// <summary>Per point of [q], its nearest of [ours] (sorted by height): distance and index.</summary>
    private static (double[] d, int[] j) Nearest(Vector2[] q, Vector2[] ours)
    {
        var d = new double[q.Length];
        var j = new int[q.Length];
        for (int i = 0; i < q.Length; i++)
        {
            int lo = 0, hi = ours.Length;
            while (lo < hi)
            {
                int mid = (lo + hi) / 2;
                if (ours[mid].Y < q[i].Y)
                    lo = mid + 1;
                else
                    hi = mid;
            }
            double best = double.MaxValue;
            int at = 0;
            for (int a = lo; a < ours.Length && ours[a].Y - q[i].Y < best; a++)
            {
                double dd = q[i].DistanceTo(ours[a]);
                if (dd < best)
                {
                    best = dd;
                    at = a;
                }
            }
            for (int a = lo - 1; a >= 0 && q[i].Y - ours[a].Y < best; a--)
            {
                double dd = q[i].DistanceTo(ours[a]);
                if (dd < best)
                {
                    best = dd;
                    at = a;
                }
            }
            d[i] = best;
            j[i] = at;
        }
        return (d, j);
    }

    /// <summary>[all] moved by the 2D similarity taking [src] onto [dst]: Horn's symmetric scale (a curve's nearest
    /// points pull no collapse).</summary>
    private static Vector2[] Similarity2(System.Collections.Generic.List<Vector2> src, System.Collections.Generic.List<Vector2> dst,
        Vector2[] all)
    {
        int m = src.Count;
        double msx = 0, msy = 0, mdx = 0, mdy = 0;
        for (int i = 0; i < m; i++)
        {
            msx += src[i].X;
            msy += src[i].Y;
            mdx += dst[i].X;
            mdy += dst[i].Y;
        }
        msx /= m;
        msy /= m;
        mdx /= m;
        mdy /= m;
        double sxx = 0, sxy = 0, syx = 0, syy = 0, na = 0, nb = 0;
        for (int i = 0; i < m; i++)
        {
            double ax = src[i].X - msx, ay = src[i].Y - msy, bx = dst[i].X - mdx, by = dst[i].Y - mdy;
            sxx += ax * bx;
            sxy += ax * by;
            syx += ay * bx;
            syy += ay * by;
            na += ax * ax + ay * ay;
            nb += bx * bx + by * by;
        }
        double angle = Math.Atan2(sxy - syx, sxx + syy);  // the rotation taking a onto b
        double c = Math.Cos(angle), s = Math.Sin(angle);
        double scale = Math.Sqrt(nb / Math.Max(na, 1e-12));
        var outp = new Vector2[all.Length];
        for (int i = 0; i < all.Length; i++)
        {
            double ax = all[i].X - msx, ay = all[i].Y - msy;
            outp[i] = new Vector2((float)(scale * (c * ax - s * ay) + mdx), (float)(scale * (s * ax + c * ay) + mdy));
        }
        return outp;
    }
}
