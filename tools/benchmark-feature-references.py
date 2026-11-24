"""Same-machine timing diagnostics, not a claim of semantic interchangeability.

Run with the test-only feature_program requirements. Setup/input generation and
checksums are excluded; operation intermediates/allocations are included.
OpenCV is restricted to one thread. Pin the process externally with taskset.
"""
import argparse
import csv
import platform
import sys
import time
import numpy as np
import cv2
import scipy
import skimage
from scipy.ndimage import median_filter
from skimage.feature import canny
from skimage.exposure import equalize_adapthist


def fixtures(size, rgb):
    y, x = np.indices((size, size), dtype=np.uint64)
    v = ((x*37+y*17+(x*y) % 97) & 255).astype(np.uint8)
    if not rgb:
        return (v.astype(np.float32)/np.float32(255)).astype(np.float64)
    r, g = v.astype(np.float64)/255, (255-v).astype(np.float64)/255
    def linear(a):
        return np.where(a <= .04045, a/12.92, ((a+.055)/1.055)**2.4)
    return .2848*linear(r)+.7152*linear(g)


def operations(source):
    border = cv2.BORDER_REPLICATE
    def gradient():
        gx = cv2.Sobel(source, cv2.CV_64F, 1, 0, scale=1/8, borderType=border)
        gy = cv2.Sobel(source, cv2.CV_64F, 0, 1, scale=1/8, borderType=border)
        return np.hypot(gx, gy), np.arctan2(gy, gx)
    def normalization():
        mean = cv2.boxFilter(source, -1, (7, 7), borderType=border)
        square = cv2.boxFilter(source*source, -1, (7, 7), borderType=border)
        deviation = np.sqrt(np.maximum(0, square-mean*mean))
        return np.divide(source-mean, deviation, out=np.zeros_like(source), where=deviation > 0)
    def ridge():
        best = np.zeros_like(source)
        angle, scale = np.zeros_like(source), np.zeros_like(source)
        for radius in range(1, 4):
            for i, (dx, dy) in enumerate([(1, 0), (1, 1), (0, 1), (-1, 1)]):
                kernel = np.zeros((7, 7))
                kernel[3, 3] = 1
                kernel[3+dx*radius, 3-dy*radius] = -.5
                kernel[3-dx*radius, 3+dy*radius] = -.5
                response = cv2.filter2D(source, -1, kernel, borderType=border)
                wins = response > best
                np.copyto(best, response, where=wins)
                np.copyto(angle, i*np.pi/4, where=wins)
                np.copyto(scale, radius, where=wins)
        return best, angle, scale
    kernels = []
    for wavelength in (2, 4):
        y, x = np.mgrid[-wavelength:wavelength+1, -wavelength:wavelength+1]
        envelope = np.exp(-(x*x+y*y)/(.5*wavelength*wavelength))
        for i in range(4):
            theta = i*np.pi/4
            phase = 2*np.pi*(x*np.cos(theta)+y*np.sin(theta))/wavelength
            kernels.append((envelope*np.cos(phase)/envelope.sum(),
                            envelope*np.sin(phase)/envelope.sum(), theta, wavelength))
    def gabor():
        best = np.zeros_like(source)
        angle, scale = np.zeros_like(source), np.zeros_like(source)
        for real, imaginary, theta, wavelength in kernels:
            re = cv2.filter2D(source, -1, real, borderType=border)-source*real.sum()
            im = cv2.filter2D(source, -1, imaginary, borderType=border)-source*imaginary.sum()
            response = np.hypot(re, im)
            wins = response > best
            np.copyto(best, response, where=wins)
            np.copyto(angle, theta, where=wins)
            np.copyto(scale, wavelength, where=wins)
        return best, angle, scale
    # Canny's scalar primitive takes unnormalized Sobel gradients. OpenCV
    # only accepts integer derivatives: this row includes their preparation
    # and explicit 1/255 quantization. skimage accepts the float working plane.
    source32 = source.astype(np.float32)
    def gradient32():
        gx = cv2.Sobel(source32, cv2.CV_32F, 1, 0, scale=1/8, borderType=border)
        gy = cv2.Sobel(source32, cv2.CV_32F, 0, 1, scale=1/8, borderType=border)
        return np.hypot(gx, gy), np.arctan2(gy, gx)
    def cv_canny():
        gx = np.rint(cv2.Sobel(source32, cv2.CV_32F, 1, 0, borderType=border)*255).astype(np.int16)
        gy = np.rint(cv2.Sobel(source32, cv2.CV_32F, 0, 1, borderType=border)*255).astype(np.int16)
        return cv2.Canny(gx, gy, .15*255, .3*255, L2gradient=True)
    byte = np.rint(source*255).clip(0, 255).astype(np.uint8)
    clahe = cv2.createCLAHE(clipLimit=2, tileGridSize=(max(1, source.shape[1]//32), max(1, source.shape[0]//32)))
    return [
        ('gaussian', 'OpenCV', lambda: cv2.GaussianBlur(source, (3, 3), 0, borderType=border), 'float64 binomial 3x3'),
        ('gaussian', 'OpenCV-float32', lambda: cv2.GaussianBlur(source32, (3, 3), 0, borderType=border), 'float32 binomial 3x3; different intermediate rounding'),
        ('gradient', 'OpenCV+NumPy', gradient, 'float64 strength+angle; normalized Sobel'),
        ('gradient', 'OpenCV+NumPy-float32', gradient32, 'float32 strength+angle; normalized Sobel; different intermediate rounding'),
        ('localNormalization', 'OpenCV+NumPy', normalization, 'float64 moments via E[x^2]-E[x]^2; finite fixture only'),
        ('ridge', 'OpenCV+NumPy', ridge, 'float64 twelve linear stencils+winner planes; finite fixture only'),
        ('gabor', 'OpenCV+NumPy', gabor, 'float64 eight complex filters+winner planes; finite fixture only'),
        ('median', 'OpenCV', lambda: cv2.medianBlur(source32, 3), 'float32 3x3; lower precision than Engine'),
        ('median', 'scipy', lambda: median_filter(source, size=3, mode='nearest'), 'float64 3x3'),
        ('canny', 'OpenCV', cv_canny, 'quantized derivatives; native plateau/tie semantics'),
        ('canny', 'scikit-image', lambda: canny(source32, sigma=0, low_threshold=.15, high_threshold=.3, mode='nearest'), 'float32; interpolated NMS; no Gaussian smoothing'),
        ('clahe', 'OpenCV', lambda: clahe.apply(byte), 'uint8 linear-luminance quantization; native edge/interpolation semantics'),
        ('clahe', 'scikit-image', lambda: equalize_adapthist(source, kernel_size=32, clip_limit=2/256, nbins=256), 'native normalization/interpolation; not Engine-equivalent'),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sizes', nargs='+', type=int, default=[1024, 4096])
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--domains', nargs='+', choices=['scalar', 'rgb'], default=['scalar', 'rgb'])
    parser.add_argument('--operators', nargs='+')
    args = parser.parse_args()
    if args.repeats < 1 or any(s < 8 or s > 4096 for s in args.sizes):
        parser.error('sizes 8..4096, positive repeats required')
    cv2.setNumThreads(1)
    print(f'# {platform.platform()}; numpy={np.__version__}; OpenCV={cv2.__version__}; scipy={scipy.__version__}; scikit-image={skimage.__version__}', flush=True)
    writer = csv.writer(sys.stdout)
    writer.writerow(['size', 'domain', 'operator', 'reference', 'ns_per_pixel', 'checksum', 'scope'])
    for size in args.sizes:
        for domain in args.domains:
            source = fixtures(size, domain == 'rgb')
            for name, reference, operation, scope in operations(source):
                if args.operators and name not in args.operators:
                    continue
                timings, checksum = [], 0.
                for run in range(args.repeats+1):
                    start = time.perf_counter_ns()
                    result = operation()
                    elapsed = time.perf_counter_ns()-start
                    if run:
                        timings.append(elapsed/source.size)
                    for plane in result if isinstance(result, tuple) else (result,):
                        checksum += float(np.sum(plane, dtype=np.float64))
                    del result
                writer.writerow([size, domain, name, reference, f'{np.median(timings):.3f}', f'{checksum:.12g}', scope])
                sys.stdout.flush()
            # Neither reference offers the same monotonic DAG path morphology.
            writer.writerow([size, domain, 'pathOpening', 'unavailable', '', '', 'use retained D scalar oracle; no substitute line opening'])


if __name__ == '__main__':
    main()
