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
from skimage.feature import structure_tensor as skimage_structure_tensor

data = json.loads(subprocess.check_output([sys.argv[1]], text=True))
from decimal import Decimal, localcontext
weight_errors = {'ordinary': 0., 'extreme': 0.}
with localcontext() as context:
    context.prec = 2000
    for case in data['quality_weight_cases']:
        masses = []
        for contributor in case['contributors']:
            factors = [Decimal.from_float(float(v)) for v in contributor['factors']]
            masses.append(factors[0]*factors[1]*factors[2] if contributor['valid'] else Decimal(0))
        total = sum(masses)
        expected = np.array([float(mass/total) for mass in masses])
        actual = np.array(case['weights'])
        tolerance = 3e-15 if case['regime'] == 'ordinary' else 1e-12
        np.testing.assert_allclose(actual, expected, rtol=tolerance, atol=8*np.nextafter(0., 1.))
        normal = expected >= np.finfo(float).tiny
        weight_errors[case['regime']] = max(weight_errors[case['regime']],
            np.max(abs(actual[normal]-expected[normal])/expected[normal], initial=0))
        assert np.all(np.isfinite(actual)) and np.all(actual >= 0)
        assert abs(np.sum(actual)-1) < 4e-15
assert len(data['quality_weight_cases']) == 100
np.testing.assert_allclose(data['quality_alpha_mixture'], [.8, .8, 1., .5], rtol=0, atol=1e-15)
assert data['quality_weight_recipe'] == 'normalized-premultiplied-mixture-v1'
print(f"Quality weights: 100 Decimal cases, relative errors={weight_errors}; transparent/NoData mixture passes")
assert data['mixed_view_samples'] == 5355 and data['mixed_view_combinations'] == 31
assert data['mixed_view_peak_bytes'] <= 8*1024*1024
print(f"Mixed views: {data['mixed_view_samples']} reference samples, 31 support combinations; "
      f"peak work payload={data['mixed_view_peak_bytes']}")
assert data['configured_request_families'] == 6 and data['configured_request_samples'] == 66141
print(f"Configured requests: 6 families, {data['configured_request_samples']} queue/batch samples")
from scipy.ndimage import convolve, correlate1d, label

assert data['worker32_gaussian32_samples'] == 2156
assert data['worker32_gaussian32_error'] <= 3*np.finfo(np.float32).eps
print(f"Explicit Gaussian32: 2156 float32/64 strided/ROI samples, masked/wide/signed-zero fallback; max error={data['worker32_gaussian32_error']:.9g}, absolute gate=3*float32.eps")
assert data['worker32_exact_median_samples'] == 504
assert data['prepared_canny_cases'] == 120
print('Prepared Canny: 120 exact scalar border/zero-threshold/extreme-finite cases, warm zero-GC')
primitive = np.array(data['primitive_input'], dtype=np.float32).reshape(17, 19)
gx = cv2.Sobel(primitive, cv2.CV_32F, 1, 0, ksize=3, borderType=cv2.BORDER_REPLICATE)
gy = cv2.Sobel(primitive, cv2.CV_32F, 0, 1, ksize=3, borderType=cv2.BORDER_REPLICATE)
np.testing.assert_array_equal(np.array(data['primitive_gx']).reshape(17, 19), gx)
np.testing.assert_array_equal(np.array(data['primitive_gy']).reshape(17, 19), gy)
magnitude = np.sqrt(gx*gx+gy*gy)
thin = np.full(primitive.shape, -np.inf, dtype=np.float32)
for y in range(1, 16):
    for x in range(1, 18):
        ax, ay = abs(gx[y, x]), abs(gy[y, x])
        if ax >= ay*np.float32(2.4142):
            a, b = magnitude[y, x-1], magnitude[y, x+1]
        elif ay >= ax*np.float32(2.4142):
            a, b = magnitude[y-1, x], magnitude[y+1, x]
        elif gx[y, x]*gy[y, x] >= 0:
            a, b = magnitude[y-1, x-1], magnitude[y+1, x+1]
        else:
            a, b = magnitude[y+1, x-1], magnitude[y-1, x+1]
        if magnitude[y, x] >= a and magnitude[y, x] >= b:
            thin[y, x] = magnitude[y, x]
