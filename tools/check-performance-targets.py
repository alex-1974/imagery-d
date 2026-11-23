"""Report separate measured regression, fixed target, allocation and scaling gates.

Input is a qualification JSON with independently checked numerical_preflight,
observations and scaling rows. Only --require-targets turns timing targets into
a failing manual gate; --require-allocation is suitable for resource CI.
"""
import argparse
import json
import math
from pathlib import Path


def interval_gate(summary,limit,reason,ratio=True):
    if not math.isfinite(limit) or limit<=0:raise ValueError('Invalid Engine budget')
    interval=summary.get('bootstrap_95')
    center=summary.get('ratio' if ratio else 'median')
    count=summary.get('accepted_cycles' if ratio else 'samples',0)
    if not interval or center is None or count<15:return dict(status='pending',reason=reason,limit=limit)
    lo,hi=interval
    if not all(math.isfinite(x) and x>0 for x in (lo,hi,center)) or lo>hi:
        raise ValueError('Invalid bootstrap interval')
    status='pass' if hi<=limit else 'fail' if lo>limit and center>=limit*1.1 else 'pending'
    return dict(status=status,reason=reason,limit=limit,median=center,bootstrap_95=interval)


def check_engine_paths(report,policy):
    engine=policy.get('engine')
    if not engine: return [dict(status='pending',reason='missing Engine policy')]
    gates=[]
    if report.get('numerical_preflight') is not True:
        return [dict(status='pending',reason='Independent numerical preflight missing')]
    if report.get('comparison_contract')!='strict-float64-final-float32/full-frame-v1':
        return [dict(status='pending',reason='Engine/worker comparison contract mismatch')]
    if report.get('size')!=engine['size']:return [dict(status='pending',reason='Engine budget size not qualified')]
    for feature,budget in engine['operators'].items():
        modes=report.get('results',{}).get(feature,{})
        for mode in engine['eligible_modes']:
            summary=modes.get(mode,{})
            gates.append(interval_gate(summary,budget['maximum_ratio'],f'{feature}/{mode}: strict Engine/prepared ratio'))
            if summary.get('prepared_gc_bytes',0):gates.append(dict(status='fail',reason=f'{feature}: prepared GC allocation'))
        phases=report.get('profile_results',{}).get(feature,{}).get('cold64',{}).get('phases',{})
        for phase,limit in engine['phase_ceilings_ns_per_pixel'].items():
            gates.append(interval_gate(phases.get(phase,{}),limit,f'{feature}: profiled {phase}',False))
    for variant,key in [('portable','canny'),('native','canny:native')]:
        canny=report.get('results',{}).get(key,{}).get('canny-d',{})
        if report.get('canny',{}).get(variant,{}).get('validation')!={'cases':120,'mismatched_pixels':0}:
            gates.append(dict(status='fail',reason=f'Canny {variant} equal-work numerical preflight missing'))
        else:gates.append(interval_gate(canny,policy['targets']['canny']['maximum_ratio'],f'Canny / aligned {variant} C'))
    return gates


