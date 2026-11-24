# Verbatim distinct hot-source LLVM remarks

## portable

```text
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: value that could not be identified as reduction is used outside the loop
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:38:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_output32.d:38:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:40:38: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:57:64: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/feature_output32.d:57:64: vectorized loop (vectorization width: 2, interleaved count: 1)
remark: source/imagery/analysis/feature_output32.d:57:64: vectorized loop (vectorization width: 4, interleaved count: 1)
remark: source/imagery/analysis/feature_output32.d:57:64: vectorized loop (vectorization width: 4, interleaved count: 2)
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Auto-vectorization of loops with potentially faulting load is not supported
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop with strided fault-only-first load
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: loop control flow is not understood by vectorizer
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: value that could not be identified as reduction is used outside the loop
remark: source/imagery/analysis/feature_worker32.d:124:9: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized: value that could not be identified as reduction is used outside the loop
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: loop control flow is not understood by vectorizer
remark: source/imagery/analysis/feature_worker32.d:435:21: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:435:21: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:444:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:445:21: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized: loop control flow is not understood by vectorizer
remark: source/imagery/analysis/feature_worker32.d:462:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:462:17: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:100:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:101:13: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:101:13: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/hessian_lines.d:101:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:143:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:144:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:146:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:151:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:175:19: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:203:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:78:9: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/hessian_lines.d:78:9: vectorized loop (vectorization width: 2, interleaved count: 1)
remark: source/imagery/analysis/hessian_lines.d:81:13: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:81:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/hessian_lines.d:81:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:81:43: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:84:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:85:17: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:85:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:96:9: vectorized loop (vectorization width: 2, interleaved count: 2)
remark: source/imagery/analysis/hessian_lines.d:99:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:209:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:211:32: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:248:38: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:265:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized: Cannot vectorize early exit loop
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:287:9: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/path_kernels.d:287:9: vectorized loop (vectorization width: 16, interleaved count: 1)
remark: source/imagery/analysis/path_kernels.d:307:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:125:29: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:128:29: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:128:29: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:129:29: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:129:29: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:140:86: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:141:61: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: Early exit loop with store but no supported condition load
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:170:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:170:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:170:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:170:13: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/row_kernels.d:170:13: the cost-model indicates that vectorization is not beneficial
remark: source/imagery/analysis/row_kernels.d:173:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:173:13: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:191:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:191:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:232:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:232:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:252:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:252:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:254:17: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:254:17: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/row_kernels.d:254:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:262:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:266:33: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:67:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:106:13: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:106:13: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
remark: source/imagery/analysis/structure_tensor.d:106:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:106:44: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:129:17: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:129:17: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/structure_tensor.d:131:13: vectorized loop (vectorization width: 2, interleaved count: 2)
remark: source/imagery/analysis/structure_tensor.d:139:9: vectorized loop (vectorization width: 2, interleaved count: 2)
remark: source/imagery/analysis/structure_tensor.d:194:22: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:212:9: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:212:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:212:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:214:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/structure_tensor.d:79:9: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:79:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:82:9: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/structure_tensor.d:82:9: vectorized loop (vectorization width: 2, interleaved count: 1)
remark: source/imagery/analysis/window_kernels.d:112:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:114:18: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:121:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:125:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:126:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:131:30: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:133:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:133:38: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:136:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:137:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:137:45: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:140:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:141:34: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:141:55: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:142:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:199:16: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:202:27: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:211:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:21:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:220:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:220:41: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:221:33: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:221:64: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:225:45: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:225:65: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:234:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:236:40: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:236:64: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:237:28: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:237:56: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:240:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:241:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:249:5: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:268:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:272:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:285:39: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:67:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:68:44: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:68:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:83:88: loop not vectorized: unsafe dependent memory operations in loop. Use #pragma clang loop distribute(enable) to allow loop distribution to attempt to isolate the offending operations into a separate loop
remark: source/imagery/analysis/window_kernels.d:83:9: loop not vectorized
remark: source/imagery/analysis/window_kernels.d:83:9: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
```

Unlocated remarks from the complete build, grouped verbatim with occurrence counts. LLVM supplies no source location here; these cannot safely be attributed to a particular kernel.

