"""Retain static packed-opcode evidence; counts are not dynamic throughput."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('artifacts', type=Path)
    args = p.parse_args()
    report = dict(tool=subprocess.check_output(['objdump','--version'],text=True).splitlines()[0],targets={})
    for target in ['portable','v3','native']:
        binary = args.artifacts/(target+'-bench')
        assembly = subprocess.check_output(['objdump','-d','-l','--demangle=dlang',str(binary)],text=True)
        counts = Counter()
        source = ''
        for line in assembly.splitlines():
            location = re.match(r'(/.*\.d):\d+',line)
            if location:
                source = Path(location[1]).name
            elif re.match(r'[0-9a-f]+ <',line):
                source = ''
            if source not in ['row_kernels.d','path_kernels.d','window_kernels.d','hessian_lines.d']:
                continue
            instruction = re.match(r'([a-z][a-z0-9]+)\s+(.*)',line.split('\t')[-1])
            if not instruction:
                continue
            opcode, operands = instruction.groups()
            packed = re.search(r'(add|sub|mul|div|min|max|sqrt|fmadd|fmsub)\w*p[sd]$',opcode) or opcode.endswith(('pminub','pmaxub'))
            if packed and ('%ymm' in operands or '%xmm' in operands):
                counts[(source,opcode,'256' if '%ymm' in operands else '128')] += 1
        report['targets'][target] = dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
            instructions=[dict(source=s,opcode=o,bits=int(b),static_count=n) for (s,o,b),n in sorted(counts.items())])
    (args.artifacts/'packed-opcodes.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__':
    main()