for case in data['primitive_edges']:
    components, _ = label(thin >= case['low'], structure=np.ones((3, 3)))
    seeded = np.unique(components[thin >= case['high']])
    expected = np.isin(components, seeded[seeded != 0])
    np.testing.assert_array_equal(np.array(case['edges']).reshape(17, 19), expected)
assert data['primitive_frontier_reached'] == 17
# Reproduce only the documented scalar Gaussian stencil; independent scipy
# passes retain float32 output after each axis, like the primitive.
sigma = np.float32(1.2)
radius = int(np.float32(sigma*3+.5))
coordinate = np.arange(-radius, radius+1, dtype=np.float32)
weights = np.exp(-coordinate**2/(np.float32(2)*sigma*sigma))
weights /= np.sum(weights, dtype=np.float32)
expected = correlate1d(correlate1d(primitive, weights, axis=1, mode='nearest'), weights, axis=0, mode='nearest')
primitive_gaussian_error = np.max(abs(np.array(data['primitive_gaussian']).reshape(17, 19)-expected))
np.testing.assert_allclose(np.array(data['primitive_gaussian']).reshape(17, 19), expected, rtol=3e-7, atol=3e-5)
print(f"Primitives: exact OpenCV Sobel and 3 NMS/connectivity oracles; Gaussian error={primitive_gaussian_error:.9g}")
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('timing_references', Path(__file__).with_name('benchmark-feature-references.py'))
timing_references = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timing_references)
reference_source = (primitive/np.float32(255)).astype(np.float64)
reference_ops = {(name, library): operation for name, library, operation, _ in timing_references.operations(reference_source)}
timing_reference_error = 0.
for case in data['timing_reference_features']:
    name = case['feature']
    library = 'OpenCV+NumPy' if name in ('gradient', 'localNormalization', 'ridge', 'gabor') else 'OpenCV' if name == 'gaussian' else 'scipy'
    expected = reference_ops[name, library]()
    if isinstance(expected, tuple):
        expected = expected[0]
    actual = np.asarray(case['strength']).reshape(17, 19)
    timing_reference_error = max(timing_reference_error, np.max(abs(actual-expected)))
    np.testing.assert_allclose(actual, expected, rtol=2e-13, atol=1e-14)
print(f"Timing reference preflight: 6 finite scalar strength planes; max error={timing_reference_error:.9g}")
float32_reference_error = 0.
for case in data['timing_reference_features']:
    if case['feature'] not in ('gaussian','gradient','median'):
        continue
    library={'gaussian':'OpenCV-float32','gradient':'OpenCV+NumPy-float32','median':'OpenCV'}[case['feature']]
    expected=reference_ops[case['feature'],library]()
    if isinstance(expected,tuple):expected=expected[0]
    actual=np.asarray(case['strength'],dtype=np.float32).reshape(17,19)
    error=float(np.max(abs(actual-expected)))
    float32_reference_error=max(float32_reference_error,error)
    if case['feature']=='median':
        np.testing.assert_array_equal(actual,expected)
    else:
        # Float32 Sobel/subtraction/hypot and two-axis Gaussian each round
        # intermediate results. The native float64 oracle gate remains intact.
        np.testing.assert_allclose(actual,expected,rtol=0,atol=3*np.finfo(np.float32).eps)
print(f'Float32 timing comparators: median exact; Gaussian/gradient max error={float32_reference_error:.9g}; absolute gate=3*float32.eps on [0,1]')
from scipy.ndimage import uniform_filter
normalized = (primitive/np.float32(255)).astype(np.float64)
padded = np.pad(normalized, 3, mode='edge')
bilateral = np.zeros_like(normalized)
weights = np.zeros_like(normalized)
for dy in range(-3, 4):
    for dx in range(-3, 4):
        neighbor = padded[3+dy:20+dy, 3+dx:22+dx]
        weight = np.exp(-(dx*dx+dy*dy)/(2*float(np.float32(1.2))**2)
                        -(neighbor-normalized)**2/(2*float(np.float32(.2))**2))
        bilateral += neighbor*weight
        weights += weight
