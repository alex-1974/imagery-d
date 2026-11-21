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
from skimage.filters import sato, frangi, meijering

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

# The Hessian stencil is specified independently of scikit-image's different
# two-first-derivative discretization. Compare all outputs to scipy convolution
# plus NumPy symmetric eigenvectors, and separately characterize public filters.
hessian_errors = {'response': 0.0, 'angle': 0.0}

def check_hessian(fixture):
    line = np.asarray(fixture['hessian_input']).reshape(49, 65)
    curvatures = []
    for sigma in fixture['hessian_sigmas']:
        radius = int(np.ceil(4*sigma))
        coordinate = np.arange(-radius, radius+1)
        smooth = np.exp(-.5*(coordinate/sigma)**2)
        smooth /= sum(smooth)
        dc = np.sum(((coordinate/sigma)**2-1)/sigma**2*smooth)
        xx = gaussian_filter(line, sigma, order=(0, 2), mode='nearest', radius=radius)
        xx -= dc*gaussian_filter(line, sigma, order=(0, 0), mode='nearest', radius=(radius, 0))
        yy = gaussian_filter(line, sigma, order=(2, 0), mode='nearest', radius=radius)
        yy -= dc*gaussian_filter(line, sigma, order=(0, 0), mode='nearest', radius=(0, radius))
        xy = gaussian_filter(line, sigma, order=(1, 1), mode='nearest', radius=radius)
        matrix = np.stack([xx, xy, xy, yy], axis=-1).reshape(49, 65, 2, 2)*sigma**2
        curvatures.append(matrix)

    for case in fixture['hessian_cases']:
        variant, polarity = case['variant'], case['polarity']
        expected = np.zeros(line.shape, dtype=np.float32)
        best_scale = np.zeros_like(expected)
        angles = np.zeros_like(expected)
        valid = np.zeros(line.shape, dtype=np.uint8)
        signs = [-1, 1] if polarity == 2 else [1 if polarity == 1 else -1]
        for sigma, matrix in zip(fixture['hessian_sigmas'], curvatures):
            for sign in signs:
                eigen, vectors = np.linalg.eigh(sign*matrix)
                small, large = eigen[..., 0], eigen[..., 1]
                principal = np.ones(line.shape, dtype=bool)
                if variant == 0:
                    response = np.maximum(0, large)/case['responseScale']
                elif variant == 1:
                    dominant = np.where(abs(large) >= abs(small), large, small)
                    other = np.where(abs(large) >= abs(small), small, large)
                    ratio = np.divide(abs(other), dominant, out=np.zeros_like(dominant), where=dominant > 0)
                    response = np.where(dominant > 0, np.exp(-.5*(ratio/case['beta'])**2)*(-np.expm1(-.5*((small*small+large*large)/case['gamma']**2))), 0)
                else:
                    a, b = large+case['alpha']*small, small+case['alpha']*large
                    principal = abs(a) >= abs(b)
                    response = np.maximum(0, np.where(principal, a, b))/case['responseScale']
                response = response.astype(np.float32)
                wins = response > expected
                normal = np.where(principal[..., None], vectors[..., :, 1], vectors[..., :, 0])
                direction = np.mod(np.arctan2(normal[..., 1], normal[..., 0])+np.pi/2, np.pi)
                gap = (large-small)/2
                resolved = gap > 32*np.finfo(float).eps*(np.abs(matrix[..., 0, 0])+np.abs(matrix[..., 1, 1])+2*np.abs(matrix[..., 0, 1]))
                angles[wins] = np.where(resolved, direction, 0)[wins]
                valid[wins] = resolved[wins]
                best_scale[wins] = sigma
                expected[wins] = response[wins]
        actual = np.asarray(case['response']).reshape(line.shape)
        hessian_errors['response'] = max(hessian_errors['response'], float(np.max(abs(actual-expected))))
        np.testing.assert_allclose(actual, expected, rtol=2e-7, atol=1e-16)
        # Ignore numerical zero responses when comparing the winning scale.
        significant = expected > 2e-7
        np.testing.assert_array_equal(np.asarray(case['scales']).reshape(line.shape)[significant], best_scale[significant])
        np.testing.assert_array_equal(np.asarray(case['valid']).reshape(line.shape)[significant], valid[significant])
        selected = significant & (valid != 0)
        error = (np.asarray(case['angles']).reshape(line.shape)-angles+np.pi/2) % np.pi - np.pi/2
        hessian_errors['angle'] = max(hessian_errors['angle'], float(np.max(abs(error[selected]), initial=0)))
        np.testing.assert_allclose(error[selected], 0, atol=4e-7)


check_hessian(data)
check_hessian(data['hessian_extra'])
check_hessian(data['hessian_configured'])
line = np.asarray(data['hessian_input']).reshape(49, 65)

bright_cases = {case['variant']: np.asarray(case['response']).reshape(line.shape) for case in data['hessian_cases'] if case['polarity'] == 0}
sato_reference = sato(line, sigmas=[1, 2, 4], black_ridges=False, mode='nearest')
center = (24, 32)
sato_center_error = abs(bright_cases[0][center]-sato_reference[center])/sato_reference[center]
assert sato_center_error < .003, sato_center_error
frangi_reference = np.maximum.reduce([frangi(line, sigmas=[s], beta=.5, gamma=.5/s**2, black_ridges=False, mode='nearest') for s in [1.,2.,4.]])
frangi_error = np.max(abs(bright_cases[1]-frangi_reference))
assert frangi_error < .015, frangi_error
# Report the shape agreement, with each response normalized only for this
# diagnostic. Production uses the caller's fixed responseScale instead.
meijering_reference = meijering(line, sigmas=[1, 2, 4], alpha=1/3, black_ridges=False, mode='nearest')
shape_error = np.max(abs(bright_cases[2]/bright_cases[2].max()-meijering_reference))
assert shape_error < .001, shape_error
print(f'Hessian: 27 fixture/variant/polarity cases; Sato center relative error vs scikit-image={sato_center_error:.6g}; Frangi error={frangi_error:.6g}; Meijering normalized shape error={shape_error:.6g}')
print(f'Hessian scipy/NumPy exact-stencil maxima: {hessian_errors}')
print(f"Windows: {data['window_samples']} valid samples; max absolute mean error={data['window_max_mean_error']:.9g}; max deviation error={data['window_max_deviation_error']:.9g}")
print(f"PASS: 35 area grids, 72 geometric paths, RGB domains, tensor planes, parameter partitions, known noise sigma={data['noise_sigma']:.6f}")
print(f"numpy={np.__version__} OpenCV={cv2.__version__} scikit-image={skimage.__version__}")
