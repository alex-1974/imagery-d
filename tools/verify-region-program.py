"""Independent NumPy/SciPy references for Lab SLIC and owned region graphs.

Uses the separately compiled tests/component_regions public consumer. Optional
--scene accepts a local RGB image; all ordinary fixtures are deterministic.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import subprocess
import tempfile
import numpy as np
from scipy.ndimage import label as components

parser=argparse.ArgumentParser()
parser.add_argument('consumer')
parser.add_argument('--scene',type=Path)
parser.add_argument('--benchmark',action='store_true')
args=parser.parse_args()


def connected_ids(assignments):
    accepted=assignments!=0
    preceding=np.zeros_like(accepted)
    preceding[:,1:] |= (assignments[:,1:]==assignments[:,:-1]) & accepted[:,1:]
    preceding[1:] |= (assignments[1:]==assignments[:-1]) & accepted[1:]
    births=np.zeros_like(assignments)
    births[accepted & ~preceding]=np.arange(1,np.count_nonzero(accepted & ~preceding)+1)
    result=np.zeros_like(assignments)
    for category in np.unique(assignments[accepted]):
        pieces,count=components(assignments==category)
        for region in range(1,count+1):
            selected=pieces==region
            born=births[selected];result[selected]=born[born!=0].min()
    return result


def graph_reference(labels,case,colors):
    h,w=labels.shape; yy,xx=np.indices((h,w));result={}
    texture=np.array([s[5] for s in case['samples']],float).reshape(h,w)
    edge=np.array([s[6] for s in case['samples']],float).reshape(h,w)
    adjacency=defaultdict(list)
    for dx,dy in ((1,0),(0,1)):
        for y in range(h-dy):
            for x in range(w-dx):
                a,b=int(labels[y,x]),int(labels[y+dy,x+dx])
                if a and b and a!=b:
                    value=.5*edge[y,x]+.5*edge[y+dy,x+dx]
                    adjacency[tuple(sorted((a,b)))].append(value)
    for region in np.unique(labels[labels!=0]):
        selected=labels==region; xs,ys=xx[selected],yy[selected];color=colors[selected]
        points=np.stack([xs+.5,ys+.5],axis=-1)
        centered=points-points.mean(axis=0)
        cov=centered.T@centered/len(points)
        perimeter=0
        for x,y in zip(xs,ys):
            perimeter+=sum(not(0<=x+dx<w and 0<=y+dy<h) or labels[y+dy,x+dx]!=region
                           for dx,dy in ((-1,0),(1,0),(0,-1),(0,1)))
        record=dict(pixels=len(xs),bounds=[int(xs.min())+case['origin_x'],int(ys.min())+case['origin_y'],
                    int(np.ptp(xs))+1,int(np.ptp(ys))+1],mean=color.mean(axis=0),variance=color.var(axis=0),
                    centroid=points.mean(axis=0),covariance=[cov[0,0],cov[1,1],cov[0,1]],perimeter=perimeter,
                    fill=len(xs)/((np.ptp(xs)+1)*(np.ptp(ys)+1)))
        for name,values in (('texture',texture[selected]),('edge',edge[selected])):
            values=values[np.isfinite(values)]
            record[name+'_count']=len(values);record[name]=values.mean() if len(values) else None
            record[name+'_variance']=values.var() if len(values) else 0.
        result[int(region)]=record
    return result,adjacency


def check_graph(actual,labels,case,colors):
    regions,adj=graph_reference(labels,case,colors)
    assert [r['id'] for r in actual['regions']]==sorted(regions)
    error=0.
    for r in actual['regions']:
        expected=regions[r['id']]
        for name,value in expected.items():
            if value is None: assert r[name] is None
            elif name in ('pixels','bounds','perimeter','texture_count','edge_count'): assert r[name]==value
            else:
                np.testing.assert_allclose(r[name],value,rtol=8e-15 if name in ('mean','variance') else 3e-15,
                                           atol=2e-13 if name=='covariance' else 1e-13 if name in ('mean','variance') else 2e-14,
                                           err_msg=f"{name}, region {r['id']}")
                error=max(error,float(np.max(np.abs(np.asarray(r[name])-value))))
        neighbors=sorted(b if a==r['id'] else a for a,b in adj if r['id'] in (a,b))
        assert r['neighbors']==neighbors
        cov=expected['covariance'];delta=cov[0]-cov[1]
        oriented=max(abs(delta),abs(2*cov[2]))>64*np.finfo(float).eps*(cov[0]+cov[1])
        assert r['oriented']==oriented
        if oriented:
            expected_angle=.5*np.arctan2(2*cov[2],delta)%np.pi
            assert abs((r['orientation']-expected_angle+np.pi/2)%np.pi-np.pi/2)<3e-12
    assert [tuple(e['ids']) for e in actual['edges']]==sorted(adj)
    for e in actual['edges']:
        a,b=e['ids'];values=np.array(adj[a,b]);values=values[np.isfinite(values)]
        assert e['sides']==len(adj[a,b]) and e['edge_count']==len(values)
        if len(values):
            np.testing.assert_allclose(e['edge'],values.mean(),rtol=0,atol=3e-15)
            np.testing.assert_allclose(e['variance'],values.var(),rtol=0,atol=3e-15)
        else: assert e['edge'] is None
        np.testing.assert_allclose(e['contrast'],np.linalg.norm(regions[a]['mean']-regions[b]['mean']),rtol=1e-14,atol=8e-13)
    return error


def merge_labels(labels,pairs):
    ids=set(map(int,np.unique(labels)))-{0};parents={i:i for i in ids}
    def root(i):
        while parents[i]!=i:i=parents[i]
        return i
    for a,b in pairs:
        a,b=root(a),root(b);parents[max(a,b)]=min(a,b)
    return np.array([root(int(i)) if i else 0 for i in labels.ravel()]).reshape(labels.shape)


def slic_reference(case,color,actual=None):
    h,w=color.shape[:2];s=case['spacing'];yy,xx=np.indices((h,w));px,py=xx+.5,yy+.5
    selected=np.array([v[1] and v[0]!=0 for v in case['samples']]).reshape(h,w)
    centers=[]
    for top in range(0,h,s):
        for left in range(0,w,s):
            ix,iy=min(w-1,left+s//2),min(h-1,top+s//2)
            candidates=[(x,y) for y in range(top,min(h,top+s)) for x in range(left,min(w,left+s)) if selected[y,x]]
            if not candidates:centers.append(None);continue
            x,y=min(candidates,key=lambda p:(p[0]-ix)**2+(p[1]-iy)**2)
            if case['perturb']:
                best=np.inf;chosen=(x,y)
                for ny in range(max(0,y-1),min(h,y+2)):
                    for nx in range(max(0,x-1),min(w,x+2)):
                        if not selected[ny,nx]:continue
                        points=[(max(0,nx-1),ny),(min(w-1,nx+1),ny),(nx,max(0,ny-1)),(nx,min(h-1,ny+1))]
                        if not all(selected[qy,qx] for qx,qy in points):continue
                        (ax,ay),(bx,by),(cx,cy),(dx,dy)=points
                        gradient=np.sum((color[ay,ax]-color[by,bx])**2)+np.sum((color[cy,cx]-color[dy,dx])**2)
                        if gradient<best:best=gradient;chosen=(nx,ny)
                x,y=chosen
            centers.append(np.r_[color[y,x],x+.5,y+.5])
    active=[i for i,c in enumerate(centers) if c is not None]
    assignments=np.zeros((h,w),int)
    if active:
        for _ in range(case['iterations']):
            cs=np.array([centers[i] for i in active])
            spatial=(px[None]-cs[:,3,None,None])**2+(py[None]-cs[:,4,None,None])**2
            costs=np.sum((color[None]-cs[:,:3,None,None].transpose(0,2,3,1))**2,axis=-1)
            costs+=(case['compactness']/s)**2*spatial
            tx=32*np.finfo(float).eps*np.maximum(s,np.maximum(abs(px[None]),abs(cs[:,3,None,None])))
            ty=32*np.finfo(float).eps*np.maximum(s,np.maximum(abs(py[None]),abs(cs[:,4,None,None])))
            local=(abs(px[None]-cs[:,3,None,None])<=s+tx)&(abs(py[None]-cs[:,4,None,None])<=s+ty)
            cost_local=np.where(local,costs,np.inf)
            orphan=np.all(~local,axis=0);cost_local[:,orphan]=costs[:,orphan]
            assignments=np.take(np.array(active)+1,np.argmin(cost_local,axis=0));assignments[~selected]=0
            for i in active:
                used=assignments==i+1
                if np.any(used):centers[i]=np.r_[color[used].mean(axis=0),px[used].mean(),py[used].mean()]
    labels=connected_ids(assignments)
    if actual is not None:
        got=np.array(actual['assignments']).reshape(h,w)
        np.testing.assert_array_equal(got,assignments)
    rounds=0;minimum=case['minimum_size']*s*s
    while minimum:
        regions,edges=graph_reference(labels,case,color);pairs=[]
        for region,node in sorted(regions.items()):
            if node['pixels']>=minimum:continue
            neighbors=[(b if a==region else a,len(values)) for (a,b),values in edges.items() if region in (a,b)]
            if neighbors:
                other,_=min(neighbors,key=lambda p:(-p[1],np.linalg.norm(node['mean']-regions[p[0]]['mean']),p[0]))
                pairs.append((region,other))
        if not pairs:break
        labels=merge_labels(labels,pairs);rounds+=1
        assert rounds<=32
    return labels,len(active),rounds


def fixture(kind,program,block,disk):
    h,w=13,19;yy,xx=np.indices((h,w));rng=np.random.default_rng(211+kind)
    color=np.stack([20.+10*(xx//4),-30.+20*(yy//4),15.*((xx+yy)//5%3)],axis=-1)
    if kind==1:color=rng.integers(-30,80,size=(h,w,3)).astype(float)
    elif kind==2:color[:]=[50.,0.,0.]
    valid=(xx+7*yy)%31!=0 if kind!=2 else np.ones((h,w),bool)
    samples=[[1,bool(valid[y,x]),*map(float,color[y,x]),float(x-y)/16 if (x+y)%3 else None,
              float((x*y)%13)/16 if (x+2*y)%4 else None] for y,x in np.ndindex(h,w)]
    case=dict(program=program,width=w,height=h,origin_x=2**53+37,origin_y=31,samples=samples,
              block=block,disk=disk,spacing=4,compactness=10.,iterations=5,minimum_size=.25,perturb=True)
    if program=='graph':
        labels=(1+(xx//4)+5*(yy//4))*7;labels[~valid]=0
        case['labels']=labels.ravel().tolist();case['merges']=[[[7,14],[14,21]],[[7,42]]]
    return case


cases=[fixture(kind,program,block,disk) for kind in range(3) for program in ('graph','slic')
       for block in (1,7,256) for disk in (False,True)]
stages=[]
for iteration in range(1,6):
    case=fixture(1,'slic',1,False);case.update(iterations=iteration,minimum_size=0.)
    stages.append(case)
cases=stages+cases
# Variants isolate color, compactness, NoData, one-pixel spacing, no perturbation,
# and explicit disabling of the small-region merge policy.
for spacing,compactness,iterations,perturb,minimum in ((1,1.,1,False,0.),(3,.5,3,False,0.),
                                                      (7,35.,10,True,1.),(32,10.,2,True,.25),
                                                      (3,1e-6,10,True,.25),(3,1e6,3,False,.25)):
    case=fixture(1,'slic',7,False)
    case.update(spacing=spacing,compactness=compactness,iterations=iterations,perturb=perturb,minimum_size=minimum)
    cases.append(case)
for excluded_valid in (False,True):
    case=fixture(0,'slic',7,False)
    for sample in case['samples']:sample[0]=0;sample[1]=excluded_valid
    cases.append(case)
case=fixture(1,'slic',7,True)
for i,sample in enumerate(case['samples']):
    x,y=i%case['width'],i//case['width']
    sample[1]=(x<3 and y<3) or (x>15 and y>9)
cases.append(case)
# Sparse corner plus a dense lower patch pulls its seed beyond the local
# window. The next assignment must use the explicit global orphan fallback.
for block,disk in ((1,False),(7,False),(1,True),(7,True)):
    case=fixture(0,'slic',block,disk)
    case.update(width=8,height=8,spacing=4,iterations=3,perturb=False,minimum_size=0.)
    case['samples']=[]
    for y,x in np.ndindex(8,8):
        valid=(x==0 and y==0) or (x>=3 and y>=3)
        color=100. if (x,y) in ((6,3),(3,6),(6,6)) else 0.
        case['samples'].append([1,valid,color,color,color,None,None])
    cases.append(case)
if args.scene:
    from PIL import Image
    rgb=np.asarray(Image.open(args.scene).convert('RGB'))[183:279,273:401]
    h,w,_=rgb.shape
    for block,disk in ((7,False),(256,False),(7,True)):
        case=fixture(0,'slic',block,disk)
        case.update(width=w,height=h,origin_x=0,origin_y=0,spacing=8,rgb=True,
                    samples=[[1,True,*map(float,rgb[y,x]),None,None] for y,x in np.ndindex(h,w)])
        cases.append(case)
    for block,disk in ((7,False),(256,False),(7,True)):
        case=fixture(0,'graph',block,disk)
        yy,xx=np.indices((h,w))
        case.update(width=w,height=h,origin_x=0,origin_y=0,rgb=True,
                    labels=(1+xx//16+((w+15)//16)*(yy//16)).ravel().tolist(),
                    merges=[[[1,2]],[[1,9]]],
                    samples=[[1,True,*map(float,rgb[y,x]),None,None] for y,x in np.ndindex(h,w)])
        cases.append(case)
with tempfile.TemporaryDirectory(prefix='imagery-region-program-') as temp:
    for i,case in enumerate(cases):case['disk_path']=str(Path(temp)/f'labels-{i}')
    path=Path(temp)/'input.json';path.write_text(json.dumps(cases,allow_nan=False))
    output=json.loads(subprocess.check_output([args.consumer,str(path)],text=True))
    maximum=0.;pixels=0;adapter_error=0.
    for index,(case,actual) in enumerate(zip(cases,output)):
        h,w=case['height'],case['width'];pixels+=h*w
        colors=np.array(actual['observed_colors']).reshape(h,w,3)
        if case.get('rgb'):
            # Independent bulk CSS Color 4 rational RGB->XYZ, Bradford D50 and
            # CIE Lab transform; math stays in color-d in production.
            rgb=np.array([s[2:5] for s in case['samples']]).reshape(h,w,3)/255
            linear=np.where(rgb<=.04045,rgb/12.92,((rgb+.055)/1.055)**2.4)
            xyz=linear@np.array([[506752/1228815,87881/245763,12673/70218],
                                 [87098/409605,175762/245763,12673/175545],
                                 [7918/409605,87881/737289,1001167/1053270]]).T
            d50=xyz@np.array([[1.0479297925449969,.022946870601609652,-.05019226628920524],
                              [.02962780877005599,.9904344267538799,-.017073799063418826],
                              [-.009243040646204504,.015055191490298152,.7518742814281371]]).T
            t=d50/np.array([.3457/.3585,1.,(1-.3457-.3585)/.3585])
            f=np.where(t>(6/29)**3,np.cbrt(t),((29/3)**3*t+16)/116)
            lab=np.stack([116*f[:,:,1]-16,500*(f[:,:,0]-f[:,:,1]),200*(f[:,:,1]-f[:,:,2])],axis=-1)
            np.testing.assert_allclose(colors,lab,rtol=0,atol=5e-13)
            adapter_error=max(adapter_error,float(np.max(abs(colors-lab))))
        if case['program']=='slic':
            expected,centers,rounds=slic_reference(case,colors,actual)
            try:np.testing.assert_array_equal(np.array(actual['labels']).reshape(h,w),expected)
            except AssertionError:
                print('SLIC case',index,{k:case[k] for k in ('spacing','compactness','iterations','perturb','minimum_size','block','disk')});raise
            np.testing.assert_array_equal(actual['crop_labels'],expected[1:6,1:8].ravel())
            assert actual['centers']==centers and actual['cleanup_rounds']==rounds
            maximum=max(maximum,check_graph(actual['graph'],expected,case,colors))
            assert actual['comparisons'] <= case['iterations']*h*w*max(centers,1)
        else:
            labels=np.array(case['labels']).reshape(h,w)
            for stage,snapshot in enumerate(actual['snapshots']):
                if stage:labels=merge_labels(labels,case['merges'][stage-1])
                maximum=max(maximum,check_graph(snapshot,labels,case,colors))
                mapping=dict(snapshot['map']);original=np.array(case['labels']).reshape(h,w)
                mapped=np.array([mapping.get(int(i),0) for i in original.ravel()]).reshape(h,w)
                np.testing.assert_array_equal(labels,mapped)
                assert snapshot['generation']==stage
    for start in range(5,41,6):
        for offset in range(1,6):
            for field in ('labels','graph'):
                assert output[start][field]==output[start+offset][field]
    print(f"Region program: {len(cases)} cases / {pixels} pixels; exact SLIC labels/partitions/backings, "
          f"graph/merge/lineage references; max statistic error={maximum:.9g}")
    print('SLIC work maximum:',max(o['work_bytes'] for c,o in zip(cases,output) if c['program']=='slic'))
    print('RGB Lab maximum error:',adapter_error,'; assignment fallback pixels:',sum(o.get('fallbacks',0) for o in output))
    if args.scene:
        for start in (len(cases)-6,len(cases)-3):
            for field in ('labels','graph','crop_labels'):
                for offset in (1,2):assert output[start][field]==output[start+offset][field]
        for case,result in zip(cases[-6:],output[-6:]):
            keys=('elapsed_ns','gc_bytes','work_bytes','centers','comparisons','fallbacks','cleanup_rounds') if case['program']=='slic' else ('build_ns','merge_ns','work_bytes')
            print(json.dumps({k:result[k] for k in keys}|
                              {'block':case['block'],'disk':case['disk'],'regions':len(result['graph']['regions'])}))
    if args.benchmark:
        assert args.scene,'--benchmark needs --scene'
        family=[cases[-6],cases[-4],cases[-3],cases[-1]]
        timed_cases=[]
        for round_number in range(6):
            timed_cases.extend(family if round_number%2==0 else family[::-1])
        path.write_text(json.dumps(timed_cases,allow_nan=False))
        timed=json.loads(subprocess.check_output([args.consumer,str(path)],text=True))
        for i,(case,result) in enumerate(zip(timed_cases,timed)):
            # Preflight already checked this exact source/domain/policy. Keep
            # reference checks outside native timing in the repeated series too.
            expected=output[cases.index(case)]
            for field in ('labels','graph','crop_labels'):assert result[field]==expected[field]
            keys=('elapsed_ns','gc_bytes','work_bytes','comparisons','fallbacks','cleanup_rounds') if case['program']=='slic' else ('build_ns','merge_ns','work_bytes')
            print(json.dumps({'round':i//4,'warmup':i<4,'program':case['program'],'disk':case['disk'],
                              **{key:result[key] for key in keys}},sort_keys=True))
