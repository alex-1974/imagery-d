"""Paired ABBA evidence on a noisy host; rejected observations remain in receipts.

Bootstrap units are whole ABBA cycles, never individual correlated timings.
No control normalization or timing-based outlier deletion is performed.
"""
import math
import random
import os
from pathlib import Path
import time
from statistics import median


def mad(values):
    center=median(values)
    return median(abs(x-center) for x in values)


def distribution(values,minimum=15,seed=212,draws=4000):
    if not values or any(not math.isfinite(x) or x<=0 for x in values):
        raise ValueError('Positive finite measurements required')
    result=dict(median=median(values),mad=mad(values),samples=len(values))
    if len(values)>=minimum:
        rng=random.Random(seed)
        boot=sorted(median(rng.choices(values,k=len(values))) for _ in range(draws))
        result['bootstrap_95']=[boot[int(.025*draws)],boot[min(draws-1,int(.975*draws))]]
    return result


def cpu_ticks(text):
    result={}
    for line in text.splitlines():
        fields=line.split()
        if fields and fields[0].startswith('cpu') and fields[0][3:].isdigit():
            values=list(map(int,fields[1:]))
            # guest ticks are already contained in user/nice; do not count twice.
            result[int(fields[0][3:])]=(sum(values[:8]),values[3]+values[4])
    return result


def cpu_list(text):
    result=set()
    for part in text.split(','):
        ends=part.split('-')
        result.update(range(int(ends[0]),int(ends[-1])+1))
    return result


def select_cpu(requested='auto'):
    allowed=os.sched_getaffinity(0)
    if str(requested)!='auto':
        cpu=int(requested)
        if cpu not in allowed:raise ValueError('Requested CPU outside affinity')
        return cpu,dict(method='explicit')
    first=cpu_ticks(Path('/proc/stat').read_text());time.sleep(.5)
    last=cpu_ticks(Path('/proc/stat').read_text());scores=[]
    for cpu in allowed:
        family=cpu_list(Path(f'/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list').read_text())
        if cpu!=min(family&allowed):continue
        siblings=family-{cpu}
        busy=sum((last[s][0]-first[s][0])-(last[s][1]-first[s][1]) for s in siblings)
        own=(last[cpu][0]-first[cpu][0])-(last[cpu][1]-first[cpu][1])
        scores.append((busy,own,cpu))
    cpu=min(scores)[2]
    return cpu,dict(method='least observed SMT sibling activity over 0.5 seconds',scores=scores)


def hygiene(row, max_load=6., max_frequency_change=.05, max_sibling_busy_fraction=.05):
    before,after=row['before'],row['after']
    reasons=[]
    if before['cpu']!=after['cpu']: reasons.append('CPU migration')
    try:
        a,b=float(before['frequency_khz']),float(after['frequency_khz'])
        if min(a,b)<=0 or max(a,b)/min(a,b)-1>max_frequency_change:
            reasons.append('frequency changed > limit')
    except (KeyError,ValueError): reasons.append('frequency unavailable')
    try:
        if max(float(x['loadavg'].split()[0]) for x in (before,after))>max_load:
            reasons.append('load above limit')
    except (KeyError,ValueError,IndexError): reasons.append('load unavailable')
    if not before.get('governor') or before.get('governor')!=after.get('governor'):
        reasons.append('governor unavailable/changed')
    if before.get('power')!=after.get('power'): reasons.append('power state changed')
    activity={}
    try:
        siblings=cpu_list(before['siblings'])-{before['cpu']}
        first,last=cpu_ticks(before['cpu_ticks']),cpu_ticks(after['cpu_ticks'])
        for cpu in siblings:
            total=last[cpu][0]-first[cpu][0]; idle=last[cpu][1]-first[cpu][1]
            busy=total-idle
            activity[cpu]=dict(total_ticks=total,busy_ticks=busy,busy_fraction=busy/total if total>0 else None)
            if total<=0: reasons.append('SMT sibling idle state unresolved at tick resolution')
            elif busy<0 or busy>total:reasons.append('SMT accounting discontinuity')
            elif busy/total>max_sibling_busy_fraction: reasons.append('SMT sibling activity above limit')
    except (KeyError,ValueError): reasons.append('SMT topology/activity unavailable')
    return dict(accepted=not reasons,reasons=reasons,sibling_activity=activity)


