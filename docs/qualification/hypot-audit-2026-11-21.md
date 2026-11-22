# Phobos 2.111 hypot audit

Issue #17. Source baseline: develop `819492a` and feature-program changes.
Declared minimum frontend: 2.111.0. Controlled compiler matrix: DMD
2.111.0/2.112.1/2.113.0 and LDC 1.41.0/1.42.0/1.43.0, fixed DUB 1.40.0.

`rg '\bhypot\b' source` found no imagery-d call. The gradient implementations
use direct or scaled square-root norms. Component distance uses explicit
squared differences. None reaches the affected Phobos two-argument overload.

The used color-d 0.4.0 operations cover sRGB transfer, XYZ/OKLab conversion,
YCbCr conversion and compositing. Its `color.difference` module contains
two-argument hypot calls, but those routines are not called by imagery-d's
processing paths. Its OKLCh implementation separately documents avoiding the
Phobos tiny-operand defect. raster-d 0.5.5, imageio-d 0.1.1 and transport-d
0.2.1 had no hypot matches in their installed source trees.

Decision: imagery-d processing is unaffected by this specific defect. No
numerical workaround or euclid-core-d dependency is added. This does not
assert that direct sqrt(x*x+y*y) is universally underflow-safe; its behavior
has a separate numerical contract and must not be silently changed as part
of this audit.
