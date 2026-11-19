#!/usr/bin/env python3
"""C11H-342 guest proof: groups and ungrouped workspaces share one sidebar root order.
Runs inside a sandbox guest only (scripts/sandbox-exec.sh), one phase per call:
  <script> <run-id> <phase> [args...]
Phases:
  setup                      Flagship, Alpha, Beta ungrouped; groups Fleet (Member1) and Lab (Member2).
  shot <name> [EXPECTED]     screenshot + the app's root order; passes when it equals EXPECTED, if given.
  drag <name> X1 Y1 X2 Y2 EXPECTED
                             a real HID drag (scripts/guest-xdrag.m); waits for the app's sidebar.drop line
                             and passes only when the root order equals EXPECTED.
EXPECTED is a comma-separated root order of workspace titles and group:<name> entries.
  cli-move <group> <ws>      moves the group before that workspace by CLI, then back where it was.
  quit                       waits past the 8 s autosave, then quits the app with Command-Q (twice:
                             the "Quit all of c11?" dialog takes it too).
  stop-core <app-path> <tag> stops that build's hc cores with hc's own `server stop`, so another
                             build of the same tag can start its own.
  launch <app-path>          launches that app with the run's socket, restoring the saved session.
Drag points are read off a screenshot (docs/c11-guest-drags.md); the socket judges every result.
Writes screenshots and result.json to the run's shared folder (out/proof342)."""
import json, os, subprocess, sys, time
from pathlib import Path

RUN, PHASE, ARGS = sys.argv[1], sys.argv[2], sys.argv[3:]
SOCKET = f'/tmp/c11-sandbox-{RUN}.sock'
LOG = Path(f'/tmp/c11-sandbox-{RUN}.log')
SHARE = Path('/Volumes/My Shared Files/out')
OUT = SHARE / 'proof342'
OUT.mkdir(parents=True, exist_ok=True)
RESULT = OUT / 'result.json'
XDRAG = str(SHARE / 'xdrag')
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}


def app_pids():
    rows = subprocess.check_output(['ps', '-axo', 'pid,command'], text=True).splitlines()[1:]
    return [(int(r.split(None, 1)[0]), r.split(None, 1)[1]) for r in rows
            if r.strip().endswith('.app/Contents/MacOS/c11') and ('/c11-sandbox/' in r or 'proof342-apps' in r)]


def cli_path():
    pids = app_pids()
    assert len(pids) == 1, pids
    app = pids[0][1].strip().rsplit('/Contents/MacOS/c11', 1)[0]
    return pids[0][0], os.path.join(app, 'Contents/Resources/bin/c11')


def cli(*args, check=True):
    _, path = cli_path()
    p = subprocess.run([path, '--socket', SOCKET, *args], capture_output=True, text=True, env=ENV, timeout=30)
    if check and p.returncode:
        raise RuntimeError(f'cli {args}: {p.stdout} {p.stderr}')
    return p.stdout.strip()


def groups_payload():
    return json.loads(cli('--id-format', 'both', 'workspace-group', 'list', '--json'))


def titles():
    tree = json.loads(cli('--id-format', 'both', 'tree', '--all', '--json', '--no-layout'))
    names = {}
    for w in tree['windows']:
        for ws in w['workspaces']:
            names[ws['id']] = ws.get('title')
        for g in w.get('workspace_groups', []):
            names[g['id']] = 'group:' + g['name']
    return names


def root_order():
    names = titles()
    return [names.get(item['id'], item['id']) for item in groups_payload().get('root_order', [])]


def record(case, ok, **data):
    results = json.loads(RESULT.read_text()) if RESULT.exists() else []
    results = [r for r in results if r['case'] != case]
    results.append(dict(case=case, ok=bool(ok), at=time.strftime('%H:%M:%S'), **data))
    RESULT.write_text(json.dumps(results, indent=1))
    print('PASS' if ok else 'FAIL', case, json.dumps(data)[:1500], flush=True)


