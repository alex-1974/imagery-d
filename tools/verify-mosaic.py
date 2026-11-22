"""Independent rational-cell/linear-sRGB reference for the owned mosaic.

Usage: python tools/verify-mosaic.py tests/feature_program/feature-program-oracle
Test-only numpy; no image library's incompatible alpha/NoData rules are assumed.
"""
from fractions import Fraction
import json
import math
import subprocess
import sys
import numpy as np


def verify(data):
    pyramids = [[(37, 29), (19, 15), (11, 9)],
                [(31, 23), (17, 13), (9, 7)],
                [(23, 19), (13, 11), (7, 5)]]

    def weights(position, source, target, mode):
        if mode == 1:
            return [(int(Fraction(2*position+1, 2*target)*source), Fraction(1))]
        if mode == 2:
            center = max(Fraction(0), min(Fraction(source-1),
                         Fraction(2*position+1, 2*target)*source-Fraction(1, 2)))
            low = math.floor(center)
            fraction = center-low
            return [(low, 1-fraction)] + ([(low+1, fraction)] if fraction else [])
        left, right = Fraction(position*source, target), Fraction((position+1)*source, target)
        return [(i, (min(right, i+1)-max(left, i))/(right-left))
                for i in range(math.floor(left), math.ceil(right))]

    def source_pixel(s, level, x, y):
        encoded = np.array([(x*37+y*19+s*71+level*11) % 256,
                            (x*13+y*43+s*17+level*29) % 256,
                            (x*53+y*7+s*47+level*31) % 256], dtype=float)/255
        alpha = 0 if (x+y+s) % 7 == 0 else ((x*23+y*11+s*41) % 256)/255
        linear = np.where(encoded <= .04045, encoded/12.92, ((encoded+.055)/1.055)**2.4)
        return np.r_[linear*alpha, alpha]

    pixels = 0
    max_byte_error = 0
    for case in data['mosaic_cases']:
        w, h, mode = case['width'], case['height'], case['filter']
        levels = []
        for pyramid in pyramids:
            adequate = [i for i, (sw, sh) in enumerate(pyramid) if sw >= w and sh >= h]
            levels.append(adequate[-1] if adequate else 0)
        assert levels == case['levels']
        assert [pyramids[s][level][0] for s, level in enumerate(levels)] == case['source_widths']
        assert [pyramids[s][level][1] for s, level in enumerate(levels)] == case['source_heights']
        actual = np.array(case['bytes']).reshape(h, w, 5)
        for y in range(h):
            for x in range(w):
                values, masses = [], []
                for s, level in enumerate(levels):
                    sw, sh = pyramids[s][level]
                    taps = [(sx, sy, float(wx*wy))
                            for sx, wx in weights(x, sw, w, mode)
                            for sy, wy in weights(y, sh, h, mode)]
                    valid = all((sx*3+sy*5+s) % 17 != 0 and
                                ((sx//(4+s))+2*(sy//(3+s))+s) % 13 != 6
                                for sx, sy, _ in taps)
                    valid &= (x+y+s) % 11 != 0
                    mass = (.25+.25*((x+s) % 4))*(.2+.2*((y+s) % 5))*(1+s) if valid else 0
                    masses.append(mass)
                    values.append(sum((source_pixel(s, level, sx, sy)*weight
                                       for sx, sy, weight in taps), np.zeros(4)))
                total = math.fsum(masses)
                mixed = sum((value*(mass/total) for value, mass in zip(values, masses)), np.zeros(4)) if total else np.zeros(4)
                alpha = min(1., max(0., mixed[3]))
                rounded_alpha = math.floor(alpha*255+.5)
                encoded = np.zeros(3)
                if rounded_alpha:
                    linear = np.clip(mixed[:3], 0, alpha)/alpha
                    encoded = np.where(linear <= .0031308, linear*12.92, 1.055*linear**(1/2.4)-.055)
                unrounded = np.r_[encoded*255, alpha*255]
                expected = np.r_[np.floor(unrounded+.5), int(total > 0)]
                difference = abs(actual[y, x]-expected)
                assert difference[4] == 0, (w, h, mode, x, y, 'validity')
                for c in range(4):
                    if difference[c]:
                        # Different summation/transfer rounding may choose either
                        # adjacent byte ONLY at a quantizer's exact half boundary.
                        assert difference[c] == 1 and abs((unrounded[c] % 1)-.5) < 1e-10, (
                            w, h, mode, x, y, c, actual[y, x], expected, unrounded)
                max_byte_error = max(max_byte_error, int(max(difference)))
                pixels += 1
    assert len(data['mosaic_cases']) == 19
    assert data['mosaic_partition_pixels'] == pixels
    assert data['mosaic_failure_checks'] >= 20
    assert data['mosaic_peak_work_bytes'] == 6_029_952
    print(f"Mosaic: 19 rational/linear-sRGB cases, {pixels} pixels; max byte error={max_byte_error}; "
          f"exact partition/layout equality, {data['mosaic_failure_checks']} failure/ownership checks")


if __name__ == '__main__':
    verify(json.loads(subprocess.check_output([sys.argv[1], '--mosaic'], text=True)))
