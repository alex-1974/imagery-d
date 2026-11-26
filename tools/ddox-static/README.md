# DDox static resources

Unmodified `public/` resources from DDox 0.16.24. `manifest.json` records the
upstream commit, source archive SHA-256 and every installed file's SHA-256.
The files were compared with the same pinned DUB package.

DDox's HTML generator does not copy these files: its
[offline documentation instructions](https://github.com/dlang/ddox/blob/v0.16.24/README.md#generating-offline-documentation)
require copying `public/` separately. Keeping the small bundle here lets Pages
restore historical releases without installing a compiler or fetching an
unversioned theme. Both the build and the legacy repair use this bundle.

The DDox MIT license is included as `public/LICENSE-DDOX.txt`. The bundled
jQuery 3.5.1 retains its upstream notice and MIT license in
`public/LICENSE-JQUERY.txt`. Both licenses are copied into the rendered site.
Do not modify minified upstream files. Upgrade the generator, bundle, provenance
and compatibility tests together.