```text
1400 x remark: <unknown>:0:0: loop not vectorized
89 x remark: <unknown>:0:0: loop not vectorized: Auto-vectorization of loops with potentially faulting load is not supported
51 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop
85 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
434 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
21 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
43 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with strided fault-only-first load
268 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize uncountable loop
335 x remark: <unknown>:0:0: loop not vectorized: Control flow cannot be substituted for a select
1 x remark: <unknown>:0:0: loop not vectorized: Early exit loop contains operations that cannot be speculatively executed
13 x remark: <unknown>:0:0: loop not vectorized: Early exit loop with store but no supported condition load
14 x remark: <unknown>:0:0: loop not vectorized: Incorrect number of successors from early exiting block
15 x remark: <unknown>:0:0: loop not vectorized: Loop contains an unsupported switch
1 x remark: <unknown>:0:0: loop not vectorized: Value cannot be used outside the loop
24 x remark: <unknown>:0:0: loop not vectorized: cannot identify array bounds
484 x remark: <unknown>:0:0: loop not vectorized: could not determine number of loop iterations
615 x remark: <unknown>:0:0: loop not vectorized: instruction cannot be vectorized
32 x remark: <unknown>:0:0: loop not vectorized: loop control flow is not understood by vectorizer
387 x remark: <unknown>:0:0: loop not vectorized: loop induction variable could not be identified
874 x remark: <unknown>:0:0: loop not vectorized: value that could not be identified as reduction is used outside the loop
5 x remark: <unknown>:0:0: loop not vectorized: write to a loop invariant address could not be vectorized
71 x remark: <unknown>:0:0: the cost-model indicates that interleaving is not beneficial
46 x remark: <unknown>:0:0: the cost-model indicates that vectorization is not beneficial
50 x remark: <unknown>:0:0: vectorized loop (vectorization width: 16, interleaved count: 2)
17 x remark: <unknown>:0:0: vectorized loop (vectorization width: 2, interleaved count: 1)
131 x remark: <unknown>:0:0: vectorized loop (vectorization width: 2, interleaved count: 2)
8 x remark: <unknown>:0:0: vectorized loop (vectorization width: 4, interleaved count: 1)
78 x remark: <unknown>:0:0: vectorized loop (vectorization width: 4, interleaved count: 2)
17 x remark: <unknown>:0:0: vectorized loop (vectorization width: 8, interleaved count: 2)
```

## v3

```text
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: value that could not be identified as reduction is used outside the loop
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:38:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_output32.d:38:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:40:38: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:57:64: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/feature_output32.d:57:64: vectorized loop (vectorization width: 4, interleaved count: 1)
remark: source/imagery/analysis/feature_output32.d:57:64: vectorized loop (vectorization width: 8, interleaved count: 1)
remark: source/imagery/analysis/feature_output32.d:57:64: vectorized loop (vectorization width: 8, interleaved count: 4)
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Auto-vectorization of loops with potentially faulting load is not supported
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop with strided fault-only-first load
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: loop control flow is not understood by vectorizer
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: value that could not be identified as reduction is used outside the loop
remark: source/imagery/analysis/feature_worker32.d:124:9: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized: value that could not be identified as reduction is used outside the loop
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: loop control flow is not understood by vectorizer
remark: source/imagery/analysis/feature_worker32.d:435:21: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:435:21: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:444:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:445:21: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized: loop control flow is not understood by vectorizer
remark: source/imagery/analysis/feature_worker32.d:462:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:462:17: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:100:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:101:13: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:101:13: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/hessian_lines.d:101:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:143:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:144:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:146:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:151:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:175:19: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:203:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:78:9: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/hessian_lines.d:78:9: vectorized loop (vectorization width: 4, interleaved count: 1)
remark: source/imagery/analysis/hessian_lines.d:81:13: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:81:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/hessian_lines.d:81:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:81:43: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:84:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:85:17: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:85:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:96:9: vectorized loop (vectorization width: 4, interleaved count: 4)
remark: source/imagery/analysis/hessian_lines.d:99:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:163:9: loop not vectorized
remark: source/imagery/analysis/path_kernels.d:163:9: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/path_kernels.d:172:17: loop not vectorized: unsafe dependent memory operations in loop. Use #pragma clang loop distribute(enable) to allow loop distribution to attempt to isolate the offending operations into a separate loop
remark: source/imagery/analysis/path_kernels.d:209:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:211:32: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:248:38: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:265:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized: Cannot vectorize early exit loop
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:287:9: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/path_kernels.d:287:9: vectorized loop (vectorization width: 32, interleaved count: 1)
remark: source/imagery/analysis/path_kernels.d:307:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:125:29: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:128:29: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:128:29: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:129:29: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:129:29: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:140:86: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:141:61: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: Early exit loop with store but no supported condition load
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:170:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:170:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:170:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:170:13: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/row_kernels.d:170:13: vectorized loop (vectorization width: 32, interleaved count: 1)
remark: source/imagery/analysis/row_kernels.d:173:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:173:13: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:191:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:191:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:232:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:232:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:252:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:252:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:254:17: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:254:17: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/row_kernels.d:254:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:262:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:266:33: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:67:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:106:13: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:106:13: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
remark: source/imagery/analysis/structure_tensor.d:106:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:106:44: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:129:17: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:129:17: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/structure_tensor.d:131:13: vectorized loop (vectorization width: 4, interleaved count: 4)
remark: source/imagery/analysis/structure_tensor.d:139:9: vectorized loop (vectorization width: 4, interleaved count: 4)
remark: source/imagery/analysis/structure_tensor.d:194:22: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:212:9: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:212:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:212:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:214:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/structure_tensor.d:79:9: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:79:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:82:9: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/structure_tensor.d:82:9: vectorized loop (vectorization width: 4, interleaved count: 1)
remark: source/imagery/analysis/window_kernels.d:112:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:114:18: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:121:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:125:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:126:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:131:30: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:133:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:133:38: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:136:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:137:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:137:45: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:140:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:141:34: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:141:55: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:142:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:199:16: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:202:27: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:211:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:21:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:220:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:220:41: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:221:33: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:221:64: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:225:45: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:225:65: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:234:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:236:40: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:236:64: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:237:28: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:237:56: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:240:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:241:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:249:5: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:268:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:272:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:285:39: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:67:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:68:44: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:68:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:83:88: loop not vectorized: unsafe dependent memory operations in loop. Use #pragma clang loop distribute(enable) to allow loop distribution to attempt to isolate the offending operations into a separate loop
remark: source/imagery/analysis/window_kernels.d:83:9: loop not vectorized
remark: source/imagery/analysis/window_kernels.d:83:9: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
```

