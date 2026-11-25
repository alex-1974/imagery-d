# Add imagery-d to a DUB application

Use the tagged GitHub source until imagery-d is registered on DUB. The commands
below place the library and application next to each other:

```sh
git clone --branch v0.4.0 --depth 1 https://github.com/alex-1974/imagery-d.git
mkdir -p image-example/source
cd image-example
```

Create `dub.sdl` in the application directory:

```sdl
name "image-example"
targetType "executable"
sourcePaths "source"
dependency "imagery-d" path="../imagery-d"
subConfiguration "imagery-d" "no-io"
```

Copy the complete D program from the [README](../../README.md#a-first-example)
into `source/app.d`, then run:

```sh
dub run --compiler=dmd
```

LDC callers can use `--compiler=ldc2`. The published frontend floor is 2.111.0;
see [support status](../../README.md#status) for the qualified versions/platform.
The relative dependency path is resolved from the application's `dub.sdl`.

## Choose a configuration

| Library configuration | Use it when | Effect |
| --- | --- | --- |
| `default` | You want imagery's file/URL integration and writer forwards | Enables `imagery.io` with imageio-d and transport-d |
| `no-io` | Your application supplies decoded pixels | Leaves the file/URL convenience integration out of the compiled processing surface |

The example selects `no-io` through `subConfiguration`. Remove that line to
use the default configuration. When building the library itself, use
`dub build --config=no-io`; an application's `--config` selects its own
configuration, not automatically its dependency's configuration.

DUB can resolve optional recipe dependencies even for `no-io`. That does not
mean the I/O helpers execute or are exposed in that configuration. The declared
version ranges are listed in [related libraries](../../README.md#related-libraries).

To reproduce an existing application, retain its resolved dependency versions.
The library's pre-1.0 policy permits source changes between minor releases.
