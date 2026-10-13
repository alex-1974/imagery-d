# M3 research: modular imagery import surface

**Status:** Executable research prototype only. Not an admitted public package, source compatibility promise, API freeze or M3 production ADR.
Tracking: [Issue #64](https://github.com/alex-1974/imagery-d/issues/64) and [draft PR #65](https://github.com/alex-1974/imagery-d/pull/65).
Parent: [M3 first-slice selection](m3-first-production-slice-selection.md) and [M3.2 evidence review](m3-2-evidence-admission-review.md).

## 1. Prototype folder and actual D import contract

Production root dub.sdl and production source/imagery/ are deliberately NOT created because the [M3 Roadmap](../../ROADMAP.md) still gates public admission.
Instead the compiled prototype lives under experiments/m3_module_import_surface/, with a DUB library and a **separate DUB executable consumer** under its smoke/ directory.

| Import in an independent D consumer | Provisional exposed contract |
| --- | --- |
| `import imagery;` | Curated root: imagery.core only, no presentation symbols. |
| `import imagery.core;` | ChannelDescriptor, IntrinsicChannel, ImageView, M1.5 view validation/factory. |
| `import imagery.core.channel;` | ChannelDescriptor only. |
| `import imagery.core.metadata;` | IntrinsicChannel only. |
| `import imagery.core.image;` | ImageView and its original checked construction. |
| `import imagery.presentation;` | ColourBinding, DeclaredColour, ValueInterpretation, ResearchLongLivedMetadataSource, SourceRoiError. |
| `import imagery.presentation.channels;` | Same directly importable selection/ROI metadata-source concepts. |
| `import imagery.all;` | Core plus presentation together. |
| `import imagery.core.channel : ChannelDescriptor;` | A specific public name from a specific module. |

Each directory-level entry point is a real D **package.d** with `module imagery.core;` (or analogous module name) and selected `public import` statements. A separate `imagery.all` module deliberately exports all currently implemented prototype groups; the normal `imagery` root does not. All types are imported from **existing, separately tested M1.5/M3.2 research modules** rather than duplicated or stubbed.

**Important:** Research names, including ResearchLongLivedMetadataSource and ImageView, do not become production API names simply because this prototype can import them.

## 2. Standalone DUB consumer test

The experimental package is a DUB `library`, with raster-d as its only external library dependency. Its smoke/ directory has a separate DUB manifest and a path dependency on the library. This is a genuine dependent package, not merely several imports compiled inside the library.

Five independent consumer modules test the curated root, the core family, presentation family, broad all import, and precise module/symbol imports. Static `__traits(compiles, ...)` tests check both visible names and intentional *nonvisibility*, for example that `import imagery;` does not expose ColourBinding.

Runtime tests construct real channel metadata, snapshot mutable arrays into immutable metadata, mutate the old aliases, assert the original snapshot remains intact, explicitly publish a refreshed snapshot, and use genuinely immutable arrays through fromImmutable. The selection binding is explicit and ordered. No empty future feature modules are involved.

CI builds and runs the independent consumer using **DMD 2.111/2.113 and LDC 1.41/1.43**, both debug and release, with the tagged raster-d v0.2.0 dependency. The inherited M3.2 real ROI/pixel/lifetime research remains separate and unchanged.

From the imagery-d repository root with raster-d adjacent:

~~~bash
for compiler in dmd ldc2; do
  dub run --root=experiments/m3_module_import_surface/smoke \
    --compiler="$compiler" --config=default --build=debug --force
  dub run --root=experiments/m3_module_import_surface/smoke \
    --compiler="$compiler" --config=default --build=release --force
done
~~~

## 3. Do not confuse imports and package/build isolation

Selective `import` controls symbol visibility, not the transitive DUB dependency set, what a complete library build compiles, or what the linker drops. This experiment intentionally has **one DUB library** and **no required color-d or imageio-d dependency**. The developing imageio-d should remain independently composable with raster-d-based images; an adapter dependency is introduced only after a real decoder/source consumer requires it.

Potential later DUB subpackages such as `imagery-d:filters` or `imagery-d:color` can have separate dependencies. They add build/test/release surface, so we should introduce them only when optional dependencies or build isolation are proved useful. A hierarchical D import tree does not require multiple Git repositories or DUB packages.

The names imagery.filters, imagery.analysis, imagery.transform, imagery.color and imagery.source are **reserved only as future design candidates**, not created as empty modules. Those families must first have an admitted image-domain function and nonduplicative responsibility relative to raster-d/color-d/imageio-d.

## 4. Public admission remains gated

Per the shared DLANG_PRACTICES.md section 3.6, review separately the curated root import, directly supported module imports, technically importable internals and package/internal symbols. A minimal root does not make other technical modules automatically private.

Before moving any of this into production, select an actual downstream consumer, settle invalidity/error/borrow contracts, account for all source/result memory, qualify optimized reference performance, and accept an explicit M3 ADR. Only then port the smallest tested implementation into a clean topic from develop, with public docs and external DUB consumer checks.

**No develop merge, research-integration merger, sibling repository change, or public imagery-d DUB/API admission occurs in this prototype.**