Unlocated remarks from the complete build, grouped verbatim with occurrence counts. LLVM supplies no source location here; these cannot safely be attributed to a particular kernel.

```text
1400 x remark: <unknown>:0:0: loop not vectorized
89 x remark: <unknown>:0:0: loop not vectorized: Auto-vectorization of loops with potentially faulting load is not supported
51 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop
84 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
435 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
21 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
43 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with strided fault-only-first load
268 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize uncountable loop
339 x remark: <unknown>:0:0: loop not vectorized: Control flow cannot be substituted for a select
1 x remark: <unknown>:0:0: loop not vectorized: Early exit loop contains operations that cannot be speculatively executed
13 x remark: <unknown>:0:0: loop not vectorized: Early exit loop with store but no supported condition load
14 x remark: <unknown>:0:0: loop not vectorized: Incorrect number of successors from early exiting block
15 x remark: <unknown>:0:0: loop not vectorized: Loop contains an unsupported switch
1 x remark: <unknown>:0:0: loop not vectorized: Value cannot be used outside the loop
24 x remark: <unknown>:0:0: loop not vectorized: cannot identify array bounds
484 x remark: <unknown>:0:0: loop not vectorized: could not determine number of loop iterations
615 x remark: <unknown>:0:0: loop not vectorized: instruction cannot be vectorized
32 x remark: <unknown>:0:0: loop not vectorized: loop control flow is not understood by vectorizer
387 x remark: <unknown>:0:0: loop not vectorized: loop induction variable could not be identified
874 x remark: <unknown>:0:0: loop not vectorized: value that could not be identified as reduction is used outside the loop
5 x remark: <unknown>:0:0: loop not vectorized: write to a loop invariant address could not be vectorized
58 x remark: <unknown>:0:0: the cost-model indicates that interleaving is not beneficial
26 x remark: <unknown>:0:0: the cost-model indicates that vectorization is not beneficial
17 x remark: <unknown>:0:0: vectorized loop (vectorization width: 16, interleaved count: 4)
7 x remark: <unknown>:0:0: vectorized loop (vectorization width: 32, interleaved count: 1)
30 x remark: <unknown>:0:0: vectorized loop (vectorization width: 32, interleaved count: 2)
20 x remark: <unknown>:0:0: vectorized loop (vectorization width: 32, interleaved count: 4)
17 x remark: <unknown>:0:0: vectorized loop (vectorization width: 4, interleaved count: 1)
42 x remark: <unknown>:0:0: vectorized loop (vectorization width: 4, interleaved count: 2)
100 x remark: <unknown>:0:0: vectorized loop (vectorization width: 4, interleaved count: 4)
8 x remark: <unknown>:0:0: vectorized loop (vectorization width: 8, interleaved count: 1)
25 x remark: <unknown>:0:0: vectorized loop (vectorization width: 8, interleaved count: 2)
55 x remark: <unknown>:0:0: vectorized loop (vectorization width: 8, interleaved count: 4)
```

