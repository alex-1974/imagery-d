"""Descriptive block/halo sweep; never admits a timing target."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
from measurement_protocol import cpu_list,hygiene,select_cpu

ROOT=Path(__file__).resolve().parents[1]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--cpu',default='auto')
    p.add_argument('--size',type=int,default=1024)
    p.add_argument('--repeats',type=int,default=3)
    args=p.parse_args()
    if args.repeats<3:p.error('at least three descriptive rounds required')
    args.output.mkdir(parents=True,exist_ok=True)
    cpu,selection=select_cpu(args.cpu)
    family=cpu_list(Path(f'/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list').read_text())
    observers=os.sched_getaffinity(0)-family
    if observers:os.sched_setaffinity(0,{min(observers)})
    shapes=[(r,w) for w in [64,128,256] for r in [8,16,32,64,128]]
    report=dict(admission='descriptive tuning only',cpu=cpu,selection=selection,size=args.size,
        binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        source=(args.binary.parent/'source.txt').read_text().strip(),rows=[],summaries={})
    for round_ in range(args.repeats):
        rotation=(round_*5)%len(shapes)
        for rows,width in shapes[rotation:]+shapes[:rotation]:
            for feature in ['hessian','tensor']:
                env=dict(os.environ,IMAGERY_STRIP_ROWS=str(rows),IMAGERY_STRIP_WIDTH=str(width))
                command=['taskset','-c',str(cpu),str(args.binary.resolve()),str(args.size),'1','sample','scalar',feature]
                row=json.loads(subprocess.check_output(command,cwd=ROOT,env=env,text=True))
                row.update(round=round_,strip_rows=rows,strip_width=width)
                row['hygiene']=hygiene(row)
                if row['gc_bytes']:raise ValueError('Gaussian evaluation allocated')
                report['rows'].append(row)
                (args.output/'sweep.json').write_text(json.dumps(report,indent=2)+'\n')
    for feature in ['hessian','tensor']:
        rows=[r for r in report['rows'] if r['operator']==feature]
        if len({r['digest'] for r in rows})!=1:raise ValueError('Block dimensions changed output bits')
        for height,width in shapes:
            cells=[r for r in rows if r['strip_rows']==height and r['strip_width']==width]
            times=[r['ns_per_pixel'] for r in cells];center=statistics.median(times)
            report['summaries'][f'{feature}/{height}/{width}']=dict(median=center,
                mad=statistics.median(abs(t-center) for t in times),payload=cells[0]['standalone_payload_bytes'],
                observations=len(cells),hygiene_qualified=sum(r['hygiene']['accepted'] for r in cells))
    (args.output/'sweep.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['summaries'],indent=2))


if __name__=='__main__':main()