def check(report, policy):
    failures = []
    rows = []
    targets = policy['targets']
    if report.get('schema') != 1 or report.get('numerical_preflight') is not True:
        raise ValueError('A successful independent numerical preflight is required')
    seen = set()
    allocation_failures = []
    for item in report['observations']:
        key = (item['operator'], item['mode'], item['size'], item['domain'])
        if key in seen:
            raise ValueError(f'duplicate observation: {key}')
        seen.add(key)
        ns = item['ns_per_pixel']
        if not math.isfinite(ns) or ns <= 0 or not math.isfinite(item['checksum']):
            raise ValueError(f'invalid native observation: {key}')
        if item.get('steady_state'):
            if item['computed_tiles'] <= 0:
                allocation_failures.append(f'{key}: no computed tiles (cache hits do not qualify)')
            if item['gc_bytes'] != 0:
                allocation_failures.append(f'{key}: {item["gc_bytes"]} warm thread-GC bytes')
        ratio = None
        status = 'diagnostic'
        reference = item.get('reference')
        if reference:
            ref=reference['ns_per_pixel']
            if not math.isfinite(ref) or ref<=0:
                raise ValueError(f'invalid reference time: {key}')
            ratio=ns/ref
        if item.get('target_eligible'):
            if item['operator'] not in targets or not reference or not item.get('comparison_contract'):
                raise ValueError(f'missing target/comparison contract: {key}')
            if item['mode'] not in targets[item['operator']].get('eligible_modes',[item['mode']]):
                raise ValueError(f'ineligible target execution scope: {key}')
            ref = reference['ns_per_pixel']
            if not math.isfinite(ref) or ref <= 0:
                raise ValueError(f'invalid reference time: {key}')
            ratio = ns/ref
            limit = targets[item['operator']]['maximum_ratio']
            status = 'pass' if ratio <= limit else 'pending'
            if status != 'pass':
                failures.append(f'{key}: ratio {ratio:.3f} > target {limit}')
        rows.append(dict(key=key, ns=ns, ratio=ratio, status=status,
                         gc_bytes=item.get('gc_bytes'), computed_tiles=item.get('computed_tiles')))
    admitted = {r['key'][0] for r in rows if r['status'] == 'pass'}
    for name in targets.keys()-admitted:
        failures.append(f'{name}: no passing eligible observation')
    covered = {r['operator'] for r in report['observations'] if r.get('steady_state') and r['computed_tiles'] > 0}
    if not covered:
        allocation_failures.append('no actual warm computed-work observations')
    for name in set(report.get('expected_steady_operators', []))-covered:
        allocation_failures.append(f'{name}: missing warm computed-work coverage')
    for name in report.get('expected_steady_operators', []):
        for mode in report.get('expected_steady_modes', []):
            if not any(r['operator']==name and r['mode']==mode and r.get('steady_state') and r['computed_tiles']>0
                       for r in report['observations']):
                allocation_failures.append(f'{name}/{mode}: missing warm computed-work coverage')
    scaling = report.get('scaling', [])
    if not scaling:
        failures.append('missing multicore scaling qualification')
    for group in set(report.get('expected_scaling_operators', []))-{r['operator'] for r in scaling}:
        failures.append(f'{group}: missing multicore scaling qualification')
    for group in {r['operator'] for r in scaling}:
        selected = [r for r in scaling if r['operator'] == group]
        workers = {r['workers'] for r in selected}
        available = report['available_workers']
        if not isinstance(available, int) or available < 1:
            raise ValueError('invalid available worker count')
        required = {1, min(2, available), min(4, available), available}
        if not required <= workers:
            raise ValueError(f'{group}: missing scaling rows {required-workers}')
        digests = {r['digest'] for r in selected}
        if len(digests) != 1:
            raise ValueError(f'{group}: multicore result differs')
        if any(len(r['digest'])!=64 or any(c not in '0123456789abcdefABCDEF' for c in r['digest']) for r in selected):
            raise ValueError(f'{group}: invalid output digest')
        if len(workers)!=len(selected):
            raise ValueError(f'{group}: duplicate worker count')
        if any(r.get('gc_bytes',0)!=0 or r.get('computed_tiles',0)<=0 for r in selected):
            allocation_failures.append(f'{group}: nonzero worker GC bytes or no actual computed work')
        if any(not math.isfinite(r['ns_per_pixel']) or r['ns_per_pixel'] <= 0 for r in selected):
            raise ValueError(f'{group}: invalid scaling time')
    return rows, failures, allocation_failures


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('report', type=Path)
    p.add_argument('--targets', type=Path, default=Path(__file__).resolve().parents[1]/'docs/benchmarks/performance-targets.json')
    p.add_argument('--require-targets', action='store_true')
    p.add_argument('--require-allocation', action='store_true')
    p.add_argument('--engine-paths',action='store_true',help='check the paired Engine/phase/aligned-Canny receipt')
    args = p.parse_args()
    report = json.loads(args.report.read_text())
    if args.engine_paths:
        gates=check_engine_paths(report,json.loads(args.targets.read_text()))
        print(json.dumps(gates,indent=2))
        raise SystemExit(1 if any(g['status']=='fail' for g in gates) else
                         2 if not gates or any(g['status']=='pending' for g in gates) else 0)
    rows, failures, allocations = check(report, json.loads(args.targets.read_text()))
    print('| Operator / mode / size / domain | ns/pixel | Ratio | Target | Warm GC bytes |')
    print('|---|---:|---:|---|---:|')
    for r in rows:
        ratio = '—' if r['ratio'] is None else f'{r["ratio"]:.3f}'
        print(f'| {" / ".join(map(str,r["key"]))} | {r["ns"]:.3f} | {ratio} | {r["status"]} | {r["gc_bytes"]} |')
    for label, issues in [('Target admission', failures), ('Steady allocation', allocations)]:
        print(f'{label}: {"PASS" if not issues else "PENDING"}')
        for issue in issues:
            print(f'  {issue}')
    print('\n| Operator | Workers | ns/pixel | Speedup | Efficiency | Digest |')
    print('|---|---:|---:|---:|---:|---|')
    for r in report.get('scaling', []):
        print(f'| {r["operator"]} | {r["workers"]} | {r["ns_per_pixel"]:.3f} | {r.get("speedup",0):.3f} | {r.get("efficiency",0):.3f} | {r["digest"][:12]} |')
    if report.get('cache_layout'):
        print('\n| Operator | Legacy whole cache bytes | Planar dependency bytes | Planar final bytes | Whole-cache ratio | Final pixel ratio |')
        print('|---|---:|---:|---:|---:|---:|')
        for r in report['cache_layout']:
            print(f'| {r["operator"]} | {r["legacy_total_bytes"]} | {r["planar_dependency_bytes"]} | {r["planar_final_bytes"]} | {r["whole_cache_ratio"]} | {r["final_pixel_payload_ratio"]} |')
    if report.get('paired'):
        print('\n| Operator | Cycle | Candidate ns/pixel | Baseline ns/pixel | Target delta % | Control delta % | Target minus control points |')
        print('|---|---:|---:|---:|---:|---:|---:|')
        for r in report['paired']:
            print(f'| {r["operator"]} | {r["cycle"]} | {r["candidate_ns"]:.3f} | {r["baseline_ns"]:.3f} | {r["target_delta_percent"]:.2f} | {r["control_delta_percent"]:.2f} | {r["target_minus_control_percent"]:.2f} |')
    if (args.require_targets and failures) or (args.require_allocation and allocations):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