## native

```text
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:24:66: loop not vectorized: value that could not be identified as reduction is used outside the loop
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_output32.d:29:32: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:38:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_output32.d:38:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:40:38: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_output32.d:57:64: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/feature_output32.d:57:64: vectorized loop (vectorization width: 4, interleaved count: 1)
remark: source/imagery/analysis/feature_output32.d:57:64: vectorized loop (vectorization width: 8, interleaved count: 1)
remark: source/imagery/analysis/feature_output32.d:57:64: vectorized loop (vectorization width: 8, interleaved count: 4)
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Auto-vectorization of loops with potentially faulting load is not supported
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Cannot vectorize early exit loop with strided fault-only-first load
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: loop control flow is not understood by vectorizer
remark: source/imagery/analysis/feature_worker32.d:123:9: loop not vectorized: value that could not be identified as reduction is used outside the loop
remark: source/imagery/analysis/feature_worker32.d:124:9: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/feature_worker32.d:411:21: loop not vectorized: value that could not be identified as reduction is used outside the loop
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:432:17: loop not vectorized: loop control flow is not understood by vectorizer
remark: source/imagery/analysis/feature_worker32.d:435:21: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:435:21: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:444:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:445:21: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:460:17: loop not vectorized: loop control flow is not understood by vectorizer
remark: source/imagery/analysis/feature_worker32.d:462:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/feature_worker32.d:462:17: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:100:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:101:13: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:101:13: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/hessian_lines.d:101:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:143:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:144:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:146:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:151:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:175:19: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:203:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:52:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:78:9: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/hessian_lines.d:78:9: vectorized loop (vectorization width: 4, interleaved count: 1)
remark: source/imagery/analysis/hessian_lines.d:81:13: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:81:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/hessian_lines.d:81:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:81:43: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:84:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:85:17: loop not vectorized
remark: source/imagery/analysis/hessian_lines.d:85:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/hessian_lines.d:96:9: vectorized loop (vectorization width: 4, interleaved count: 4)
remark: source/imagery/analysis/hessian_lines.d:99:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:163:9: loop not vectorized
remark: source/imagery/analysis/path_kernels.d:163:9: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/path_kernels.d:172:17: loop not vectorized: unsafe dependent memory operations in loop. Use #pragma clang loop distribute(enable) to allow loop distribution to attempt to isolate the offending operations into a separate loop
remark: source/imagery/analysis/path_kernels.d:209:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:211:32: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:232:21: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:248:38: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:265:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized: Cannot vectorize early exit loop
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/path_kernels.d:287:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/path_kernels.d:287:9: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/path_kernels.d:287:9: vectorized loop (vectorization width: 32, interleaved count: 1)
remark: source/imagery/analysis/path_kernels.d:307:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:124:29: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:125:29: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:128:29: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:128:29: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:129:29: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:129:29: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/row_kernels.d:133:25: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:140:86: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:141:61: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: Early exit loop with store but no supported condition load
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/row_kernels.d:155:48: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: cannot identify array bounds
remark: source/imagery/analysis/row_kernels.d:157:44: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:170:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:170:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:170:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:170:13: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/row_kernels.d:170:13: vectorized loop (vectorization width: 32, interleaved count: 1)
remark: source/imagery/analysis/row_kernels.d:173:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:173:13: loop not vectorized: instruction return type cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:191:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:191:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:232:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:232:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:252:13: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:252:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/row_kernels.d:254:17: loop not vectorized
remark: source/imagery/analysis/row_kernels.d:254:17: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/row_kernels.d:254:17: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:262:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:266:33: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/row_kernels.d:67:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:106:13: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:106:13: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
remark: source/imagery/analysis/structure_tensor.d:106:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:106:44: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:129:17: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:129:17: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
remark: source/imagery/analysis/structure_tensor.d:131:13: vectorized loop (vectorization width: 4, interleaved count: 4)
remark: source/imagery/analysis/structure_tensor.d:139:9: vectorized loop (vectorization width: 4, interleaved count: 4)
remark: source/imagery/analysis/structure_tensor.d:194:22: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:212:9: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:212:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:212:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:214:9: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/structure_tensor.d:79:9: loop not vectorized
remark: source/imagery/analysis/structure_tensor.d:79:9: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/structure_tensor.d:82:9: the cost-model indicates that interleaving is not beneficial
remark: source/imagery/analysis/structure_tensor.d:82:9: vectorized loop (vectorization width: 4, interleaved count: 1)
remark: source/imagery/analysis/window_kernels.d:112:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:114:18: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:121:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:125:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:126:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:131:30: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:133:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:133:38: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:136:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:137:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:137:45: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:140:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:141:34: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:141:55: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:142:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:199:16: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:202:27: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:211:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:21:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:220:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:220:41: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:221:33: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:221:64: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:225:45: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:225:65: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:234:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized: Control flow cannot be substituted for a select
remark: source/imagery/analysis/window_kernels.d:236:13: loop not vectorized: instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:236:40: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:236:64: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:237:28: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:237:56: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:240:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:241:17: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:249:5: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:268:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:272:13: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:285:39: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:67:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:68:44: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:68:9: loop not vectorized: call instruction cannot be vectorized
remark: source/imagery/analysis/window_kernels.d:83:88: loop not vectorized: unsafe dependent memory operations in loop. Use #pragma clang loop distribute(enable) to allow loop distribution to attempt to isolate the offending operations into a separate loop
remark: source/imagery/analysis/window_kernels.d:83:9: loop not vectorized
remark: source/imagery/analysis/window_kernels.d:83:9: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
```

