# FLAME 2023 Open -> the character bank

Carries the identity directions of FLAME 2023 Open (Max Planck Institute for Intelligent Systems, CC BY 4.0,
https://flame.is.tue.mpg.de) onto the Vitruvian head: shape keys `FLAME_Identity_00..` of the bank, each one standard
deviation of real faces (learnt from ~3 800 3D scans). Only these derived keys ship (in `human_bank.res`); the FLAME
file itself is never in the repository. Only the **Open** version may be used: the other FLAME releases are
non-commercial and forbid distribution. Its licence also forbids pornographic use and "fake, libelous, misleading or
defamatory" content: no preset may reproduce a real person.

Please cite: T. Li, T. Bolkart, M. J. Black, H. Li, J. Romero. Learning a model of facial shape and expression from
4D scans. ACM Transactions on Graphics (Proc. SIGGRAPH Asia), 2017.

## Regenerate

Download `FLAME2023Open.zip` from the FLAME site (an account and the licence's acceptance are needed), unzip
`flame2023_Open.pkl` into `~/datasets/flame/`. With the PyTorch venv (`~/datasets/ffhq/.torch`) and the MediaPipe one
(`~/datasets/ffhq/.mp`), from the project root, after the bank is built (tools/character/vitruvian/README.md):

```bash
F=~/datasets/flame
.torch/bin/python tools/character/flame/register_flame.py render $F/flame2023_Open.pkl $F/render
.mp/bin/python tools/character/face_survey/landmarks.py face_landmarker.task $F/flame_lm.npz $F/render/flame_00000.png
# corr.npz: the same landmarks on our neutral head (tools/character/face_survey/README.md, steps 1-3)
.torch/bin/python tools/character/flame/register_flame.py fit $F/flame2023_Open.pkl build/character/human_bank.npz corr.npz $F/flame_lm.npz $F/registration.npz
python3 tools/character/flame/transfer_flame.py $F/flame2023_Open.pkl $F/registration.npz build/character/human_bank.npz . --count 50
# then pack the bank (pack_human_bank.tscn)
```

`register_flame.py fit` lays FLAME on our neutral head (MediaPipe landmarks found on both renders, and our skin's
distance to its surface): ~1 mm at the landmarks, 1.6 mm median skin distance. `transfer_flame.py` ties each of our
head's vertices to the nearest vertices of the laid FLAME (the eyes to their eyeball), carries each identity direction
over, and fades it to nothing at the head/body join. A slider of the creator reaches 3 deviations
(CharacterAppearance.FLAME_RANGE).
