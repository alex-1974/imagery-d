"""ABBA before/after, parameter sensitivity and normalization reference gate.

The native sample command times prepared Float32-input kernels; process setup,
fixture construction, frame copies and hashes are outside that kernel clock.
The parent session interleaves independently built binaries and OpenCV. Raw
results, including every rejected cycle, are retained. No noisy row passes.
"""
import argparse
from pathlib import Path
import os
import sys
import json
import time
import hashlib
import subprocess
import math
import platform
from measurement_protocol import select_cpu,hygiene,summarize,distribution,raw_diagnostic
from canny_reference import build,validate

ROOT=Path(__file__).resolve().parents[1]


def optional(path):
    try:return Path(path).read_text().strip()
    except OSError:return ''


def telemetry(cpu):
    base=f'/sys/devices/system/cpu/cpu{cpu}'
    frequency=optional(base+'/cpufreq/scaling_cur_freq')
    return dict(cpu=cpu,frequency_khz=frequency,governor=optional(base+'/cpufreq/scaling_governor'),
        siblings=optional(base+'/topology/thread_siblings_list'),loadavg=optional('/proc/loadavg'),
        cpu_ticks='\n'.join(x for x in optional('/proc/stat').splitlines() if x.startswith('cpu')),
        power={str(p):optional(p) for p in Path('/sys/class/power_supply').glob('*/online')},
        temperatures_millic={str(p):optional(p) for p in Path('/sys/class/thermal').glob('*/temp')})


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True);p.add_argument('--baseline',type=Path,required=True)
    p.add_argument('--oracle',type=Path,default=ROOT/'tests/feature_program/feature-program-oracle')
    p.add_argument('--output',type=Path,required=True);p.add_argument('--cpu',default='auto')
    p.add_argument('--compiler',default='ldc-1.43.0')
    p.add_argument('--build-flags',default='DUB release: -O -release -inline; default target and safe bounds checks')
    p.add_argument('--repeats',type=int,default=15);p.add_argument('--max-cycles',type=int,default=90)
    p.add_argument('--max-seconds',type=float,help='optional per-case cap, checked after complete cycles')
    p.add_argument('--load-limit',type=float,default=6.);p.add_argument('--diagnostic',action='store_true')
    p.add_argument('--sibling-busy-limit',type=float,default=.05)
    p.add_argument('--cases',nargs='+',default=['pathOpening','pathClosing','path-length','localNormalization','normalization-radii'])
    args=p.parse_args()
    if args.repeats<15 or args.max_cycles<args.repeats:p.error('>=15 cycles required')
    if args.max_seconds is not None and args.max_seconds<=0:p.error('positive collection cap required')
    args.output.mkdir(parents=True,exist_ok=True)
    policy=json.loads((ROOT/'docs/benchmarks/performance-targets.json').read_text())
    limits=policy['windows']['ratios']
    numerical=subprocess.check_output([sys.executable,str(ROOT/'tools/verify-feature-program.py'),str(args.oracle.resolve())],text=True,cwd=ROOT)
    (args.output/'numerical.txt').write_text(numerical)
    args.cpu,selection=select_cpu(args.cpu);os.sched_setaffinity(0,{args.cpu})
    import cv2
    import numpy as np
    cv2.setNumThreads(1)
    reference,metadata=build(args.output/'reference')
    primitives=json.loads(subprocess.check_output([str(args.oracle.resolve()),'--primitives'],text=True))
    validate(reference,primitives)
    control,control_edges=reference.prepare([(i*37%257)/256 for i in range(64*64)],64,64,.1,.2)
    def unchanged_control():
        control()  # match preheated control state on both sides of every cell
        started=time.perf_counter_ns();control();ns=time.perf_counter_ns()-started
        hashlib.sha256(control_edges).hexdigest()
        return ns
    def native(binary,feature):
        before_control=unchanged_control()
        command=[str(binary.resolve()),'1024','1','sample','scalar',feature]
        row=json.loads(subprocess.check_output(command,text=True,cwd=ROOT))
        after_control=unchanged_control()
        row['compiled_target_control']={k:row[k] for k in ['control_before_ns','control_after_ns','control_digest']}
        row.update(control_before_ns=before_control,control_after_ns=after_control,
            control_digest=hashlib.sha256(control_edges).hexdigest())
        if row.get('input_storage')!='float32':raise ValueError('Parameter target requires actual Float32 input storage')
        if row['gc_bytes']!=0:raise ValueError('Prepared parameter kernel allocated GC bytes')
        return row
    y,x=np.indices((1024,1024),dtype=np.uint64)
    source=(((x*37+y*17+x*y%97)&255).astype(np.float32)/np.float32(255)).astype(np.float64)
    def opencv(radius):
        def operation():
            mean=cv2.boxFilter(source,-1,(2*radius+1,2*radius+1),borderType=cv2.BORDER_REPLICATE)
            square=cv2.boxFilter(source*source,-1,(2*radius+1,2*radius+1),borderType=cv2.BORDER_REPLICATE)
            deviation=np.sqrt(np.maximum(0,square-mean*mean))
            return np.divide(source-mean,deviation,out=np.zeros_like(source),where=deviation>0)
        def measure():
            before_control=unchanged_control();operation();before=telemetry(args.cpu)
            start=time.perf_counter_ns();result=operation();ns=time.perf_counter_ns()-start
            after=telemetry(args.cpu);after_control=unchanged_control()
            return dict(ns_per_pixel=ns/source.size,digest=hashlib.sha256(result).hexdigest(),before=before,after=after,
                control_before_ns=before_control,control_after_ns=after_control,
                control_digest=hashlib.sha256(control_edges).hexdigest(),gc_bytes=0)
        return measure
    tasks=[]
    for feature in ['pathOpening','pathClosing','localNormalization']:
        if feature in args.cases:tasks.append((feature,lambda f=feature:native(args.binary,f),
            lambda f=feature:native(args.baseline,f),limits[feature],feature.startswith('path')))
    if 'path-length' in args.cases:tasks.append(('path-length',lambda:native(args.binary,'pathOpening:31:2'),lambda:native(args.binary,'pathOpening:7:1'),limits['path-length'],False))
    if 'normalization-radii' in args.cases:
        for radius in [1,3,7,15,31]:tasks.append((f'normalization-r{radius}',lambda r=radius:native(args.binary,f'localNormalization:{r}'),opencv(radius),limits[f'normalization-r{radius}'],False))
        tasks.append(('normalization-radius-sensitivity',lambda:native(args.binary,'localNormalization:31'),lambda:native(args.binary,'localNormalization:1'),limits['normalization-radius-sensitivity'],False))
    report=dict(schema=1,numerical_preflight=True,selection=selection,cpu=args.cpu,size=1024,
        comparison_contract='float32-input-float64-statistics/prepared-kernel-v1',
        scope='prepared float32 input, float64 statistics; complete output observation outside per-tile kernel clocks',
        baseline_source='5b1b0b95a57c2e31dbed1fedcd5dfdafe8a4909d plus identical benchmark-only overlay',
        candidate_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),baseline_sha256=hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
        binary_source=(args.binary.resolve().parent/'source.txt').read_text().strip() if (args.binary.resolve().parent/'source.txt').exists() else 'unrecorded',
        benchmark_overlay_sha256=hashlib.sha256(''.join(str(f.relative_to(ROOT))+'\0'+hashlib.sha256(f.read_bytes()).hexdigest()+'\n'
            for f in sorted((ROOT/'benchmark/source').rglob('*.d'))).encode()).hexdigest(),
        numpy=np.__version__,opencv=cv2.__version__,c_control=metadata,results={},
        compiler=subprocess.check_output([args.compiler,'--version'],text=True),build_flags=args.build_flags,host=platform.platform(),
        cpu_model=next((x.split(':',1)[1].strip() for x in Path('/proc/cpuinfo').read_text().splitlines() if x.startswith('model name')),'unknown'),
        oracle_sha256=hashlib.sha256(args.oracle.read_bytes()).hexdigest(),
        maximum_collection_seconds_per_case=args.max_seconds,
        hygiene=dict(load_limit=args.load_limit,frequency_limit=.05,sibling_busy_fraction=args.sibling_busy_limit),
        git_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip())
    report['status']='collecting'
    (args.output/'window-paths.json').write_text(json.dumps(report,indent=2)+'\n')
    for name,a,b,target,identity in tasks:
        groups=[]
        raw=args.output/(name+'.raw.jsonl');raw.write_text('')
        collection_started=time.monotonic()
        for cycle in range(args.max_cycles):
            group=[]
            for position,(mode,operation) in enumerate([('A',a),('B',b),('B',b),('A',a)]):
                row=operation();row.update(position=position,mode=mode,cycle=cycle)
                row['hygiene']=hygiene(row,args.load_limit,max_sibling_busy_fraction=args.sibling_busy_limit);group.append(row)
            groups.append(group)
            with raw.open('a') as stream:stream.write(json.dumps(group)+'\n')
            if sum(all(r['hygiene']['accepted'] for r in g) for g in groups)>=args.repeats:break
            if args.max_seconds is not None and time.monotonic()-collection_started>=args.max_seconds:break
            time.sleep(.1)
        summary=summarize(groups,target=target,require_equal_outputs=identity)
        summary['raw_diagnostic']=raw_diagnostic(groups,require_equal_outputs=identity)
        if len({r['control_digest'] for g in groups for r in g})!=1:raise ValueError('Unchanged C control output differs')
        if name.startswith('normalization-r') and name!='normalization-radius-sensitivity':
            accepted=[math.sqrt(g[0]['ns_per_pixel']*g[3]['ns_per_pixel']) for g in groups if all(r['hygiene']['accepted'] for r in g)]
            if accepted:summary['absolute_native_ns_per_pixel']=distribution(accepted)
        report['results'][name]=summary
        (args.output/(name+'.json')).write_text(json.dumps(groups,indent=2)+'\n')
        (args.output/'window-paths.json').write_text(json.dumps(report,indent=2)+'\n')
        print(name,json.dumps(summary),flush=True)
    from importlib.util import spec_from_file_location,module_from_spec
    spec=spec_from_file_location('targets',ROOT/'tools/check-performance-targets.py');checker=module_from_spec(spec);spec.loader.exec_module(checker)
    report['gates']=checker.check_window_paths(report,policy)
    report['status']='fail' if any(g['status']=='fail' for g in report['gates']) else 'pending' if any(g['status']=='pending' for g in report['gates']) else 'pass'
    (args.output/'window-paths.json').write_text(json.dumps(report,indent=2)+'\n')
    if not args.diagnostic:raise SystemExit({'pass':0,'fail':1,'pending':2}[report['status']])


if __name__=='__main__':main()