Unlocated remarks from the complete build, grouped verbatim with occurrence counts. LLVM supplies no source location here; these cannot safely be attributed to a particular kernel.

```text
1400 x remark: <unknown>:0:0: loop not vectorized
89 x remark: <unknown>:0:0: loop not vectorized: Auto-vectorization of loops with potentially faulting load is not supported
51 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop
84 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with complex writes to memory
435 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with more than one early exit
21 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with reductions or recurrences
43 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize early exit loop with strided fault-only-first load
268 x remark: <unknown>:0:0: loop not vectorized: Cannot vectorize uncountable loop
339 x remark: <unknown>:0:0: loop not vectorized: Control flow cannot be substituted for a select
1 x remark: <unknown>:0:0: loop not vectorized: Early exit loop contains operations that cannot be speculatively executed
13 x remark: <unknown>:0:0: loop not vectorized: Early exit loop with store but no supported condition load
14 x remark: <unknown>:0:0: loop not vectorized: Incorrect number of successors from early exiting block
15 x remark: <unknown>:0:0: loop not vectorized: Loop contains an unsupported switch
1 x remark: <unknown>:0:0: loop not vectorized: Value cannot be used outside the loop
24 x remark: <unknown>:0:0: loop not vectorized: cannot identify array bounds
484 x remark: <unknown>:0:0: loop not vectorized: could not determine number of loop iterations
615 x remark: <unknown>:0:0: loop not vectorized: instruction cannot be vectorized
32 x remark: <unknown>:0:0: loop not vectorized: loop control flow is not understood by vectorizer
387 x remark: <unknown>:0:0: loop not vectorized: loop induction variable could not be identified
874 x remark: <unknown>:0:0: loop not vectorized: value that could not be identified as reduction is used outside the loop
5 x remark: <unknown>:0:0: loop not vectorized: write to a loop invariant address could not be vectorized
58 x remark: <unknown>:0:0: the cost-model indicates that interleaving is not beneficial
20 x remark: <unknown>:0:0: the cost-model indicates that vectorization is not beneficial
17 x remark: <unknown>:0:0: vectorized loop (vectorization width: 16, interleaved count: 4)
7 x remark: <unknown>:0:0: vectorized loop (vectorization width: 32, interleaved count: 1)
30 x remark: <unknown>:0:0: vectorized loop (vectorization width: 32, interleaved count: 2)
20 x remark: <unknown>:0:0: vectorized loop (vectorization width: 32, interleaved count: 4)
23 x remark: <unknown>:0:0: vectorized loop (vectorization width: 4, interleaved count: 1)
42 x remark: <unknown>:0:0: vectorized loop (vectorization width: 4, interleaved count: 2)
100 x remark: <unknown>:0:0: vectorized loop (vectorization width: 4, interleaved count: 4)
8 x remark: <unknown>:0:0: vectorized loop (vectorization width: 8, interleaved count: 1)
25 x remark: <unknown>:0:0: vectorized loop (vectorization width: 8, interleaved count: 2)
55 x remark: <unknown>:0:0: vectorized loop (vectorization width: 8, interleaved count: 4)
```