def summarize(groups, minimum=15, minimum_effect=.10, target=None, seed=212, draws=4000,require_equal_outputs=True):
    accepted=[]; rejected=[]
    for group in groups:
        if len(group)!=4 or [r['position'] for r in group]!=[0,1,2,3]:
            raise ValueError('A complete ordered ABBA cycle is required')
        if not (group[0]['mode']==group[3]['mode'] and group[1]['mode']==group[2]['mode']):
            raise ValueError('Invalid ABBA order')
        if require_equal_outputs and len({r['digest'] for r in group})!=1:
            raise ValueError('Full output differs inside paired cycle')
        for r in group:
            if not math.isfinite(r['ns_per_pixel']) or r['ns_per_pixel']<=0:
                raise ValueError('Nonpositive/nonfinite observation')
        if all(r['hygiene']['accepted'] for r in group): accepted.append(group)
        else: rejected.append(group)
    result=dict(accepted_cycles=len(accepted),rejected_cycles=len(rejected),minimum_cycles=minimum,
                classification='noisy',effect='inconclusive',target_status='pending',minimum_effect=minimum_effect)
    if not accepted: return result
    # Both A and B occupy symmetric positions in each cycle. Keep the pairing.
    a=[math.sqrt(g[0]['ns_per_pixel']*g[3]['ns_per_pixel']) for g in accepted]
    b=[math.sqrt(g[1]['ns_per_pixel']*g[2]['ns_per_pixel']) for g in accepted]
    ratios=[x/y for x,y in zip(a,b)]
    result.update(a_median=median(a),a_mad=mad(a),b_median=median(b),b_mad=mad(b),
                  ratio=median(ratios),ratio_mad=mad(ratios),paired_ratios=ratios,
                  control_ratios=[median([r['control_after_ns']/r['control_before_ns'] for r in g]) for g in accepted])
    if len(accepted)<minimum: return result
    rng=random.Random(seed)
    boot=sorted(median(rng.choices(ratios,k=len(ratios))) for _ in range(draws))
    lo,hi=boot[int(.025*draws)],boot[min(draws-1,int(.975*draws))]
    result['bootstrap_95']=[lo,hi]
    if hi<1 and result['ratio']<=1-minimum_effect:
        result.update(classification='conclusive',effect='improvement')
    elif lo>1 and result['ratio']>=1+minimum_effect:
        result.update(classification='conclusive',effect='regression')
    if target is not None:
        if not math.isfinite(target) or target<=0: raise ValueError('Invalid fixed target')
        result['target']=target
        if hi<=target: result['target_status']='pass'
        elif lo>target and result['ratio']>=target*(1+minimum_effect): result['target_status']='fail'
        # Inconclusive evidence is never a passing manual admission gate.
    return result


def raw_diagnostic(groups,require_equal_outputs=True):
    """Describe all complete pairs without turning hygiene failures into admission.

    The original flags are untouched. These intervals describe recorded host
    conditions, including load/frequency changes; they certify no idle target.
    """
    copies=[[dict(row,hygiene=dict(accepted=True)) for row in group] for group in groups]
    summary=summarize(copies,require_equal_outputs=require_equal_outputs)
    effect=summary.pop('effect')
    summary.pop('accepted_cycles');summary.pop('rejected_cycles')
    summary.pop('target_status');summary.pop('classification')
    summary.update(raw_cycles=len(groups),classification='descriptive only',observed_effect=effect,
        admission='not admitted',hygiene_qualified_cycles=sum(all(r['hygiene']['accepted'] for r in g) for g in groups))
    return summary
