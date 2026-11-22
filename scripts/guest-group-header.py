#!/usr/bin/env python3
"""C11H-410 guest proof: a workspace group's header gives its name the width at the
narrowest sidebar, in every bundled theme, light and dark. Runs inside a sandbox guest
only, one phase per call:
    <script> <run-id> setup|narrow|sweep <tag> <scale>|still|hover|menu|density <mode>|single <tag>|scale <preset>
Needs scripts/guest-ax.m compiled to out/ax in the guest. The socket and the AX frames
judge each step; screenshots and result.json land in the run's shared folder
(out/proof410)."""
import json, os, subprocess, sys, time
from pathlib import Path

RUN, PHASE = sys.argv[1], sys.argv[2]
ARGS = sys.argv[3:]
SOCKET = f'/tmp/c11-sandbox-{RUN}.sock'
APP_ROOT = f'/Users/admin/c11-sandbox/apps/{RUN}/'
SHARE = Path('/Volumes/My Shared Files/out')
OUT = SHARE / 'proof410'
OUT.mkdir(parents=True, exist_ok=True)
STATE = OUT / 'state.json'
RESULT = OUT / 'result.json'
APP = next(Path(APP_ROOT).glob('*.app'))
CLI = str(APP / 'Contents/Resources/bin/c11')
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
ENV['TZ'] = 'America/Los_Angeles'
os.environ['TZ'] = 'America/Los_Angeles'
time.tzset()
AX = str(SHARE / 'ax')
CLICLICK = '/opt/homebrew/bin/cliclick'
THEMES = ['stage11', 'c11', 'nocturne', 'bigboard', 'outrun-horizon', 'terminal-grid', 'datasheet-mono']
SCALE = {'standard': 1.0, 'large': 1.25, 'extraLarge': 1.55}


def model_check():
    model = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip()
    if not model.startswith('VirtualMac'):
        raise SystemExit(f'refusing: not a guest ({model})')


def pid():
    pids = [int(l.split(None, 1)[0]) for l in subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True).splitlines()
            if APP_ROOT in l and l.endswith('/Contents/MacOS/c11')]
    assert len(pids) <= 1, pids
    return pids[0] if pids else None


def cli(*args, check=True, panel=None):
    # A flag is raised by its own panel: the CLI reads the raiser from C11_PANEL_ID.
    env = dict(ENV, C11_PANEL_ID=panel) if panel else ENV
    p = subprocess.run([CLI, '--socket', SOCKET, *args], capture_output=True, text=True, env=env, timeout=30)
    if check and p.returncode:
        raise RuntimeError(f'cli {args}: {p.stdout} {p.stderr}')
    return p.stdout.strip()


def cjson(*args):
    return json.loads(cli('--json', '--id-format', 'uuids', *args))


def ax(*args, check=True):
    p = subprocess.run([AX, str(pid()), *args], capture_output=True, text=True, timeout=30)
    if check and p.returncode:
        raise RuntimeError(f'ax {args}: rc={p.returncode} {p.stdout} {p.stderr}')
    return p.stdout.strip() if p.returncode == 0 else None


def frame(ident):
    out = ax('frame', ident, check=False)
    if not out:
        return None
    x, y, w, h = (float(v) for v in out.split())
    return dict(x=x, y=y, w=w, h=h)


def wait_for(fn, timeout=15, step=0.25):
    end = time.time() + timeout
    while time.time() < end:
        value = fn()
        if value:
            return value
        time.sleep(step)
    return None


def activate():
    subprocess.run(['/usr/bin/open', str(APP)], capture_output=True, timeout=20)
    time.sleep(1.0)


def quit_app():
    activate()
    before = pid()
    subprocess.run(['osascript', '-e',
                    f'tell application "System Events" to tell (first process whose unix id is {before}) '
                    'to click (first menu item of menu 1 of menu bar item 2 of menu bar 1 whose name starts with "Quit")'],
                   capture_output=True, text=True, timeout=20)
    time.sleep(1.5)
    if pid() is not None:
        subprocess.run([CLICLICK, 'kd:cmd', 't:q', 'ku:cmd'], check=True)
        subprocess.run([CLICLICK, 'ku:cmd', 'ku:alt', 'ku:shift', 'ku:ctrl'])
    return wait_for(lambda: pid() is None, timeout=20)


