"""Paired optional-target experiment; never changes the portable CPU floor.

Each executable must come from the same source with only its target flags
changed. Uses prepared kernel clocks, full output observation, an unchanged
Canny control and the same hygiene/whole-cycle bootstrap as issue #212.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time
from measurement_protocol import hygiene, summarize, select_cpu, cpu_list

ROOT = Path(__file__).resolve().parents[1]
FEATURES = ['gaussian32', 'gradient', 'median', 'ridge', 'gabor', 'hessian',
            'pathOpening', 'localNormalization']
FLAGS = {'portable': '', 'v3': '--mcpu=x86-64-v3', 'native': '--mcpu=native'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cpu', default='auto')
    parser.add_argument('--size', type=int, default=1024)
    parser.add_argument('--cycles', type=int, default=15)
    parser.add_argument('--max-cycles', type=int, default=90)
    parser.add_argument('--features', nargs='+', choices=FEATURES, default=FEATURES)
    args = parser.parse_args()
    if args.cycles < 15 or args.max_cycles < args.cycles:
        parser.error('at least 15 complete accepted cycles required')
    artifacts = args.artifacts.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    cpu, selection = select_cpu(args.cpu)
    family = cpu_list(Path(f'/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list').read_text())
    observers = os.sched_getaffinity(0) - family
    if observers:
        os.sched_setaffinity(0, {min(observers)})
    report = dict(schema=1, cpu=cpu, selection=selection, size=args.size,
        observer_affinity=sorted(os.sched_getaffinity(0)), host=platform.platform(),
        compiler=subprocess.check_output(['ldc-1.43.0', '--version'], text=True),
        source=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        tracked_dirty=bool(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT, text=True)),
        cpu_model=next(x.split(':',1)[1].strip() for x in Path('/proc/cpuinfo').read_text().splitlines() if x.startswith('model name')),
        contract='prepared Float32 input; strict worker except opt-in Gaussian32; Hessian three scales 1,2,4; frame copy/hash outside clock',
        hygiene=dict(max_load=6., max_frequency_change=.05, max_sibling_busy_fraction=.05),
        builds={}, results={})
    for target, flags in FLAGS.items():
        binary = artifacts / (target + '-bench')
        oracle = artifacts / (target + '-oracle')
        validation = artifacts / (target + '-numerical.txt')
        if not validation.exists() or not any(line.startswith('PASS:') for line in validation.read_text().splitlines()):
            raise ValueError('Independent oracle must pass for every target before timing')
        report['builds'][target] = dict(flags='DUB release; --gline-tables-only; '+flags,
            binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
            oracle_sha256=hashlib.sha256(oracle.read_bytes()).hexdigest(),
            numerical_sha256=hashlib.sha256(validation.read_bytes()).hexdigest(),
            remarks_sha256=hashlib.sha256((artifacts/(target+'-build.log')).read_bytes()).hexdigest())

    def measure(target, feature):
        command = ['taskset', '-c', str(cpu), str(artifacts/(target+'-bench')),
                   str(args.size), '1', 'sample', 'scalar', feature]
        row = json.loads(subprocess.check_output(command, cwd=ROOT, text=True))
        if row['gc_bytes'] != 0 or row.get('input_storage') != 'float32':
            raise ValueError('Prepared kernels must have Float32 input and zero measured GC bytes')
        row['target'] = target
        row['hygiene'] = hygiene(row)
        return row

    for feature in args.features:
        report['results'][feature] = {}
        for target in FLAGS:
            groups = []
            for cycle in range(args.max_cycles):
                group = []
                for position, (mode, setting) in enumerate([('A',target),('B','portable'),('B','portable'),('A',target)]):
                    row = measure(setting, feature)
                    row.update(position=position, mode=mode, cycle=cycle)
                    group.append(row)
                # Different compiler targets may round floating operations
                # differently; independent per-target oracle is the numerical
                # admission. Exact fingerprints are still retained/reported.
                groups.append(group)
                if sum(all(r['hygiene']['accepted'] for r in g) for g in groups) >= args.cycles:
                    break
                time.sleep(.1)
            controls = {r['control_digest'] for g in groups for r in g}
            if len(controls) != 1:
                raise ValueError('Unchanged control produced different output')
            summary = summarize(groups, require_equal_outputs=False)
            summary['exact_output_identity'] = len({r['digest'] for g in groups for r in g}) == 1
            report['results'][feature][target] = summary
            (args.output/(feature+'-'+target+'.json')).write_text(json.dumps(groups,indent=2)+'\n')
            (args.output/'codegen.json').write_text(json.dumps(report,indent=2)+'\n')
            print(feature,target,json.dumps(summary),flush=True)
    report['status'] = 'measured' if set(report['results']) == set(FEATURES) and all(
        s['accepted_cycles']>=15 for v in report['results'].values() for s in v.values()) else 'inconclusive'
    (args.output/'codegen.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__':
    main()
