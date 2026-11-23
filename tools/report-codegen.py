"""Render retained code-generation receipts and verbatim hot-loop remarks."""
import argparse
import json
from pathlib import Path

HOT = ('row_kernels.d:', 'path_kernels.d:', 'window_kernels.d:',
       'hessian_lines.d:', 'structure_tensor.d:', 'feature_worker32.d:',
       'feature_output32.d:')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--measurements', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--stem', default='codegen-2026-11-23')
    args = parser.parse_args()
    report = json.loads(args.measurements.read_text())
    destination = args.destination
    destination.mkdir(parents=True, exist_ok=True)
    stem = args.stem
    (destination/(stem+'.json')).write_text(json.dumps(report,indent=2)+'\n')
    title='Hessian vertical rows: paired source experiment' if 'baseline_source' in report else 'Optional code-generation experiment'
    lines = ['# '+title+', 2026-11-23', '',
        'Refs #214; measurement protocol #212; path/statistics kernels #213.', '',
        f'Source receipt: `{report["source"]}`; tracked modifications: `{report["tracked_dirty"]}`.',
        f'Binary build source: `{report["binary_source"]}`.',
        f'Host: {report["cpu_model"]}; measured CPU {report["cpu"]}; observer CPUs {report["observer_affinity"]}.',
        f'Overall collection: **{report["status"]}**. The portable configuration remains the default.', '',
        '## Scope and protocol', '', report['contract']+'.', '',
        ('Same-target source comparison against '+report['baseline_source']+'. ' if 'baseline_source' in report else 'Same production source, ')+
        'LDC 1.43.0 ordinary DUB release, safe bounds checks, '
        'line-table metadata and loop-vectoriser success/missed/analysis remarks. '
        +('Each A/B pair holds the target fixed; the three settings are absent, `x86-64-v3`, and `native`. ' if 'baseline_source' in report else
        'Only `--mcpu` differs: absent, `x86-64-v3`, or `native`. ')+
        'There is no fast-math override. Each target independently passes the full numerical oracle.', '',
        'At 1024² the standalone Hessian workspace owns four Float64 planes '
        '(32 MiB), separate from its caller-owned input/output. The 8 MiB '
        'Engine tile budget for #213 does not describe this standalone operation.', '',
        'A separate pilot chooses 1..100 frames per cell, targeting at least 150 ms '
        'of kernel work so SMT tick accounting is observable. The batch kernel time '
        'is divided by its frame count; output publication/hash remain outside the clock. '
        'Four cells form each ABBA cycle. '+('The source change must preserve exact full-output fingerprints.' if 'baseline_source' in report else
        'Portable/portable is an actual control experiment.'), '',
        'The unchanged control is the same portable C shared object for every ISA '
        'setting, validated on 120 retained Canny cases. It runs on the measured '
        'physical core before and after each executable, with identical untimed '
        'preheat. Per-target D controls are retained separately as diagnostics.', '',
        'At least 15 complete accepted cycles are required. The median ratio uses the '
        'geometric mean of the two symmetric A and B cells. A seeded 4,000-draw '
        'bootstrap resamples whole cycles. A conclusive effect additionally requires '
        '10% change. Endpoint frequency movement >5%, load >6, governor/power changes '
        'or SMT sibling busy fraction >5% reject the entire cycle. Zero tick intervals '
        'are unresolved and rejected. Controls are diagnostic, not a normalization factor. '
        'All rejected observations are retained; retries stop at 90 cycles per cell.', '',
        '## Paired results', '',
        '| Kernel | Setting | ns/px median ± MAD | Baseline ns/px ± MAD | Ratio [95% CI] | Cycles accepted/rejected | Effect | Exact output identity |',
        '|---|---|---:|---:|---:|---:|---|---|']
    for feature, variants in report['results'].items():
        for target, result in variants.items():
            fmt = lambda k: f'{result[k]:.3f}' if k in result else '—'
            ci = ', '.join(f'{x:.3f}' for x in result.get('bootstrap_95',[])) or 'pending'
            lines.append(f'| {feature} | {target} | {fmt("a_median")} ± {fmt("a_mad")} | '
                f'{fmt("b_median")} ± {fmt("b_mad")} | {fmt("ratio")} [{ci}] | '
                f'{result["accepted_cycles"]}/{result["rejected_cycles"]} | {result["effect"]} | '
                f'{result["exact_output_identity"]} |')
    lines += ['', 'A ratio below 1 favors A. An inconclusive effect '
        'is not an improvement claim. These prepared-kernel results are not an Engine '
        'overhead or 60-fps admission.', '', '## Loop decisions', '',
        '| Loop family | Decision |', '|---|---|',
        '| Path row stencils | #213 exposes bounded equal-length min/max row expressions and an exact byte carrier. Keep the complete masked/wide-domain scalar fallback. |',
        '| Local statistics | Keep exact integer rolling counts, ordered Float64 sums, constant certificates and centered fallback. Reduction/early-exit remarks do not justify reassociation or loss of masks. |',
        '| Gaussian32 and median | Existing bounded row expressions / rank network allow packed operations. Width is a compiler decision; a missed loop remark is not proof that its body has no packed SLP/array instructions. |',
        '| Ridge/Gabor accumulation | Equal-length array expressions already isolate the tap computation. Winner stores remain semantically ordered; bank angles do not call atan2. |',
        '| Gradient/Hessian angles | Retain libm and exact degeneracy/validity rules. No polynomial error policy or approximation is introduced. |',
        '| Hessian/tensor vertical taps | A separate source experiment traverses each tap across contiguous rows, preserving each pixel’s original tap order. The horizontal scalar traversal supplies the bit-exact transpose oracle; no new working planes are allocated. |',
        '| Validation, preparation, full-domain fallback | Preserve safety checks, exits and independent reference behavior. Do not use unchecked pointers or blanket fast-math to silence remarks. |', '',
        'No explicit-vector function was added, so there is no new vector/scalar '
        'dispatch to qualify. Existing DMD scalar and LDC vector luminance code '
        'remains in the ordinary functional matrix. No byte median 5x5 or new '
        '16-bit API is claimed. Integer histograms and CLAHE already exist; '
        'a different lane-partition scheme needs its own representative benchmark. '
        'See [ADR 0024](../adr/0024-optional-code-generation-targets.md).', '',
        '## Compiler evidence and reproduction', '',
        'The adjacent remarks file retains every distinct hot-source remark emitted '
        'by the requested loop-vectoriser passes, including bare “loop not vectorized” '
        'messages for which LLVM supplied no more precise reason. Locations may occur '
        'with several reasons because templates and fallback paths are instantiated '
        'more than once. This is a compiler-reported inventory, not a claim that LLVM '
        'reports every machine loop. Other sources/dependencies and unknown locations '
        'remain in the full build logs; their hashes are in the JSON receipt.', '',
        '```sh',
        'ORACLE_PYTHON=/path/to/pinned-python bash tools/build-codegen-experiment.sh benchmark/results/codegen-214',
        '/path/to/pinned-python tools/qualify-codegen.py --artifacts benchmark/results/codegen-214 --output benchmark/results/codegen-214/paired --cpu auto',
        'python tools/report-codegen.py --artifacts benchmark/results/codegen-214 --measurements benchmark/results/codegen-214/paired/codegen.json --destination docs/benchmarks',
        '```', '',
        'Pinned Python references: `tests/feature_program/requirements.txt`. '
        'Full binary/oracle/log/validation hashes and compiler version are retained '
        'in the adjacent JSON. Raw cycles live under the reproducible output directory.']
    (destination/(stem+'.md')).write_text('\n'.join(lines)+'\n')
    remarks = ['# Verbatim distinct hot-source LLVM remarks', '']
    for target in report['builds']:
        text = (args.artifacts/(target+'-build.log')).read_text()
        selected = sorted(set(line for line in text.splitlines()
            if line.startswith('remark: source/imagery/') and any(name in line for name in HOT)))
        remarks += [f'## {target}', '', '```text', *selected, '```', '']
    (destination/(stem+'-remarks.md')).write_text('\n'.join(remarks))
    packed=args.artifacts/'packed-opcodes.json'
    if packed.exists():
        data=json.loads(packed.read_text())
        for target,build in data['targets'].items():
            if build['binary_sha256']!=report['builds'][target]['binary_sha256']:
                raise ValueError('Disassembly must belong to measured binary')
        (destination/(stem+'-opcodes.json')).write_text(json.dumps(data,indent=2)+'\n')


if __name__ == '__main__':
    main()
