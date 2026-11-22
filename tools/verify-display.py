"""Real imageio PNG -> resident overview cache -> moving 512² viewport gate.

python tools/verify-display.py tests/materialization/materialization-consumer
Optional --scene /path/esri.png --require-60; use taskset for local qualification.
The 60-fps gate applies to the named resident/interactive workloads, not decoding,
overview preparation, arbitrary fractional bilinear/area or multi-source blending.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import numpy as np
from PIL import Image

p=argparse.ArgumentParser()
p.add_argument('consumer')
p.add_argument('--scene',type=Path)
p.add_argument('--require-60',action='store_true')
p.add_argument('--workspace',action='store_true')
args=p.parse_args()
if args.scene:
    image=Image.open(args.scene).convert('RGBA')
    identity=args.scene.parent.name
    revision=hashlib.sha256(args.scene.read_bytes()).hexdigest()
else:
    yy,xx=np.indices((1230,2048),dtype=np.uint32)
    rgba=np.stack([(37*xx+19*yy)%256,(13*xx+43*yy)%256,(53*xx+7*yy)%256,
                   np.where((xx+yy)%7==0,0,(23*xx+11*yy)%256)],axis=-1).astype('uint8')
    image=Image.fromarray(rgba)
    identity='deterministic-rgba-display';revision='formula-v1'
with tempfile.TemporaryDirectory(prefix='imagery-display-') as tmp:
    root=Path(tmp);levels=[];expected=[];masks=[]
    for index,size in enumerate((image.size,(image.width//2,(image.height+1)//2))):
        overview=image if index==0 else image.resize(size,Image.Resampling.BOX)
        pixels=np.asarray(overview)
        path=root/f'level-{index}.png';overview.save(path,compress_level=1)
        level=dict(path=str(path),width=size[0],height=size[1])
        mask=np.ones((size[1],size[0]),dtype='uint8')
        if not args.scene:
            yy,xx=np.indices(mask.shape);mask[(3*xx+5*yy)%37==0]=0
            mask_path=root/f'mask-{index}.bin';mask.tofile(mask_path);level['mask']=str(mask_path)
        levels.append(level);expected.append(pixels);masks.append(mask)
    provider_revision=revision+';overview=Pillow13-RGBA-BOX-v1;mask='+('absent' if args.scene else 'formula-v1')
    manifest=dict(identity=identity,revision=provider_revision,levels=levels,output_directory=str(root),workspace=args.workspace)
    path=root/'manifest.json';path.write_text(json.dumps(manifest))
    result=json.loads(subprocess.check_output([args.consumer,'--display',str(path)],text=True))
    pixels=expected[1];mask=masks[1];height,width=mask.shape
    for mode in result['modes']:
        x,y,w,h=mode['region'];tw,th=mode['target']
        xx=(2*(x+np.arange(w,dtype='uint64'))+1)*width//(2*tw)
        yy=(2*(y+np.arange(h,dtype='uint64'))+1)*height//(2*th)
        expected_rgba=pixels[yy[:,None],xx[None,:]].copy()
        validity=mask[yy[:,None],xx[None,:]]
        expected_rgba[expected_rgba[:,:,3]==0,:3]=0
        expected_rgba[validity==0]=0
        expected_frame=np.concatenate([expected_rgba,validity[:,:,None]],axis=-1)
        actual=np.fromfile(mode['output'],dtype='uint8').reshape(h,w,5)
        np.testing.assert_array_equal(actual,expected_frame)
        assert mode['work_bytes']<=8*1024*1024
        mode.pop('output')
        if args.require_60:
            assert mode['p95_ns']<=1e9/60,(identity,mode['mode'],mode['p95_ns']/1e6)
    result['identity']=identity;result['revision']=revision
    result['provider_revision']=provider_revision
    result['reference_pixels']=4*512*512
    result['preparation_policy']='Pillow BOX RGBA overview, separate explicit mask; imageio decode/cache before timed frames'
    print(json.dumps(result,sort_keys=True))
