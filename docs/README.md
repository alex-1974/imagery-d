# Using imagery-d

Start with decoded image samples, choose an operation, and decide whether its
result can use your existing buffers or needs an independently owned raster.

| Your question | Read |
| --- | --- |
| How do I add the library to a project? | [Installation and configurations](how-to/install.md) |
| How do I adjust a decoded RGB image? | [Levels tutorial](tutorial/levels.md) |
| Which entry point should I use? | [Choose an API](how-to/choose-an-api.md) |
| How do I read or write an image? | [Image I/O](how-to/image-io.md) |
| How do I request reusable image features? | [Feature requests](how-to/features.md) |
| What do masks, regions and borrowed outputs mean? | [Image data](concepts/image-data.md) |
| What does a term mean here? | [Glossary](glossary.md) |
| What are the numerical and performance limits? | [Accuracy and validation](accuracy-and-validation.md) |

The [versioned reference](https://alex-1974.github.io/imagery-d/v0.4.0/) defines
each public symbol's inputs, units, result and failure behavior. For a checkout's
current source reference, run `bash tools/build-docs.sh` from the repository root
and open `build/ddox/site/index.html`.

For implementation work, start with [CONTRIBUTING](../CONTRIBUTING.md) and the
[code layout](ARCHITECTURE.md). Design rationale lives in [ADRs](adr/);
measurements and experiments live in the
[released evidence](https://github.com/alex-1974/imagery-d/tree/v0.4.0/docs/benchmarks)
and [research repository](https://github.com/alex-1974/imagery-d-research).