def relaunch_app():
    bin_ = str(APP / 'Contents/MacOS/c11')
    uid, user = str(os.getuid()), os.environ.get('USER', 'admin')
    dsock = f'{os.environ["HOME"]}/Library/Application Support/c11/c11d-sandbox-{RUN}.sock'
    subprocess.run(['/usr/bin/sudo', '-n', '/bin/rm', '-f', SOCKET])
    subprocess.run(['/usr/bin/sudo', '-n', '/bin/launchctl', 'asuser', uid, '/usr/bin/sudo', '-n', '-u', user,
                    '/usr/bin/env', '-i', f'HOME={os.environ["HOME"]}', f'USER={user}', f'LOGNAME={user}',
                    'PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', 'TMPDIR=/tmp',
                    'C11_SOCKET_MODE=automation', 'C11_ALLOW_SOCKET_OVERRIDE=1', f'C11_SOCKET={SOCKET}',
                    f'C11_SOCKET_PATH={SOCKET}', f'CMUXD_UNIX_PATH={dsock}', f'C11_DEBUG_LOG=/tmp/c11-sandbox-{RUN}.log',
                    'C11_QA_LAUNCH=resume', '/bin/zsh', '-c', 'nohup "$1" > "$2" 2>&1 &', '_', bin_,
                    f'/tmp/c11-sandbox-{RUN}.relaunch.stdout'], check=True)
    up = bool(wait_for(lambda: os.path.exists(SOCKET) and pid(), timeout=60))
    time.sleep(3)
    return up


def load():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save(state):
    STATE.write_text(json.dumps(state, indent=2, ensure_ascii=False))


def record(step, ok, **detail):
    result = json.loads(RESULT.read_text()) if RESULT.exists() else {}
    result[step] = dict(ok=ok, at=time.strftime('%H:%M:%S %Z'), **detail)
    RESULT.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(json.dumps({step: result[step]}, ensure_ascii=False))


def window_shot(name):
    path = OUT / f'{name}.png'
    subprocess.run(['screencapture', '-x', '-o', f'-l{ax("windowid", "-")}', str(path)], check=True)
    return path.name


def set_appearance(mode):
    """View > Appearance > Light or Dark: the app's own setting. c11 forces Dark at every
    launch, so the system's dark mode would change nothing."""
    activate()
    subprocess.run(['osascript', '-e',
                    f'tell application "System Events" to tell (first process whose unix id is {pid()}) '
                    f'to click menu item "{mode}" of menu 1 of menu item "Appearance" of menu 1 '
                    'of menu bar item "View" of menu bar 1'],
                   check=True, capture_output=True, timeout=20)
    time.sleep(1.5)


def pixel(x, y):
    """The screen's colour at one global point, from a 1x1 capture (the guest display is 1x)."""
    import struct, zlib
    path = '/tmp/g410-pixel.png'
    subprocess.run(['screencapture', '-x', f'-R{int(x)},{int(y)},1,1', path], check=True)
    data, pos, idat, ihdr = open(path, 'rb').read(), 8, b'', None
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            ihdr = body
        elif kind == b'IDAT':
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    return list(raw[1:4]) if ihdr and ihdr[8] == 8 else None


def tab_fill(name_frame, scale):
    """The name tab's fill: a point in the tab's trailing padding, clear of the text."""
    if not name_frame:
        return None
    return pixel(name_frame['x'] + name_frame['w'] - 3 * scale, name_frame['y'] + name_frame['h'] / 2)


def groups():
    return {g['name']: g for g in cjson('workspace-group', 'list')['workspace_groups']}


def headers(state):
    """Every group header's frame, and its name button's."""
    out = {}
    for name, gid in state['groups'].items():
        out[name] = dict(header=frame(f'workspace-group-header-{gid}'), name=frame(f'workspace-group-name-{gid}'),
                         captain=frame(f'workspace-group-captain-{gid}') is not None)
    return out


def first_panel(ws):
    tree = cjson('tree', '--workspace', ws)
    def walk(node):
        if isinstance(node, dict):
            if node.get('type') in ('terminal', 'panel') and node.get('id') and node.get('kind', node.get('type')) == 'terminal':
                return node['id']
            for value in node.values():
                found = walk(value)
                if found:
                    return found
        elif isinstance(node, list):
            for value in node:
                found = walk(value)
                if found:
                    return found
        return None
    return walk(tree)


model_check()

