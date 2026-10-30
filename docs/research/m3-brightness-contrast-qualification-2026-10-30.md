# M3 Brightness/Contrast qualification

The independent consumer covers planar/interleaved layouts with positive and
negative row strides over a complete ROI, checks output bounds and 18,468
component values, and remains outside
`source/imagery`. A horizontal two-packet partition is compared exactly with
the corresponding rows of the whole-ROI result. The current LDC Release
receipt is:

```text
M3_BRIGHTNESS_CONTRAST_QUALIFICATION=PASS;component_checks:18468;layouts:planar,interleaved;partition_oracle:PASS
```

The qualification covers layout, ROI, partition and graded-mask behavior. A
full DMD/LDC matrix remains the CI admission gate.
