#!/usr/bin/env python3
"""C11H-349 guest proof: an operator's jump lands on the display the operator is on.
Runs inside a sandbox guest only, one phase per call: <script> <run-id> <phase> [args].
  setup                  second display (create-virtual-display), window 2 moved onto it, a flag
                         raised on its panel, window 1 key on the main display
  notification           the pointer on the main display, then the operator's notification open
                         (debug.notification.open runs openNotification as a banner click does)
  park                   window 2 back on the second display, window 1 key again
  click X Y              a real, timestamped HID click (e.g. the sidebar's Flagged button)
  closed                 window 2's flagged panel closed, then the same open: a notice, no move
  shot NAME              screenshots of every display
Writes screenshots and results to the run's shared folder (out/proof349). Needs
scripts/create-virtual-display.m compiled to out/vd and scripts/guest-xdrag.m to out/xdrag."""
import json, os, socket, subprocess, sys, time
from pathlib import Path

RUN, PHASE = sys.argv[1], sys.argv[2]
SOCKET = f'/tmp/c11-sandbox-{RUN}.sock'
APP_ROOT = f'/Users/admin/c11-sandbox/apps/{RUN}/'
SHARE = Path('/Volumes/My Shared Files/out')
OUT = SHARE / 'proof349'
OUT.mkdir(parents=True, exist_ok=True)
STATE = OUT / 'state.json'
CLI = str(next(Path(APP_ROOT).glob('*.app/Contents/Resources/bin/c11')))
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
LOG = Path.home() / 'Library/Logs/c11/hc-diagnostics.log'


def rpc(method, **params):
    s = socket.socket(socket.AF_UNIX); s.settimeout(15); s.connect(SOCKET)
    s.sendall((json.dumps(dict(id=1, method=method, params=params)) + '\n').encode())
    r = json.loads(s.makefile('rb').readline()); s.close()
    if not r.get('ok'):
        raise RuntimeError(f'{method} {params} -> {r}')
    return r['result']


def cli(*args, check=True, env=None):
    p = subprocess.run([CLI, '--socket', SOCKET, *args], capture_output=True, text=True,
                       env={**ENV, **(env or {})}, timeout=30)
    if check and p.returncode:
        raise RuntimeError(f'cli {args}: {p.stdout} {p.stderr}')
    return p.stdout.strip()


def windows():
    return json.loads(cli('--id-format', 'both', 'list-windows', '--json'))


def displays():
    return json.loads(cli('--id-format', 'both', 'display', 'list', '--json'))


def window(wid):
    return next(w for w in windows() if w['id'] == wid)


def shot(name):
    files = []
    for i in range(1, len(displays_list()) + 1):
        tmp = f'/tmp/p349-{name}-{i}.png'
        files.append(tmp)
    subprocess.run(['screencapture', '-x', *files], check=True, timeout=30)
    for i, tmp in enumerate(files, 1):
        subprocess.run(['cp', tmp, str(OUT / f'{name}-display{i}.png')], check=True)


def displays_list():
    d = displays()
    return d['displays'] if isinstance(d, dict) else d


def summary(wid):
    w = window(wid)
    return {k: w.get(k) for k in ('ref', 'frame', 'display', 'state', 'visible_fraction')}


def jump_lines(after):
    if not LOG.exists():
        return []
    return [l.strip() for l in LOG.read_text().splitlines() if 'event=operator_jump' in l][after:]


def jump_count():
    return len(jump_lines(0))


def panel_focused(panel_id):
    tree = json.loads(cli('--id-format', 'both', 'tree', '--all', '--json', '--no-layout'))
    for w in tree['windows']:
        for ws in w['workspaces']:
            for a in ws.get('areas', []):
                for p in a.get('panels', []):
                    if p['id'] == panel_id:
                        return dict(window_key=w.get('key'), workspace_selected=ws.get('selected'),
                                    panel_focused=p.get('focused'))
    return None


def point_in(display, fx=0.5, fy=0.5):
    f = display['frame']
    return int(f['x'] + f['width'] * fx), int(f['y'] + f['height'] * fy)


def write(name, payload):
    (OUT / f'{name}.json').write_text(json.dumps(payload, indent=2))
    print(json.dumps(payload, indent=2))


def wait_for(predicate, seconds=10):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return predicate()


