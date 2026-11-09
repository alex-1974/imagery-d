# Dunia consumer capability matrix

**Date:** 2026-10-30  
**Status:** research input; no public API admission

## Evidence from established libraries

The common imagery/raster libraries converge on a capability set rather than
one monolithic image type:

- GDAL models datasets, bands, geotransforms, CRS, NoData masks, statistics,
  scale/offset and overviews. Its raster tools cover translate, window/clip,
  algebra, fill-NoData, mosaic, overview creation, resize and reprojection.
  Sources: <https://gdal.org/en/stable/user/raster_data_model.html> and
  <https://gdal.org/en/stable/programs/gdal_raster.html>.
- Rasterio exposes windowed reads, explicit resampling and reprojection between
  source and destination grids. Its documentation explicitly warns that
  nearest-neighbour is not suitable for every continuous-data use case.
  Sources: <https://rasterio.readthedocs.io/en/stable/topics/reproject.html>
  and <https://rasterio.readthedocs.io/en/stable/topics/resampling.html>.
- libvips provides arithmetic, histograms, convolution, morphology, colour,
  resampling, statistics, alpha handling and compositing over many numeric
  formats, with demand-driven threaded execution. Source:
  <https://www.libvips.org/>.

The practical baseline is therefore: bounded region access; metadata and
validity; resampling/reprojection boundaries; radiometric and presentation
operations; statistics; compositing/mosaics; and multiresolution access.
File-format decoding and network scheduling are normally separate layers.

## Dunia-specific workload from the workspace research

The workspace documents identify Dunia as an interactive geospatial consumer,
not as an imagery-d-specific data model. For satellite and orthophoto use it
must be able to:

1. request a visible region progressively and cancel obsolete requests;
2. consume single scenes and overlapping scenes without requiring the complete
   mosaic in RAM;
3. select an overview/resolution appropriate to the display scale;
4. resample/reproject onto the display grid with explicit kernels and pixel
   semantics;
5. preserve CRS, ground extent, geotransform, resolution/GSD, provenance,
   alpha/masks and NoData alongside the pixels;
6. apply display transforms such as brightness, contrast, gamma, saturation,
   opacity and RGB/NIR-derived presentation without changing source meaning;
7. calculate statistics/histograms and support valid-pixel selection;
8. blend overlaps with an explicit validity/quality policy, including seam
   handling; and
9. support ordinary raster operations (crop/ROI, channel selection, band
   arithmetic, colour mapping and export) without assuming satellite identity.

These requirements come from `RESEARCH.md` R02–R07, `DESIGN.md` sections 2,
4, 5 and 8, `docs/research/m2-reference-consumer-validation.md`, and ADR 0002.
The documents explicitly keep CRS transformation, source backends, caches and
scheduling outside the image-operation kernel.

## Boundary and implementation order

### Dunia / source adapter responsibilities

Dunia (or an optional source adapter) owns file/network decoding, COG/GeoTIFF
access, tile scheduling, CRS choice and transformation setup, provenance,
scene comparability, cloud/acquisition policy, and construction of validity or
quality fields.

### imagery-d responsibilities

imagery-d should provide tested, region-first operations over caller-supplied
rasters: radiometric/presentation transforms, statistics, explicit resampling,
mask/NoData-aware arithmetic, alpha/compositing, and deterministic overlap
blending/mosaic assembly. It must not infer registration, quality, cloud
status, CRS or provenance.

### Admission sequence

The next consumer-backed slices should be:

1. **Region + metadata contract:** a Dunia fixture carrying CRS/extent/GSD,
   masks and NoData, with cancellation/progressive stages represented outside
   the kernel.
2. **Continuous-data resampling:** nearest, bilinear and one area-aware
   downsampling contract, with whole-vs-partition and NoData tests.
3. **Display pipeline:** histogram/statistics plus levels/contrast/gamma and
   RGB/NIR presentation, preserving source values and masks.
4. **Overlap policy:** construct the explicit weight/validity field in the
   consumer, then call imagery-d's linear-light blend; add more than two
   contributors only after the ownership and alpha contract is settled.
5. **Mosaic/overview integration:** connect overview selection and bounded
   decoded tiles to the source adapter, without introducing a scheduler or
   backend into imagery-d.

No public mosaic or geospatial metadata API should be admitted until the first
slice has a real Dunia caller and an agreed result/ownership contract.
