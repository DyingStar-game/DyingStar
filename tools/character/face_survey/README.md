# Face survey (FFHQ)

Measures real adult faces to learn what the character creator lacks and how skins vary. The photos and
everything measured per photo stay in `~/datasets/ffhq/`, never in this repository: only aggregate results
(distributions, principal axes, new shape keys learnt over thousands of faces) may come in, credited.

FFHQ (NVIDIA) and its labels (DCGM/ffhq-features-dataset) are CC BY-NC-SA 4.0, like our assets. FFHQ must
not serve face recognition: nothing here identifies anyone.

## Data

```bash
cd ~/datasets/ffhq
# labels and metadata: features/ (git clone DCGM/ffhq-features-dataset), ffhq-dataset-v2.json (gdown)
# keep.txt: adults (estimated age >= 20), no glasses, |yaw| < 25, |pitch| < 20, sharp, eyes and mouth visible
.venv/bin/python tools/fetch_adults.py --threads 8   # the kept images, from the HF mirror marcosv/ffhq-dataset
```

## Pipeline

1. `render_heads.tscn` renders baked heads unskinned (bank space) through an orthographic camera, with
   their true target weights beside each PNG: `--looks=<file>` (`neutral`, or encoded looks) or
   `--random=N --seed=S` (training faces: every face slider moved, pose and light varied).
2. `landmarks.py` (MediaPipe venv): 478 landmarks, 52 expression scores, pose, per image.
3. `correspond.py`: where each landmark lies on the neutral head (from its render).
4. `fit.py`: fits sliders to landmarks directly. `--truth` scores it on our own renders: MediaPipe's
   landmarks are too loose for that (their error is as large as the difference between two faces).
5. `regress.py train` learns, on the random renders, landmarks -> dense face shape (ridge on its principal
   components); `regress.py apply` predicts photos' shapes, fits the sliders to them and keeps what the
   sliders cannot make (the residual: what the creator lacks).
   `regress.py train-views` does it over the same faces seen from the front and turned (`render_heads.tscn
   --random=2000 --flame --seed=7 --size=512`, then again with `--yaw=40` and `--yaw=-40`: the same seed, the
   same faces; also `--yaw=75` and `--yaw=-75` for true profiles, which MediaPipe finds on about half the faces):
   one regression per set of views holding the front, one turned view a side. On held-out FLAME faces: 1.80 mm
   from the front alone, 1.25 mm with a side at 40 degrees, 1.37 mm with a profile, 1.10 mm with both sides at 40
   (2.97 mm for the mean face). `pack_face_fit.tscn
   -- --npz=corr.npz --model=model_views.npz` ships it in `face_fit.res`, for the game's photo-to-character
   (`FaceFit`: the learned shape, the sliders fitted to it, then the landmark fit for the expression and pose).
