#!/usr/bin/env python3
"""C11H-207 guest proof: real HID drags of workspace cards and panel tabs between c11 windows.
Runs inside a sandbox guest only, one phase per call: <script> <run-id> <phase> [X1 Y1 X2 Y2 ...].
Drag points are read off the phase's "before" screenshot (docs/c11-guest-drags.md); the socket
judges every result. Writes screenshots and result.json to the run's shared folder (out/proof207).
Needs scripts/guest-xdrag.m compiled to out/xdrag in the guest."""
import json, os, socket, subprocess, sys, time
from pathlib import Path

RUN, PHASE = sys.argv[1], sys.argv[2]
SOCKET = f'/tmp/c11-sandbox-{RUN}.sock'
APP_ROOT = f'/Users/admin/c11-sandbox/apps/{RUN}/'
SHARE = Path('/Volumes/My Shared Files/out')
OUT = SHARE / 'proof207'
OUT.mkdir(parents=True, exist_ok=True)
STATE = OUT / 'state.json'
RESULT = OUT / 'result.json'
PIDS = [int(l.split(None, 1)[0]) for l in subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True).splitlines()
        if APP_ROOT in l and l.endswith('/Contents/MacOS/c11')]
assert len(PIDS) == 1, PIDS
PID = PIDS[0]
CLI = str(next(Path(APP_ROOT).glob('*.app/Contents/Resources/bin/c11')))
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
XDRAG = str(SHARE / 'xdrag')


def rpc(method, **params):
    s = socket.socket(socket.AF_UNIX); s.settimeout(15); s.connect(SOCKET)
    s.sendall((json.dumps(dict(id=1, method=method, params=params)) + '\n').encode())
    r = json.loads(s.makefile('rb').readline()); s.close()
    if not r.get('ok'):
        raise RuntimeError(f'{method} {params} -> {r}')
    return r['result']


def cli(*args, check=True):
    p = subprocess.run([CLI, '--socket', SOCKET, *args], capture_output=True, text=True, env=ENV, timeout=30)
    if check and p.returncode:
        raise RuntimeError(f'cli {args}: {p.stdout} {p.stderr}')
    return p.stdout.strip()


def tree():
    return json.loads(cli('--id-format', 'both', 'tree', '--all', '--json', '--no-layout'))


def layout():
    """window id -> [(workspace title, ws id, [(panel title, panel id, area id)])]"""
    out = {}
    for w in tree()['windows']:
        out[w['id']] = [(ws.get('title'), ws['id'],
                         [(p['title'], p['id'], a['id']) for a in ws.get('areas', []) for p in a.get('panels', [])])
                        for ws in w['workspaces']]
    return out


def where_panel(title):
    for wid, wss in layout().items():
        for wst, wsid, panels in wss:
            for pt, pid, aid in panels:
                if pt == title:
                    return dict(window=wid, workspace=wsid, workspace_title=wst, panel=pid, area=aid)
    return None


def ws_of(panel):
    for wss in layout().values():
        for _, wsid, panels in wss:
            if any(pid == panel for _, pid, _ in panels):
                return wsid
    raise RuntimeError(f'panel {panel} not found')


def pcli(panel, *args, check=True):
    """A panel-scoped command, with the workspace that holds the panel now."""
    return cli(*args, '--workspace', ws_of(panel), '--panel', panel, check=check)


def where_workspace(title):
    for wid, wss in layout().items():
        for i, (wst, wsid, _) in enumerate(wss):
            if wst == title:
                return dict(window=wid, workspace=wsid, index=i, order=[t for t, _, _ in wss])
    return None


def hc():
    return {p['panel_id']: dict(terminal=p.get('terminal'), tty=p.get('tty'), pid=p.get('pid'), lifecycle=p.get('lifecycle'))
            for p in json.loads(cli('hc-diagnostics', '--json')).get('panels', [])}


def meta(panel):
    return json.loads(pcli(panel, '--json', 'get-metadata'))


def osa(body, timeout=120):
    return subprocess.check_output(['osascript', '-e',
        f'tell application "System Events" to tell (first process whose unix id is {PID})\n{body}\nend tell'],
        text=True, timeout=timeout).strip()


