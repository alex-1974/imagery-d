"""Generate numerical, target, allocation and scaling receipts in one command.

Build the portable release benchmark and the debug feature-program oracle first.
Timing is manual evidence; deterministic warm-allocation checks also run in CI.
"""
import argparse
import csv
import hashlib
import importlib.util
import json
import os
import platform
import subprocess
import sys
import io
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def records(text):
    header = None
    for line in text.splitlines():
        row = next(csv.reader([line]))
        if row and row[0] in ('feature', 'operator', 'size'):
            header = row
        elif header and len(row) == len(header):
            yield dict(zip(header, row))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, default=ROOT/'imagery-d_bench')
    p.add_argument('--oracle', type=Path, default=ROOT/'tests/feature_program/feature-program-oracle')
    p.add_argument('--compiler', default='ldc2', help='compiler executable used to build the supplied benchmark')
    p.add_argument('--baseline', type=Path)
    p.add_argument('--size', type=int, default=1024)
    p.add_argument('--repeats', type=int, default=3)
    p.add_argument('--cpu', type=int, default=min(os.sched_getaffinity(0)))
    p.add_argument('--workers', type=int, default=len(os.sched_getaffinity(0)))
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--require-targets', action='store_true')
    p.add_argument('--paired-cycles', type=int, default=3)
    args = p.parse_args()
    if args.size not in (1024,4096) or args.repeats < 3:
        p.error('qualification requires size 1024/4096 and >=3 measured repeats')
    if args.paired_cycles < 3:
        p.error('at least three paired cycles required when a baseline is supplied')
    args.output.mkdir(parents=True, exist_ok=True)

    def capture(name, command):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, text=True, stdout=subprocess.PIPE, check=True)
        (args.output/name).write_text(result.stdout)
        return result.stdout

    capture('numerical.txt', [sys.executable, ROOT/'tools/verify-feature-program.py', args.oracle.resolve()])
    compiler=capture('compiler.txt',[args.compiler,'--version'])
    prefix = ['taskset', '-c', str(args.cpu)]
    binary = args.binary.resolve()
    report = dict(schema=1, numerical_preflight=True, observations=[], scaling=[],
                  available_workers=args.workers, expected_scaling_operators=[
                      'gaussian','gradient','median','ridge','gabor','localNormalization','pathOpening'],
                  host=platform.platform(), affinity=sorted(os.sched_getaffinity(0)), single_cpu=args.cpu,
                  size=args.size, repeats=args.repeats,
                  git_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                  dirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True)),
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  baseline_commit='e80fc215a5f48ec817a1a86478fee44a07da4d8e',
                  compiler=compiler,build_flags='DUB release: -O -release -inline; default @safe bounds checks',
                  cpu_model=next((line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),'unknown'),
                  baseline_binary_sha256=hashlib.sha256(args.baseline.read_bytes()).hexdigest() if args.baseline else None,
                  precision='Engine float32 fixture, float64 arithmetic/output; strict worker float64 arithmetic/final float32 planes; exact median rank projection; explicit Gaussian32 uses float32 separable arithmetic')
    # Retain chronological controls: baseline -> candidate -> external -> baseline.
    if args.baseline:
        capture('baseline-before.csv', prefix+[args.baseline.resolve(),args.size,args.repeats,'all','scalar'])
    native = list(records(capture('engine.csv', prefix+[binary,args.size,args.repeats,'all','scalar'])))
    regression=subprocess.run([sys.executable,str(ROOT/'tools/check-feature-budgets.py'),str(args.output/'engine.csv'),
        '--domain','scalar','--size',str(args.size)],cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (args.output/'regression.txt').write_text(regression.stdout)
    report['regression_status']='PASS' if regression.returncode==0 else 'FAIL'
    worker = list(records(capture('worker.csv', prefix+[binary,args.size,args.repeats,'worker32'])))
    prepared = list(records(capture('canny.csv', prefix+[binary,args.size,args.repeats,'prepared-canny'])))
    refs = list(records(capture('external.csv', prefix+[sys.executable,ROOT/'tools/benchmark-feature-references.py',
                        '--sizes',args.size,'--repeats',args.repeats,'--domains','scalar'])))
    if args.baseline:
        capture('baseline-after.csv', prefix+[args.baseline.resolve(),args.size,args.repeats,'all','scalar'])
    reference = {(r['operator'],r['reference']):r for r in refs}

    def observation(r, mode, size, steady=False):
        return dict(operator=r.get('feature',r.get('operator')),mode=mode,size=size,domain='scalar',
                    ns_per_pixel=float(r['ns_per_pixel']), checksum=float(r['checksum']),
                    steady_state=steady,gc_bytes=int(r.get('gc_bytes',r.get('gc_bytes_per_call',0))),
                    computed_tiles=int(r.get('computed_tiles',0)),target_eligible=False)

    for r in native:
        item = observation(r,'engine-cold-float64',args.size)
        # End-to-end Engine does strictly more transfer/publication work. A
        # passing ratio is conservative; reference winner bits are not asserted.
        lib = {'gaussian':'OpenCV','gradient':'OpenCV+NumPy','median':'scipy',
               'ridge':'OpenCV+NumPy','gabor':'OpenCV+NumPy'}.get(item['operator'])
        if lib:
            ref = reference[item['operator'],lib]
            item.update(target_eligible=True,reference=dict(library=lib,ns_per_pixel=float(ref['ns_per_pixel']),scope=ref['scope']),
                comparison_contract='Finite float32-origin scalar fixture; float64 arithmetic/strength; Engine also source/cache/provenance, external timing includes intermediates. Independent preflight checks strength; orientation ties use retained D oracle.')
        report['observations'].append(item)
    for r in worker:
        item = observation(r,r['publication'],args.size,True)
        item['computed_tiles'] = ((args.size+255)//256)**2*args.repeats
        if (r['publication']=='prepared-float32-soa' and item['operator'] in ('gradient','median')) or r['publication']=='prepared-float32-gaussian32':
            lib={'gaussian':'OpenCV-float32','gradient':'OpenCV+NumPy-float32','median':'OpenCV'}[item['operator']]
            ref=reference[item['operator'],lib]
            item.update(target_eligible=True,reference=dict(library=lib,ns_per_pixel=float(ref['ns_per_pixel']),scope=ref['scope']),
                comparison_contract='Same finite float32-origin fixture and final float32 strength. Native validates/publishes three planes and three masks; Gaussian32 opts into float32 separable arithmetic with its own 3*float32.epsilon error gate, Sobel keeps strict float64 arithmetic/projection. External float32 strength/angle has different intermediate rounding. Median ranking/projection is exact; independent numerical preflights remain separate.')
        report['observations'].append(item)
    for r in prepared:
        item=observation(r,r['mode'],args.size,r['mode']=='prepared-global')
        # Both external Cannys use different NMS/tie/quantization contracts.
        item['comparison_contract']='Global finite float32 Canny, exact old D output; OpenCV and scikit-image are diagnostic only'
        item['reference']=dict(library='OpenCV (different NMS)',ns_per_pixel=float(reference['canny','OpenCV']['ns_per_pixel']))
        report['observations'].append(item)
    resources=list(records(capture('allocation.csv',prefix+[binary,64,args.repeats,'resources'])))
    report['expected_steady_operators']=sorted({r['feature'] for r in resources})
    report['expected_steady_modes']=['engine-float64-warm-miss','engine-planar-warm-miss']
    for r in resources:
        item=observation(r,r['mode'],64,True);item['domain']='rgb'
        report['observations'].append(item)
    scaling=list(records(capture('scaling.csv',[binary,args.size,args.repeats,'scaling','scalar',args.workers])))
    for r in scaling:
        report['scaling'].append(dict(operator=r['operator'],workers=int(r['workers']),
            ns_per_pixel=float(r['ns_per_pixel']),digest=r['digest'],gc_bytes=int(r['gc_bytes']),computed_tiles=int(r['computed_tiles']),
            speedup=float(r['speedup']),efficiency=float(r['efficiency'])))
    epochs=capture('epochs.csv',prefix+[binary,4096,args.repeats,'epochs'])
    import math
    epoch_rows=list(csv.DictReader(epochs.splitlines()))
    if len(epoch_rows)!=2 or any(int(r['gc_bytes']) or not math.isfinite(float(r['checksum'])) for r in epoch_rows):
        raise ValueError('Invalid epoch receipt: finite output and zero query GC bytes required')
    report['paired'] = []
    if args.baseline:
        # Alternating order and one unchanged complete Canny control per target
        # preserve pairing instead of normalizing unrelated batch medians.
        for cycle in range(args.paired_cycles):
            for native_row in native:
                name=native_row['feature']
                measurements={}
                order=[('baseline',args.baseline.resolve()),('candidate',binary)]
                if cycle%2:order.reverse()
                for label,executable in order:
                    raw=capture(f'paired-{cycle}-{name}-{label}.csv',prefix+[executable,args.size,args.repeats,name,'scalar'])
                    row=next(records(raw))
                    raw_control=capture(f'control-{cycle}-{name}-{label}.csv',prefix+[executable,args.size,args.repeats,'canny','scalar'])
                    control=next(records(raw_control))
                    measurements[label]=(row,control)
                baseline_row,baseline_control=measurements['baseline']
                candidate_row,candidate_control=measurements['candidate']
                if baseline_row['checksum']!=candidate_row['checksum'] or baseline_control['checksum']!=candidate_control['checksum']:
                    raise ValueError(f'{name}: paired baseline/candidate output differs')
                candidate_ns=float(candidate_row['ns_per_pixel']);baseline_ns=float(baseline_row['ns_per_pixel'])
                target_delta=100*(candidate_ns/baseline_ns-1)
                control_delta=100*(float(candidate_control['ns_per_pixel'])/float(baseline_control['ns_per_pixel'])-1)
                report['paired'].append(dict(operator=name,cycle=cycle,candidate_ns=candidate_ns,baseline_ns=baseline_ns,
                    target_delta_percent=target_delta,control_delta_percent=control_delta,
                    target_minus_control_percent=target_delta-control_delta))
        buffer=io.StringIO();writer=csv.DictWriter(buffer,fieldnames=list(report['paired'][0]))
        writer.writeheader();writer.writerows(report['paired']);(args.output/'paired.csv').write_text(buffer.getvalue())
    receipt=args.output/'qualification.json';receipt.write_text(json.dumps(report,indent=2)+'\n')
    command=[sys.executable,ROOT/'tools/check-performance-targets.py',receipt,'--require-allocation']
    if args.require_targets:command+=['--require-targets']
    result=subprocess.run(list(map(str,command)),cwd=ROOT,text=True,stdout=subprocess.PIPE)
    rendered=f'Regression ceilings: {report["regression_status"]}\n\n'+regression.stdout+'\n'+result.stdout
    (args.output/'report.md').write_text(rendered)
    print(rendered)
    raise SystemExit(result.returncode)


if __name__=='__main__':
    main()