if PHASE == 'setup':
    names = ['Acetate', 'Coevolution Lab', 'Meridian Lab', 'Tally Swarm', 'Ledger', 'Harbor', 'Rocket Ops', 'Flagship']
    # Safe to run again: only what is missing is created.
    existing = {w['title'] for w in cjson('list-workspaces')['workspaces']}
    for n in names:
        if n not in existing:
            cjson('new-workspace', '--title', n)
            time.sleep(0.3)
    ids = {w['title']: w['id'] for w in cjson('list-workspaces')['workspaces']}
    for g in ['The Constellation Bus Program', 'Swarm Research', 'Stage 11 Deployments and Client Work', 'Ops']:
        if g not in groups():
            cjson('workspace-group', 'create', '--name', g)
    g = groups()
    gid = {k: v['id'] for k, v in g.items()}
    cli('workspace-group', 'add', '--group', gid['The Constellation Bus Program'],
        '--workspaces', ','.join(ids[n] for n in ['Acetate', 'Coevolution Lab', 'Meridian Lab']), check=False)
    cli('workspace-group', 'add', '--group', gid['Swarm Research'], '--workspaces', ids['Tally Swarm'], check=False)
    cli('workspace-group', 'add', '--group', gid['Stage 11 Deployments and Client Work'],
        '--workspaces', ','.join([ids['Ledger'], ids['Harbor']]), check=False)
    cli('workspace-group', 'add', '--group', gid['Ops'], '--workspaces', ids['Rocket Ops'], check=False)
    cli('workspace-group', 'set-color', '--group', gid['The Constellation Bus Program'], '--color', '#7C3AED')
    cli('workspace-group', 'set-color', '--group', gid['Stage 11 Deployments and Client Work'], '--color', '#E0A33C')
    cli('workspace-group', 'set-icon', '--group', gid['Ops'], '--icon', '🚀')
    cli('workspace-group', 'pin', '--group', gid['Swarm Research'])
    cli('set-workspace-metadata', '--group', gid['The Constellation Bus Program'], 'captain', 'bus-captain')
    flagged = {}
    for n in ['Acetate', 'Coevolution Lab', 'Ledger']:
        panel = first_panel(ids[n])
        flagged[n] = panel
        cli('raise-flag', '--panel', panel, 'C11H-410 guest flag', panel=panel)
    cli('workspace-group', 'collapse', '--group', gid['Stage 11 Deployments and Client Work'])
    save(dict(workspaces=ids, groups=gid, flagged=flagged))
    time.sleep(1)
    activate()
    # The operator selects a card inside the purple group: Beacon's selected card under its header.
    ax('click', f'sidebar.workspace.{ids["Coevolution Lab"]}', check=False)
    time.sleep(1)
    g = groups()
    record('setup', all(n in ids for n in names) and len(g) == 4, workspaces=ids, groups=gid, flagged=flagged,
           summaries={k: {kk: v.get(kk) for kk in ('member_count', 'is_collapsed', 'is_pinned', 'icon', 'color',
                                                    'captain', 'captain_state')}
                      for k, v in g.items()})

elif PHASE == 'narrow':
    # Drag the sidebar's edge as far left as it goes: c11 clamps it at its 180 pt minimum.
    s = load()
    activate()
    h = wait_for(lambda: frame(f'workspace-group-header-{s["groups"]["The Constellation Bus Program"]}'))
    edge_x = int(h['x'] + h['w'] + 6 + 1)
    y = int(h['y'] + h['h'] + 140)
    before = h['w']
    subprocess.run([CLICLICK, '-e', '300', f'm:{edge_x},{y}', f'dd:{edge_x},{y}', f'dm:{edge_x - 60},{y}',
                    f'dm:{edge_x - 300},{y}', f'du:{edge_x - 300},{y}'], check=True)
    time.sleep(1.5)
    after = frame(f'workspace-group-header-{s["groups"]["The Constellation Bus Program"]}')
    record('narrow', after is not None and abs(after['w'] - 168) <= 2, header_width_before=before,
           header_width_after=after and after['w'], shot=window_shot('00-narrow'))

