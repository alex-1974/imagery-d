# M3 blend-mode and validity qualification plan

The next independent consumer extends the RGBA source-over matrix with
`multiply`, `screen`, `darken` and `lighten` channel oracles, then exercises
the explicit validity flags separately from alpha. All modes must preserve
whole-vs-partition equality and invalid-contributor behavior.
