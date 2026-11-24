"""Independent graph/reference checks for the public caller-backed region API.

Usage: python tools/verify-component-regions.py tests/component_regions/component-regions-oracle
Optional: --scene /absolute/esri.png --benchmark (five paired RAM/disk runs).
Only test dependencies are used: NumPy, SciPy, and Pillow for the real scene.
"""
import argparse
from collections import Counter, deque
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tempfile

import numpy as np
from scipy.ndimage import label as scipy_label
from scipy.ndimage import sobel, minimum_filter

parser = argparse.ArgumentParser()
parser.add_argument('consumer')
parser.add_argument('--scene', type=Path)
parser.add_argument('--benchmark', action='store_true')
args = parser.parse_args()


def adapter_case(case):
    """Independent bulk Sobel + directional NMS for cannyComponents."""
    case = dict(case)
    h, w = case['height'], case['width']
    image = np.array([s[2] for s in case['samples']]).reshape(h, w)
    valid = np.array([s[1] for s in case['samples']]).reshape(h, w)
    if case['adapter'] != 'canny':
        case['samples'] = [[1, s[1], s[2], 0., 0., None, None] for s in case['samples']]
        return case
    gx, gy = sobel(image, axis=1, mode='nearest')/8, sobel(image, axis=0, mode='nearest')/8
    strength = np.hypot(gx, gy)
    gradient_valid = minimum_filter(valid, size=3, mode='nearest')
    direction = (np.floor((np.arctan2(gy, gx)+np.pi) % np.pi*4/np.pi+.5).astype(int) % 4)
    axes = [(1, 0), (1, 1), (0, 1), (-1, 1)]
    samples = []
    for y, x in np.ndindex(h, w):
        observed = bool(gradient_valid[y, x])
        state, edge = 0, None
        if observed and strength[y, x] >= .04:
            dx, dy = axes[direction[y, x]]
            def neighbor(sign):
                nonlocal observed
                nx, ny = x+sign*dx, y+sign*dy
                if not (0 <= nx < w and 0 <= ny < h):
                    return False
                observed &= bool(gradient_valid[ny, nx])
                return bool(gradient_valid[ny, nx] and
                            (strength[y, x] >= strength[ny, nx] if sign > 0
                             else strength[y, x] > strength[ny, nx]))
            before, after = neighbor(-1), neighbor(1)
            if before and after:
                state = 2 if strength[y, x] >= .1 else 1
                edge = float(strength[y, x])
        samples.append([state, observed, 0., 0., 0., None, edge])
    case['samples'] = samples
    return case