def shot(name):
    # Capture locally, then copy: writing straight to the share can stall.
    local = f'/tmp/p342-{name}.png'
    subprocess.run(['screencapture', '-x', local], check=True, timeout=30)
    subprocess.run(['/bin/cp', local, str(OUT / f'{name}.png')], check=True, timeout=60)


def wait_for_drop(offset, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        with LOG.open('rb') as f:
            f.seek(offset)
            text = f.read().decode('utf-8', 'replace')
        hits = [l for l in text.splitlines() if 'sidebar.drop ' in l]
        if hits:
            time.sleep(1.0)
            return hits[0][:200]
        time.sleep(0.25)
    return None


def ws_ref(title):
    tree = json.loads(cli('--id-format', 'both', 'tree', '--all', '--json', '--no-layout'))
    for w in tree['windows']:
        for ws in w['workspaces']:
            if ws.get('title') == title:
                return ws['id']
    raise RuntimeError(f'no workspace {title}')


def group_id(name):
    return next(g['id'] for g in groups_payload()['workspace_groups'] if g['name'] == name)


if PHASE == 'setup':
    # A clone can boot with System Settings over the app: ask it to quit (never pkill).
    subprocess.run(['osascript', '-e', 'if application "System Settings" is running then '
                    'tell application "System Settings" to quit'], check=False, timeout=30)
    first = json.loads(cli('--id-format', 'both', 'tree', '--all', '--json', '--no-layout'))['windows'][0]['workspaces'][0]['id']
    cli('rename-workspace', '--workspace', first, 'Flagship')
    for title in ['Member1', 'Alpha', 'Member2', 'Beta']:
        cli('new-workspace', '--title', title)
    fleet = json.loads(cli('workspace-group', 'create', '--name', 'Fleet', '--json'))['group_id']
    lab = json.loads(cli('workspace-group', 'create', '--name', 'Lab', '--json'))['group_id']
    cli('workspace-group', 'add', '--group', fleet, '--workspaces', ws_ref('Member1'))
    cli('workspace-group', 'add', '--group', lab, '--workspaces', ws_ref('Member2'))
    time.sleep(1.5)
    order = root_order()  # empty from an app without the root order (main)
    shot('setup')
    record('setup', not order or order[:2] == ['group:Fleet', 'group:Lab'], root_order=order,
           tree=cli('tree', '--all', '--no-layout'))

elif PHASE == 'shot':
    name = ARGS[0]
    expected = ARGS[1].split(',') if len(ARGS) > 1 else None
    time.sleep(1.0)
    order = root_order()
    shot(name)
    record(name, expected is None or order == expected, root_order=order, expected=expected,
           raw=groups_payload().get('root_order'))

elif PHASE == 'drag':
    name, (x1, y1, x2, y2), expected = ARGS[0], [float(v) for v in ARGS[1:5]], ARGS[5].split(',')
    subprocess.run(['/opt/homebrew/bin/cliclick', 'ku:cmd', 'ku:alt', 'ku:shift', 'ku:ctrl'], check=False, timeout=10)
    before = root_order()
    shot(f'{name}-1-before')
    offset = LOG.stat().st_size
    proc = subprocess.Popen([XDRAG, *(str(round(v)) for v in (x1, y1, x2, y2)), '40', '1500'])
    time.sleep(1.3)
    shot(f'{name}-2-mid')
    proc.wait(timeout=30)
    drop = wait_for_drop(offset)
    after = root_order()
    shot(f'{name}-3-after')
    record(name, drop is not None and after == expected, before=before, after=after, expected=expected, drop=drop)

elif PHASE == 'cli-move':
    name, target = ARGS[0], ARGS[1]
    lab = group_id(name)
    before = root_order()
    assert before.index('group:' + name) > 0, before
    previous = before[before.index('group:' + name) - 1]
    cli('workspace-group', 'move', '--group', lab, '--before', ws_ref(target))
    moved = root_order()
    shot('cli-move-1-before-workspace')
    text = cli('workspace-group', 'list')
    # Back where it was: after the item that preceded it (a workspace or a group).
    anchor = group_id(previous[len('group:'):]) if previous.startswith('group:') else ws_ref(previous)
    cli('workspace-group', 'move', '--group', lab, '--after', anchor)
    back = root_order()
    shot('cli-move-2-back')
    ok = moved.index('group:' + name) + 1 == moved.index(target) and back == before
    record('cli-move', ok, before=before, moved=moved, list_text=text, back=back)

elif PHASE == 'quit':
    pid, _ = cli_path()
    order = root_order()
    time.sleep(10)  # past the 8 s autosave tick
    # Bring it forward with a real click on its title bar, then Command-Q. While
    # terminals run, c11 asks "Quit all of c11?"; its Quit button takes Command-Q too.
    subprocess.run([XDRAG, 'click', '700', '45'], check=False, timeout=30)
    for _ in range(2):
        subprocess.run(['/opt/homebrew/bin/cliclick', 'ku:cmd', 'ku:alt', 'ku:shift', 'ku:ctrl',
                        'kd:cmd', 't:q', 'ku:cmd'], check=False, timeout=30)
        time.sleep(2.5)
        if not any(p == pid for p, _ in app_pids()):
            break
    for _ in range(60):
        if not any(p == pid for p, _ in app_pids()):
            break
        time.sleep(0.5)
    record('quit', not any(p == pid for p, _ in app_pids()), root_order_at_quit=order)

elif PHASE == 'stop-core':
    # hc's own stop for each of the tag's core sockets: nothing found by process name.
    core, tag = os.path.join(ARGS[0], 'Contents/Helpers/herdr-core'), ARGS[1]
    run = Path(os.environ['HOME']) / '.local/share/c11/run'
    stopped = []
    for sock in sorted(run.glob(f'c11-{tag}*.sock')):
        if '.holder.' in sock.name:
            continue
        env = {'HOME': os.environ['HOME'], 'PATH': '/usr/bin:/bin', 'HC_SESSION': sock.stem, 'HC_SOCKET': str(sock)}
        p = subprocess.run([core, 'server', 'stop'], env=env, capture_output=True, text=True, timeout=60)
        stopped.append(dict(session=sock.stem, status=p.returncode, out=(p.stdout + p.stderr).strip()[:200]))
    time.sleep(2)
    record(f'stop-core:{ARGS[0]}', all(x['status'] == 0 or 'not running' in x['out'] for x in stopped), stopped=stopped)

elif PHASE == 'launch':
    app = ARGS[0]
    binary = os.path.join(app, 'Contents/MacOS/c11')
    env = {'HOME': os.environ['HOME'], 'USER': os.environ.get('USER', 'admin'),
           'LOGNAME': os.environ.get('USER', 'admin'), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',
           'TMPDIR': os.environ.get('TMPDIR', '/tmp'), 'C11_SOCKET_MODE': 'automation',
           'C11_ALLOW_SOCKET_OVERRIDE': '1', 'C11_SOCKET': SOCKET, 'C11_SOCKET_PATH': SOCKET,
           'C11_DEBUG_LOG': str(LOG), 'C11_QA_LAUNCH': 'resume'}
    subprocess.run(['sudo', '-n', 'rm', '-f', SOCKET], check=False)
    subprocess.Popen(['nohup', binary], env=env, stdout=open(f'/tmp/p342-{RUN}-app.out', 'a'),
                     stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(120):
        if os.path.exists(SOCKET):
            break
        time.sleep(0.5)
    time.sleep(4)
    order = root_order()
    shot(f'launch-{Path(app).name.replace(" ", "_")}')
    record(f'launch:{app}', bool(order), root_order=order)

else:
    raise SystemExit(f'unknown phase {PHASE}')