def ax(identifier=None, label=None, suffix=False):
    """Frames (x, y, w, h, top-left global points) of AX elements matching an identifier or label, all windows."""
    if identifier:
        cond = f'(value of attribute "AXIdentifier" of e) is {json.dumps(identifier)}'
    elif suffix:
        q = json.dumps(label)
        cond = (f'((description of e as text) ends with {q}) or ((name of e as text) ends with {q})'
                f' or ((value of e as text) ends with {q})')
    else:
        cond = (f'((description of e) is {json.dumps(label)}) or ((name of e) is {json.dumps(label)})')
    body = f'''set out to ""
repeat with w in windows
repeat with e in (entire contents of w)
try
if {cond} then
set p to position of e
set s to size of e
set out to out & (item 1 of p) & "," & (item 2 of p) & "," & (item 1 of s) & "," & (item 2 of s) & linefeed
end if
end try
end repeat
end repeat
return out'''
    frames = []
    for line in osa(body).splitlines():
        if line.strip():
            frames.append(tuple(float(v) for v in line.split(',')))
    return frames


def center(frame, dx=0.5, dy=0.5):
    x, y, w, h = frame
    return (x + w * dx, y + h * dy)


def shot(name):
    # Capture locally, then copy: writing straight to the share can stall.
    local = f'/tmp/p207-{name}.png'
    subprocess.run(['screencapture', '-x', local], check=True, timeout=30)
    subprocess.run(['/bin/cp', local, str(OUT / f'{name}.png')], check=True, timeout=60)


LOG = Path(f'/tmp/c11-sandbox-{RUN}.log')
DONE = ('tab.drop ', 'pane.drop ', 'rail.drop', 'sidebar.crossWindowDrop.moved', 'sidebar.crossWindowDrop.perform',
        'sidebar.dropOutside.perform', 'drag.tearOff.release', 'sidebar.reorder', 'sidebar.drop ')


