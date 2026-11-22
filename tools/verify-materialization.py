"""Independent rational/source-center and YCbCr reference using real JPEG planes.

The consumer decodes Pillow-produced 420/422 JPEGs through public imageio.
Declared test-provider metadata is explicit; unknown decoder facts must fail.
"""
from fractions import Fraction
from pathlib import Path
import json
import math
import subprocess
import sys
import tempfile
import hashlib

import numpy as np
from PIL import Image


def verify(consumer, rgb_fixed=False):
    with tempfile.TemporaryDirectory(prefix='imagery-materialization-') as directory:
        yy, xx = np.mgrid[:13, :19]
        rgb = np.stack([(xx*17+yy*11) % 256, (xx*29+yy*7) % 256,
                        (xx*3+yy*31) % 256], axis=-1).astype(np.uint8)
        fixtures = []
        for subsampling, name in [(2, '420'), (1, '422')]:
            path = Path(directory)/f'{name}.jpg'
            Image.fromarray(rgb).save(path, quality=91, subsampling=subsampling)
            fixtures.append(str(path))
        rgb[3, 5] = 0
        ppm = Path(directory)/'georeference.ppm'
        Image.fromarray(rgb).save(ppm)
        rgb_tiff = Path(directory)/'rgb-georeference.tif'
        subprocess.check_call(['gdal_translate', '-q', '-of', 'GTiff', '-a_srs', 'EPSG:32633',
                               '-a_ullr', '500000', '5200000', '500038', '5199974', '-a_nodata', '0',
                               '-co', 'TILED=YES', '-co', 'BLOCKXSIZE=16', '-co', 'BLOCKYSIZE=16',
                               '-co', 'COMPRESS=NONE', str(ppm), str(rgb_tiff)])
        geotiff = Path(directory)/'georeference.tif'
        subprocess.check_call(['gdal_translate', '-q', '-b', '1', str(rgb_tiff), str(geotiff)])
        fixtures.append(str(geotiff))
        fixtures.append(str(rgb_tiff))
        gdal = json.loads(subprocess.check_output(['gdalinfo', '-json', str(geotiff)], text=True))
        hashes = {Path(p).name: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in fixtures}
        data = json.loads(subprocess.check_output([consumer, *fixtures], text=True))
        handoff = data['region_handoff']
        assert handoff['crs'] == 'EPSG:32633' and '32633' in gdal['coordinateSystem']['wkt']
        np.testing.assert_array_equal(handoff['source_transform'], gdal['geoTransform'])
        assert handoff['roi_transform'] == [500006., 2., 0., 5199998., 0., -2.]
        assert handoff['extent'] == [500006., 5199984., 500024., 5199998.]
        assert handoff['first_pixel_center'] == [500007., 5199997.] and handoff['gsd'] == [2., 2.]
        assert handoff['bands'] == ['intensity'] and handoff['alpha'] == 'absent'
        assert all(band['noDataValue'] == handoff['nodata'] == 0 for band in gdal['bands'])
        expected_roi = rgb[1:8, 3:12, 0]
        np.testing.assert_array_equal(np.array(handoff['pixels']).reshape(7, 9), expected_roi)
        np.testing.assert_array_equal(np.array(handoff['validity']).reshape(7, 9), expected_roi != 0)
        assert handoff['owned_bytes'] == 63
        assert data['rgb_tiff_decoder_status'] == ('none' if rgb_fixed else 'unsupportedLayout')
        if rgb_fixed:
            rgb_handoff = data['rgb_region_handoff']
            np.testing.assert_array_equal(np.array(rgb_handoff['pixels']).reshape(7, 9, 3), rgb[1:8, 3:12])
            np.testing.assert_array_equal(np.array(rgb_handoff['validity']).reshape(7, 9), np.any(rgb[1:8, 3:12] != 0, axis=-1))
            for key in ['crs', 'roi_transform', 'extent', 'first_pixel_center', 'gsd']:
                assert rgb_handoff[key] == handoff[key]
            assert rgb_handoff['bands'] == ['red', 'green', 'blue'] and rgb_handoff['owned_bytes'] == 189
    maximum = {'double': 0., 'float': 0., 'ubyte': 0.}
    pixels = 0
    for case in data['cases']:
        output = []
        planes = case['planes']
        arrays = [np.array(p['bytes']).reshape(p['height'], p['width']) for p in planes]
        for y in range(case['y'], case['y']+case['height']):
            for x in range(case['x'], case['x']+case['width']):
                samples = []
                for index in case['indices']:
                    p, a = planes[index], arrays[index]
                    gx, gy, cx, cy = [Fraction(n, d) for n, d in p['offset_rationals']]
                    sx = max(Fraction(0), min(Fraction(p['width']-1),
                             (Fraction(x)-gx-cx)/p['factor_x']-p['x']))
                    sy = max(Fraction(0), min(Fraction(p['height']-1),
                             (Fraction(y)-gy-cy)/p['factor_y']-p['y']))
                    if case['filter'] == 'nearest':
                        sample = Fraction(int(a[math.floor(sy+Fraction(1, 2)), math.floor(sx+Fraction(1, 2))]))
                    else:
                        x0, y0 = math.floor(sx), math.floor(sy)
                        x1, y1 = min(x0+1, p['width']-1), min(y0+1, p['height']-1)
                        fx, fy = sx-x0, sy-y0
                        sample = (int(a[y0, x0])*(1-fx)+int(a[y0, x1])*fx)*(1-fy)
                        sample += (int(a[y1, x0])*(1-fx)+int(a[y1, x1])*fx)*fy
                    samples.append(float(sample))
                yv, cb, cr = samples
                if case['range'] == 0:
                    yv, cb, cr = yv/255, cb/255-.5, cr/255-.5
                else:
                    yv, cb, cr = (yv-16)/219, (cb-128)/224, (cr-128)/224
                coefficients = (1.402, .344136, .714136, 1.772) if case['matrix'] == 0 else (1.5748, .187324, .468124, 1.8556)
                rcr, gcb, gcr, bcb = coefficients
                output.append([yv+rcr*cr, yv-gcb*cb-gcr*cr, yv+bcb*cb])
        expected = np.array(output).reshape(-1)
        actual = np.array(case['rgb'])
        if case['sample'] == 'ubyte':
            scaled = expected.clip(0, 1)*255
            rounded = np.floor(scaled+.5)
            difference = abs(actual-rounded)
            for i in np.flatnonzero(difference):
                assert difference[i] == 1 and abs(scaled[i] % 1-.5) < 1e-10
            error = difference.max(initial=0)
        else:
            error = abs(actual-expected).max(initial=0)
            tolerance = 3e-15 if case['sample'] == 'double' else 2e-7
            np.testing.assert_allclose(actual, expected, rtol=0, atol=tolerance)
        maximum[case['sample']] = max(maximum[case['sample']], float(error))
        pixels += case['width']*case['height']
    assert len(data['cases']) == 193 and data['decoder_regions'] == 4
    assert data['error_checks'] >= 31
    print(f"Materialization: {len(data['cases'])} cases / {pixels} pixels; maxima={maximum}; "
          f"4 real JPEG regions, {data['error_checks']} structured failure/rollback probes")
    print(f"Dunia handoff: real GeoTIFF / GDAL metadata and visible pixels agree; "
          f"CRS/transform/GSD/bands/NoData/validity/origin preserved after decoder result release; hashes={hashes}")
    print('RGB GeoTIFF: fixed decoder and full RGB handoff pass' if rgb_fixed else
          'RGB GeoTIFF: released imageio-d 0.1.1 unsupportedLayout is an explicit dependency blocker')


if __name__ == '__main__':
    verify(str(Path(sys.argv[1]).resolve()), '--rgb-decoder-fixed' in sys.argv[2:])
