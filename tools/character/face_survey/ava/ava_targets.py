"""Per Ava-256 frame, the creator's shape sliders fitted straight to its registered mesh (eval_now.oracle), for
each base body: the targets the photo reading learns. python3 -I ava_targets.py <eval_now model dir> <out.json>"""
import sys, os, json, glob, numpy as np
os.environ.setdefault("OMP_NUM_THREADS", "1"); os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))  # eval_now
from multiprocessing import Pool
import eval_now as e
from ava_common import DATA, ROOT, load_ply

MODELS = None
IDX = json.load(open(os.path.join(ROOT, "ava_landmarks7.json")))["mp7_vertices"]
# The registered mesh's outer surface: seen from the front or +-25/45 degrees (no mouth bag, no eyes' insides).
OUTER = np.load(os.path.join(ROOT, "ava_outer.npy"))
# The fit's pull towards the mean face: 0.01 keeps FLAME's directions about real faces' spread (rms 0.66 on NoW's
# scans, none at its bounds) where 0.001 chased the mesh's details with extreme ones (rms 1.44, 7 % at +-3) that
# the reader then learnt -- a pointed nose on a webcam photo.
RIDGE = float(os.environ.get("AVA_RIDGE", "0.01"))


def init(model_dir):
    global MODELS
    MODELS = {b: e.load_model(os.path.join(model_dir, "model_" + b)) for b in e.BASES}


def job(item):
    ident, frame = item
    v = load_ply(f"{DATA}/{ident}/{frame}.ply")
    lmk = v[IDX]
    scan = e.crop(v[OUTER], lmk)
    out = {}
    for base, m in MODELS.items():
        fitted, w = e.oracle(scan, lmk, m, False, ridge=RIDGE)
        out[base] = {"weights": {k: float(x) for k, x in w.items()}, "error": float(np.mean(e.scan_error(scan, fitted, m)))}
    return ident, frame, out


if __name__ == "__main__":
    model_dir, out_path = sys.argv[1], sys.argv[2]
    items = []
    for meta in sorted(glob.glob(DATA + "/*/meta.json")):
        m = json.load(open(meta))
        items += [(m["identity"], f) for f in m["frames"]]
    results = {}
    with Pool(8, initializer=init, initargs=(model_dir,)) as pool:
        for n, (ident, frame, out) in enumerate(pool.imap_unordered(job, items)):
            results.setdefault(ident, {})[frame] = out
            print(n + 1, ident, frame, {b: round(o["error"], 2) for b, o in out.items()}, flush=True)
    json.dump(results, open(out_path, "w"))
