#!/usr/bin/env python3
"""What the game needs to grow hair on the neutral head itself (HairGroom, scenes/_universe/characters/human):
the scalp and the space around the head.

    python3 tools/character/hair_groom/hair_head.py build/character/human_bank.npz build/character/hair_head.npz

then pack it (tools/character/hair_groom/pack_hair_head.tscn) into assets/_universe/characters/human/hair_head.res.

Writes:
  centre, crown                 the skull's centre (groom.Head) and the hair's whorl (m, neutral head)
  scalp_vertex                  compact head vertices of the scalp's triangles; per one of them:
    scalp_position/normal       where it is and its normal
    scalp_density               how much hair grows there, 0..1 (the hairline's fade, the ears kept bare)
    scalp_above                 how far above the hairline it is (sine of the elevation from the centre):
                                a receding hairline raises that line
    scalp_edge                  how far from the scalp's edge it is (m): the hairline fades in over a width
                                across it -- the elevation alone is no width where the line runs down the temples
  scalp_triangles               triangles over scalp_vertex (positions in it), where roots are drawn
  shell_vertex, shell_uv,       the same triangles at render level (split at UV seams) for a shell of hair
  shell_index, shell_tangent    lifted off the scalp: per render vertex its scalp_vertex position, UV, and
                                reference tangent; triangles over those render vertices
  sdf_origin, sdf_cell,         signed distance (m, > 0 outside) to the head, the neck and the shoulders on a
  sdf_size, sdf                 grid (x fastest), what growing strands stay out of
  beard_vertex, beard_position, the face where a beard may grow (groom.beard_zones), like the scalp: compact
  beard_normal, beard_zones,    vertices, positions, normals, per vertex how much each zone has it -- 4 per
  beard_triangles, beard_shell_ vertex: moustache, chin, cheeks, neck (the jaw zone parted by where the skin
  vertex/uv/index/tangent       faces down) -- triangles, and the same at render level for a shell
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "human_bank"))
from build_human_bank import tangents  # noqa: E402
from groom import EAR_BOX, Head, beard_zones, unit  # noqa: E402

SDF_CELL = 0.008  # m
SDF_BOX = ((-0.27, 1.18, -0.25), (0.27, 1.94, 0.23))  # head, neck and shoulders under long hair (m)
SDF_CLAMP = 0.12
CROWN = (0.012, 0.10, -0.055)
LOW_LINE_ROOM = 0.12  # sine of the elevation: the scalp reaches this far under the bank's line over the forehead
LOW_LINE_AZIMUTH = 1.1  # rad from the front: the forehead's width, in front of the temples
EAR_MARGIN = 0.012  # m: the scalp's edge this near the ears' box is theirs, not the hairline  # the whorl, from the skull's centre (groom.Head.flow "crown")


def main():
    bank = dict(np.load(sys.argv[1], allow_pickle=True))
    head = Head(bank)
    ids = head.face_ids
    u = unit(head.verts - head.centre)
    above = u[:, 1] - head.hairline(np.arctan2(u[:, 0], u[:, 2]))
    keep = head.scalp > 0.0  # above the hairline, the ears left bare
    # Over the forehead, room under the bank's line for a low hairline (HairGroom: HairCut.low_line): the game's
    # line fades in over 2 cm, which the scalp's edge would cut short.
    azimuth = np.abs(np.arctan2(u[:, 0], u[:, 2]))
    keep |= (above > -LOW_LINE_ROOM) & (azimuth < LOW_LINE_AZIMUTH) & np.isin(np.arange(len(head.verts)), ids)
    # Triangles (render level, the face zone) whose three vertices are kept.
    render_tris = head.face_tris[keep[head.face_compact[head.face_tris]].all(1)]
    used_render = np.unique(render_tris)
    scalp_vertex = np.unique(head.face_compact[used_render])
    local = np.full(len(head.verts), -1, np.int64)
    local[scalp_vertex] = np.arange(len(scalp_vertex))
    compact_tris = local[head.face_compact[render_tris]]
    compact_tris = np.unique(np.sort(compact_tris, 1), axis=0)  # seams split a triangle in two render copies
    compact_tris = compact_tris[(compact_tris[:, 0] != compact_tris[:, 1]) & (compact_tris[:, 1] != compact_tris[:, 2])]
    render_local = np.full(len(head.face_render), -1, np.int64)
    render_local[used_render] = np.arange(len(used_render))
    shell_vertex = local[head.face_compact[used_render]]
    shell_uv = head.face_uv[used_render]
    shell_index = render_local[render_tris].reshape(-1)
    pos = head.verts[head.face_compact[used_render]]
    nrm = head.normals[head.face_compact[used_render]]
    shell_tangent = tangents(pos, nrm, shell_uv, shell_index)
    # Distance to the scalp's edge: the vertices of its triangles' unshared sides.
    sides = np.sort(np.concatenate([compact_tris[:, [0, 1]], compact_tris[:, [1, 2]], compact_tris[:, [2, 0]]]), 1)
    uniq, count = np.unique(sides, axis=0, return_counts=True)
    rim = np.unique(uniq[count == 1])
    scalp_pos = head.verts[scalp_vertex]
    # Not around the ears: hair grows thick right up to them (the hairline is the line above the face and nape).
    m = EAR_MARGIN
    by_ear = (np.abs(scalp_pos[rim, 0]) > EAR_BOX[0][0] - m) & (scalp_pos[rim, 1] > EAR_BOX[1][0] - m) \
        & (scalp_pos[rim, 1] < EAR_BOX[1][1] + m) & (scalp_pos[rim, 2] > EAR_BOX[2][0] - m) & (scalp_pos[rim, 2] < EAR_BOX[2][1] + m)
    rim = rim[~by_ear]
    from scipy.spatial import cKDTree
    edge, _ = cKDTree(scalp_pos[rim]).query(scalp_pos)
    # The signed distance grid.
    lo, hi = np.array(SDF_BOX[0]), np.array(SDF_BOX[1])
    size = np.ceil((hi - lo) / SDF_CELL).astype(int) + 1
    zz, yy, xx = np.meshgrid(*[lo[a] + np.arange(size[a]) * SDF_CELL for a in (2, 1, 0)], indexing="ij")
    grid = np.stack([xx.ravel(), yy.ravel(), zz.ravel()], 1)  # x fastest
    sdf = np.empty(len(grid))
    for start in range(0, len(grid), 200000):
        d, _n, _q = head.surface(grid[start:start + 200000])
        sdf[start:start + 200000] = d
    sdf = np.clip(sdf, -SDF_CLAMP, SDF_CLAMP)
    beard = beard_data(head)
    np.savez_compressed(
        sys.argv[2], centre=head.centre.astype(np.float32), crown=(head.centre + np.array(CROWN)).astype(np.float32),
        scalp_vertex=scalp_vertex.astype(np.int32), scalp_position=head.verts[scalp_vertex].astype(np.float32),
        scalp_normal=head.normals[scalp_vertex].astype(np.float32), scalp_density=head.scalp[scalp_vertex].astype(np.float32),
        scalp_above=above[scalp_vertex].astype(np.float32), scalp_edge=edge.astype(np.float32),
        scalp_triangles=compact_tris.reshape(-1).astype(np.int32),
        shell_vertex=shell_vertex.astype(np.int32), shell_uv=shell_uv.astype(np.float32),
        shell_index=shell_index.astype(np.int32), shell_tangent=shell_tangent.astype(np.float32),
        sdf_origin=lo.astype(np.float32), sdf_cell=np.float32(SDF_CELL), sdf_size=size.astype(np.int32),
        sdf=sdf.astype(np.float32), head_bone=np.int32(head.head_bone), **beard)
    print(f"scalp: {len(scalp_vertex)} vertices, {len(compact_tris)} triangles ({len(used_render)} render vertices); "
          f"sdf {size.tolist()} = {len(sdf)} cells -> {sys.argv[2]}")


def surface_part(head, keep):
    """Compact vertices where `keep` (per compact vertex), their triangles (local), and the same at render level."""
    render_tris = head.face_tris[keep[head.face_compact[head.face_tris]].any(1)]
    used_render = np.unique(render_tris)
    vertex = np.unique(head.face_compact[used_render])
    local = np.full(len(head.verts), -1, np.int64)
    local[vertex] = np.arange(len(vertex))
    tris = np.unique(np.sort(local[head.face_compact[render_tris]], 1), axis=0)
    tris = tris[(tris[:, 0] != tris[:, 1]) & (tris[:, 1] != tris[:, 2])]
    render_local = np.full(len(head.face_render), -1, np.int64)
    render_local[used_render] = np.arange(len(used_render))
    uv = head.face_uv[used_render]
    index = render_local[render_tris].reshape(-1)
    pos = head.verts[head.face_compact[used_render]]
    tangent = tangents(pos, head.normals[head.face_compact[used_render]], uv, index)
    return vertex, tris, local[head.face_compact[used_render]], uv, index, tangent


def beard_data(head):
    zones = beard_zones(head)
    jaw = zones["jaw"]
    # Under the jaw: the neck. The front of the lower cheeks faces down a little too (normal y ~ -0.3): kept cheek.
    under = smoothstep_np(-0.45, -0.75, head.normals[:, 1])
    fields = np.stack([zones["moustache"], zones["chin"], jaw * (1.0 - under), jaw * under], 1)
    vertex, tris, shell_vertex, uv, index, tangent = surface_part(head, fields.max(1) > 0.0)
    return {"beard_vertex": vertex.astype(np.int32), "beard_position": head.verts[vertex].astype(np.float32),
            "beard_normal": head.normals[vertex].astype(np.float32), "beard_zones": fields[vertex].astype(np.float32),
            "beard_triangles": tris.reshape(-1).astype(np.int32), "beard_shell_vertex": shell_vertex.astype(np.int32),
            "beard_shell_uv": uv.astype(np.float32), "beard_shell_index": index.astype(np.int32),
            "beard_shell_tangent": tangent.astype(np.float32)}


def smoothstep_np(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


if __name__ == "__main__":
    main()
