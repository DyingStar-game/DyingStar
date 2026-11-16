using System;
using System.Collections.Generic;
using System.Linq;
using Godot;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

/// <summary>
/// A face on a photo, as MediaPipe's face landmarker finds it, in the game: the face detector (BlazeFace short range,
/// 128 x 128), then the face mesh (478 landmarks with the irises, 256 x 256) on a square crop turned upright by the
/// eyes, and the multiclass selfie segmenter (hair, face skin...). The ONNX models are MediaPipe's
/// (tools/character/face_survey/export_onnx.py); the pre- and post-processing follow MediaPipe's graphs and OpenCV's
/// pixel conventions, so the landmarks land within ~0.5 px of MediaPipe's (tools: scratchpad parity check).
/// Client only: the dedicated server never loads it. Runs on the CPU (ONNX Runtime), well under a second a photo.
/// </summary>
public partial class FaceDetectNative : RefCounted
{
    private const int DetectorSize = 128;
    private const int MeshSize = 256;
    private const int SegmenterSize = 256;
    private const float MinScore = 0.5f;
    private const float NmsOverlap = 0.3f;
    private const float RoiScale = 1.5f;
    /// <summary>Segmenter classes (selfie_multiclass_256x256).</summary>
    public const int ClassBackground = 0, ClassHair = 1, ClassBodySkin = 2, ClassFaceSkin = 3, ClassClothes = 4, ClassOthers = 5;

    private InferenceSession _detector;
    private InferenceSession _mesh;
    private InferenceSession _segmenter;
    private float[] _anchors = Array.Empty<float>();

    /// <summary>Loads the three models from a res:// folder (read as bytes: works from a packed export too).</summary>
    public bool Load(string folder)
    {
        try
        {
            var options = new SessionOptions { InterOpNumThreads = 1, IntraOpNumThreads = Math.Max(1, System.Environment.ProcessorCount / 2) };
            _detector = new InferenceSession(FileAccess.GetFileAsBytes(folder + "/face_detector.onnx"), options);
            _mesh = new InferenceSession(FileAccess.GetFileAsBytes(folder + "/face_landmarks.onnx"), options);
            _segmenter = new InferenceSession(FileAccess.GetFileAsBytes(folder + "/selfie_multiclass.onnx"), options);
            _anchors = Anchors();
            return true;
        }
        catch (Exception e)
        {
            GD.PushWarning($"FaceDetectNative: models not loaded ({e.Message})");
            return false;
        }
    }

    public bool IsLoaded() => _detector != null && _mesh != null && _segmenter != null;

    // --- images as float RGB ---------------------------------------------------------------------------

    private sealed class Rgb
    {
        public int W, H;
        public float[] Data;  // W * H * 3, 0..255

        public static Rgb From(Image image)
        {
            Image copy = (Image)image.Duplicate();
            if (copy.IsCompressed())
                copy.Decompress();
            copy.Convert(Image.Format.Rgb8);
            byte[] bytes = copy.GetData();
            var rgb = new Rgb { W = copy.GetWidth(), H = copy.GetHeight(), Data = new float[bytes.Length] };
            for (int i = 0; i < bytes.Length; i++)
                rgb.Data[i] = bytes[i];
            return rgb;
        }

        /// <summary>Bilinear sample at pixel coordinates (OpenCV's: pixel centres at integers), 0 outside.</summary>
        public void Sample(double x, double y, float[] into, int at)
        {
            int x0 = (int)Math.Floor(x), y0 = (int)Math.Floor(y);
            double fx = x - x0, fy = y - y0;
            for (int c = 0; c < 3; c++)
            {
                double v00 = Get(x0, y0, c), v10 = Get(x0 + 1, y0, c), v01 = Get(x0, y0 + 1, c), v11 = Get(x0 + 1, y0 + 1, c);
                into[at + c] = (float)((v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy);
            }
        }

        /// <summary>As cv2.resize's linear filter: clamped at the border.</summary>
        public void SampleClamped(double x, double y, float[] into, int at)
        {
            x = Math.Clamp(x, 0.0, W - 1.0);
            y = Math.Clamp(y, 0.0, H - 1.0);
            Sample(x, y, into, at);
        }

        /// <summary>Mean luminance (0..255) of the pixels in [x0, x1) x [y0, y1), 0 when none.</summary>
        public double MeanLuminance(double x0, double y0, double x1, double y1)
        {
            int ax = Math.Max(0, (int)x0), ay = Math.Max(0, (int)y0), bx = Math.Min(W, (int)x1), by = Math.Min(H, (int)y1);
            double sum = 0.0;
            long n = 0;
            for (int y = ay; y < by; y++)
                for (int x = ax; x < bx; x++)
                {
                    int i = (y * W + x) * 3;
                    sum += 0.2126 * Data[i] + 0.7152 * Data[i + 1] + 0.0722 * Data[i + 2];
                    n++;
                }
            return n > 0 ? sum / n : 0.0;
        }

        private double Get(int x, int y, int c)
        {
            if (x < 0 || y < 0 || x >= W || y >= H)
                return 0.0;
            return Data[(y * W + x) * 3 + c];
        }
    }

