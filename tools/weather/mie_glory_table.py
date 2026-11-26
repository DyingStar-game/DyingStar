#!/usr/bin/env python3
"""Colour tables of the dust sea's glory and iridescence, from the Mie theory of its grains.

The dust sea of Sandbox is made of corundum grains (real refractive index 1.77, nearly white). Seen
from above, around the shadow of the eye's head (the antisolar point), sunlit grains of one size send
back coloured rings: the glory. Near the sun, the thin edges of the sea are fringed with colours by
the forward lobe of the same grains: the iridescence. Both come out of the angular scattering
of each grain (Mie), averaged over the sizes of the grains.

This script computes, for three wavelengths (red, green, blue), the scattered intensity at angles
near the sun (forward, 0..FORE_DEG) and near the antisolar point (backward, 180 - BACK_DEG..180),
averaged over a lognormal distribution of radii, and writes its COLOUR alone: each channel over the
luminance at that angle (brightness kept, so the shader's own phase stays the brightness). Two files:

  scenes/_universe/environment/dust_sea_mie.gdshaderinc   (const arrays for dust_sea.gdshaderinc)
  scenes/weather/dust_sea_mie.gd                           (the same numbers for GDScript: tests, probe)

Run from the game's root:  python3 tools/weather/mie_glory_table.py
Standard library only. The Mie series is Bohren & Huffman's (BHMIE, 1983).

The grains: the atmosphere model's fine class (services weather, data/atmosphere/defaut.toml:
diameter 1.5 um, mie_sigma_g 1.5, n 1.77). A distribution that wide washes most of the colour out:
the image uses a narrower one (SIGMA_G below), the bright grains of the sea's top sorted by the
settling (an IMAGE choice; see the docstring of SIGMA_G).
"""

import cmath
import math
import os

# The grains (see the module docstring).
DIAMETER_M = 1.5e-6
REFRACTIVE_INDEX = complex(1.77, 1e-4)
# The width of the size distribution the tables are averaged over. The model's 1.5 leaves a pale
# glory; 1.15 (the coarser grains settled out of the top, the finest carried away) gives the two or
# three coloured rings of the reference image (bitogno's "mer blanche et reflets arc-en-ciel").
SIGMA_G = 1.15
# Red, green and blue (m): the centres of the sRGB primaries.
WAVELENGTHS_M = (0.65e-6, 0.55e-6, 0.45e-6)
LUMINANCE = (0.2126, 0.7152, 0.0722)
# The two lobes, in degrees from the sun (forward) and from the antisolar point (backward), and
# the samples across each.
FORE_DEG = 20.0
BACK_DEG = 20.0
SAMPLES = 64
# Where each lobe starts fading to white (share of its span): the iridescence fades over its outer half (at
# 0.8 its orange ring ended in a hard edge 18 deg from the sun, a disc pasted on the sky: the user, 2026-11-26).
FORE_FADE = 0.5
BACK_FADE = 0.8
# Radii the distribution is integrated over (+-3 ln sigma_g, trapezoid in ln r).
RADIUS_NODES = 41


def bhmie_s11(x, m, angles_rad):
    """|S1|^2 + |S2|^2 / 2 (the unpolarised intensity) at each angle, for a sphere of size
    parameter x and refractive index m (Bohren & Huffman, appendix A)."""
    nstop = int(x + 4.05 * x ** (1.0 / 3.0) + 2.0)
    y = m * x
    nmx = int(max(nstop, abs(y)) + 15)
    d = [0j] * (nmx + 1)
    for n in range(nmx, 0, -1):
        d[n - 1] = n / y - 1.0 / (d[n] + n / y)
    mus = [math.cos(a) for a in angles_rad]
    pi0 = [0.0] * len(mus)
    pi1 = [1.0] * len(mus)
    s1 = [0j] * len(mus)
    s2 = [0j] * len(mus)
    psi0, psi1 = math.cos(x), math.sin(x)
    chi0, chi1 = -math.sin(x), math.cos(x)
    xi1 = complex(psi1, -chi1)
    for n in range(1, nstop + 1):
        fn = (2.0 * n + 1.0) / (n * (n + 1.0))
        psi = (2.0 * n - 1.0) * psi1 / x - psi0
        chi = (2.0 * n - 1.0) * chi1 / x - chi0
        xi = complex(psi, -chi)
        an = ((d[n] / m + n / x) * psi - psi1) / ((d[n] / m + n / x) * xi - xi1)
        bn = ((d[n] * m + n / x) * psi - psi1) / ((d[n] * m + n / x) * xi - xi1)
        for j, mu in enumerate(mus):
            pi = pi1[j]
            tau = n * mu * pi - (n + 1.0) * pi0[j]
            s1[j] += fn * (an * pi + bn * tau)
            s2[j] += fn * (an * tau + bn * pi)
            pi1[j] = ((2.0 * n + 1.0) * mu * pi - (n + 1.0) * pi0[j]) / n
            pi0[j] = pi
        psi0, psi1 = psi1, psi
        chi0, chi1 = chi1, chi
        xi1 = complex(psi1, -chi1)
    return [0.5 * (abs(a) ** 2 + abs(b) ** 2) for a, b in zip(s1, s2)]


