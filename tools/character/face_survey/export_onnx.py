#!/usr/bin/env python3
"""MediaPipe's face models as ONNX, for the game's photo-to-character (FaceDetectNative.cs runs them with ONNX
Runtime: no Python, no TensorFlow in the game).

    python export_onnx.py <face_landmarker.task> <selfie_multiclass_256x256.tflite> <out dir>

Extracts the face detector (BlazeFace short range, 128 x 128) and the face mesh (478 landmarks with the irises,
256 x 256) from the task bundle, takes the multiclass selfie segmenter (256 x 256: background, hair, body skin,
face skin, clothes, others), converts each with tf2onnx and checks the ONNX model against the TFLite one on random
inputs (largest difference printed; a conversion over 1e-3 is refused). The blendshapes model is left out: it reads
a subset of 146 landmarks whose indices live in MediaPipe's C++ graph -- the game judges a neutral face from the
landmarks' geometry instead.

Needs Python 3.12 with tensorflow-cpu 2.18, tf2onnx, onnx and onnxruntime (a venv of its own). The models are
MediaPipe's (Apache-2.0): each .onnx gets its credit .txt beside it.
"""
import os
import sys
import tempfile
import zipfile

import numpy as np

MODELS = {  # out name: (file in the task bundle or None for the segmenter, credit line)
    "face_detector": ("face_detector.tflite", "Google MediaPipe - Face Detector (BlazeFace short range) - "
                      "https://ai.google.dev/edge/mediapipe/solutions/vision/face_detector - Apache-2.0"),
    "face_landmarks": ("face_landmarks_detector.tflite", "Google MediaPipe - Face Landmarker (face mesh with irises) - "
                       "https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker - Apache-2.0"),
    "selfie_multiclass": (None, "Google MediaPipe - Selfie multiclass segmentation 256x256 - "
                          "https://ai.google.dev/edge/mediapipe/solutions/vision/image_segmenter - Apache-2.0"),
}
TOLERANCE = 1e-3


def convert(tflite_path, onnx_path):
    import tf2onnx
    tf2onnx.convert.from_tflite(tflite_path, opset=17, output_path=onnx_path)


def check(tflite_path, onnx_path):
    import onnxruntime as ort
    import tensorflow as tf
    interp = tf.lite.Interpreter(model_path=tflite_path)
    interp.allocate_tensors()
    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(0)
    worst = 0.0
    for _ in range(3):
        feeds = {}
        for d, o in zip(interp.get_input_details(), sess.get_inputs()):
            x = rng.uniform(-1.0, 1.0, d["shape"]).astype(np.float32)
            interp.set_tensor(d["index"], x)
            feeds[o.name] = x
        interp.invoke()
        got = dict(zip([o.name for o in sess.get_outputs()], sess.run(None, feeds)))
        for d in interp.get_output_details():  # tf2onnx keeps the outputs' names (with a ':0' at most)
            a = interp.get_tensor(d["index"])
            b = got.get(d["name"], got.get(d["name"] + ":0"))
            if b is None:
                b = next(g for n, g in got.items() if n.split(":")[0] == d["name"].split(":")[0])
            worst = max(worst, float(np.abs(a.reshape(-1) - b.reshape(-1)).max() / max(np.abs(a).max(), 1.0)))
    return worst


def main():
    task, segmenter, out = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        zipfile.ZipFile(task).extractall(tmp)
        for name, (member, credit) in MODELS.items():
            src = os.path.join(tmp, member) if member else segmenter
            dst = os.path.join(out, name + ".onnx")
            convert(src, dst)
            worst = check(src, dst)
            if worst > TOLERANCE:
                os.remove(dst)
                sys.exit(f"{name}: ONNX differs from TFLite by {worst:.2e} (relative) -- refused")
            open(os.path.join(out, name + ".txt"), "w").write(credit + "\n")
            print(f"{name}: {os.path.getsize(dst) / 1e6:.1f} MB, largest relative difference {worst:.1e}")


if __name__ == "__main__":
    main()
