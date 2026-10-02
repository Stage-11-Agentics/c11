import json, re, csv, glob, collections
from datetime import datetime, timezone, timedelta

import os
S = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data')
GO = datetime(2026, 10, 2, 4, 45, tzinfo=timezone.utc)   # Atin's GO, 21:45 PDT
NOW = datetime.now(timezone.utc)

def P(s):
    if not s: return None
    return datetime.fromisoformat(s.replace('Z', '+00:00'))

def H(a, b):
    return max(0.0, (b - a).total_seconds() / 3600)

lat = json.load(open(f'{S}/lattice.json'))
prs = json.load(open(f'{S}/prs.json'))
runs = []
for r in csv.reader(open(f'{S}/runs.tsv'), delimiter='\t'):
    runs.append(dict(id=r[0], name=r[1], event=r[2], branch=r[3], sha=r[4], status=r[5], concl=r[6],
                     created=P(r[7]), started=P(r[8]), updated=P(r[9]), attempt=r[10]))
runs_by_id = {r['id']: r for r in runs}
jobs = []
for r in csv.reader(open(f'{S}/jobs.tsv'), delimiter='\t'):
    if len(r) < 8: continue
    jobs.append(dict(run=r[0], name=r[1], status=r[2], concl=r[3], created=P(r[4]), started=P(r[5]),
                     completed=P(r[6]), labels=r[7]))
for j in jobs:
    j['branch'] = runs_by_id.get(j['run'], {}).get('branch')
    j['wf'] = runs_by_id.get(j['run'], {}).get('name')

runstate = open('/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/run-state.md').read()
log_lines = [l for l in runstate.splitlines() if l.startswith('- ')]

VERDICT = re.compile(r'(?:Verdict|verdict)\W{0,6}(PASS|FAIL)|\b(PASS|FAIL)\b')

def family(actor):
    a = actor or ''
    for k in ('fable', 'opus', 'grok', 'astra', 'sol', 'luna', 'codex'):
        if k in a: return k
    return a

def union(intervals):
    iv = sorted((a, b) for a, b in intervals if a and b and b > a)
    out = []
    for a, b in iv:
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out

def clip_sum(intervals, lo, hi):
    tot = 0
    for a, b in union(intervals):
        a2, b2 = max(a, lo), min(b, hi)
        if b2 > a2: tot += (b2 - a2).total_seconds()
    return tot / 3600