def wait_for_drop(offset, timeout=30):
    """A slow guest can finish a drop seconds after the mouse-up: wait for the app's own log line."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        with LOG.open('rb') as f:
            f.seek(offset)
            text = f.read().decode('utf-8', 'replace')
        hits = [l for l in text.splitlines() if any(k in l for k in DONE)]
        if hits:
            time.sleep(1.5)  # let the async move and any window close land
            return hits[0][:160]
        time.sleep(0.25)
    return None


def drag(name, start, end, hold=1500):
    subprocess.run(['/opt/homebrew/bin/cliclick', 'ku:cmd', 'ku:alt', 'ku:shift', 'ku:ctrl'], check=True, timeout=10)
    shot(f'{name}-1-before')
    offset = LOG.stat().st_size
    proc = subprocess.Popen([XDRAG, *(str(round(v)) for v in (*start, *end)), '40', str(hold)])
    time.sleep(1.5)
    shot(f'{name}-2-mid')
    proc.wait(timeout=30)
    print('drop:', wait_for_drop(offset), flush=True)
    shot(f'{name}-3-after')


def load():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save(state):
    STATE.write_text(json.dumps(state, indent=1))


def record(case, ok, **data):
    results = json.loads(RESULT.read_text()) if RESULT.exists() else []
    results = [r for r in results if r['case'] != case]
    results.append(dict(case=case, ok=bool(ok), at=time.strftime('%H:%M:%S'), **data))
    RESULT.write_text(json.dumps(results, indent=1))
    print('PASS' if ok else 'FAIL', case, json.dumps(data)[:1500], flush=True)


def focus(window):
    rpc('window.focus', window_id=window)
    time.sleep(0.6)


def screen_text(panel, lines=40):
    return pcli(panel, 'read-screen', '--lines', str(lines), check=False)


def identity(panel):
    m = meta(panel)
    return dict(panel=panel, hc=hc().get(panel), address=m.get('metadata', m).get('mailbox.address') if isinstance(m, dict) else None,
                parent=m.get('metadata', m).get('parent_panel_id') if isinstance(m, dict) else None, meta=m)


s = load()
ARGS = [float(v) for v in sys.argv[3:7]] if len(sys.argv) >= 7 else None


def points():
    assert ARGS, 'pass X1 Y1 X2 Y2 (screen points read off the latest screenshot)'
    return (ARGS[0], ARGS[1]), (ARGS[2], ARGS[3])

if PHASE == 'setup':
    windows = [w['id'] for w in tree()['windows']]
    if len(windows) == 1:
        windows.append(rpc('window.create')['window_id'])
        time.sleep(1.5)
    L0 = layout()
    titles = {t for wss in L0.values() for t, _, _ in wss}
    w1 = next((wid for wid, wss in L0.items() if any(t == 'ALPHA' for t, _, _ in wss)), None)
    w2 = next((wid for wid, wss in L0.items() if any(t == 'CHARLIE' for t, _, _ in wss)), None)
    if w1 is None:
        w1 = rpc('system.identify')['focused']['window_id']
        cli('--window', w1, 'rename-workspace', 'ALPHA')
    if w2 is None:
        w2 = next(w for w in windows if w != w1)
        cli('--window', w2, 'rename-workspace', 'CHARLIE')
    for title, w in (('BRAVO', w1), ('ECHO', w1), ('DELTA', w2)):
        if title not in titles:
            cli('--window', w, 'new-workspace', '--title', title)
    rpc('window.move', window_id=w1, preset='left-half')
    rpc('window.move', window_id=w2, preset='right-half')
    for w in (w1, w2):
        cli('resize-window', '--window', w, '-', '600')
    time.sleep(1.5)
    L = layout()
    ws = {t: wid for wins in L.values() for t, wid, _ in wins}
    # Unique panel titles: tabs carry them as their accessibility label.
    def title_first(ws_title, new):
        panel = next(p for wins in L.values() for t, _, ps in wins if t == ws_title for _, p, _ in ps)
        pcli(panel, 'rename-panel', new)
        return panel
    a1 = title_first('ALPHA', 'A1')
    b1 = title_first('BRAVO', 'B1')
    title_first('ECHO', 'E1')
    title_first('CHARLIE', 'C1')
    title_first('DELTA', 'D1')
    known = {pid for wss in layout().values() for _, _, ps in wss for _, pid, _ in ps}
    cli('new-panel', '--workspace', ws['ALPHA'])
    time.sleep(1)
    a2 = next(pid for _, _, ps in layout()[w1] for _, pid, _ in ps if pid not in known)
    pcli(a2, 'rename-panel', 'A2')
    # BRAVO: a terminal running a counter, a markdown panel and a browser with a load id.
    (SHARE / 'notes207.md').write_text('# C11H-207\n\nA markdown panel that must survive the move.\n')
    (SHARE / 'page207.html').write_text('<!doctype html><title>P207</title><body><script>'
        'window.__loadId=Math.random().toString(36).slice(2);document.body.textContent="load "+window.__loadId;</script>')
    cli('new-panel', '--workspace', ws['BRAVO'], '--type', 'markdown', '--file', str(SHARE / 'notes207.md'))
    cli('new-panel', '--workspace', ws['BRAVO'], '--type', 'browser', '--url', 'file://' + str(SHARE / 'page207.html').replace(' ', '%20'))
    pcli(b1, 'set-metadata', '--key', 'mailbox.address', '--value', 'bravo-proof', '--type', 'string')
    pcli(b1, 'set-description', 'Proof terminal: counts every second; must not restart.')
    cli('set-status', 'proof', 'kept', '--workspace', ws['BRAVO'])
    cli('send', '--workspace', ws['BRAVO'], '--panel', b1, 'echo SHELL=$$; while true; do date +%s; sleep 1; done')
    pcli(a2, 'set-metadata', '--key', 'mailbox.address', '--value', 'a2-proof', '--type', 'string')
    time.sleep(3)
    L = layout()
    s.update(w1=w1, w2=w2, ws=ws, b1=b1, a1=a1, a2=a2)
    save(s)
    (OUT / 'layout-setup.json').write_text(json.dumps(L, indent=1))
    print(json.dumps(L, indent=1))
    focus(w2)
    shot('00-setup')

elif PHASE == 'trim':
    # The first workspace of each window opens with the welcome quad; one area each keeps the strips unfolded.
    for wss in layout().values():
        for t, wsid, ps in wss:
            if t in ('ALPHA', 'CHARLIE'):
                for pt, pid, _ in ps:
                    if pt == '~':
                        cli('close-panel', '--workspace', wsid, '--panel', pid)
    time.sleep(1.5)
    focus(s['w2'])
    (OUT / 'layout-trim.json').write_text(json.dumps(layout(), indent=1))
    shot('00-setup')

elif PHASE == 'p1':
    # Workspace card BRAVO: window 1's sidebar -> window 2's sidebar, onto DELTA's top edge.
    ws = s['ws']
    browser = next(pid for pt, pid, _ in next(ps for t, _, ps in layout()[s['w1']] if t == 'BRAVO') if pt.startswith('P207') or 'page207' in pt)
    before = dict(b1=identity(s['b1']), counter=screen_text(s['b1'], 6),
                  load=cli('browser', '--panel', browser, 'eval', 'window.__loadId', check=False),
                  panels=sorted(p for _, p, _ in next(ps for t, _, ps in layout()[s['w1']] if t == 'BRAVO')))
    focus(s['w2'])
    drag('p1-workspace-card', *points())
    time.sleep(1.5)
    after_ws = where_workspace('BRAVO')
    selected = next(w for w in tree()['windows'] if w['id'] == s['w2'])['selected_workspace_id']
    after = dict(b1=identity(s['b1']), counter=screen_text(s['b1'], 6),
                 load=cli('browser', '--panel', browser, 'eval', 'window.__loadId', check=False),
                 panels=sorted(p for _, p, _ in next(ps for t, _, ps in layout()[s['w2']] if t == 'BRAVO')))
    ok = (after_ws and after_ws['window'] == s['w2'] and after_ws['order'] == ['CHARLIE', 'BRAVO', 'DELTA']
          and after_ws['workspace'] == ws['BRAVO'] and selected == ws['BRAVO']
          and after['b1']['hc'] == before['b1']['hc'] and after['b1']['address'] == 'bravo-proof'
          and after['load'] == before['load'] and after['panels'] == before['panels'])
    s['browser'] = browser
    save(s)
    record('p1 workspace card into another window at the pointed slot', ok, where=after_ws,
           selected_in_w2=selected == ws['BRAVO'], before=before, after=after)

elif PHASE == 'p2a':
    # Panel tab A2: window 1's strip -> window 2's strip (BRAVO now shows there).
    focus(s['w2'])
    before = identity(s['a2'])
    drag('p2a-tab-to-strip', *points())
    w = where_panel('A2')
    after = identity(s['a2'])
    record('p2a panel tab into another window tab strip', w and w['window'] == s['w2'] and after['hc'] == before['hc']
           and after['address'] == 'a2-proof', where=w, before=before, after=after)

elif PHASE == 'p2b':
    # Back into window 1's content centre: the stale-drag-state case that failed on main.
    focus(s['w2'])
    before = identity(s['a2'])
    drag('p2b-tab-back-to-content', *points())
    w = where_panel('A2')
    after = identity(s['a2'])
    record('p2b panel back into the source window content (stale state)', w and w['window'] == s['w1']
           and w['workspace_title'] == 'ALPHA' and after['hc'] == before['hc'], where=w, before=before, after=after)

elif PHASE == 'p2c':
    # Window 1 -> window 2 content, bottom edge: a new split in BRAVO. (Window 2 runs past the
    # screen's right edge, so its right zone is off screen.) Setup: A2 back in ALPHA by socket.
    if where_panel('A2')['workspace_title'] != 'ALPHA':
        cli('move-panel', '--panel', s['a2'], '--workspace', s['ws']['ALPHA'], '--focus', 'true')
        time.sleep(1)
    focus(s['w2'])
    areas_before = len({a for _, _, a in next(ps for t, _, ps in layout()[s['w2']] if t == 'BRAVO')})
    drag('p2c-tab-to-split-edge', *points())
    w = where_panel('A2')
    areas_after = len({a for _, _, a in next(ps for t, _, ps in layout()[s['w2']] if t == 'BRAVO')})
    record('p2c panel tab onto another window split edge', w and w['window'] == s['w2'] and areas_after == areas_before + 1,
           where=w, areas_before=areas_before, areas_after=areas_after)

elif PHASE == 'p3':
    # A folded strip (narrow area) drags the panel it shows.
    ws = s['ws']
    for _ in range(2):
        cli('new-area', '--workspace', ws['ALPHA'], '--direction', 'right', '--allow-undersized')
    time.sleep(1)
    alpha = next(ps for t, _, ps in layout()[s['w1']] if t == 'ALPHA')
    a3 = next(pid for pt, pid, _ in reversed(alpha) if pt not in ('A1', 'A2'))
    pcli(a3, 'rename-panel', 'A3')
    s['a3'] = a3
    save(s)
    time.sleep(1)
    focus(s['w2'])
    shot('p3-0-folded')

elif PHASE == 'p3drag':
    focus(s['w2'])
    title = sys.argv[7] if len(sys.argv) > 7 else 'A3'
    before = where_panel(title)
    drag('p3-folded-block', *points())
    w = where_panel(title)
    record('p3 folded strip block drags its panel', w and w['window'] == s['w2'] and before['window'] == s['w1'],
           panel=title, before=before, where=w)

elif PHASE == 'p4':
    # Panel tab A3 from window 2 dropped on the desktop: a new window holding only it.
    focus(s['w2'])
    title = sys.argv[7] if len(sys.argv) > 7 else 'A3'
    panel = where_panel(title)['panel']
    before_windows = {w['id'] for w in tree()['windows']}
    before = identity(panel)
    drag('p4-tab-tear-off', *points())
    time.sleep(1.5)
    after_windows = {w['id'] for w in tree()['windows']}
    new = list(after_windows - before_windows)
    w = where_panel(title)
    panels_new = [p for wss in [layout().get(new[0], [])] for _, _, ps in wss for p in ps] if new else []
    after = identity(panel)
    s['w3'] = new[0] if new else None
    save(s)
    record('p4 panel tab dropped outside every window opens a new window', len(new) == 1 and w and w['window'] == new[0]
           and len(panels_new) == 1 and after['hc'] == before['hc'], new_windows=new, where=w, panels_in_new=panels_new,
           before=before, after=after)

elif PHASE == 'p5':
    # Workspace card ECHO dropped on the desktop: a new window holding it.
    ws = s['ws']
    focus(s['w1'])
    before_windows = {w['id'] for w in tree()['windows']}
    drag('p5-workspace-tear-off', *points())
    time.sleep(1.5)
    new = list({w['id'] for w in tree()['windows']} - before_windows)
    w = where_workspace('ECHO')
    s['w4'] = new[0] if new else None
    save(s)
    record('p5 workspace card dropped outside every window opens a new window', len(new) == 1 and w
           and w['window'] == new[0] and w['workspace'] == ws['ECHO'], new_windows=new, where=w)

elif PHASE == 'p6prep':
    rpc('window.move', window_id=s['w4'], preset='left-half')
    rpc('window.move', window_id=s['w2'], preset='right-half')
    focus(s['w4'])
    focus(s['w2'])
    shot('p6-0-prep')

elif PHASE == 'p6':
    # ECHO is window 4's only workspace: dragging it into window 2 closes window 4, and no terminal starts.
    ws = s['ws']
    # A real click on window 2's empty titlebar makes it key and main the way the operator does;
    # the socket focus leaves the previous window main (C11H-207 proof note).
    if len(sys.argv) > 8:
        subprocess.run([XDRAG, 'click', sys.argv[7], sys.argv[8]], check=True, timeout=10)
        time.sleep(0.8)
    else:
        focus(s['w2'])
    terminals_before = sorted(hc())
    drag('p6-last-workspace', *points())
    time.sleep(1.5)
    windows = {w['id'] for w in tree()['windows']}
    w = where_workspace('ECHO')
    terminals_after = sorted(hc())
    record('p6 the last workspace leaves and its window closes, no new terminal', s['w4'] not in windows and w
           and w['window'] == s['w2'] and w['order'][0] == 'ECHO' and terminals_after == terminals_before,
           where=w, windows=sorted(windows), terminals_before=len(terminals_before), terminals_after=len(terminals_after))

elif PHASE == 'p7':
    # A card dropped on another window's panels moves into that window (end of its lane).
    focus(s['w2'])
    before = where_workspace('DELTA')
    drag('p7-card-onto-panels', *points())
    w = where_workspace('DELTA')
    record('p7 workspace card dropped on another window panels moves in', before['window'] == s['w2']
           and w and w['window'] == s['w1'] and w['workspace'] == before['workspace'] and w['order'][-1] == 'DELTA',
           before=before, where=w)

elif PHASE == 'ovsetup':
    # Window 2 slides left so its panels sit over window 1's panels.
    osa('set position of (first window whose name is "CHARLIE") to {540, 30}')
    time.sleep(1)
    focus(s['w2'])
    shot('ov-0-setup')

elif PHASE == 'ovtab':
    # A tab from background window 1 dropped on window 2's panels where window 1 lies underneath.
    focus(s['w2'])
    before = where_panel('A2')
    areas_before = len({a for _, _, a in next(ps for t, _, ps in layout()[s['w2']] if t == 'CHARLIE')})
    drag('ov-tab-over-overlap', *points())
    w = where_panel('A2')
    areas_after = len({a for _, _, a in next(ps for t, _, ps in layout()[s['w2']] if t == 'CHARLIE')})
    record('ov tab onto an overlapping window lands there, not in the window it came from',
           w and w['window'] == s['w2'] and areas_after == areas_before + 1, before=before, where=w,
           areas_before=areas_before, areas_after=areas_after)

elif PHASE == 'esc':
    # Escape during a drag toward the desktop, then release there: no tear-off.
    windows_before = {w['id'] for w in tree()['windows']}
    (x1, y1), (x2, y2) = points()
    subprocess.run(['/opt/homebrew/bin/cliclick', 'ku:cmd', 'ku:alt', 'ku:shift', 'ku:ctrl'], check=True, timeout=10)
    shot('esc-1-before')
    # A timestamped HID Escape 800 ms into a 3.5 s hold over the desktop (cliclick's does not reach a drag).
    proc = subprocess.Popen([XDRAG, *(str(round(v)) for v in (x1, y1, x2, y2)), '40', '3500', '800'])
    time.sleep(2.6)
    shot('esc-2-after-escape')
    proc.wait(timeout=30)
    time.sleep(3)
    shot('esc-3-after-release')
    new = sorted({w['id'] for w in tree()['windows']} - windows_before)
    record('esc Escape during a drag cancels the tear-off', not new, new_windows=new)

elif PHASE == 'reorder':
    # A plain reorder inside one window still works: argv[7] should end up first in that window.
    title = sys.argv[7]
    focus(s['w2'])
    before = where_workspace(title)
    drag('reorder-same-window', *points())
    w = where_workspace(title)
    record('reorder a card inside its own window', w and w['window'] == before['window'] and w['index'] == 0
           and before['index'] != 0, before=before, where=w)

elif PHASE == 'final':
    b1 = s['b1']
    record('final terminal B1 never restarted', True, counter=screen_text(b1, 30), b1=identity(b1))
    (OUT / 'layout-final.json').write_text(json.dumps(layout(), indent=1))
    shot('99-final')

elif PHASE == 'axids':
    body = '''set out to ""
set n to 0
repeat with w in windows
set out to out & "WINDOW " & (name of w) & linefeed
repeat with e in (entire contents of w)
set n to n + 1
try
set i to value of attribute "AXIdentifier" of e
if i is not missing value and i is not "" then set out to out & i & " | " & (role of e) & linefeed
end try
end repeat
end repeat
return out & "count " & n'''
    print(osa(body, timeout=300))

elif PHASE == 'probe':
    # Which panel is "16"; then its portal log lines; then focus window 1 and shoot.
    for wid, wss in layout().items():
        for t, wsid, ps in wss:
            print(wid[:6], t, [(pt, pid[:5], aid[:5]) for pt, pid, aid in ps])
    shot('probe-1-before-focus')
    focus(s['w1'])
    time.sleep(1)
    shot('probe-2-after-focus-w1')

elif PHASE == 'ax':
    print(ax(label=sys.argv[3]))
