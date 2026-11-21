"""Independent OpenCV and scikit-image checks of a built oracle consumer.

Usage: python tools/verify-feature-program.py tests/feature_program/feature-program-oracle
Dependencies are test-only: numpy, opencv-python-headless, scikit-image.
"""
import json
import subprocess
import sys
import numpy as np
import cv2
import skimage
from skimage.graph import MCP_Geometric
from scipy.ndimage import gaussian_filter

data = json.loads(subprocess.check_output([sys.argv[1]], text=True))
image = np.asarray(data["area_input"], dtype=np.float64).reshape(5, 7)
for case in data["areas"]:
    expected = cv2.resize(image, (case["w"], case["h"]), interpolation=cv2.INTER_AREA)
    actual = np.asarray(case["values"]).reshape(case["h"], case["w"])
    # OpenCV uses float32 weights even for a float64 source.
    np.testing.assert_allclose(actual, expected, rtol=2e-7, atol=2e-6)
cost = np.asarray(data["costs"]).reshape(8, 9)
expected, _ = MCP_Geometric(cost, fully_connected=True).find_costs([(0, 0), (7, 8)])
np.testing.assert_allclose(np.asarray(data["distances"]).reshape(8, 9), expected, rtol=1e-13)
rgb = np.array([64, 128, 32]) / 255.0
for linear, actual in enumerate(data["indices"]):
    v = np.where(rgb <= .04045, rgb / 12.92, ((rgb+.055)/1.055)**2.4) if linear else rgb
    np.testing.assert_allclose(actual, [2*v[1]-v[0]-v[2], v[0]/sum(v), v[1]/sum(v)], atol=1e-14)
tensor = np.asarray(data['tensor_input']).reshape(19, 17)
gx = gaussian_filter(tensor, 1, order=(0, 1), mode='nearest', truncate=3)
gy = gaussian_filter(tensor, 1, order=(1, 0), mode='nearest', truncate=3)
xx, xy, yy = [gaussian_filter(v, 2, mode='nearest', truncate=3) for v in [gx*gx, gx*gy, gy*gy]]
trace = xx+yy
delta = np.sqrt((xx-yy)**2+4*xy*xy)
for key, expected in [('angles', .5*np.arctan2(2*xy, xx-yy)), ('coherences', delta/trace), ('energies', trace)]:
    np.testing.assert_allclose(np.asarray(data['tensor_'+key]).reshape(19, 17), expected, rtol=2e-6, atol=2e-7)
print(f"PASS: 35 area grids, 72 geometric paths, RGB domains, tensor planes, parameter partitions, known noise sigma={data['noise_sigma']:.6f}")
print(f"numpy={np.__version__} OpenCV={cv2.__version__} scikit-image={skimage.__version__}")
