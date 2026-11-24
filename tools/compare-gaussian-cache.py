"""Descriptive Gaussian-block instruction/cache companion; no wall-time admission."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('counts',ROOT/'tools/check-instruction-counts.py')
counts=importlib.util.module_from_spec(spec);spec.loader.exec_module(counts)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--before',type=Path,required=True)
    p.add_argument('--after',type=Path,required=True)
    p.add_argument('--valgrind',default='valgrind')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--size',type=int,default=256)
    args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    report=dict(scope='one prepared frame; descriptive fixed simulated cache, not measured hardware misses or a bandwidth diagnosis',
        model=counts.MODEL,size=args.size,tool=subprocess.check_output([args.valgrind,'--version'],text=True).strip(),
        binaries={k:dict(sha256=hashlib.sha256(v.read_bytes()).hexdigest(),source=(v.parent/'source.txt').read_text().strip())
                  for k,v in [('before',args.before),('after',args.after)]},results={})
    for feature in ['hessian','tensor']:
        digests=set()
        for kind,rows in [('before',0),('after',32),('after',64),('after',128)]:
            binary=args.before if kind=='before' else args.after
            key=f'{feature}-{kind}-{rows}';out=(args.output/(key+'.callgrind')).resolve()
            env=dict(os.environ,IMAGERY_STRIP_ROWS=str(rows or 32),IMAGERY_STRIP_WIDTH='128')
            command=[args.valgrind,'--tool=callgrind','--collect-atstart=no','--toggle-collect=imageryInstructionRegion',
                '--cache-sim=yes',*counts.MODEL,'--callgrind-out-file='+str(out),str(binary.resolve()),str(args.size),'1','instructions','scalar',feature]
            run=subprocess.run(command,cwd=ROOT,env=env,text=True,capture_output=True,check=True)
            (args.output/(key+'.stderr')).write_text(run.stderr)
            digest=run.stdout.strip()
            if len(digest)!=64:raise ValueError('Missing complete output fingerprint')
            digests.add(digest)
            report['results'][key]=dict(digest=digest,command=command,counters=counts.counters(out.read_text()))
            (args.output/'gaussian-cache.json').write_text(json.dumps(report,indent=2)+'\n')
        if len(digests)!=1:raise ValueError('Source or block shape changed output bits')
    print('GAUSSIAN_CACHE_COMPANION=PASS')


if __name__=='__main__':main()
