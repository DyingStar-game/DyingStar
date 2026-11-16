"""FLAME 2023 Open (Max Planck Institute for Intelligent Systems, CC BY 4.0, https://flame.is.tue.mpg.de), read
from its .pkl -- only plain arrays: numpy arrays and one scipy sparse matrix (checked with pickletools).

T. Li, T. Bolkart, M. J. Black, H. Li, J. Romero: Learning a model of facial shape and expression from 4D scans.
ACM Transactions on Graphics (Proc. SIGGRAPH Asia), 2017.

Only the neutral pose is used here (no joints): the template plus identity and expression offsets. Identity
coefficients are in standard deviations (the shape directions carry their spread), as are expression ones.
"""
import pickle

import numpy as np

IDENTITY = 300  # the first 300 shape directions; the last 100 are expression (supr_expression_metadata)


class Flame:
    def __init__(self, path):
        with open(path, "rb") as f:
            m = pickle.load(f, encoding="latin1")
        self.template = np.asarray(m["v_template"], dtype=np.float64)
        self.faces = np.asarray(m["f"], dtype=np.int64)
        dirs = np.asarray(m["shapedirs"], dtype=np.float64)
        self.identity = dirs[:, :, :IDENTITY]
        self.expression = dirs[:, :, IDENTITY:]
        # The head and the two eyeballs are separate pieces of the mesh.
        import scipy.sparse as sp
        import scipy.sparse.csgraph as cg
        n = len(self.template)
        a = sp.coo_matrix((np.ones(self.faces.size), (self.faces.ravel(), np.roll(self.faces, 1, 1).ravel())), shape=(n, n))
        _count, label = cg.connected_components(a, directed=False)
        sizes = np.bincount(label)
        head = np.argmax(sizes)
        self.part = np.where(label == head, 0, -1)
        for other in [i for i in range(len(sizes)) if i != head]:
            side = 1 if self.template[label == other, 0].mean() > 0 else 2  # 1: the eye at +x
            self.part[label == other] = side

    def shape(self, identity=None, expression=None):
        v = self.template.copy()
        if identity is not None:
            v += self.identity[:, :, :len(identity)] @ identity
        if expression is not None:
            v += self.expression[:, :, :len(expression)] @ expression
        return v
