"""MediaPipe Face Landmarker on a FlowHMR video: 52 ARKit blendshapes + head matrix per frame.

The face is small in a full-body shot, so each frame is cropped around the head (from FlowHMR's
person box) and upscaled before detection.
usage: face_capture.py video_30fps.mp4 bbox.npz face_landmarker.task out_dir

Needs `pip install mediapipe opencv-python-headless numpy` (Python 3.9-3.12) and the model
https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
(Apache 2.0). video and bbox are FlowHMR's working files (output/<stem>/<stem>_30fps.mp4, <stem>_bbox.npz).
The scores are named like the character's shape keys; test/animation/face_units_probe.tscn plays
out_dir/face_capture.json with `-- --face=<path>`.
"""
import json
import sys

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks.python import BaseOptions, vision

video, bbox_path, model, out_dir = sys.argv[1:5]
boxes = np.load(bbox_path, allow_pickle=False)["bbox"]

options = vision.FaceLandmarkerOptions(
    base_options=BaseOptions(model_asset_path=model),
    running_mode=vision.RunningMode.VIDEO,
    num_faces=1,
    output_face_blendshapes=True,
    output_facial_transformation_matrixes=True,
)
landmarker = vision.FaceLandmarker.create_from_options(options)

cap = cv2.VideoCapture(video)
fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
frames = []
names = None
frame = 0
CROP = 640
while True:
    ok, img = cap.read()
    if not ok:
        break
    x1, y1, x2, y2 = boxes[min(frame, len(boxes) - 1)][:4]
    half = (y2 - y1) * 0.16
    cx, top = (x1 + x2) / 2, y1 - half * 0.2
    sx0, sy0 = int(max(0, cx - half)), int(max(0, top))
    crop = img[sy0:int(top + 2 * half), sx0:int(cx + half)]
    crop = cv2.resize(crop, (CROP, CROP))
    rgb = cv2.cvtColor(crop, cv2.COLOR_BGR2RGB)
    result = landmarker.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), int(frame * 1000 / fps))
    entry = {"t": frame / fps, "found": bool(result.face_blendshapes)}
    if result.face_blendshapes:
        cats = result.face_blendshapes[0]
        names = names or [c.category_name for c in cats]
        entry["blend"] = [round(c.score, 4) for c in cats]
        entry["matrix"] = np.asarray(result.facial_transformation_matrixes[0]).round(5).tolist()
        if frame % 30 == 6:
            for lm in result.face_landmarks[0]:
                cv2.circle(crop, (int(lm.x * CROP), int(lm.y * CROP)), 1, (0, 255, 255), -1)
            cv2.imwrite(f"{out_dir}/lm_{frame:04d}.jpg", crop)
    frames.append(entry)
    frame += 1

json.dump({"fps": fps, "names": names, "frames": frames}, open(f"{out_dir}/face_capture.json", "w"))
print("frames", frame, "face found", sum(f["found"] for f in frames))
