"""Manual Callgrind instruction/cache canary, outside wall-clock admission.

Only imageryInstructionRegion is collected; setup/hash/reporting are excluded.
Cache simulation uses an explicit model, not a claim about real cache misses.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
MODEL=['--I1=32768,8,64','--D1=32768,8,64','--LL=8388608,16,64']


def counters(text):
    events=next((line.split()[1:] for line in text.splitlines() if line.startswith('events:')),None)
    totals=next((line.split()[1:] for line in text.splitlines() if line.startswith('summary:')),None)
    if events is None or totals is None or len(totals)>len(events):raise ValueError('Missing Callgrind event summary')
    totals+=['0']*(len(events)-len(totals))
    values=dict(zip(events,map(int,totals)))
    if values.get('Ir',0)<=0 or not all(k in values for k in ('D1mr','D1mw','DLmr','DLmw')):
        raise ValueError('Instruction region/cache simulation was not collected')
    return dict(instructions=values['Ir'],d1_misses=values['D1mr']+values['D1mw'],ll_misses=values['DLmr']+values['DLmw'])


def check(observed, policy):
    if observed.keys()!=policy.keys():raise ValueError('Instruction feature coverage changed')
    return [f'{feature}/{key}: {value} > {policy[feature][key]}'
            for feature,counts in observed.items() for key,value in counts.items() if value>policy[feature][key]]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--valgrind',default='valgrind');p.add_argument('--size',type=int,default=32)
    p.add_argument('--features',nargs='+',default=['gaussian','gradient','median','gabor','localNormalization','pathOpening'])
    p.add_argument('--policy',type=Path,default=ROOT/'docs/benchmarks/instruction-budget-2026-11-23.json')
    p.add_argument('--record',action='store_true',help='write initial reviewed canary ceilings, without promoting wall time')
    args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    report=dict(tool=subprocess.check_output([args.valgrind,'--version'],text=True).strip(),size=args.size,
        model=MODEL,binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),observed={},commands=[])
    for feature in args.features:
        out=args.output/(feature.replace(':','-')+'.callgrind')
        command=[args.valgrind,'--tool=callgrind','--collect-atstart=no','--toggle-collect=imageryInstructionRegion',
            '--cache-sim=yes',*MODEL,'--callgrind-out-file='+str(out.resolve()),str(args.binary.resolve()),str(args.size),'1','instructions','scalar',feature]
        result=subprocess.run(command,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
        (args.output/(feature.replace(':','-')+'.log')).write_text(result.stderr)
        if len(result.stdout.strip())!=64:raise ValueError('Missing complete output observation')
        report['observed'][feature]=counters(out.read_text());report['commands'].append(command)
    if args.record:
        policy=dict(schema=1,tool=report['tool'],size=args.size,model=MODEL,
            compiler='LDC 1.43.0 portable DUB release, default safe bounds checks',
            scope='One prepared frame, fixture/setup/hash excluded; manual canary, not performance admission',
            baseline_binary_sha256=report['binary_sha256'],
            ceilings={f:{k:math.ceil(v*(1.05 if k=='instructions' else 1.25))+1 for k,v in counts.items()}
                      for f,counts in report['observed'].items()})
        args.policy.write_text(json.dumps(policy,indent=2)+'\n')
    policy=json.loads(args.policy.read_text())
    if (policy['model'],policy['size'],policy['tool'])!=(MODEL,args.size,report['tool']):
        raise ValueError('Canary tool/workload/model differs from calibrated scope')
    failures=check(report['observed'],policy['ceilings']);report['failures']=failures
    report['status']='fail' if failures else 'pass'
    (args.output/'instructions.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report['observed'],indent=2))
    if failures:raise SystemExit('\n'.join(failures))


if __name__=='__main__':main()
