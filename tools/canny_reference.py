"""Build/load the independently authored finite Canny benchmark reference."""
import ctypes as C
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def build(directory, native=False):
    directory=Path(directory); directory.mkdir(parents=True, exist_ok=True)
    binary=directory/('canny-native.so' if native else 'canny-portable.so')
    flags=['-std=c11','-O3','-fno-fast-math','-fno-math-errno','-ffp-contract=off','-shared','-fPIC']
    if native: flags.append('-march=native')
    source=ROOT/'tests/reference/canny.c'
    subprocess.run(['gcc',*flags,str(source),'-lm','-o',str(binary)],check=True)
    return Reference(binary), dict(compiler=subprocess.check_output(['gcc','--version'],text=True).splitlines()[0],
        flags=flags,source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
        binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),native=native)


class Reference:
    def __init__(self, binary):
        self.library=C.CDLL(str(Path(binary).resolve()))
        self.run=self.library.imagery_canny_reference
        f=C.POINTER(C.c_float); b=C.POINTER(C.c_uint8)
        self.run.argtypes=[f,C.c_size_t,C.c_size_t,C.c_float,C.c_float,b,f,f,b,b,C.POINTER(C.c_uint32)]
        self.run.restype=C.c_int

    def prepare(self, samples, w, h, low, high):
        n=w*h
        args=((C.c_float*n)(*samples), w,h,low,high,(C.c_uint8*n)(),
              (C.c_float*n)(),(C.c_float*n)(),(C.c_uint8*n)(),(C.c_uint8*n)(),(C.c_uint32*n)())
        def evaluate():
            if self.run(*args)!=1: raise ValueError('Canny C reference rejected finite fixture')
        return evaluate, args[5]


def validate(reference, oracle):
    cases=oracle['canny_reference_cases']
    if len(cases)!=120: raise ValueError('120 independently retained scalar cases required')
    for case in cases:
        run, edges=reference.prepare(case['input'],case['width'],case['height'],case['low'],case['high'])
        run()
        if list(edges)!=case['edges']: raise ValueError('Aligned C Canny differs from scalar D corpus')
    return dict(cases=len(cases),mismatched_pixels=0)


if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser(); p.add_argument('oracle',type=Path);p.add_argument('output',type=Path)
    args=p.parse_args()
    oracle=json.loads(subprocess.check_output([str(args.oracle.resolve()),'--primitives'],text=True))
    for native in (False,True):
        reference,metadata=build(args.output,native)
        print(json.dumps(dict(build=metadata,validation=validate(reference,oracle))))