def distribution_intensity(wavelength, angles_rad):
    """The intensity at each angle averaged over the lognormal radii (weighted by number), for
    the effective diameter DIAMETER_M: median radius r_g = r_eff exp(-2.5 ln^2 sigma_g)."""
    ls = math.log(SIGMA_G)
    r_g = 0.5 * DIAMETER_M * math.exp(-2.5 * ls * ls)
    total = [0.0] * len(angles_rad)
    for i in range(RADIUS_NODES):
        u = -3.0 + 6.0 * i / (RADIUS_NODES - 1)
        weight = math.exp(-0.5 * u * u) * (0.5 if i in (0, RADIUS_NODES - 1) else 1.0)
        r = r_g * math.exp(u * ls)
        s11 = bhmie_s11(2.0 * math.pi * r / wavelength, REFRACTIVE_INDEX, angles_rad)
        for j, v in enumerate(s11):
            # S11 is per unit of (k^2): over wavelengths, the intensity goes as S11 lambda^2.
            total[j] += weight * v * wavelength * wavelength
    return total


def colour_table(angles_rad):
    """For each angle, (r, g, b) / luminance: the colour of the scattered light, brightness 1."""
    per = [distribution_intensity(w, angles_rad) for w in WAVELENGTHS_M]
    # One white for the whole lobe: the mean of each channel over it.
    means = [sum(c) / len(c) for c in per]
    rows = []
    for j in range(len(angles_rad)):
        rgb = [per[c][j] / means[c] for c in range(3)]
        lum = sum(LUMINANCE[c] * rgb[c] for c in range(3))
        rows.append(tuple(v / lum for v in rgb))
    return rows