    // --- the face detector -------------------------------------------------------------------------------

    /// <summary>SSD anchors of BlazeFace short range: strides 8, 16, 16, 16 -> 16x16x2 + 8x8x6 = 896 (centres).</summary>
    private static float[] Anchors()
    {
        var anchors = new List<float>();
        int[] strides = { 8, 16, 16, 16 };
        int i = 0;
        while (i < strides.Length)
        {
            int stride = strides[i];
            int perCell = 0;
            while (i < strides.Length && strides[i] == stride)
            {
                perCell += 2;
                i++;
            }
            int grid = DetectorSize / stride;
            for (int y = 0; y < grid; y++)
                for (int x = 0; x < grid; x++)
                    for (int k = 0; k < perCell; k++)
                    {
                        anchors.Add((x + 0.5f) / grid);
                        anchors.Add((y + 0.5f) / grid);
                    }
        }
        return anchors.ToArray();
    }

    private sealed class Detection
    {
        public double X0, Y0, X1, Y1;  // image pixels
        public double[] Keypoints = new double[12];
        public double Score;
        public int Faces;  // how many distinct faces scored over MinScore (the photo should hold one)
    }

    private Detection Detect(Rgb rgb)
    {
        // Letterboxed into 128 x 128, values in -1..1 (cv2.resize, linear, then a black frame).
        double scale = (double)DetectorSize / Math.Max(rgb.W, rgb.H);
        int nw = (int)Math.Round(rgb.W * scale), nh = (int)Math.Round(rgb.H * scale);
        int px = (DetectorSize - nw) / 2, py = (DetectorSize - nh) / 2;
        var input = new float[DetectorSize * DetectorSize * 3];
        for (int i = 0; i < input.Length; i++)
            input[i] = -1.0f;
        var px3 = new float[3];
        double sx = (double)rgb.W / nw, sy = (double)rgb.H / nh;
        for (int y = 0; y < nh; y++)
            for (int x = 0; x < nw; x++)
            {
                rgb.SampleClamped((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5, px3, 0);
                int at = ((y + py) * DetectorSize + (x + px)) * 3;
                for (int c = 0; c < 3; c++)
                    input[at + c] = px3[c] / 127.5f - 1.0f;
            }
        var tensor = new DenseTensor<float>(input, new[] { 1, DetectorSize, DetectorSize, 3 });
        using var results = _detector.Run(new[] { NamedOnnxValue.CreateFromTensor(_detector.InputMetadata.Keys.First(), tensor) });
        float[] reg = results.First(r => r.Name.StartsWith("regressors")).AsEnumerable<float>().ToArray();
        float[] cls = results.First(r => r.Name.StartsWith("classificators")).AsEnumerable<float>().ToArray();
        int n = cls.Length;
        var score = new double[n];
        int best = 0;
        for (int i = 0; i < n; i++)
        {
            score[i] = 1.0 / (1.0 + Math.Exp(-Math.Clamp(cls[i], -100.0f, 100.0f)));
            if (score[i] > score[best])
                best = i;
        }
        if (score[best] < MinScore)
            return null;
        double[] Box(int i, double[] kp)
        {
            double ax = _anchors[i * 2], ay = _anchors[i * 2 + 1];
            double cx = reg[i * 16] / 128.0 + ax, cy = reg[i * 16 + 1] / 128.0 + ay;
            double w = reg[i * 16 + 2] / 128.0, h = reg[i * 16 + 3] / 128.0;
            for (int k = 0; k < 6; k++)
            {
                kp[k * 2] = reg[i * 16 + 4 + k * 2] / 128.0 + ax;
                kp[k * 2 + 1] = reg[i * 16 + 5 + k * 2] / 128.0 + ay;
            }
            return new[] { cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2 };
        }
        var kpBest = new double[12];
        double[] b0 = Box(best, kpBest);
        var accBox = new double[4];
        var accKp = new double[12];
        double accW = 0.0;
        var kp = new double[12];
        for (int i = 0; i < n; i++)
        {
            if (score[i] <= MinScore)
                continue;
            double[] b = Box(i, kp);
            double ix = Math.Max(0, Math.Min(b[2], b0[2]) - Math.Max(b[0], b0[0])) * Math.Max(0, Math.Min(b[3], b0[3]) - Math.Max(b[1], b0[1]));
            double union = (b[2] - b[0]) * (b[3] - b[1]) + (b0[2] - b0[0]) * (b0[3] - b0[1]) - ix;
            if (ix / union <= NmsOverlap)
                continue;
            for (int k = 0; k < 4; k++)
                accBox[k] += b[k] * score[i];
            for (int k = 0; k < 12; k++)
                accKp[k] += kp[k] * score[i];
            accW += score[i];
        }
        // Distinct faces: anchors over the threshold, best first, each not overlapping a kept one.
        var order = Enumerable.Range(0, n).Where(i => score[i] > MinScore).OrderByDescending(i => score[i]).ToList();
        var kept = new System.Collections.Generic.List<double[]>();
        foreach (int i in order)
        {
            double[] b = Box(i, kp);
            bool overlaps = kept.Any(k =>
            {
                double ix = Math.Max(0, Math.Min(b[2], k[2]) - Math.Max(b[0], k[0])) * Math.Max(0, Math.Min(b[3], k[3]) - Math.Max(b[1], k[1]));
                return ix / ((b[2] - b[0]) * (b[3] - b[1]) + (k[2] - k[0]) * (k[3] - k[1]) - ix) > NmsOverlap;
            });
            if (!overlaps)
                kept.Add(b);
        }
        double ToX(double u) => (u * DetectorSize - px) / scale;
        double ToY(double v) => (v * DetectorSize - py) / scale;
        var d = new Detection
        {
            X0 = ToX(accBox[0] / accW), Y0 = ToY(accBox[1] / accW), X1 = ToX(accBox[2] / accW), Y1 = ToY(accBox[3] / accW), Score = score[best],
            Faces = kept.Count,
        };
        for (int k = 0; k < 6; k++)
        {
            d.Keypoints[k * 2] = ToX(accKp[k * 2] / accW);
            d.Keypoints[k * 2 + 1] = ToY(accKp[k * 2 + 1] / accW);
        }
        return d;
    }

    // --- the face mesh ---------------------------------------------------------------------------------

    private Vector3[] Mesh(Rgb rgb, Detection d)
    {
        // The ROI: a square 1.5 times the box, turned so that the eyes (keypoints 0 and 1) are level.
        double cx = (d.X0 + d.X1) / 2, cy = (d.Y0 + d.Y1) / 2;
        double angle = -Math.Atan2(-(d.Keypoints[3] - d.Keypoints[1]), d.Keypoints[2] - d.Keypoints[0]);
        angle -= 2 * Math.PI * Math.Floor((angle + Math.PI) / (2 * Math.PI));
        double size = Math.Max(d.X1 - d.X0, d.Y1 - d.Y0) * RoiScale;
        double c = Math.Cos(angle), s = Math.Sin(angle), half = size / 2;
        // crop pixel (u, v) -> image: corner (-half, -half) at (0, 0), axes turned by the angle, size / 256 a pixel
        double k = size / MeshSize;
        double ox = cx + (-half) * c - (-half) * s, oy = cy + (-half) * s + (-half) * c;
        double ux = c * k, uy = s * k, vx = -s * k, vy = c * k;
        var input = new float[MeshSize * MeshSize * 3];
        for (int v = 0; v < MeshSize; v++)
            for (int u = 0; u < MeshSize; u++)
            {
                int at = (v * MeshSize + u) * 3;
                rgb.Sample(ox + u * ux + v * vx, oy + u * uy + v * vy, input, at);
                for (int ch = 0; ch < 3; ch++)
                    input[at + ch] /= 255.0f;
            }
        var tensor = new DenseTensor<float>(input, new[] { 1, MeshSize, MeshSize, 3 });
        using var results = _mesh.Run(new[] { NamedOnnxValue.CreateFromTensor(_mesh.InputMetadata.Keys.First(), tensor) });
        float[] raw = results.Select(r => r.AsEnumerable<float>().ToArray()).First(a => a.Length == 478 * 3);
        var points = new Vector3[478];
        for (int i = 0; i < 478; i++)
        {
            double u = raw[i * 3], v = raw[i * 3 + 1];
            points[i] = new Vector3((float)(ox + u * ux + v * vx), (float)(oy + u * uy + v * vy), (float)(raw[i * 3 + 2] * k));
        }
        return points;
    }

    // --- the segmenter ----------------------------------------------------------------------------------

    // A face darker than this (mean luminance of its box's middle, 0..255) is brightened up to it for the segmenter,
    // at most by MaxSegmentGain: on a dim photo it loses the skin (a dark profile: no face skin at all, x2.5 finds it).
    private const double SegmentFaceLuminance = 100.0;
    private const double MaxSegmentGain = 4.0;

    /// <summary>Per pixel of the photo, its class (ClassHair, ClassFaceSkin...), as an L8 image of the photo's size.</summary>
    private Image Segment(Rgb rgb, Detection d)
    {
        var input = new float[SegmenterSize * SegmenterSize * 3];
        double sx = (double)rgb.W / SegmenterSize, sy = (double)rgb.H / SegmenterSize;
        double gain = 1.0 / 255.0;
        double luminance = rgb.MeanLuminance(0.75 * d.X0 + 0.25 * d.X1, 0.75 * d.Y0 + 0.25 * d.Y1, 0.25 * d.X0 + 0.75 * d.X1, 0.25 * d.Y0 + 0.75 * d.Y1);
        if (luminance > 0.0 && luminance < SegmentFaceLuminance)
            gain *= Math.Min(SegmentFaceLuminance / luminance, MaxSegmentGain);
        for (int y = 0; y < SegmenterSize; y++)
            for (int x = 0; x < SegmenterSize; x++)
            {
                int at = (y * SegmenterSize + x) * 3;
                rgb.SampleClamped((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5, input, at);
                for (int ch = 0; ch < 3; ch++)
                    input[at + ch] = (float)Math.Min(input[at + ch] * gain, 1.0);
            }
        var tensor = new DenseTensor<float>(input, new[] { 1, SegmenterSize, SegmenterSize, 3 });
        using var results = _segmenter.Run(new[] { NamedOnnxValue.CreateFromTensor(_segmenter.InputMetadata.Keys.First(), tensor) });
        float[] probs = results.First().AsEnumerable<float>().ToArray();  // 256 x 256 x 6
        var mask = new byte[rgb.W * rgb.H];
        double gx = (double)SegmenterSize / rgb.W, gy = (double)SegmenterSize / rgb.H;
        var p = new double[6];
        for (int y = 0; y < rgb.H; y++)
            for (int x = 0; x < rgb.W; x++)
            {
                double fx = Math.Clamp((x + 0.5) * gx - 0.5, 0.0, SegmenterSize - 1.0), fy = Math.Clamp((y + 0.5) * gy - 0.5, 0.0, SegmenterSize - 1.0);
                int x0 = (int)fx, y0 = (int)fy, x1 = Math.Min(x0 + 1, SegmenterSize - 1), y1 = Math.Min(y0 + 1, SegmenterSize - 1);
                double ax = fx - x0, ay = fy - y0;
                int best = 0;
                for (int ch = 0; ch < 6; ch++)
                {
                    p[ch] = (probs[(y0 * SegmenterSize + x0) * 6 + ch] * (1 - ax) + probs[(y0 * SegmenterSize + x1) * 6 + ch] * ax) * (1 - ay)
                        + (probs[(y1 * SegmenterSize + x0) * 6 + ch] * (1 - ax) + probs[(y1 * SegmenterSize + x1) * 6 + ch] * ax) * ay;
                    if (p[ch] > p[best])
                        best = ch;
                }
                mask[y * rgb.W + x] = (byte)best;
            }
        return Image.CreateFromData(rgb.W, rgb.H, false, Image.Format.L8, mask);
    }

    // --- hair texture --------------------------------------------------------------------------------------

    /// <summary>
    /// How straight a photo's hair runs: the median coherence of the image's structure tensor (gradients' products
    /// blurred at [sigma] pixels) inside the [mask]'s class [cls] eroded [erode] times (its outline left out), on
    /// textured pixels only (blown-out or black hair tells nothing). 1 = parallel strands, low = curls and coils;
    /// -1 when too little hair shows (tools/character/face_survey/hair_measure.py's measure).
    /// </summary>
    public float HairCoherence(Image image, Image mask, int cls, float sigma, int erode)
    {
        if (image == null || mask == null || image.GetSize() != mask.GetSize())
            return -1.0f;
        Rgb rgb = Rgb.From(image);
        int w = rgb.W, h = rgb.H;
        byte[] m = mask.GetData();
        var inside = new bool[w * h];
        for (int i = 0; i < w * h; i++)
            inside[i] = m[i] == cls;
        for (int it = 0; it < erode; it++)
        {
            var next = new bool[w * h];
            for (int y = 1; y < h - 1; y++)
                for (int x = 1; x < w - 1; x++)
                {
                    int i = y * w + x;
                    next[i] = inside[i] && inside[i - 1] && inside[i + 1] && inside[i - w] && inside[i + w]
                        && inside[i - w - 1] && inside[i - w + 1] && inside[i + w - 1] && inside[i + w + 1];
                }
            inside = next;
        }
        var grey = new float[w * h];
        for (int i = 0; i < w * h; i++)
            grey[i] = (0.299f * rgb.Data[i * 3] + 0.587f * rgb.Data[i * 3 + 1] + 0.114f * rgb.Data[i * 3 + 2]) / 255.0f;
        var jxx = new float[w * h];
        var jyy = new float[w * h];
        var jxy = new float[w * h];
        for (int y = 1; y < h - 1; y++)
            for (int x = 1; x < w - 1; x++)
            {
                int i = y * w + x;
                float gx = (grey[i - w + 1] + 2 * grey[i + 1] + grey[i + w + 1]) - (grey[i - w - 1] + 2 * grey[i - 1] + grey[i + w - 1]);
                float gy = (grey[i + w - 1] + 2 * grey[i + w] + grey[i + w + 1]) - (grey[i - w - 1] + 2 * grey[i - w] + grey[i - w + 1]);
                jxx[i] = gx * gx;
                jyy[i] = gy * gy;
                jxy[i] = gx * gy;
            }
        Blur(jxx, w, h, sigma);
        Blur(jyy, w, h, sigma);
        Blur(jxy, w, h, sigma);
        var values = new List<float>();
        for (int i = 0; i < w * h; i++)
        {
            float trace = jxx[i] + jyy[i];
            if (!inside[i] || trace <= 1e-4f)
                continue;
            float root = MathF.Sqrt((jxx[i] - jyy[i]) * (jxx[i] - jyy[i]) + 4.0f * jxy[i] * jxy[i]);
            values.Add(root / Math.Max(trace, 1e-6f));
        }
        if (values.Count <= 200)
            return -1.0f;
        values.Sort();
        return values[values.Count / 2];
    }

    /// <summary>A separable Gaussian blur, in place (edges clamped).</summary>
    private static void Blur(float[] data, int w, int h, float sigma)
    {
        int r = Math.Max(1, (int)Math.Ceiling(3.0f * sigma));
        var k = new float[2 * r + 1];
        float sum = 0.0f;
        for (int i = -r; i <= r; i++)
            sum += k[i + r] = MathF.Exp(-0.5f * i * i / (sigma * sigma));
        for (int i = 0; i < k.Length; i++)
            k[i] /= sum;
        var tmp = new float[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                float v = 0.0f;
                for (int i = -r; i <= r; i++)
                    v += k[i + r] * data[y * w + Math.Clamp(x + i, 0, w - 1)];
                tmp[y * w + x] = v;
            }
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                float v = 0.0f;
                for (int i = -r; i <= r; i++)
                    v += k[i + r] * tmp[Math.Clamp(y + i, 0, h - 1) * w + x];
                data[y * w + x] = v;
            }
    }

    // --- the API ---------------------------------------------------------------------------------------

    /// <summary>
    /// The face on [image]: { "found": bool, "score": float, "faces": int (distinct faces seen), "box": Rect2,
    /// "points": PackedVector3Array (478 landmarks:
    /// x, y in the photo's pixels, z in pixels too, towards the camera negative -- MediaPipe's order), "mask": Image (L8,
    /// the segmenter's classes) }. "found" false when no face scores over 0.5.
    /// </summary>
    public Godot.Collections.Dictionary Detect(Image image, bool segment)
    {
        var result = new Godot.Collections.Dictionary { ["found"] = false };
        if (!IsLoaded() || image == null || image.IsEmpty())
            return result;
        Rgb rgb = Rgb.From(image);
        Detection d = Detect(rgb);
        if (d == null)
            return result;
        result["found"] = true;
        result["score"] = d.Score;
        result["faces"] = d.Faces;
        result["box"] = new Rect2((float)d.X0, (float)d.Y0, (float)(d.X1 - d.X0), (float)(d.Y1 - d.Y0));
        result["points"] = Mesh(rgb, d);
        if (segment)
            result["mask"] = Segment(rgb, d);
        return result;
    }
}
