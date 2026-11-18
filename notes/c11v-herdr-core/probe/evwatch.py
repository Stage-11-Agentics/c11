import sys,json,time,os
X=os.environ['X']
exec(open(X+'/hcx.py').read().split('cmd = sys.argv[1]')[0])
secs=float(sys.argv[1])
c=Conn(framed=False); r=c.call_plain('events.subscribe',{}); print('events snapshot seq', r['result'].get('seq'), 'terminals', len(r['result'].get('terminals',[])), flush=True)
t0=time.time(); c.s.settimeout(1.0)
while time.time()-t0 < secs:
    if b"\n" not in c.buf:
        try: d=c.s.recv(65536)
        except Exception: d=b""
        if d: c.buf+=d
        if b"\n" not in c.buf: continue
    line,c.buf=c.buf.split(b"\n",1)
    try: m=json.loads(line)
    except Exception: continue
    p=m.get('params',{})
    if m.get('method')=='heartbeat': continue
    print(f"  ev +{time.time()-t0:4.1f}s {m.get('method')} {p.get('type')} {p.get('terminal','')} {p.get('machine','')} {json.dumps(p.get('data',''))[:90]}", flush=True)