elif PHASE == 'sweep':
    # Every bundled theme in the app's Light then Dark appearance, at the current width and scale.
    s = load()
    tag = ARGS[0] if ARGS else 'sweep'
    scale = float(ARGS[1]) if len(ARGS) > 1 else 1.0
    rows = {}
    for mode in ('Light', 'Dark'):
        set_appearance(mode)
        for theme in THEMES:
            cli('themes', 'set', theme)
            time.sleep(1.2)
            key = f'{theme}-{mode.lower()}'
            hs = headers(s)
            fill = tab_fill(hs['Swarm Research']['name'], scale)
            rows[key] = dict(shot=window_shot(f'{tag}-{key}'), tab_fill=fill, headers=hs)
    heights = {round(v['headers'][n]['header']['h'], 1) for v in rows.values() for n in v['headers'] if v['headers'][n]['header']}
    widths = {round(v['headers'][n]['header']['w'], 1) for v in rows.values() for n in v['headers'] if v['headers'][n]['header']}
    # c11's own fallback surfaces (stage11, c11) follow the appearance: a light tab in Light, a dark one in Dark.
    lum = lambda rgb: sum(rgb) / 765 if rgb else None
    applied = {t: (lum(rows[f'{t}-light']['tab_fill']), lum(rows[f'{t}-dark']['tab_fill'])) for t in ('stage11', 'c11')}
    appearance_ok = all(l is not None and d is not None and l > 0.6 and d < 0.3 for l, d in applied.values())
    ok = len(heights) == 1 and len(widths) == 1 and appearance_ok
    record(tag, ok, header_heights=sorted(heights), header_widths=sorted(widths),
           tab_luminance_light_dark=applied, rows=rows)

elif PHASE == 'still':
    # Nothing moves when a flag goes up or down, or when the selection leaves a group and comes
    # back: every header's and name's frame, and the card under the flag, stay put.
    s = load()
    ws = s['workspaces']
    def snapshot():
        out = {n: dict(header=frame(f'workspace-group-header-{g}'), name=frame(f'workspace-group-name-{g}'))
               for n, g in s['groups'].items()}
        out['card'] = frame(f'sidebar.workspace.{ws["Tally Swarm"]}')
        return out
    activate()
    ax('click', f'sidebar.workspace.{ws["Coevolution Lab"]}', check=False)
    time.sleep(1)
    before = snapshot()
    panel = first_panel(ws['Tally Swarm'])
    cli('raise-flag', '--panel', panel, 'C11H-410 still check', panel=panel)
    time.sleep(1.2)
    raised = snapshot()
    shot = window_shot('still-flag-raised')
    cli('lower-flag', '--panel', panel, panel=panel)
    time.sleep(1.2)
    lowered = snapshot()
    # The selection leaves the purple group (its name drops to secondary ink) and returns.
    ax('click', f'sidebar.workspace.{ws["Flagship"]}', check=False)
    time.sleep(1.2)
    away = snapshot()
    shot_away = window_shot('still-selection-away')
    ax('click', f'sidebar.workspace.{ws["Coevolution Lab"]}', check=False)
    time.sleep(1.2)
    back = snapshot()
    same = before == raised == lowered == away == back
    record('still', same, before=before, raised=raised, lowered=lowered, selection_away=away,
           selection_back=back, shot=shot, shot_selection_away=shot_away)

elif PHASE == 'hover':
    # Under the pointer the count's slot holds the actions menu; away from it, it does not exist.
    s = load()
    gid = s['groups']['The Constellation Bus Program']
    activate()
    away = frame(f'workspace-group-actions-{gid}')
    h = frame(f'workspace-group-header-{gid}')
    subprocess.run([CLICLICK, f'm:{int(h["x"] + h["w"] / 2)},{int(h["y"] + h["h"] / 2)}'], check=True)
    menu = wait_for(lambda: frame(f'workspace-group-actions-{gid}'), timeout=5)
    time.sleep(2.5)  # the name's tooltip
    shot = subprocess.run(['screencapture', '-x', str(OUT / 'hover.png')], check=True) and 'hover.png'
    header_after = frame(f'workspace-group-header-{gid}')
    subprocess.run([CLICLICK, 'm:700,880'], check=True)
    time.sleep(0.8)
    gone = frame(f'workspace-group-actions-{gid}') is None
    inside = bool(menu and h and menu['x'] >= h['x'] and menu['x'] + menu['w'] <= h['x'] + h['w'] + 0.5)
    record('hover', away is None and bool(menu) and gone and inside and header_after == h,
           menu_frame=menu, header=h, header_while_hovered=header_after, menu_before_hover=away,
           menu_after_leaving=not gone and 'still there' or None, shot='hover.png')