6. `skin_measure.py`: relative skin numbers per photo (tone, redness, shadows, spots, creases, evenness).
7. `measure_beards.tscn` + `beard_model.py`: the game's beard reading (`PhotoBeard`). The segmenter takes a beard
   for skin, so `PhotoBeard.measure` reads, in five zones (moustache, chin, cheeks, sideburns, neck), how much
   darker, less coloured and finer-textured they are than the upper cheeks; `beard_model.py` learns ridge
   regressions from those to FFHQ's facial hair labels (features/json, Azure's moustache / beard / sideburns), one
   from every measure for whether there is facial hair and one per zone from that zone's own (the labels go
   together, so only that tells a moustache from a beard), and writes their coefficients to `beard_model.json`.
   On 5 700 front photos (every bearded man, as many stubbled and shaven, 500 women), held out: facial hair or
   not AUC 0.94 (0.92 among men), MAE 0.11 on the labels' 0..1 (0.20 guessing their mean); the neck's measures
   tell nothing (the neck follows the beard's length).
8. Real faces, not our renders: `eval_now.tscn` + `eval_now.py` measure the photo-to-character's shapes against
   the NoW benchmark's scans (now.is.tue.mpg.de, after registering; its evaluation redone without the MPI
   libraries: crop, 7-landmark alignment, rigid ICP, scan-to-mesh distance; `metrical` keeps the face's size).
   On its 20 validation people (metrical, mean per person): the sliders fitted straight to the scans 0.71 mm (they
   can make real faces), the base face 1.96, the learned shape from the front 2.13 and from the front and both
   sides 2.12 (worse than nothing: learnt on our renders, it does not carry to real photos), the landmark fit
   alone from the front 1.78 (the game's since), with the sides 1.85. `eval_multiview.tscn` + `eval_multiview.py`
   ask the same without scans on the FEI face database (fei.edu.br/~cet: 200 people from profile to profile): how
   alike one person's shapes from separate photos are, and how well a shape explains a side photo it did not see.
9. The slider reader learnt on real faces (`ava/`): Ava-256 (Meta, CC BY-NC 4.0, github.com/facebookresearch/ava-256:
   256 people, a dome of calibrated cameras, a tracked 3D mesh per frame). `ava/fetch.py` takes only what is
   needed by HTTP range reads of its zips (626 MB, not the 4 TB package): per person two neutral frames
   (`EXP_neutral_peak`) seen from the front and about 45 degrees each way, with their meshes, head poses and
   cameras. `dump_landmarks.tscn` reads MediaPipe's landmarks on the photos as the game does; `ava/ava_prepare.py`
   places NoW's 7 alignment landmarks on Ava's topology and keeps its outer surface (no mouth bag); `ava/ava_targets.py`
   fits the creator's sliders to every mesh, for the man's and the woman's base (`eval_now.oracle`: 0.81 mm);
   `ava/ava_learn.py` learns a ridge from the photos' landmarks (aligned per view as `FaceFitNative.Read` does) to
   those sliders, per base and set of views, judges it on NoW (independent people) and `--export`s it for
   `pack_face_fit.tscn --reader=`. On NoW (metrical, 20 people): the reader alone 1.72 mm from the front, 1.64
   with both sides; half the reader and half the landmark fit (the game's, `FaceFitData.reader_blend`) 1.61 from
   the front, 1.59 with the sides -- against 1.78 for the landmark fit alone and 1.96 for the base face.
   The targets are fitted with a ridge of 0.01 (`AVA_RIDGE`) over FaceFit's keys, the creator's nine nose sliders
   among them: with 0.001 FLAME's directions chased the meshes' details (rms 1.44 on NoW's scans, 7 % at their
   bounds) and the reader learnt those extremes -- a pointed nose on a webcam photo; the nose sliders bring the
   nose's error on the scans from 0.89 to 0.73 mm. With them: NoW 1.68 mm for the reader alone from the front,
   1.61 half and half.
10. The nose's bridge (`ava/ava_dorsum.py`): our nose sliders move the bridge's top or the whole lower nose, never its
    middle, so a hump or a scooped bridge was made of steps. `modes` measures, on Ava-256's meshes, the middle
    outline along the bridge minus our head's whose sliders were fitted to that mesh: the misses' first two
    directions (40 % and 21 % of their variance: a hump at the bridge's lower half, 0.83 mm a deviation; the bridge
    fuller at its top than at its bottom, 0.60 mm) go to `dorsum_modes.json`; `bank` makes them the shape keys
    `Nose_Dorsum_Hump` and `Nose_Dorsum_Curve` (3 deviations at a slider's end), then the bank is packed again.
    Only a profile shows them: read from the front or the 45-degree sides (learnt on Ava-256) they help nothing
    (NoW 1.61 mm from the front, 1.64 instead of 1.59 with the sides), so `FaceFit.PROFILE_KEYS` keeps them out of
    the reader; fitted to a NoW scan's own side outline they bring the nose from 1.45 to 1.30 mm (the nine older
    nose sliders fitted the same way made it worse, 1.67-2.13: they change its width too).
11. The profile photo (the creator's fourth, optional): `PhotoProfile.measure` reads the face's edge row by row from
    the segmenter's mask (person against background, kept where it is skin), the rows and the scale from the face
    detector's box -- MediaPipe's landmarks are loose on a true profile, all of them by the eye on some; the
    segmenter is fed a dim face brightened (`FaceDetectNative.Segment`), or it loses the skin. On Ava-256's 75 and
    90 degree views (`ava/fetch.py --profiles`, `dump_landmarks.tscn --profile`) that edge lies 0.3-2 px from the
    mesh's own silhouette. `FaceFit.fit_profile` (C#: `FaceFitNative.FitProfile`) lays it on our head's side outline
    by the forehead, lips and chin (a trimmed ICP by a 2D similarity, the best of a few views and starting scales),
    then moves the bridge's keys (`PROFILE_KEYS`) so that the nose's outline follows it. `profile_fit.py` is its
    prototype and judge on NoW (19 people with a real profile): the nose 1.445 -> 1.37 mm, the face 1.565 -> 1.56,
    15 of 19 better or alike (the scan's own outline: 1.30); the nine older nose sliders fitted the same way made it
    worse. `ava/ava_profile.py` asked the same of a reader learnt on Ava's profiles: barely better (1.43).

## What a player can make (creator survey)

Where the creator's sliders must stop: looks made the way a player makes them, judged by eye.

1. `creator_survey.tscn -- --subject=face|body --out=DIR --from=1 --count=N` (GPU, not `--headless`): each sample
   is a `CharacterAppearance.random()` look plus a few gestures on the creator's own controls (face: detail
   sliders, overall axes, origins; body: gender, age, height, body sliders, origins), drawn over their whole
   travel, rendered through the creator's preview. One id in ten is an untouched control. Faces are seen front and
   three-quarter; bodies front and side, without garments (the tool strips them from the bake: the game always
   dresses a look). `samples.json` holds each sample's gestures and final sliders.
2. `clip_judge.py DIR --subject face|body` (torch + open_clip, outside the project: `~/datasets/clip/.venv`):
   a zero-shot guess per sample, its threshold set on the controls, and the age CLIP reads -> `clip.json`.
3. `random_faces_sheets.py DIR --subject face|body --out SHEETS --prefix face|body`: contact sheets for the
   rating page, where the guesses are corrected by hand.
   `--sweep=0.4,0.7,1` moves one control per sample instead (every control, both ways, each level);
   `--combos=mouth,eyes --levels=0.5,1,1.5,2,3` moves 2 to 5 sliders of one tab together, at a set sum of squares.
   400 samples is what one rating session gets through. CLIP disagreed with the eye on 75 of 78 corrected faces
   (2026-11-20): later series start every sample OK and are rated by hand alone.
4. `fit_limits.py --series DIR:VERDICTS[:clip] ... --target 0.03` -> `creator_limits.json`, read by `CreatorLimits`:
   a face's load (per tab, a weight times the sum of its sliders' squares) and the budget the creator holds it to.
   On the European series (1 200 faces): one slider alone broke 4 faces in 399; together, the mouth's weigh most
   (1), then the eyes' (0.5), the jaw's (0.28), the nose's, the skull's, the ears' hardly; FLAME's none.
   `--direction Mouth_Lips_LowerAngle:-` gives one slider, one way, a weight of its own: the counter-survey (series 3's
   faces and gestures, under the limits: `creator_survey --limits=1`) still had 7 of its 12 rejects there. Snapshot
   the verdicts (ArtifactData `out_dir`) before each fit, and never rewrite a stored look: to relax, refit with a
   higher `--target` or lower `CreatorLimits.strength`.