tickets = []
for sid, t in lat.items():
    if sid == 'C11-272': continue
    ev = sorted(t['events'], key=lambda e: e['ts'])
    st = [(P(e['ts']), e['data'].get('from'), e['data'].get('to')) for e in ev if e['type'] == 'status_changed']
    first = lambda to: next((ts for ts, f, x in st if x == to), None)
    impl = first('in_progress')
    handoff = first('review')
    done = next((ts for ts, f, x in reversed(st) if x == 'done'), None)
    inval = first('in_validation')
    blocked = []
    cur = None
    for ts, f, x in st:
        if x == 'blocked': cur = ts
        elif f == 'blocked' and cur: blocked.append((cur, ts)); cur = None
    verdicts, vals = [], []
    for e in ev:
        if e['type'] != 'comment_added' or e['data'].get('role') != 'review': continue
        body = (e['data'].get('body') or '')[:400]
        m = VERDICT.search(body)
        if not m: continue
        v = m.group(1) or m.group(2)
        rec = dict(ts=P(e['ts']), v=v, actor=e['actor'], fam=family(e['actor']))
        (vals if 'validator' in (e['actor'] or '') else verdicts).append(rec)
    num = sid.split('-')[1]
    tprs = sorted([p for p in prs if re.search(rf'C11-{num}(-|$)', p['headRefName'])], key=lambda p: p['createdAt'])
    pr = tprs[0] if tprs else None
    merged = P(pr['mergedAt']) if pr and pr.get('mergedAt') else None
    branches = {p['headRefName'] for p in tprs}

    # Segments
    segs = []
    if impl is None and handoff is None and not merged:
        pass
    else:
        t0 = impl or handoff
        created = P(ev[0]['ts'])
        ready = max(GO, created)
        if t0 and t0 > ready and t0 - ready > timedelta(minutes=5):
            segs.append(['queued', ready, t0])
        h = handoff or (verdicts[0]['ts'] if verdicts else None) or merged or (NOW if t0 else None)
        if t0 and h and h > t0:
            segs.append(['implement', t0, h])
        cursor = h
        # code-review verdicts before merge (or all, if unmerged)
        pre = [v for v in verdicts if (merged is None or v['ts'] <= merged) and cursor and v['ts'] >= cursor - timedelta(minutes=1)]
        last_fail_idx = max([i for i, v in enumerate(pre) if v['v'] == 'FAIL'], default=-1)
        final_pass = next((v for v in pre[last_fail_idx + 1:] if v['v'] == 'PASS'), None)
        phase = 'review'
        for v in pre:
            if final_pass and v['ts'] > final_pass['ts']: break
            if cursor and v['ts'] > cursor:
                segs.append([phase, cursor, v['ts']])
                cursor = v['ts']
            phase = 'repair' if v['v'] == 'FAIL' else 'review'
        land_start = final_pass['ts'] if final_pass else cursor
        if merged and land_start and merged > land_start:
            segs.append(['landing', land_start, merged])
            cursor = merged
        elif not merged and land_start and land_start < NOW:
            # still open: in review / repair / waiting
            segs.append(['repair' if phase == 'repair' else ('landing' if final_pass else 'review'), land_start, NOW])
            cursor = NOW
        if merged:
            end = done if (done and done > merged) else (None if t['status'] == 'done' else NOW)
            if end and end - merged > timedelta(minutes=3):
                segs.append(['validation', merged, end])
    segs = [s for s in segs if s[2] > s[1]]

    # CI on this ticket's branches
    tr = [r for r in runs if r['branch'] in branches and r['name'] == 'CI']
    bj = [j for j in jobs if j['branch'] in branches and j['name'] == 'build' and j['started']]
    mac = [j for j in jobs if j['branch'] in branches and 'macos' in j['labels'] and j['started']]
    land = next((s for s in segs if s[0] == 'landing'), None)
    ci_q = ci_r = 0
    if land:
        lo, hi = land[1], land[2]
        ci_q = clip_sum([(j['created'], j['started']) for j in bj], lo, hi)
        ci_r = clip_sum([(j['started'], j['completed'] or NOW) for j in bj], lo, hi)
    conflicts = sum(1 for l in log_lines if re.search(rf'C11-{num}\b', l) and re.search(r'conflict|integrat', l, re.I))
    mentions_flake = sum(1 for l in log_lines if re.search(rf'C11-{num}\b', l) and re.search(r'flake|timed out|timeout|red', l, re.I))

    tickets.append(dict(
        id=sid, title=t['title'], status=t['status'],
        ws=next((x[3:] for x in t['tags'] if x.startswith('ws:')), ''),
        tier=next((x[5:] for x in t['tags'] if x.startswith('tier:')), ''),
        pr=pr['number'] if pr else None, prs=[p['number'] for p in tprs],
        additions=sum(p['additions'] for p in tprs), deletions=sum(p['deletions'] for p in tprs),
        impl=impl, merged=merged, done=done,
        segs=segs, reviews=[dict(ts=v['ts'], v=v['v'], fam=v['fam']) for v in verdicts],
        fails=sum(1 for v in verdicts if v['v'] == 'FAIL'),
        validator=[dict(ts=v['ts'], v=v['v']) for v in vals],
        blocked_h=sum(H(a, b) for a, b in blocked),
        ci_runs=len(tr), ci_cancelled=sum(1 for r in tr if r['concl'] == 'cancelled'),
        ci_failed=sum(1 for r in tr if r['concl'] == 'failure'),
        land_ci_queue_h=ci_q, land_ci_run_h=ci_r,
        conflicts=conflicts, flake_mentions=mentions_flake,
        mac_minutes=sum(((j['completed'] or NOW) - j['started']).total_seconds() / 60 for j in mac),
    ))

