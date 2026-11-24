"""Same-process ABBA Engine/worker/Canny receipts with bounded hygiene retries.

Exit 0: all requested admissions pass; 1: conclusive failure; 2: pending/noisy.
Use --diagnostic to collect incomplete evidence without claiming admission.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
from measurement_protocol import hygiene,summarize,distribution,select_cpu,cpu_list,raw_diagnostic
from canny_reference import build,validate

ROOT=Path(__file__).resolve().parents[1]


def groups(rows):
    selected=defaultdict(list)
    for row in rows: selected[(row['session'],row['pair'],row['cycle'])].append(row)
    result=defaultdict(list)
    for (_,pair,_),items in selected.items():result[pair].append(sorted(items,key=lambda r:r['position']))
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--profile-binary',type=Path)
    p.add_argument('--oracle',type=Path,default=ROOT/'tests/feature_program/feature-program-oracle')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--compiler',default='ldc-1.43.0')
    p.add_argument('--build-flags',default='DUB release: -O -release -inline; default target and safe bounds checks')
    p.add_argument('--cpu',default='auto')
    p.add_argument('--size',type=int,default=1024)
    p.add_argument('--repeats',type=int,default=15)
    p.add_argument('--max-batches',type=int,default=3)
    p.add_argument('--load-limit',type=float,default=6.)
    p.add_argument('--frequency-limit',type=float,default=.05)
    p.add_argument('--sibling-busy-limit',type=float,default=.05)
    p.add_argument('--features',nargs='+',default=['gaussian','gradient','median','ridge','gabor','localNormalization','pathOpening','canny','canny:native'])
    p.add_argument('--diagnostic',action='store_true')
    p.add_argument('--skip-numerical',action='store_true',help='diagnostic collection only; never admits a target')
    p.add_argument('--targets',type=Path,default=ROOT/'docs/benchmarks/performance-targets.json')
    args=p.parse_args()
    if args.skip_numerical and not args.diagnostic:p.error('--skip-numerical requires --diagnostic')
    if args.repeats<15 or args.repeats>100 or args.max_batches<1 or args.max_batches>10:
        p.error('15..100 cycles and 1..10 bounded batches required')
    if args.size<1 or args.size>4096:p.error('invalid size')
    args.output.mkdir(parents=True,exist_ok=True)
    policy=json.loads(args.targets.read_text())
    if not args.skip_numerical:
        numerical=subprocess.check_output([sys.executable,str(ROOT/'tools/verify-feature-program.py'),str(args.oracle.resolve())],cwd=ROOT,text=True)
        (args.output/'numerical.txt').write_text(numerical)
    oracle=json.loads(subprocess.check_output([str(args.oracle.resolve()),'--primitives'],cwd=ROOT,text=True))
    reference,build_info=build(args.output/'reference')
    c_validation=validate(reference,oracle)
    native,native_info=build(args.output/'reference',native=True)
    native_validation=validate(native,oracle)
    args.cpu,cpu_selection=select_cpu(args.cpu)
    family=cpu_list(Path(f'/sys/devices/system/cpu/cpu{args.cpu}/topology/thread_siblings_list').read_text())
    observer_pool=os.sched_getaffinity(0)-family
    if observer_pool:os.sched_setaffinity(0,{min(observer_pool)})
    observer_affinity=sorted(os.sched_getaffinity(0))
    env=dict(os.environ,IMAGERY_CANNY_REFERENCE=str((args.output/'reference/canny-portable.so').resolve()))
    report=dict(schema=1,argv=sys.argv,host=platform.platform(),cpu=args.cpu,numerical_preflight=not args.skip_numerical,
        comparison_contract='strict-float64-final-float32/full-frame-v1',
        size=args.size,minimum_cycles=15,max_batches=args.max_batches,cpu_selection=cpu_selection,observer_affinity=observer_affinity,
        hygiene=dict(load_limit=args.load_limit,frequency_limit=args.frequency_limit,sibling_busy_fraction=args.sibling_busy_limit),
        git_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        binary_source=(args.binary.resolve().parent/'source.txt').read_text().strip() if (args.binary.resolve().parent/'source.txt').exists() else 'unrecorded',
        tracked_dirty=bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=no'],cwd=ROOT,text=True)),
        compiler=subprocess.check_output([args.compiler,'--version'],text=True),
        build_flags=args.build_flags,profile_flags=args.build_flags+'; version ImageryProfile',
        cpu_model=next((x.split(':',1)[1].strip() for x in Path('/proc/cpuinfo').read_text().splitlines() if x.startswith('model name')),'unknown'),
        oracle_sha256=hashlib.sha256(args.oracle.read_bytes()).hexdigest(),
        canny=dict(portable=dict(build=build_info,validation=c_validation),native=dict(build=native_info,validation=native_validation)),
        binaries={},results={},profile_results={},status='pending')
    for kind,binary in [('primary',args.binary),('profile',args.profile_binary)]:
        if binary is None:continue
        binary=binary.resolve();report['binaries'][kind]=dict(path=str(binary),sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
        (args.output/'engine-paths.json').write_text(json.dumps(report,indent=2)+'\n')
        output=report['results'] if kind=='primary' else report['profile_results']
        for feature in args.features:
            if kind=='profile' and feature.startswith('canny'):continue
            env['IMAGERY_CANNY_REFERENCE']=str((args.output/('reference/canny-native.so' if feature=='canny:native' else 'reference/canny-portable.so')).resolve())
            rows=[];summaries={}
            for batch in range(args.max_batches):
                command=['taskset','-c',str(args.cpu),str(binary),str(args.size),str(args.repeats),'compare','scalar',feature]
                path=args.output/f'{kind}-{feature.replace(":","-")}-{batch}.jsonl'
                with path.open('w') as stream:
                    with subprocess.Popen(command,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE) as process:
                        for line in process.stdout:
                            stream.write(line);stream.flush()
                            row=json.loads(line);row['session']=batch
                            row['hygiene']=hygiene(row,args.load_limit,args.frequency_limit,args.sibling_busy_limit)
                            rows.append(row)
                        if process.wait()!=0:raise subprocess.CalledProcessError(process.returncode,command)
                grouped=groups(rows)
                for pair,cycles in grouped.items():
                    target=policy['targets']['canny']['maximum_ratio'] if feature.startswith('canny') else (
                        policy.get('engine',{}).get('operators',{}).get(feature,{}).get('maximum_ratio'))
                    summary=summarize(cycles,target=target)
                    summary['raw_diagnostic']=raw_diagnostic(cycles)
                    if kind=='profile':
                        from statistics import median
                        accepted_groups=[g for g in cycles if all(x['hygiene']['accepted'] for x in g)]
                        accepted=[r for g in accepted_groups for r in (g[0],g[3])]
                        summary['phase_medians_ns_per_pixel']={name:median(r['phases_ns'][name]/args.size**2 for r in accepted)
                            for name in ['source','prepare','kernel','cache','sink']} if accepted else {}
                        summary['phases']={}
                        summary['raw_phases_ns_per_pixel']={}
                        import math
                        for name in ['source','prepare','cache','sink','overhead']:
                            def phase(row):
                                fields=['source','prepare','cache','sink'] if name=='overhead' else [name]
                                return sum(row['phases_ns'][field] for field in fields)/args.size**2
                            samples=[math.sqrt(phase(g[0])*phase(g[3])) for g in accepted_groups]
                            if samples and all(x>0 for x in samples):summary['phases'][name]=distribution(samples)
                            raw_samples=[math.sqrt(phase(g[0])*phase(g[3])) for g in cycles]
                            if raw_samples and all(x>0 for x in raw_samples):
                                summary['raw_phases_ns_per_pixel'][name]=distribution(raw_samples)
                    summaries[pair]=summary
                if all(s['accepted_cycles']>=15 for s in summaries.values()):break
                if batch+1<args.max_batches:time.sleep(3)
            output[feature]=summaries
            for s in summaries.values():
                s['prepared_gc_bytes']=sum(r['gc_bytes'] for r in rows if r['mode'] in ('worker','canny-d','canny-c'))
                s['engine_warm_gc_bytes']=sum(r['gc_bytes'] for r in rows if r['mode']=='warm')
            (args.output/f'{kind}-{feature.replace(":","-")}-annotated.json').write_text(json.dumps(rows,indent=2)+'\n')
            (args.output/'engine-paths.json').write_text(json.dumps(report,indent=2)+'\n')
            print(json.dumps(dict(build=kind,feature=feature,summaries=summaries)),flush=True)
    # Engine policy validation is shared with the ordinary gate; absence of
    # enough hygienic cycles is pending, never a silent PASS.
    from importlib.util import spec_from_file_location,module_from_spec
    spec=spec_from_file_location('targets',ROOT/'tools/check-performance-targets.py')
    checker=module_from_spec(spec);spec.loader.exec_module(checker)
    if hasattr(checker,'check_engine_paths'):
        report['gates']=checker.check_engine_paths(report,policy)
    else: report['gates']=[dict(status='pending',reason='Engine policy not configured')]
    statuses=[g['status'] for g in report['gates']]
    report['status']='fail' if 'fail' in statuses else 'pending' if 'pending' in statuses or not statuses else 'pass'
    (args.output/'engine-paths.json').write_text(json.dumps(report,indent=2)+'\n')
    lines=['| Build / feature / A mode | A median ± MAD ns/px | Worker/reference median ± MAD | Ratio [bootstrap 95%] | Cycles accepted/rejected | Effect | Target |',
           '|---|---:|---:|---:|---:|---|---|']
    for kind,key in [('primary','results'),('profile','profile_results')]:
        for name,modes in report[key].items():
            for mode,s in modes.items():
                fmt=lambda x:f'{s[x]:.3f}' if x in s else '—'
                lines.append(f'| {kind} / {name} / {mode} | {fmt("a_median")} ± {fmt("a_mad")} | {fmt("b_median")} ± {fmt("b_mad")} | {fmt("ratio")} {s.get("bootstrap_95",[])} | {s["accepted_cycles"]}/{s["rejected_cycles"]} | {s["effect"]} | {s["target_status"]} |')
    lines+=['',f'Admission: {report["status"].upper()}',json.dumps(report['gates'],indent=2)]
    (args.output/'report.md').write_text('\n'.join(lines)+'\n')
    if not args.diagnostic:raise SystemExit({'pass':0,'fail':1,'pending':2}[report['status']])


if __name__=='__main__':main()
