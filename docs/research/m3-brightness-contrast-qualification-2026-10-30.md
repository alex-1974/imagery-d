# M3 Brightness/Contrast qualification

The independent consumer covers planar/interleaved layouts over a complete
ROI, checks output bounds and 9,216 component values, and remains outside
`source/imagery`. A horizontal two-packet partition is compared exactly with
the corresponding rows of the whole-ROI result. The current LDC Release
receipt is:

```text
M3_BRIGHTNESS_CONTRAST_QUALIFICATION=PASS;component_checks:9216;layouts:planar,interleaved;partition_oracle:PASS
```

Negative-stride and graded-mask cases remain the next extension before public
admission.