elif PHASE == 'menu':
    # Choose Pin Group from the hover "..." menu, and read the pin back from the socket. Then open
    # the menu again, move the pointer off the header while it is open, and choose Unpin Group.
    s = load()
    gid = s['groups']['Ops']
    activate()
    h = frame(f'workspace-group-header-{gid}')
    def pinned():
        return next(g for g in cjson('workspace-group', 'list')['workspace_groups'] if g['id'] == gid)['is_pinned']
    if pinned():
        cli('workspace-group', 'unpin', '--group', gid)
        time.sleep(1)
    start = pinned()
    def hover_header():
        # Read the frame each time: pinning moves the group. Two moves, so the header sees the
        # pointer enter and move inside it.
        f = frame(f'workspace-group-header-{gid}')
        cx, cy = int(f["x"] + f["w"] / 2), int(f["y"] + f["h"] / 2)
        subprocess.run([CLICLICK, '-w', '150', f'm:{cx - 30},{cy}', f'm:{cx},{cy}'], check=True)
        return wait_for(lambda: frame(f'workspace-group-actions-{gid}'), timeout=5)
    menu = hover_header()
    if not menu:
        record('menu', False, reason='the actions menu did not appear under the pointer', header=h,
               shot=subprocess.run(['screencapture', '-x', str(OUT / 'menu-missing.png')], check=True) and 'menu-missing.png')
        raise SystemExit(1)
    ax('click', f'workspace-group-actions-{gid}')
    time.sleep(0.8)
    open_shot = subprocess.run(['screencapture', '-x', str(OUT / 'menu-open.png')], check=True) and 'menu-open.png'
    ax('menuitem', 'Pin Group')
    after_pin = wait_for(lambda: pinned() is True, timeout=5)
    # Again, and the pointer leaves the header while the menu is open.
    if not hover_header():
        record('menu', False, reason='the actions menu did not appear after pinning',
               shot=subprocess.run(['screencapture', '-x', str(OUT / 'menu-missing-2.png')], check=True) and 'menu-missing-2.png')
        raise SystemExit(1)
    ax('click', f'workspace-group-actions-{gid}')
    time.sleep(0.8)
    subprocess.run([CLICLICK, 'm:700,880'], check=True)
    time.sleep(1.0)
    leave_shot = subprocess.run(['screencapture', '-x', str(OUT / 'menu-pointer-left.png')], check=True) and 'menu-pointer-left.png'
    chose = ax('menuitem', 'Unpin Group', check=False) is not None
    after_unpin = wait_for(lambda: pinned() is False, timeout=5)
    subprocess.run([CLICLICK, 'kp:esc'], check=False)
    record('menu', start is False and bool(menu) and bool(after_pin) and chose and bool(after_unpin),
           pinned_at_start=start, pinned_after_pin_group=bool(after_pin),
           unpin_chosen_after_pointer_left=chose, unpinned=bool(after_unpin),
           shots=[open_shot, leave_shot])

elif PHASE == 'density':
    # Full cards (28 pt x scale headers) or the automatic density; relaunches the app.
    mode = ARGS[0]
    bundle = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print CFBundleIdentifier',
                                      str(APP / 'Contents/Info.plist')], text=True).strip()
    gone = quit_app()
    subprocess.run(['defaults', 'write', bundle, 'sidebarDensity', mode], check=True)
    up = relaunch_app()
    record(f'density-{mode}', bool(gone and up), mode=mode)

elif PHASE == 'single':
    # One theme, Dark, at the current density, width and scale.
    s = load()
    tag = ARGS[0]
    set_appearance('Dark')
    cli('themes', 'set', 'stage11')
    time.sleep(1.2)
    hs = headers(s)
    # AX frames are whole points: a 43.4 pt header reads 43 or 44 by its position.
    heights = sorted({round(v['header']['h'], 1) for v in hs.values() if v['header']})
    record(tag, bool(heights) and heights[-1] - heights[0] <= 1, header_heights=heights, headers=hs, shot=window_shot(tag))

elif PHASE == 'scale':
    preset = ARGS[0]
    bundle = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print CFBundleIdentifier',
                                      str(APP / 'Contents/Info.plist')], text=True).strip()
    gone = quit_app()
    subprocess.run(['defaults', 'write', bundle, 'chromeScalePreset', preset], check=True)
    up = relaunch_app()
    s = load()
    h = frame(f'workspace-group-header-{s["groups"]["The Constellation Bus Program"]}')
    record(f'scale-{preset}', bool(gone and up and h), preset=preset, header=h)

else:
    raise SystemExit(f'unknown phase {PHASE}')
