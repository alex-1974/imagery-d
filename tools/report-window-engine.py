"""Render paired Engine/window admission, allocation and software counters."""
import argparse
import csv
import hashlib
import json
from pathlib import Path


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--engine',type=Path,required=True)
    p.add_argument('--windows',type=Path,required=True)
    p.add_argument('--artifacts',type=Path,required=True)
    p.add_argument('--instructions',type=Path,required=True)
    p.add_argument('--destination',type=Path,required=True)
    args=p.parse_args()
    engine=json.loads((args.engine/'engine-paths.json').read_text())
    windows=json.loads((args.windows/'window-paths.json').read_text())
    instructions=json.loads(args.instructions.read_text())
    if instructions.get('status')!='pass' or instructions.get('failures'):
        raise ValueError('The manual six-kernel instruction gate must pass')
    resources=(args.artifacts/'resources.csv').read_text()
    if not resources.rstrip().endswith('ENGINE_WARM_COMPUTED_ALLOCATION=PASS; 49 features x two precision modes, bounded caches, actual misses'):
        raise ValueError('Complete computed-work allocation probe required')
    scaling=list(csv.DictReader((args.artifacts/'scaling.csv').read_text().splitlines()))
    if len(scaling)!=28:raise ValueError('Seven operators at four worker counts required')
    for feature in {r['operator'] for r in scaling}:
        rows=[r for r in scaling if r['operator']==feature]
        if {int(r['workers']) for r in rows}!={1,2,4,12} or len({r['digest'] for r in rows})!=1:
            raise ValueError('Scaling coverage or exact frame identity failed')
        if any(int(r['gc_bytes']) or int(r['computed_tiles'])<=0 for r in rows):
            raise ValueError('Scaling must compute real frames with zero thread-GC bytes')
    payload={}
    for feature in engine['results']:
        if feature.startswith('canny'):continue
        rows=json.loads((args.engine/f'primary-{feature}-annotated.json').read_text())
        payload[feature]={key:max(r.get(key,0) for r in rows) for key in
            ['worker_payload_bytes','engine_tile_payload_bytes','cache_peak_sum_bytes','caller_frame_bytes']}
    result=dict(engine=engine,windows=windows,instructions=instructions,scaling=scaling,
        resource_binary_source=(args.artifacts/'source.txt').read_text().strip(),
        resource_binary_sha256=hashlib.sha256((args.artifacts/'portable-bench').read_bytes()).hexdigest(),
        allocation='49 features x Float64/planar; actual computed misses; zero thread-GC bytes',payload_maxima=payload,
        resources_sha256=hashlib.sha256(resources.encode()).hexdigest())
    args.destination.mkdir(parents=True,exist_ok=True)
    stem='window-engine-followup-2026-11-23'
    (args.destination/(stem+'.json')).write_text(json.dumps(result,indent=2)+'\n')
    def fmt(s,key):return f'{s[key]:.3f}' if key in s else '—'
    def interval(s):return '['+', '.join(f'{v:.3f}' for v in s.get('bootstrap_95',[]))+']' if 'bootstrap_95' in s else 'pending'
    lines=['# Engine/window follow-up, 2026-11-23','','Refs #212 and #213.','','## Admission','',
        f'Engine/phase/aligned-Canny: **{engine["status"]}**. Window/path: **{windows["status"]}**.',
        'Functional correctness and fixed performance admission are separate. Pending evidence is never PASS.', '',
        f'Engine binary source: `{engine["binary_source"]}`. Window binary source: `{windows["binary_source"]}`.',
        f'Resource/counter/scaling source: `{result["resource_binary_source"]}`; the later Hessian/tensor-only change is qualified separately.',
        f'Baseline: {windows["baseline_source"]}; benchmark overlay SHA-256 `{windows["benchmark_overlay_sha256"]}`.',
        f'Host: {engine["cpu_model"]}. Engine CPU {engine["cpu"]}; window CPU {windows["cpu"]}.', '',
        'All timed arrays use the retained 1024² deterministic fixture. Engine comparisons use strict '
        'Float64 arithmetic and identical final Float32 planes/masks, including complete frame publication. '
        'Gaussian32 is a different policy and is excluded. Window probes use actual Float32 input storage '
        'and Float64 statistics; frame publication is outside their per-tile kernel clocks.', '',
        'Effect labels describe the named A/B scopes. Conclusions about source revisions '
        'require the corresponding before/after rows; parameter-scaling and Engine/worker '
        'ratios primarily describe their different work and publication costs.', '',
        'ABBA, >=15 accepted complete cycles, medians/MAD and 4,000 whole-cycle bootstrap draws; '
        '10% minimum conclusive effect. Endpoint frequency movement >5%, load >6 or SMT sibling '
        'activity >5% reject complete cycles. Zero-tick intervals are unresolved. Governor/power '
        'changes are rejected; temperatures and controls remain in raw records. These observations '
        'do not establish physical isolation. Sample cells batch 1..100 frames from an untimed pilot '
        'targeting >=150 ms. Cold Engine frames use fresh instances; warm batches advance preallocated '
        'revision labels and report actual computed tiles and GC bytes.', '',
        '## Engine and aligned Canny', '',
        '| Feature / mode | Engine ns/px ± MAD | Prepared/reference ns/px ± MAD | Ratio [95% CI] | Cycles accepted/rejected | Effect | Budget |',
        '|---|---:|---:|---:|---:|---|---|']
    for feature,modes in engine['results'].items():
        for mode,s in modes.items():
            lines.append(f'| {feature}/{mode} | {fmt(s,"a_median")} ± {fmt(s,"a_mad")} | {fmt(s,"b_median")} ± {fmt(s,"b_mad")} | '
                f'{fmt(s,"ratio")} {interval(s)} | {s["accepted_cycles"]}/{s["rejected_cycles"]} | {s["effect"]} | {s["target_status"]} |')
    lines+=['','The matched Gabor rows supersede the historical independently timed prepared/cold '
        'discrepancy for this scope. They do not retroactively identify a cause of the historical drift. '
        'Canny uses the separately authored equal-work C implementation; both portable and native '
        'C builds pass all 120 scalar cases. OpenCV/skimage Canny remain diagnostics.', '',
        '## Profiled cold Float64 phases', '',
        '| Feature | Source | Preparation | Cache | Sink | Sum of these phases |', '|---|---:|---:|---:|---:|---:|']
    for feature,modes in engine['profile_results'].items():
        phases=modes.get('cold64',{}).get('phases',{})
        cells=[fmt(phases.get(name,{}),'median')+' '+interval(phases.get(name,{})) for name in ['source','prepare','cache','sink','overhead']]
        lines.append('| '+feature+' | '+' | '.join(cells)+' |')
    lines+=['','Units: ns/pixel with bootstrap intervals. These phase sums are regression envelopes, '
        'not a claim that the separate 5 ns/pixel overhead ambition is reached. They are not guaranteed '
        'to sum to the outer timer. Existing 5x/4x prepared external targets are unchanged.', '',
        '## Paths and normalization', '',
        '| Case | Candidate ns/px ± MAD | Baseline/reference ns/px ± MAD | Ratio [95% CI] | Cycles accepted/rejected | Effect | Budget |',
        '|---|---:|---:|---:|---:|---|---|']
    for name,s in windows['results'].items():
        lines.append(f'| {name} | {fmt(s,"a_median")} ± {fmt(s,"a_mad")} | {fmt(s,"b_median")} ± {fmt(s,"b_mad")} | '
            f'{fmt(s,"ratio")} {interval(s)} | {s["accepted_cycles"]}/{s["rejected_cycles"]} | {s["effect"]} | {s["target_status"]} |')
    lines+=['','## Descriptive raw pairs','',
        'The following intervals use all complete cycles, including the rejected frequency/SMT '
        'observations. They describe actual recorded load and cannot satisfy the strict admission '
        'gate. Raw flags remain unchanged; no timing-based outliers are removed.', '',
        '| Scope | Raw cycles | Ratio [95% CI] | Observed effect |', '|---|---:|---:|---|']
    for feature,modes in engine['results'].items():
        for mode,s in modes.items():
            d=s.get('raw_diagnostic',{})
            if d:lines.append(f'| Engine {feature}/{mode} | {d["raw_cycles"]} | {fmt(d,"ratio")} {interval(d)} | {d["observed_effect"]} |')
    for name,s in windows['results'].items():
        d=s.get('raw_diagnostic',{})
        if d:lines.append(f'| Window {name} | {d["raw_cycles"]} | {fmt(d,"ratio")} {interval(d)} | {d["observed_effect"]} |')
    lines+=['','Default opening/closing require a paired upper ratio <=0.2 (at least 5x). '
        'Length 31 / step 2 versus length 7 / step 1 requires <=3x. Every normalization radius '
        'also retains the fixed 78 ns/pixel ceiling (5 x historical 15.6), independent of the '
        'fresh OpenCV/NumPy comparison. The radius-sensitivity target is <=2x. Numerical preflight '
        'covers masks, minimumValid, scientific units, whole/tiled equality and retained path oracles.', '',
        '## Resources and deterministic companion', '',
        'All 98 default Engine computations and all 28 isolated-worker rows have zero warm thread-GC '
        'bytes and actual computed tiles. Worker counts are 1, 2, 4 and 12 logical workers, with '
        'per-worker ownership. Full output SHA-256 agrees across worker counts. Scaling times are '
        'diagnostic, not a claim of linear speedup.', '',
        '| Feature | Worker arrays | Engine tile arrays | Sum of cache peaks | Caller frame |', '|---|---:|---:|---:|---:|']
    for f,v in payload.items():lines.append('| '+f+' | '+' | '.join(str(n) for n in v.values())+' |')
    lines+=['','Bytes are owned array payloads, not RSS. The <=8 MiB tile/worker budget excludes '
        'caller inputs/complete frames, separate bounded caches, fixed metadata and stack. '
        'Local statistics use 18 KiB stack carriers plus 4 KiB constant certificates without '
        'extrema (or 16 KiB extrema queues). The exact byte path applies only to complete valid '
        '`Float32(code)/255` supports; other samples keep the complete floating/scalar path. '
        'Synthetic-fixture throughput does not establish the hit rate of arbitrary consumer scenes.', '',
        '| Feature | Instructions | D1 simulated data misses | LL simulated data misses |', '|---|---:|---:|---:|']
    for f,v in instructions['observed'].items():lines.append('| '+f+' | '+' | '.join(str(v[k]) for k in ['instructions','d1_misses','ll_misses'])+' |')
    lines+=['','The manual Callgrind canary uses the fixed 32² collected region and explicit cache '
        'model in `instruction-budget-2026-11-23.json`; it is not a physical-counter or wall-time '
        'measurement. The reviewed nine path write misses and downward normalization ratchet '
        'are documented in that policy. No automatic `--record` calibration repairs failures.', '',
        '## Non-passing admissions', '']
    failures=[g for report in [engine,windows] for g in report['gates'] if g['status']!='pass']
    lines+=['```json',json.dumps(failures,indent=2),'```','',
        'All binary/oracle/compiler/flag hashes, paired summaries, phase intervals, software counts '
        'and exact scaling digests are retained in the adjacent JSON. Complete cycles, including '
        'rejected observations, remain in the raw artifact directories. '
        'This receipt is not reviewed application acceptance or a general 60-fps claim.']
    (args.destination/(stem+'.md')).write_text('\n'.join(lines)+'\n')


if __name__=='__main__':main()
