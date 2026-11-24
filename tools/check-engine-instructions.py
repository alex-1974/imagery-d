"""Manual named-function Callgrind attribution; separate from release wall time."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]
MODEL=['--I1=32768,8,64','--D1=32768,8,64','--LL=8388608,16,64']


def function_costs(text):
    events=[];positions=1;pool={};costs=defaultdict(lambda:defaultdict(int));current=None;summary={}
    def name(value):
        match=re.fullmatch(r'\((\d+)\)(?: (.*))?',value)
        if not match:return value
        key=int(match[1])
        if match[2] is not None:pool[key]=match[2]
        return key
    for line in text.splitlines():
        if line.startswith('positions:'):positions=len(line.split())-1
        elif line.startswith('events:'):events=line.split()[1:]
        elif line.startswith('summary:'):
            values=list(map(int,line.split()[1:]));summary=dict(zip(events,values+[0]*(len(events)-len(values))))
        elif line.startswith('fn='):current=name(line[3:])
        elif line.startswith('cfn='):name(line[4:])
        elif current is not None and line and line[0] in '0123456789+*-':
            fields=line.split();values=list(map(int,fields[positions:]))
            if len(values)>len(events):raise ValueError('Invalid Callgrind cost row')
            for event,value in zip(events,values):costs[current][event]+=value
    if not summary.get('Ir'):raise ValueError('Instruction region was not collected')
    result=defaultdict(lambda:defaultdict(int))
    for key,values in costs.items():
        label=pool.get(key,str(key))
        for event,value in values.items():result[label][event]+=value
    return summary,dict(result)


def phases(text):
    total,functions=function_costs(text)
    groups={
        'source_including_prepare':['imageryEngineSourceRead','imageryEngineSourceBorrow64','imageryEngineSourceBorrow32'],
        'prepare_borrowed':['imageryEnginePreparePlane64','imageryEnginePreparePlane32'],
        'prepare_samples':['imageryEnginePrepareSamples'],
        'cache':['imageryEngineCacheExchange','imageryEngineCacheValues'],
        'sink':['imageryEngineSinkValues','imageryEngineSinkPlanes']}
    sums={}
    for group,markers in groups.items():
        selected=[v for k,v in functions.items() if any(k.startswith(m) or ('.'+m+'(') in k for m in markers)]
        sums[group]={event:sum(v.get(event,0) for v in selected) for event in total}
    result={}
    result['source']={k:sums['source_including_prepare'][k]-sums['prepare_borrowed'][k] for k in total}
    result['prepare']={k:sums['prepare_borrowed'][k]+sums['prepare_samples'][k] for k in total}
    result['cache']=sums['cache'];result['sink']=sums['sink']
    result['residual']={k:total[k]-sum(v[k] for v in result.values()) for k in total}
    if any(v<0 for values in result.values() for v in values.values()):raise ValueError('Phase attribution overlaps or missing parent')
    if any(result[k].get('Ir',0)<=0 for k in ['source','prepare','cache','sink']):
        raise ValueError('Build with ImageryInstructionPhases; all named boundaries must be retained')
    return dict(total=total,phases=result,functions=functions)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--valgrind',default='valgrind')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--size',type=int,default=64)
    p.add_argument('--features',nargs='+',default=['gaussian','gradient','median','ridge','gabor'])
    p.add_argument('--modes',nargs='+',default=['cold64','cold32','warm','cold64-view','cold32-view','warm-view'])
    args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    report=dict(tool=subprocess.check_output([args.valgrind,'--version'],text=True).strip(),model=MODEL,
        source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        build_flags='DUB release; --gline-tables-only --d-version=ImageryInstructionPhases; portable',
        compiler=subprocess.check_output(['ldc-1.43.0','--version'],text=True),
        size=args.size,binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        scope='one completed frame; diagnostic no-inline phase boundaries; residual includes setup/planning/kernel',results={})
    for feature in args.features:
        hashes=set()
        for mode in args.modes:
            path=(args.output/f'{feature}-{mode}.callgrind').resolve()
            command=[args.valgrind,'--tool=callgrind','--collect-atstart=no',
                '--toggle-collect=imageryEngineInstructionRegion','--cache-sim=yes',*MODEL,
                '--callgrind-out-file='+str(path),str(args.binary.resolve()),str(args.size),'1',
                'engine-instructions','scalar',feature,mode]
            run=subprocess.run(command,cwd=ROOT,text=True,capture_output=True,check=True)
            (args.output/f'{feature}-{mode}.stderr').write_text(run.stderr)
            frame=json.loads(run.stdout);hashes.add(frame['digest'])
            if frame['computed_tiles']<=0 or (mode.startswith('warm') and frame['gc_bytes']):
                raise ValueError('Need actual frames and zero warm thread-GC bytes')
            report['results'][f'{feature}/{mode}']=dict(frame=frame,command=command,**phases(path.read_text()))
            (args.output/'engine-instructions.json').write_text(json.dumps(report,indent=2)+'\n')
        if len(hashes)!=1:raise ValueError('Sink modes changed complete output fingerprints')
    print('ENGINE_PHASE_INSTRUCTIONS=PASS')


if __name__=='__main__':main()