# Global macOS runner occupancy, 5-min resolution, from GO-1h to NOW
start = GO - timedelta(hours=1)
steps = []
t = start
macj = [j for j in jobs if 'macos' in j['labels'] and j['created']]
while t <= NOW:
    q = {'xl': 0, 'std': 0}; r = {'xl': 0, 'std': 0}
    for j in macj:
        k = 'xl' if 'xlarge' in j['labels'] else 'std'
        s = j['started']; c = j['completed']
        if j['created'] <= t and (s is None or s > t) and (c is None or c > t) and not (s is None and j['status'] == 'completed' and c and c <= t):
            q[k] += 1
        elif s and s <= t and (c is None or c > t):
            r[k] += 1
    steps.append(dict(t=t, q_xl=q['xl'], r_xl=r['xl'], q_std=q['std'], r_std=r['std']))
    t += timedelta(minutes=5)

# build job queue waits (scatter)
bwaits = [dict(t=j['created'], wait=(j['started'] - j['created']).total_seconds() / 60, branch=j['branch'], concl=j['concl'])
          for j in jobs if j['name'] == 'build' and j['started'] and j['created'] >= start]

# merges over time
merges = sorted([P(p['mergedAt']) for p in prs if p.get('mergedAt') and P(p['mergedAt']) >= start])

wf_counts = collections.Counter((r['name'], r['concl']) for r in runs if r['created'] >= start)
mac_minutes_total = sum(((j['completed'] or NOW) - j['started']).total_seconds() / 60 for j in macj if j['started'] and j['started'] >= start)
mac_minutes_cancelled = sum(((j['completed'] or NOW) - j['started']).total_seconds() / 60 for j in macj if j['started'] and j['started'] >= start and j['concl'] == 'cancelled')

fam = collections.defaultdict(lambda: {'PASS': 0, 'FAIL': 0})
for tk in tickets:
    for v in tk['reviews']:
        fam[v['fam']][v['v']] += 1

def ser(o):
    if isinstance(o, datetime): return o.isoformat().replace('+00:00', 'Z')
    raise TypeError(o)

out = dict(go=GO, now=NOW, tickets=tickets, steps=steps, bwaits=bwaits, merges=merges,
           wf=[dict(wf=k[0], concl=k[1], n=v) for k, v in wf_counts.items()],
           mac_minutes_total=mac_minutes_total, mac_minutes_cancelled=mac_minutes_cancelled,
           reviewer_families=fam)
json.dump(out, open(f'{S}/analysis.json', 'w'), default=ser, indent=1)

# Console summary
tot = collections.Counter()
for tk in tickets:
    for s in tk['segs']: tot[s[0]] += H(s[1], s[2])
print('tickets', len(tickets), 'with segs', sum(1 for t in tickets if t['segs']))
print({k: round(v, 1) for k, v in tot.items()})
print('mac minutes', round(mac_minutes_total), 'cancelled', round(mac_minutes_cancelled))
print(dict(fam))
for tk in sorted(tickets, key=lambda t: (t['impl'] or NOW)):
    if not tk['segs']: continue
    print(tk['id'], tk['status'][:6], 'pr', tk['pr'], 'fails', tk['fails'], 'ci', tk['ci_runs'], '/', tk['ci_cancelled'], 'conf', tk['conflicts'],
          ' '.join(f"{s[0][:4]}={H(s[1], s[2]):.1f}" for s in tk['segs']), f"landQ={tk['land_ci_queue_h']:.1f} landR={tk['land_ci_run_h']:.1f}")