bilateral /= weights
mean = uniform_filter(normalized, size=5, mode='nearest')
variance = uniform_filter(normalized**2, size=5, mode='nearest')-mean**2
slope = variance/(variance+float(np.float32(.01)))
guided = slope*normalized+(1-slope)*mean
bilateral_error = np.max(abs(np.array(data['primitive_bilateral']).reshape(17, 19)-bilateral))
guided_error = np.max(abs(np.array(data['primitive_guided']).reshape(17, 19)-guided))
np.testing.assert_allclose(np.array(data['primitive_bilateral']).reshape(17, 19), bilateral, rtol=0, atol=6e-7)
np.testing.assert_allclose(np.array(data['primitive_guided']).reshape(17, 19), guided, rtol=0, atol=8e-7)
print(f"Bilateral/guided oracle errors={bilateral_error:.9g}/{guided_error:.9g}")
for case in data['slic_cases']:
    image = np.asarray(case['input'], dtype=np.float32).reshape(17, 19)
    spacing = case['spacing']
    yy, xx = np.indices(image.shape, dtype=np.float32)
    cy, cx = np.mgrid[0:17:spacing, 0:19:spacing]
    cx = np.minimum(cx+spacing//2, 18).ravel().astype(np.float32)
    cy = np.minimum(cy+spacing//2, 16).ravel().astype(np.float32)
    cc = image[cy.astype(int), cx.astype(int)]
    for _ in range(4):
        costs = ((image[None]-cc[:, None, None])**2
                 + ((xx[None]-cx[:, None, None])**2+(yy[None]-cy[:, None, None])**2)/(spacing*spacing))
        assignments = np.argmin(costs, axis=0).ravel()
        counts = np.bincount(assignments, minlength=len(cx))
        sx, sy, sc = [np.zeros(len(cx), dtype=np.float32) for _ in range(3)]
        for sums, values in ((sx, xx), (sy, yy), (sc, image)):
            np.add.at(sums, assignments, values.ravel())
        active = counts != 0
        cx[active] = sx[active]/counts[active].astype(np.float32)
        cy[active] = sy[active]/counts[active].astype(np.float32)
        cc[active] = sc[active]/counts[active].astype(np.float32)
    np.testing.assert_array_equal(case['labels'], assignments+1)
print(f"Scalar grid clustering: {len(data['slic_cases'])} independent four-iteration label maps")

quality_error = np.zeros(3)
quality_frequency = []
for case in data['quality_cases']:
    base = np.asarray(case['base']).reshape(96, 128)
    sigma = case['sigma']
    source = gaussian_filter(base, sigma, mode='wrap', radius=int(np.ceil(4*sigma))) if sigma else base
    source = source.astype(np.float32).astype(np.float64)
    # Independent bulk convolution, median reduction and centered variance.
    kernel = np.outer([1., -2., 1.], [1., -2., 1.])/6
    high = convolve(source, kernel)[1:-1, 1:-1]
    noise = np.median(abs(high-np.median(high)))/.6744897501960817
    gx = (source[1:-1, 2:]-source[1:-1, :-2])*.5
    gy = (source[2:, 1:-1]-source[:-2, 1:-1])*.5
    energy = np.mean(gx*gx+gy*gy)
    variance = np.var(source[1:-1, 1:-1])
    frequency = np.sqrt(energy/variance)/(2*np.pi) if variance else 0
    expected = np.array([noise, energy, frequency])
    actual = np.array(case['metrics'])
    np.testing.assert_allclose(actual, expected, rtol=3e-13, atol=1e-15)
    assert case['samples'] == 126*94
    quality_error = np.maximum(quality_error, abs(actual-expected))
    if case['kind'] == 0:
        quality_frequency.append(actual[2])
        # Known discrete Gaussian attenuation of a periodic sine. Source
        # float32 quantization is covered by this analytic gate.
        radius = int(np.ceil(4*sigma))
        taps = np.arange(-radius, radius+1)
        weights = np.exp(-.5*(taps/sigma)**2) if sigma else np.ones(1)
        attenuation = np.sum(weights*np.cos(2*np.pi*taps/32))/weights.sum()
        analytic_energy = attenuation**2*np.sin(2*np.pi/32)**2*np.mean(np.cos(2*np.pi*np.arange(1,127)/32)**2)
        np.testing.assert_allclose(actual[1], analytic_energy, rtol=1e-7, atol=0)
assert np.ptp(quality_frequency) < 1e-8
assert data['quality_unit_cases'] == 3
print(f"Quality: {len(data['quality_cases'])} known-blur/constant cases; metric errors={quality_error}; "
      f"single-frequency blur spread={np.ptp(quality_frequency):.9g}")
image = np.asarray(data["area_input"], dtype=np.float64).reshape(5, 7)
for case in data["areas"]:
    expected = cv2.resize(image, (case["w"], case["h"]), interpolation=cv2.INTER_AREA)
    actual = np.asarray(case["values"]).reshape(case["h"], case["w"])
    # OpenCV uses float32 weights even for a float64 source.
    np.testing.assert_allclose(actual, expected, rtol=2e-7, atol=2e-6)
cost = np.asarray(data["costs"]).reshape(8, 9)
expected, _ = MCP_Geometric(cost, fully_connected=True).find_costs([(0, 0), (7, 8)])
np.testing.assert_allclose(np.asarray(data["distances"]).reshape(8, 9), expected, rtol=1e-13)
cost_path_relative_error = 0.0
for case in data['cost_path_cases']:
    field = np.asarray(case['costs']).reshape(11, 13)
    field[field < 0] = np.inf
    x_step, y_step = case['steps']
    expected, _ = MCP_Geometric(field, fully_connected=case['connectivity'] == 8,
                               sampling=(y_step, x_step)).find_costs([(10, 12), (0, 0)])
    actual = np.asarray(case['distances']).reshape(field.shape)
    actual[actual < 0] = np.inf
    np.testing.assert_array_equal(np.isfinite(actual), np.isfinite(expected))
    finite = np.isfinite(expected)
    np.testing.assert_allclose(actual[finite], expected[finite], rtol=3e-15, atol=0)
    nonzero = finite & (expected > 0)
    cost_path_relative_error = max(cost_path_relative_error,
        np.max(abs(actual[nonzero]-expected[nonzero])/expected[nonzero]))
for case in data['cost_window_cases']:
    shape=(case['height'],case['width'])
    cost=np.asarray(case['costs']).reshape(shape)
    cost[cost<0]=np.inf
    expected,_=MCP_Geometric(cost,fully_connected=case['connectivity']==8,
                             sampling=(2.5,.75)).find_costs([(0,0),(shape[0]-1,shape[1]-1)])
    actual=np.asarray(case['distances']).reshape(shape);actual[actual<0]=np.inf
    np.testing.assert_array_equal(np.isfinite(actual),np.isfinite(expected))
    finite=np.isfinite(expected)
    np.testing.assert_allclose(actual[finite],expected[finite],rtol=3e-15,atol=0)
assert len(data['cost_window_cases'])==36
print('Lazy/reset/window cost paths: 36 independently checked domains; zero-GC replay')
assert data['planar_cases'] >= 196 and data['planar_range_failures'] > 0
print(f"Planar Engine: {data['planar_cases']} RGB/scientific/partition cases, {data['planar_pixels']} samples; exact final float32 conversion, full-precision dependencies")
print(f"Cost paths: {len(data['cost_path_cases'])} random/connectivity/step cases; "
      f"MCP relative error={cost_path_relative_error:.9g}; "
      f"path reconstruction error={data['cost_path_reconstruction_error']:.9g}")
assert data['path_enumeration_comparisons'] == 25740
print(f"Path morphology: {data['path_enumeration_comparisons']} exhaustive-path/tiled sample comparisons")
assert data['worker32_cases'] > 80 and data['worker32_peak_bytes'] <= 8*1024*1024
print(f"Float32 worker: {data['worker32_cases']} gray/RGB/strided cases, {data['worker32_samples']} samples; "
      f"max conversion error={data['worker32_max_error']:.9g}; peak payload={data['worker32_peak_bytes']}")
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

# Full tensor planes at fractional, zero-integration and maximum scales. The
# radius is explicitly ceil(3*sigma), not scipy's rounded truncate convention.
tensor_errors = {'angle': 0.0, 'coherence': 0.0, 'energy': 0.0}
tensor_grating_errors = []
tensor_skimage_angle_errors = []
for case in data['tensor_cases']:
    image = np.asarray(case['input']).reshape(49, 65)
    g, s = case['gradient_sigma'], case['integration_sigma']
    radius = int(np.ceil(3*g))
    gx = gaussian_filter(image, g, order=(0, 1), mode='nearest', radius=radius)
    gy = gaussian_filter(image, g, order=(1, 0), mode='nearest', radius=radius)
    xx, xy, yy = [gaussian_filter(v, s, mode='nearest', radius=int(np.ceil(3*s)))
                  if s else v for v in (gx*gx, gx*gy, gy*gy)]
    trace = xx+yy
    gap = np.hypot(xx-yy, 2*xy)
    coherent = np.divide(gap, trace, out=np.zeros_like(trace), where=trace > 0).clip(0, 1)
    expected_valid = (trace > 0) & (gap > 32*np.finfo(float).eps*trace)
    expected_angle = np.where(expected_valid, .5*np.arctan2(2*xy, xx-yy), 0)
    actual_angle = np.asarray(case['angles']).reshape(image.shape)
    actual_coherence = np.asarray(case['coherences']).reshape(image.shape)
    actual_energy = np.asarray(case['energies']).reshape(image.shape)
    actual_valid = np.asarray(case['valid']).reshape(image.shape) != 0
    np.testing.assert_allclose(actual_coherence, coherent, rtol=2e-7, atol=3e-8)
    np.testing.assert_allclose(actual_energy, trace, rtol=2e-7, atol=1e-16)
    # At near-isotropy angle is ill-conditioned even while mathematically
    # defined. Qualify orientations on resolved energy/gaps; local radial and
    # constant tests separately enforce undefined-orientation behavior.
    resolved = (gap > 1e-6*trace) & (trace > trace.max()*1e-12)
    np.testing.assert_array_equal(actual_valid, expected_valid)
    errors = np.abs(np.angle(np.exp(2j*(actual_angle-expected_angle))))/2
    assert errors[resolved].max(initial=0) < 2e-7
    tensor_errors['angle'] = max(tensor_errors['angle'], errors[resolved].max(initial=0))
    tensor_errors['coherence'] = max(tensor_errors['coherence'], np.max(abs(actual_coherence-coherent)))
    tensor_errors['energy'] = max(tensor_errors['energy'], np.max(abs(actual_energy-trace)))
    if case['kind'] == 1 and g == 1.25:
        interior = (slice(16, 33), slice(16, 49))
        analytic = abs(np.angle(np.exp(2j*(actual_angle[interior]-.65))))/2
        tensor_grating_errors.append(float(analytic.max()))
        assert analytic.max() < .001
        # Public skimage uses Sobel derivatives and four-sigma integration,
        # rather than the independently parameterized Gaussian derivatives.
        # Compare axial direction on a resolved grating, without claiming
        # identical energy magnitude or per-image discretization.
        sx, sxy, sy = skimage_structure_tensor(image, sigma=s, mode='nearest', order='xy')
        sk_angle = .5*np.arctan2(2*sxy, sx-sy)
        difference = abs(np.angle(np.exp(2j*(actual_angle[interior]-sk_angle[interior]))))/2
        tensor_skimage_angle_errors.append(float(difference.max()))
        assert difference.max() < .004
print(f"Tensor: {len(data['tensor_cases'])} exact-stencil cases, maxima={tensor_errors}; "
      f"ROI={data['tensor_roi_max_error']:.9g}; affine angle={data['tensor_analytic_max_error']:.9g}; "
      f"grating={max(tensor_grating_errors):.9g}; public skimage angle={max(tensor_skimage_angle_errors):.9g}")

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