def reference(case):
    h, w = case['height'], case['width']
    rows = case['samples']
    state = np.array([s[0] for s in rows]).reshape(h, w)
    valid = np.array([s[1] for s in rows]).reshape(h, w)
    color = np.array([s[2:5] for s in rows]).reshape(h, w, 3)
    valid &= np.all(np.isfinite(color), axis=2)
    selected = valid & (state != 0)
    distance, cell = case['distance'], case['cell']
    ox, oy = case['origin_x'], case['origin_y']
    neighbors = [(dx, dy) for dy in (-1, 0, 1) for dx in (-1, 0, 1)
                 if (dx or dy) and (case['diagonal'] or dx*dy == 0)]

    def joins(x, y, nx, ny):
        return (selected[ny, nx]
                and (not cell or ((x+ox)//cell == (nx+ox)//cell
                                  and (y+oy)//cell == (ny+oy)//cell))
                and (distance is None or np.linalg.norm(color[y, x]-color[ny, nx]) <= distance))

    # Birth labels follow the specified scan-order name scheme, separately from
    # graph connectivity. BFS below does not reproduce the implementation's union/find.
    births = np.zeros((h, w), dtype=np.uint32)
    next_birth = 0
    for y, x in np.argwhere(selected):
        earlier = [(x+dx, y+dy) for dx, dy in neighbors
                   if dy < 0 or (dy == 0 and dx < 0)]
        if not any(0 <= nx < w and 0 <= ny < h and joins(x, y, nx, ny)
                   for nx, ny in earlier):
            next_birth += 1
            births[y, x] = next_birth

    labels = np.zeros((h, w), dtype=np.uint32)
    visited = np.zeros((h, w), dtype=bool)
    for y, x in np.argwhere(selected):
        if visited[y, x]:
            continue
        queue, points = deque([(x, y)]), []
        visited[y, x] = True
        while queue:
            px, py = queue.popleft()
            points.append((px, py))
            for dx, dy in neighbors:
                nx, ny = px+dx, py+dy
                if (0 <= nx < w and 0 <= ny < h and not visited[ny, nx]
                        and joins(px, py, nx, ny)):
                    visited[ny, nx] = True
                    queue.append((nx, ny))
        xx, yy = np.array(points).T
        ids = births[yy, xx]
        canonical = ids[ids != 0].min()
        if not case['seeded'] or np.any(state[yy, xx] == 2):
            labels[yy, xx] = canonical
    if distance is None and not cell and not case['seeded']:
        independent, count = scipy_label(selected, np.ones((3, 3), int) if case['diagonal']
                                         else [[0, 1, 0], [1, 1, 1], [0, 1, 0]])
        assert len(np.unique(labels))-int(np.any(labels == 0)) == count
        for component in range(1, count+1):
            assert len(np.unique(labels[independent == component])) == 1
    return labels, valid


def check(case, actual):
    if 'adapter' in case:
        case = adapter_case(case)
    labels, valid = reference(case)
    h, w = labels.shape
    ox, oy = case['origin_x'], case['origin_y']
    np.testing.assert_array_equal(np.array(actual['labels']).reshape(h, w), labels)
    np.testing.assert_array_equal(np.array(actual['validity']).reshape(h, w), valid)
    np.testing.assert_array_equal(actual['crop_labels'], labels[3:8, 2:9].ravel())
    np.testing.assert_array_equal(actual['crop_validity'], valid[3:8, 2:9].ravel())
    assert actual['max_source_window'] <= case['block']+2
    assert actual['scratch_bytes'] <= 8*1024*1024
    expected_contacts = Counter()
    for a, b in ((labels[:, :-1], labels[:, 1:]), (labels[:-1], labels[1:])):
        for first, second in zip(a.ravel(), b.ravel()):
            if first and second and first != second:
                expected_contacts[tuple(sorted((int(first), int(second))))] += 1
    assert Counter(map(tuple, actual['contacts'])) == expected_contacts
    regions = {r['id']: r for r in actual['regions']}
    ids = set(map(int, np.unique(labels)))-{0}
    assert set(regions) == ids
    rows = case['samples']
    color = np.array([s[2:5] for s in rows]).reshape(h, w, 3)
    auxiliary = [np.array([s[channel] for s in rows], dtype=float).reshape(h, w)
                 for channel in (5, 6)]
    max_error = 0.

    def close(actual_values, expected_values, tolerance=2e-14):
        nonlocal max_error
        np.testing.assert_allclose(actual_values, expected_values, rtol=0, atol=tolerance)
        max_error = max(max_error, float(np.max(np.abs(np.asarray(actual_values)-expected_values))))

    for region_id in ids:
        stats = regions[region_id]
        yy, xx = np.where(labels == region_id)
        area = len(xx)
        assert stats['pixels'] == area
        assert stats['bounds'] == [int(xx.min())+ox, int(yy.min())+oy,
                                    int(np.ptp(xx))+1, int(np.ptp(yy))+1]
        close(stats['color'], color[yy, xx].mean(axis=0))
        close(stats['variance'], color[yy, xx].var(axis=0))
        perimeter = 0
        for x, y in zip(xx, yy):
            perimeter += sum(not (0 <= x+dx < w and 0 <= y+dy < h)
                             or labels[y+dy, x+dx] != region_id
                             for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)))
        assert stats['perimeter'] == perimeter
        close(stats['fill'], area/(stats['bounds'][2]*stats['bounds'][3]))
        for channel, name in zip(auxiliary, ('texture', 'edge')):
            values = channel[yy, xx]
            values = values[np.isfinite(values)]
            assert stats[name+'_count'] == len(values)
            if len(values):
                close(stats[name], values.mean())
            else:
                assert stats[name] is None
        close(stats['evidence'], [min(1., 4*np.pi*area/(perimeter*perimeter)),
                                  stats['edge_count']/area, stats['texture_count']/area])
        centered = np.array([xx-xx.mean(), yy-yy.mean()])
        covariance = centered@centered.T
        tolerance = 64*np.finfo(float).eps*np.trace(covariance)
        oriented = max(abs(covariance[0, 0]-covariance[1, 1]),
                       abs(2*covariance[0, 1])) > tolerance
        assert stats['oriented'] == oriented
        if oriented:
            _, axes = np.linalg.eigh(covariance)
            expected = math.atan2(axes[1, -1], axes[0, -1]) % np.pi
            difference = abs((stats['orientation']-expected+np.pi/2) % np.pi-np.pi/2)
            assert difference < 3e-12, difference
    lines = []
    for dx, dy in ((1, 0), (0, 1), (1, 1), (-1, 1)):
        for y, x in np.argwhere(labels != 0):
            region_id = labels[y, x]
            if 0 <= x-dx < w and 0 <= y-dy < h and labels[y-dy, x-dx] == region_id:
                continue
            nx, ny, length = x, y, 1
            while 0 <= nx+dx < w and 0 <= ny+dy < h and labels[ny+dy, nx+dx] == region_id:
                nx, ny, length = nx+dx, ny+dy, length+1
            if length >= 2:
                lines.append((x+ox, y+oy, nx+ox, ny+oy, int(region_id), length))
    assert sorted(map(tuple, actual['lines'])) == sorted(lines)
    return max_error