def write(root):
    fore = [math.radians(FORE_DEG * (i + 0.5) / SAMPLES) for i in range(SAMPLES)]
    back = [math.pi - math.radians(BACK_DEG * (i + 0.5) / SAMPLES) for i in range(SAMPLES)]
    fore_rows = colour_table(fore)
    back_rows = colour_table(back)

    def vecs(rows, fmt):
        return ",\n".join("\t" + fmt % r for r in rows)

    head = ("Generated by tools/weather/mie_glory_table.py (Mie, corundum n %.2f, effective diameter %.1f um, "
            "sigma_g %.2f): do not edit by hand." % (REFRACTIVE_INDEX.real, DIAMETER_M * 1e6, SIGMA_G))
    shader = os.path.join(root, "scenes", "_universe", "environment", "dust_sea_mie.gdshaderinc")
    with open(shader, "w", newline="\n") as f:
        f.write("// " + head + "\n")
        f.write("// The colour (r, g, b over the luminance) of the light the dust sea's grains scatter near the sun\n")
        f.write("// (SEA_MIE_FORE, %d samples from 0 to %.0f deg) and near the antisolar point (SEA_MIE_BACK, from 0\n"
                % (SAMPLES, FORE_DEG))
        f.write("// to %.0f deg away from it): the iridescence and the glory. Sample i is at (i + 0.5) / %d of the lobe.\n\n"
                % (BACK_DEG, SAMPLES))
        f.write("const float SEA_MIE_FORE_DEG = %.1f;\n" % FORE_DEG)
        f.write("const float SEA_MIE_BACK_DEG = %.1f;\n" % BACK_DEG)
        f.write("const int SEA_MIE_SAMPLES = %d;\n" % SAMPLES)
        f.write("const float SEA_MIE_FORE_FADE = %.2f;\n" % FORE_FADE)
        f.write("const float SEA_MIE_BACK_FADE = %.2f;\n\n" % BACK_FADE)
        f.write("const vec3 SEA_MIE_FORE[%d] = {\n%s\n};\n\n" % (SAMPLES, vecs(fore_rows, "vec3(%.4f, %.4f, %.4f)")))
        f.write("const vec3 SEA_MIE_BACK[%d] = {\n%s\n};\n" % (SAMPLES, vecs(back_rows, "vec3(%.4f, %.4f, %.4f)")))
    script = os.path.join(root, "scenes", "weather", "dust_sea_mie.gd")
    with open(script, "w", newline="\n") as f:
        f.write("class_name DustSeaMie\nextends RefCounted\n")
        f.write("## " + head + "\n")
        f.write("## The same tables as dust_sea_mie.gdshaderinc: the colour of the light the dust sea's grains scatter\n")
        f.write("## near the sun (FORE, the iridescence) and near the antisolar point (BACK, the glory), brightness 1.\n\n")
        f.write("const FORE_DEG: float = %.1f\n" % FORE_DEG)
        f.write("const BACK_DEG: float = %.1f\n" % BACK_DEG)
        f.write("const SAMPLES: int = %d\n" % SAMPLES)
        f.write("const FORE_FADE: float = %.2f\n" % FORE_FADE)
        f.write("const BACK_FADE: float = %.2f\n" % BACK_FADE)
        f.write("const FORE: Array[Vector3] = [\n%s,\n]\n" % vecs(fore_rows, "Vector3(%.4f, %.4f, %.4f)"))
        f.write("const BACK: Array[Vector3] = [\n%s,\n]\n\n\n" % vecs(back_rows, "Vector3(%.4f, %.4f, %.4f)"))
        f.write(TINT_GD)
    return fore_rows, back_rows


# The lookup, written once for GDScript; dust_sea.gdshaderinc has its own copy (sea_mie_tint).
TINT_GD = '''## The colour of the light scattered at [param cos_sun] (cosine of the angle between the view and the sun's
## direction, both pointing away from the eye): the forward lobe [param fore_strength] of the way from white,
## the glory [param back_strength] of it; white outside the lobes.
static func tint(cos_sun: float, fore_strength: float, back_strength: float) -> Vector3:
	var angle: float = rad_to_deg(acos(clampf(cos_sun, -1.0, 1.0)))
	if angle < FORE_DEG:
		return Vector3.ONE.lerp(_sample(FORE, angle / FORE_DEG, FORE_FADE), fore_strength)
	if 180.0 - angle < BACK_DEG:
		return Vector3.ONE.lerp(_sample(BACK, (180.0 - angle) / BACK_DEG, BACK_FADE), back_strength)
	return Vector3.ONE


## The table [param rows] at [param u] (0..1 across its lobe), linear between samples, faded to white from
## [param fade] of the lobe to its end so nothing shows a seam.
static func _sample(rows: Array[Vector3], u: float, fade: float) -> Vector3:
	var f: float = clampf(u * SAMPLES - 0.5, 0.0, SAMPLES - 1.0)
	var i: int = mini(int(f), SAMPLES - 2)
	var c: Vector3 = rows[i].lerp(rows[i + 1], f - i)
	return c.lerp(Vector3.ONE, smoothstep(fade, 1.0, u))
'''


def main():
    # Optional argument: another root to write into (a dry run), the game's root by default.
    import sys
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    fore, back = write(root)
    for name, rows, span in (("fore", fore, FORE_DEG), ("back", back, BACK_DEG)):
        print(name)
        for i in range(0, SAMPLES, 8):
            print("  %5.2f deg  %s" % (span * (i + 0.5) / SAMPLES, " ".join("%.2f" % v for v in rows[i])))


if __name__ == "__main__":
    main()
