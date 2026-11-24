"""Condense retained Engine/Gaussian receipts without promoting rejected cycles."""
import argparse
from pathlib import Path
import json


def number(x):return '—' if x is None else f'{x:.3f}'
def interval(x):return '['+', '.join(number(v) for v in x)+']' if x else 'pending'
def paired(s):
    return (f'{number(s.get("a_median"))} ± {number(s.get("a_mad"))} | '
            f'{number(s.get("b_median"))} ± {number(s.get("b_mad"))} | '
            f'{number(s.get("ratio"))} {interval(s.get("bootstrap_95"))} | '
            f'{s["accepted_cycles"]}/{s["rejected_cycles"]} | {s["effect"]}')
def dist(s):return f'{number(s.get("median"))} {interval(s.get("bootstrap_95"))}'


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--artifacts',type=Path,required=True)
    p.add_argument('--destination',type=Path,required=True)
    args=p.parse_args();root=args.artifacts
    read=lambda name:json.loads((root/name).read_text())
    gaussian=read('gaussian-paired/codegen.json')
    engine=read('engine-publication/engine-publication.json')
    phases=read('publication-phases/engine-publication.json')
    paths=read('engine-paths/engine-paths.json')
    cache=read('gaussian-cache/gaussian-cache.json')
    instructions=read('engine-instructions/engine-instructions.json')
    canary=read('instruction-canary/instructions.json')
    sweep=read('../gaussian-strips/sweep/sweep.json')
    lines=['# Engine publication and bounded Gaussian derivatives','',
        'Refs #212, #216, #217. Functional qualification and fixed performance admission are separate.', '',
        f'Candidate binary source: `{gaussian["binary_source"]}`; baseline: `{gaussian["baseline_source"]}`.',
        'The baseline is develop 118c06f with identical benchmark sources and measurement-only planar phase clocks. '
        'Both Engine transports read the same precomputed Float64 raster; fixture generation and hashing are outside clocks.',
        f'Compiler: LDC 1.43.0; portable, x86-64-v3 and native targets, default strict arithmetic and bounds policy. Host: {gaussian["cpu_model"]}.', '',
        'All paired receipts require >=15 accepted complete ABBA cycles, 4,000 whole-cycle bootstrap draws, '
        'median/MAD and a 10% minimum conclusive effect. Endpoint frequency movement >5%, load >6, '
        'governor/power changes or SMT sibling activity >5% reject whole cycles. No timing-based rejection or control normalization. '
        'Collection caps and all rejected cycles are retained. Compilers and other benchmark suites do not run concurrently.',
        'The host uses powersave with turbo enabled; frequency controls were not writable. No privilege escalation or relaxed hygiene limits were used.', '',
        '## Prepared Gaussian kernels', '',
        'Finite Float32 fixture, 1024², Hessian scales 1,2,4 and default tensor parameters. '
        'Only the prepared evaluation is clocked; complete channel/mask hashes must agree at each identical target.', '',
        '| Feature / target | After ns/px ± MAD | Before ns/px ± MAD | Ratio [95%] | Accepted/rejected | Effect | Absolute Hessian gate |',
        '|---|---:|---:|---:|---:|---|---|']
    for feature,targets in gaussian['results'].items():
        for target,s in targets.items():
            gate=s.get('absolute_gate',{}).get('status','—')
            lines.append(f'| {feature}/{target} | {paired(s)} | {gate} |')
    lines+=['', 'The fixed first Hessian ceiling is 325 ns/px. A true twofold improvement from the historical '
        '414.169 ns/px portable receipt would need about 207 ns/px; these are separate targets. '
        'No Float32 intermediate, tap folding, recursive Gaussian or approximate exp/atan2 is introduced.', '',
        '### Block selection and owned payload', '',
        'The descriptive sweep rotates 15 shapes across three rounds, with identical output fingerprints and zero GC bytes. '
        'Its observations tune storage; they do not admit a performance target.', '',
        '| Feature / rows × width | Sweep median ns/px | MAD | Owned bytes |', '|---|---:|---:|---:|']
    for feature in ['hessian','tensor']:
        for rows,width in [(32,128),(64,128),(128,128),(128,256)]:
            s=sweep['summaries'][f'{feature}/{rows}/{width}']
            lines.append(f'| {feature}/{rows}×{width} | {s["median"]:.3f} | {s["mad"]:.3f} | {s["payload"]} |')
    lines+=['', 'Hessian defaults to 128×128 (491,520 bytes at this scale envelope), tensor to 32×128 (304,896 bytes). '
        'Prior full-plane payloads are 33,554,432 and 50,331,648 bytes. Legacy reserve(samples) still retains full-plane capacity; '
        'reduced storage requires shape-aware reserve. Caller input/output, weights, metadata and fixed row stacks '
        '(6 KiB Hessian, 7 KiB tensor) are additional. The Engine 8 MiB tile-payload contract is checked independently; '
        'these standalone workspaces are not RSS claims.', '',
        '### Deterministic simulated-cache companion', '',
        f'Model: `{", ".join(cache["model"])}`, {cache["size"]}², one prepared frame after preheat.', '',
        '| Feature/source/block rows | Instructions | D1 misses | LL misses |', '|---|---:|---:|---:|']
    for name,s in cache['results'].items():
        c=s['counters'];lines.append(f'| {name} | {c["instructions"]} | {c["d1_misses"]} | {c["ll_misses"]} |')
    lines+=['', 'Both instruction work and intermediate traffic change. Simulated misses do not establish a pure '
        'memory-bandwidth bottleneck or measured hardware cache behavior; the original bandwidth-only diagnosis remains unproven.', '',
        '## Engine before/after, complete output and view publication', '',
        'Full modes include callback materialization into three Float32 planes and three masks. '
        'View-only modes count delivered samples, then independently materialize and hash the same fixture outside the clock. '
        'Fresh cold instances and changing warm revisions prevent cache-hit replay. Warm rows must allocate zero thread-GC bytes.', '',
        '| Feature / mode | After ns/px ± MAD | Before ns/px ± MAD | Ratio [95%] | Accepted/rejected | Effect |',
        '|---|---:|---:|---:|---:|---|']
    for name,s in engine['results'].items():lines.append(f'| {name} | {paired(s)} |')
    lines+=['', '## Separate instrumented phases', '',
        'These clocks come from ImageryProfile binaries, separately from ordinary release time. '
        'Source is provider transport exclusive of the nested borrowed-plane pack. Preparation packs and validates; '
        'cache publishes completed buffers; sink surrounds the actual callback. AoS record construction remains kernel/output work. '
        'Phase sums need not equal the outer timer.', '',
        '| Feature / mode | Source ns/px [95%] | Prepare | Cache | Sink | Sum | Accepted/rejected |',
        '|---|---:|---:|---:|---:|---:|---:|']
    for name,s in phases['results'].items():
        values=s['after_phases'];cells=' | '.join(dist(values.get(k,{})) for k in ['source','prepare','cache','sink','overhead'])
        lines.append(f'| {name} | {cells} | {s["accepted_cycles"]}/{s["rejected_cycles"]} |')
    for feature,modes in paths['profile_results'].items():
        for mode,s in modes.items():
            values=s.get('phases',{});cells=' | '.join(dist(values.get(k,{})) for k in ['source','prepare','cache','sink','overhead'])
            lines.append(f'| {feature}/{mode} complete frame | {cells} | {s["accepted_cycles"]}/{s["rejected_cycles"]} |')
    lines+=['', f'Explicit 5 ns/px view-only admission: **{phases["status"].upper()}**. '
        'It covers cold32-view and warm-view for the five named scalar features; it never replaces full-frame Engine/worker budgets.', '',
        'Phase gates:', '']
    lines += [f'- {g["status"]}: {g["reason"]}' for g in phases['gates']]
    lines+=['', '### Engine phase instruction attribution', '',
        'A separate no-inline diagnostic build preserves named boundaries. One 64² completed frame is collected. '
        'Source excludes nested preparation; residual includes planning/setup/kernel. These costs are not primary wall-time measurements.', '',
        '| Feature / mode | Source Ir | Prepare Ir | Cache Ir | Sink Ir | Residual Ir |', '|---|---:|---:|---:|---:|---:|']
    for name,s in instructions['results'].items():
        cells=' | '.join(str(s['phases'][k]['Ir']) for k in ['source','prepare','cache','sink','residual'])
        lines.append(f'| {name} | {cells} |')
    lines+=['', '## Existing fixed full-frame admissions', '',
        f'Combined Engine/phase/Canny gate: **{paths["status"].upper()}**. Existing thresholds are unchanged.', '',
        '| Feature / mode | Engine ns/px ± MAD | Worker/reference ns/px ± MAD | Ratio [95%] | Accepted/rejected | Effect | Budget |',
        '|---|---:|---:|---:|---:|---:|---|']
    for feature,modes in paths['results'].items():
        for mode,s in modes.items():lines.append(f'| {feature}/{mode} | {paired(s)} | {s["target_status"]} |')
    lines+=['', 'Remaining full-frame gates:', '']
    remaining=[g for g in paths['gates'] if g['status']!='pass']
    lines += [f'- {g["status"]}: {g["reason"]}' for g in remaining] or ['- None.']
    lines+=['', '## Correctness and reproducibility', '',
        'All 12 supported compiler/configuration combinations pass, as do DMD/LDC scoped API probes (16 negative contracts), '
        'DDOX and independent DMD plus LDC portable/v3/native references. Exact original-algorithm twins cover all '
        'Hessian formulas/polarities, fractional/max scales, signed zero, scientific offsets and narrow/odd layouts. '
        'Shape-aware independent ROI checks and legacy reservation remain covered. Borrow tests include dense/gapped, '
        'negative-row, nonfinite/wide/masked fallback and malformed-callback rollback, with committed cache preservation.',
        f'The existing six-kernel instruction/cache canary is **{canary["status"].upper()}** under its unchanged ceilings. '
        'Actual warm Engine and isolated-worker resource receipts, complete hashes, allocation counts and all raw/rejected cycles '
        'are retained in the checksummed evidence archive. Synthetic fixtures do not establish reviewed multi-tool consumer acceptance.',
        'raster-d 0.5.5 contiguousRowSpan has an independently reproduced element/byte-stride defect '
        '([raster-d #290](https://github.com/alex-1974/raster-d/issues/290)). The new packer uses correct affine row.load access; '
        'the upstream report does not block this implementation.', '']
    args.destination.write_text('\n'.join(lines))


if __name__=='__main__':main()