def make_case(kind, diagonal, seeded, cell, distance, block, disk):
    h, w = 13, 19
    yy, xx = np.indices((h, w))
    rng = np.random.default_rng(20261122+kind)
    if kind == 0:
        state = np.where((xx % 4 == 0) | (yy == h-1), 1, 0)
    elif kind == 1:
        state = ((xx+yy) % 2 == 0).astype(int)
    elif kind == 2:
        state = np.ones((h, w), dtype=int)
    else:
        state = (rng.random((h, w)) > .3).astype(int)
    state[(xx*7+yy*11) % 17 == 0] = 2
    valid = (xx*13+yy*3) % 29 != 0
    if kind == 2:
        valid[:] = True  # square-cell isotropy and repeated-color regions
    color = np.stack([xx//4 % 2, yy//4 % 2, (xx+yy)//7 % 2], axis=-1).astype(float)
    if kind == 3:
        color = rng.random((h, w, 3))
    samples = []
    for y, x in np.ndindex(h, w):
        samples.append([int(state[y, x]), bool(valid[y, x]), *map(float, color[y, x]),
                        float((x-y)/16) if (x+y) % 3 else None,
                        float((x*y) % 13)/16 if (x+2*y) % 4 else None])
    return dict(width=w, height=h, origin_x=2**53+37, origin_y=31,
                samples=samples, diagonal=diagonal, seeded=seeded, cell=cell,
                distance=distance, block=block, disk=disk, limit=1024)


policies = [(diagonal, seeded, cell, distance)
            for diagonal in (False, True) for seeded in (False, True)
            for cell, distance in ((0, None), (0, 0.), (0, .75), (5, None))]
cases = [make_case(kind, *policy, block, disk)
         for kind in range(4) for policy in policies
         for block in (1, 7, 256) for disk in (False, True)]
for adapter in ('canny', 'image'):
    for block in (1, 7, 256):
        for disk in (False, True):
            case = make_case(2, True, adapter == 'canny', 0, None, block, disk)
            case.update(origin_x=0, origin_y=0, adapter=adapter)
            for i, sample in enumerate(case['samples']):
                x, y = i % case['width'], i // case['width']
                sample[2] = float((x*17+y*31+x*y) % 97)/128
            cases.append(case)
scene_hash = None
if args.scene:
    from PIL import Image
    scene_hash = hashlib.sha256(args.scene.read_bytes()).hexdigest()
    # A fixed crop preserves source pixels; preprocessing is explicit test-provider
    # feature data, not a claim that this is OKLab or a trained semantic label.
    image = np.asarray(Image.open(args.scene).convert('RGB'))[183:279, 273:401]
    h, w, _ = image.shape
    color = image.astype(float)/255
    intensity = color.mean(axis=2)
    gy, gx = np.gradient(intensity)
    samples = [[1, True, *map(float, color[y, x]),
                float(intensity[y, x]**2), float(math.hypot(gx[y, x], gy[y, x]))]
               for y, x in np.ndindex(h, w)]
    for block, disk in ((16, False), (127, False), (16, True), (127, True)):
        cases.append(dict(width=w, height=h, origin_x=273, origin_y=183, samples=samples,
                          diagonal=True, seeded=False, cell=16, distance=.12,
                          block=block, disk=disk, limit=16384))

with tempfile.TemporaryDirectory(prefix='imagery-components-') as temp:
    path = Path(temp)/'input.json'
    for index, case in enumerate(cases):
        case['disk_path'] = str(Path(temp)/f'labels-{index}.bin')
    path.write_text(json.dumps(cases, allow_nan=False))
    outputs = json.loads(subprocess.check_output([args.consumer, str(path)], text=True))
    assert len(outputs) == len(cases)
    maximum = 0.
    for case, output in zip(cases, outputs):
        maximum = max(maximum, check(case, output))
    for index in range(0, len(cases)-4*bool(args.scene), 6):
        # Same source/domain/policy: IDs, all statistics, contacts and lines must
        # be identical across partitions and RAM/disk backings, not merely close.
        for field in ('labels', 'validity', 'regions', 'contacts', 'lines'):
            for offset in range(1, 6):
                assert outputs[index][field] == outputs[index+offset][field]
    print(f"Components: {len(cases)} graph/reference cases, "
          f"{sum(c['width']*c['height'] for c in cases)} pixels; "
          f"exact canonical labels/validity/contacts/lines; statistic max error={maximum:.9g}")
    print(f"Scratch range={min(o['scratch_bytes'] for o in outputs)}.."
          f"{max(o['scratch_bytes'] for o in outputs)} bytes; "
          f"largest provider window={max(o['max_source_window'] for o in outputs)} pixels")
    if args.scene:
        for field in ('labels', 'validity', 'regions', 'contacts', 'lines', 'crop_labels', 'crop_validity'):
            for output in outputs[-3:]:
                assert output[field] == outputs[-4][field]
        print(f"Scene SHA256={scene_hash}; crop=273,183,128,96; RGB/255 single-link=.12; source cells=16")
        for case, output in zip(cases[-4:], outputs[-4:]):
            print(json.dumps({key: output[key] for key in ('elapsed_ns', 'gc_bytes', 'scratch_bytes',
                              'source_reads', 'source_pixels')} | {'block': case['block'], 'disk': case['disk'],
                              'regions': len(output['regions'])}, sort_keys=True))
    if args.benchmark:
        assert args.scene, '--benchmark needs --scene'
        benchmark_cases = []
        # One warm-up + five pairs, alternating RAM/disk order by round.
        for round_number in range(6):
            pair = [cases[-4], cases[-2]]
            benchmark_cases.extend(pair if round_number % 2 == 0 else pair[::-1])
        path.write_text(json.dumps(benchmark_cases, allow_nan=False))
        timed = json.loads(subprocess.check_output([args.consumer, str(path)], text=True))
        for i, (case, output) in enumerate(zip(benchmark_cases, timed)):
            check(case, output)
            print(json.dumps({'round': i//2, 'warmup': i < 2, 'disk': case['disk'],
                              **{key: output[key] for key in ('elapsed_ns', 'gc_bytes', 'scratch_bytes')}}))
