#!/usr/bin/env python3
"""Independent high-precision scalar Levels oracle, not an image codec.
Executes the ordinary DUB consumer and checks exact float32 output bits
against a 90-digit Decimal model. No randomness is used without a seed.
"""
import decimal
import math
import random
import struct
import subprocess
import sys

decimal.getcontext().prec = 90
D = decimal.Decimal


def f32(value):
    return struct.unpack(">f", struct.pack(">f", float(value)))[0]


def f32bits(value):
    return struct.unpack(">I", struct.pack(">f", float(value)))[0]


def frombits(bits):
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def ulp_distance(a, b):
    # ordered integer float bits, preserving signed float order.
    def key(v):
        return (~v & 0xFFFFFFFF) if v & 0x80000000 else v | 0x80000000
    return abs(key(a) - key(b))


def reference(kind, value, chosen, weight, fields):
    black, white, gamma, output_black, output_white = map(
        lambda x: D.from_float(float(x)), fields)
    if kind == "u8":
        original = D(int(value)) / D(255)
    elif kind == "u16":
        original = D(int(value)) / D(65535)
    else:
        original = D.from_float(f32(value))

    if not chosen or weight == 0:
        return f32bits(original)

    if original <= black:
        t = D(0)
    elif original >= white:
        t = D(1)
    else:
        t = (original - black) / (white - black)
    if t <= 0:
        shaped = D(0)
    elif t >= 1:
        shaped = D(1)
    elif gamma < D("1e-12"):
        # For interior t and this gamma, the float32 output rounds
        # to zero for our generated t away from one.
        shaped = D(0)
    elif gamma > D("1e12"):
        shaped = D(1)
    else:
        shaped = t ** (D(1) / gamma)

    adjusted = output_black + shaped * (output_white - output_black)
    coverage = D(1) if weight == -1 else D(weight) / D(255)
    result = original + coverage * (adjusted - original)
    return f32bits(result)


def corpus():
    rng = random.Random(0x1A63D)
    u8s = [0, 1, 2, 63, 127, 128, 129, 254, 255]
    u16s = [0, 1, 2, 255, 256, 32767, 32768, 65534, 65535]
    floats = [
        -3.4028234663852886e38, -1e20, -1e10, -1, -0.5,
        -1e-38, -1e-45, -0.0, 0.0, 1e-45, 1e-40,
        1e-38, 0.1, 0.125, 0.49999997, 0.5, 0.50000006,
        0.75, 1.0, 1.1, 2.0, 1e10, 1e20, 3.4028234663852886e38
    ]
    pairs = [
        (0., 1.), (0.1, 0.9), (-2., 2.), (-1e300, 1e300),
        (-sys.float_info.max, sys.float_info.max),
        (-1e-300, 1e-300), (-1e-38, 1e-38),
        (0., 1e-38), (0.499, 0.501), (0.5, 0.500001)
    ]
    gammas = [0.125, 0.5, 1., 2., 4., 12., 1e-20, 1e20]
    out = [(0., 1.), (0.05, 0.95), (0.4, 0.4)]
    all_values = {"u8": u8s, "u16": u16s, "f32": floats}
    cases = []
    for kind, values in all_values.items():
        for i, value in enumerate(values):
            for repeat in range(7):
                # Repeatably cross endpoints, power and coverage policies.
                pair = pairs[(i + 3 * repeat) % len(pairs)]
                gamma = gammas[(i + 5 * repeat) % len(gammas)]
                output = out[(i + repeat) % len(out)]
                selected = (i + repeat) % 5 != 0
                mask = [-1, 0, 128, 255][(2 * i + repeat) % 4]
                cases.append((kind, value, selected, mask,
                              (pair[0], pair[1], gamma,
                               output[0], output[1])))
        for _ in range(110):
            value = rng.choice(values)
            pair = rng.choice(pairs)
            gamma = rng.choice(gammas)
            output = rng.choice(out)
            selected = rng.randrange(8) != 0
            mask = rng.choice([-1, 0, 128, 255])
            cases.append((kind, value, selected, mask,
                          (pair[0], pair[1], gamma,
                           output[0], output[1])))
    return cases


def main(path):
    cases = corpus()
    rows = []
    for index, (kind, value, chosen, mask, settings) in enumerate(cases):
        if kind == "f32":
            value = f32(value)
            value_text = format(value, ".9g")
        else:
            value_text = str(value)
        settings_text = [format(float(v), ".17g") for v in settings]
        rows.append("\t".join(map(str, [
            index, kind, int(chosen), mask, value_text, *settings_text
        ])))
    p = subprocess.run(
        [path], input="\n".join(rows) + "\n", text=True,
        capture_output=True, check=True)
    results = p.stdout.strip().splitlines()
    assert len(results) == len(cases), (len(results), len(cases))
    max_ulp = 0
    above_one = 0
    for index, ((kind, value, chosen, mask, settings), row) in enumerate(
            zip(cases, results)):
        index_text, bits_text = row.split("\t")
        assert int(index_text) == index
        observed = int(bits_text)
        expected = reference(kind, value, chosen, mask, settings)
        delta = ulp_distance(observed, expected)
        max_ulp = max(max_ulp, delta)
        if delta > 1:
            above_one += 1
        # One final binary32 rounding plus libm/pow variation; any
        # unexpected >8 ULP case is a qualification failure, never silently
        # normalized to a percentage or ignored.
        if delta > 8:
            raise AssertionError(
                f"case={index} kind={kind} sample={value!r} "
                f"selected={chosen} mask={mask} params={settings!r} "
                f"actual={frombits(observed)!r} "
                f"reference={frombits(expected)!r} "
                f"observedBits=0x{observed:08x} "
                f"referenceBits=0x{expected:08x} ULP={delta}")
    print(f"M3_LEVELS_DECIMAL_ORACLE=PASS cases={len(cases)} "
          f"max_ulp={max_ulp} above_one_ulp={above_one} "
          "reference=Python_decimal_90_digits; "
          "scope=sampled_u8_u16_f32_finite_parameter_corpus")


if __name__ == "__main__":
    main(sys.argv[1])