if PHASE == 'setup':
    if len(displays_list()) < 2:
        subprocess.Popen([str(SHARE / 'vd'), '--modes', '1440x900', '--ready-path', '/tmp/p349-vd.ready'],
                         stdout=open('/tmp/p349-vd.log', 'w'), stderr=subprocess.STDOUT, start_new_session=True)
        wait_for(lambda: len(displays_list()) >= 2, 15)
    ds = displays_list()
    assert len(ds) >= 2, ds
    main = next(d for d in ds if d.get('main'))
    other = next(d for d in ds if not d.get('main'))
    before = [w['id'] for w in windows()]
    w1 = before[0]
    if len(before) < 2:
        rpc('window.create')
        wait_for(lambda: len(windows()) >= 2, 15)
    w2 = next(w['id'] for w in windows() if w['id'] != w1)
    time.sleep(2)
    tree = json.loads(cli('--id-format', 'both', 'tree', '--all', '--json', '--no-layout'))
    win2 = next(w for w in tree['windows'] if w['id'] == w2)
    ws2 = win2['workspaces'][0]
    panel2 = ws2['areas'][0]['panels'][0]
    cli('window', 'move', '--window', w1, '--display', main['ref'], '--fill')
    cli('window', 'move', '--window', w2, '--display', other['ref'])
    # Raised as the agent in that panel would raise it.
    cli('raise-flag', '--panel', panel2['id'], 'C11H-349 proof: this panel lives in window 2',
        env={'C11_PANEL_ID': panel2['id'], 'C11_WORKSPACE_ID': ws2['id']})
    # The operator works in window 1 on the main display.
    x, y = point_in(main, 0.6, 0.5)
    subprocess.run([str(SHARE / 'xdrag'), 'click', str(x), str(y)], check=True)
    time.sleep(1)
    state = dict(w1=w1, w2=w2, ws2=ws2['id'], panel2=panel2['id'], main=main, other=other)
    STATE.write_text(json.dumps(state, indent=2))
    shot('setup')
    write('setup', dict(state=state, w1=summary(w1), w2=summary(w2)))

elif PHASE == 'notification':
    st = json.loads(STATE.read_text())
    before_lines = jump_count()
    x, y = point_in(st['main'], 0.85, 0.1)  # where a banner would be
    subprocess.run(['cliclick', f'm:{x},{y}'], check=True)
    before = summary(st['w2'])
    t0 = time.time()
    result = rpc('debug.notification.open', workspace_id=st['ws2'], surface_id=st['panel2'])
    after = wait_for(lambda: (s := summary(st['w2']))['display']['ref'] == st['main']['ref'] and s['state']['key'] and s, 5)
    elapsed = round(time.time() - t0, 2)
    time.sleep(0.5)
    shot('notification')
    write('notification', dict(result=result, before=before, after=summary(st['w2']), landed=bool(after),
                               elapsed_s=elapsed, w1=summary(st['w1']), log=jump_lines(before_lines),
                               panel_focused=panel_focused(st['panel2'])))

elif PHASE == 'park':
    st = json.loads(STATE.read_text())
    cli('window', 'move', '--window', st['w2'], '--display', st['other']['ref'])
    x, y = point_in(st['main'], 0.6, 0.5)
    subprocess.run([str(SHARE / 'xdrag'), 'click', str(x), str(y)], check=True)
    time.sleep(1)
    shot('park')
    write('park', dict(w1=summary(st['w1']), w2=summary(st['w2'])))

elif PHASE == 'click':
    st = json.loads(STATE.read_text())
    before_lines = jump_count()
    before = summary(st['w2'])
    subprocess.run([str(SHARE / 'xdrag'), 'click', sys.argv[3], sys.argv[4]], check=True)
    after = wait_for(lambda: (s := summary(st['w2']))['display']['ref'] == st['main']['ref'] and s['state']['key'] and s, 5)
    time.sleep(0.5)
    shot('click')
    write('click', dict(before=before, after=summary(st['w2']), landed=bool(after),
                        w1=summary(st['w1']), log=jump_lines(before_lines),
                        panel_focused=panel_focused(st['panel2'])))

elif PHASE == 'closed':
    st = json.loads(STATE.read_text())
    cli('window', 'move', '--window', st['w2'], '--display', st['other']['ref'])
    # A second panel keeps the workspace open; the flagged one closes.
    cli('new-panel', '--workspace', st['ws2'])
    time.sleep(1)
    cli('close-panel', '--panel', st['panel2'])
    time.sleep(1)
    x, y = point_in(st['main'], 0.6, 0.5)
    subprocess.run([str(SHARE / 'xdrag'), 'click', str(x), str(y)], check=True)
    time.sleep(0.5)
    before_lines = jump_count()
    before = summary(st['w2'])
    result = rpc('debug.notification.open', workspace_id=st['ws2'], surface_id=st['panel2'])
    time.sleep(0.6)
    shot('closed')
    write('closed', dict(result=result, before=before, after=summary(st['w2']), log=jump_lines(before_lines)))

elif PHASE == 'shot':
    shot(sys.argv[3])
    print('ok')

else:
    sys.exit(f'unknown phase {PHASE}')
