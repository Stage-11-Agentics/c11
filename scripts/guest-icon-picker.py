#!/usr/bin/env python3
"""C11H-343 guest proof: pick an emoji icon for a workspace group and for a workspace through
the real menus and picker, see both in the sidebar, relaunch, and see them again; an old SF
Symbol group icon keeps drawing. Runs inside a sandbox guest only, one phase per call:
    <script> <run-id> setup|before|group|workspace|quit|relaunch|after|scale|scale-cards|viewer
Needs scripts/guest-ax.m compiled to out/ax in the guest. The socket judges each step; the
screenshots and result.json land in the run's shared folder (out/proof343)."""
import json, os, subprocess, sys, time
from pathlib import Path

RUN, PHASE = sys.argv[1], sys.argv[2]
SOCKET = f'/tmp/c11-sandbox-{RUN}.sock'
APP_ROOT = f'/Users/admin/c11-sandbox/apps/{RUN}/'
SHARE = Path('/Volumes/My Shared Files/out')
OUT = SHARE / 'proof343'
OUT.mkdir(parents=True, exist_ok=True)
STATE = OUT / 'state.json'
RESULT = OUT / 'result.json'
APP = next(Path(APP_ROOT).glob('*.app'))
CLI = str(APP / 'Contents/Resources/bin/c11')
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
AX = str(SHARE / 'ax')


def pid():
    pids = [int(l.split(None, 1)[0]) for l in subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True).splitlines()
            if APP_ROOT in l and l.endswith('/Contents/MacOS/c11')]
    assert len(pids) <= 1, pids
    return pids[0] if pids else None


def cli(*args, check=True):
    p = subprocess.run([CLI, '--socket', SOCKET, *args], capture_output=True, text=True, env=ENV, timeout=30)
    if check and p.returncode:
        raise RuntimeError(f'cli {args}: {p.stdout} {p.stderr}')
    return p.stdout.strip()


def cjson(*args):
    return json.loads(cli('--json', '--id-format', 'uuids', *args))


def ax(*args, check=True):
    p = subprocess.run([AX, str(pid()), *args], capture_output=True, text=True, timeout=30)
    if check and p.returncode:
        raise RuntimeError(f'ax {args}: rc={p.returncode} {p.stdout} {p.stderr}')
    return p.stdout.strip()


def activate():
    """Bring this build forward (guest only), so typed keys reach its field, not Finder.
    System Events' `set frontmost` silently fails here; LaunchServices reopening the running
    bundle activates it."""
    subprocess.run(['/usr/bin/open', str(APP)], capture_output=True, timeout=20)
    time.sleep(1.0)


def quit_app():
    """The app menu's Quit, then the "Quit all of c11?" card's Command-Q."""
    activate()
    before = pid()
    subprocess.run(['osascript', '-e',
                    f'tell application "System Events" to tell (first process whose unix id is {before}) '
                    'to click (first menu item of menu 1 of menu bar item 2 of menu bar 1 whose name starts with "Quit")'],
                   capture_output=True, text=True, timeout=20)
    time.sleep(1.5)
    if pid() is not None:
        subprocess.run(['/opt/homebrew/bin/cliclick', 'kd:cmd', 't:q', 'ku:cmd'], check=True)
        subprocess.run(['/opt/homebrew/bin/cliclick', 'ku:cmd', 'ku:alt', 'ku:shift', 'ku:ctrl'])
    return before, wait_for(lambda: pid() is None, timeout=20)


def relaunch_app():
    """Relaunch the same bundle with sandbox-up's environment, resuming the session."""
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
    time.sleep(2)
    return up


def card_frame(ws):
    x, y, w, h = (int(v) for v in ax('frame', f'sidebar.workspace.{ws}').split())
    return dict(x=x, y=y, w=w, h=h)


def load():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save(state):
    STATE.write_text(json.dumps(state, indent=2, ensure_ascii=False))


def record(step, ok, **detail):
    result = json.loads(RESULT.read_text()) if RESULT.exists() else {}
    result[step] = dict(ok=ok, at=time.strftime('%H:%M:%S'), **detail)
    RESULT.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(json.dumps({step: result[step]}, ensure_ascii=False))


def window_shot(name):
    """The c11 window by CGWindowID: never the frontmost app by accident."""
    path = OUT / f'{name}.png'
    subprocess.run(['screencapture', '-x', '-o', f'-l{ax("windowid", "-")}', str(path)], check=True)
    return str(path)


def screen_shot(name):
    """Whole screen, for a popover (its own window above the c11 window)."""
    path = OUT / f'{name}.png'
    subprocess.run(['screencapture', '-x', str(path)], check=True)
    return str(path)


def groups():
    return {g['name']: g for g in cjson('workspace-group', 'list')['workspace_groups']}


def workspace_icon(ws):
    data = cjson('get-workspace-metadata', '--workspace', ws)
    return (data.get('metadata') or {}).get('icon')


def wait_for(predicate, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return predicate()


if PHASE == 'setup':
    first = cjson('list-workspaces')['workspaces'][0]['id']
    cli('rename-workspace', '--workspace', first, 'Alpha')
    beta = cjson('new-workspace', '--title', 'Beta')
    gamma = cjson('new-workspace', '--title', 'Gamma')
    ids = {w['title']: w['id'] for w in cjson('list-workspaces')['workspaces']}
    cjson('workspace-group', 'create', '--name', 'Old Symbol')
    cjson('workspace-group', 'create', '--name', 'Emoji Group')
    g = groups()
    cli('workspace-group', 'set-icon', '--group', g['Old Symbol']['id'], '--icon', 'server.rack')
    cli('workspace-group', 'add', '--group', g['Old Symbol']['id'], '--workspaces', ids['Beta'])
    cli('workspace-group', 'add', '--group', g['Emoji Group']['id'], '--workspaces', ids['Gamma'])
    save(dict(workspaces=ids, groups={k: v['id'] for k, v in groups().items()}))
    record('setup', True, workspaces=ids, groups={k: v.get('icon') for k, v in groups().items()})

elif PHASE == 'before':
    record('before', True, shot=window_shot('01-before'),
           old_symbol_icon=groups()['Old Symbol'].get('icon'))

elif PHASE == 'group':
    s = load()
    header = f'workspace-group-header-{s["groups"]["Emoji Group"]}'
    activate()
    # The header's actions menu shows only under the pointer (C11H-410); its
    # context menu holds the same items. AXShowMenu blocks while the menu tracks.
    ax('showmenu', header, check=False)
    time.sleep(0.6)
    ax('menuitem', 'Icon…')
    wait_for(lambda: subprocess.run([AX, str(pid()), 'frame', 'sidebar-icon-picker-grid'],
                                    capture_output=True).returncode == 0)
    picker = screen_shot('02-group-picker')
    ax('press', 'sidebar-icon-picker-cell-3')  # the common page's fourth emoji
    icon = wait_for(lambda: groups()['Emoji Group'].get('icon'))
    time.sleep(0.5)
    record('group', icon == '🚀', icon=icon, picker=picker, shot=window_shot('03-group-set'))

elif PHASE == 'workspace':
    s = load()
    card = f'sidebar.workspace.{s["workspaces"]["Alpha"]}'
    activate()
    # AXShowMenu blocks while the context menu tracks, so it reports -25204 with the menu open.
    ax('showmenu', card, check=False)
    time.sleep(0.6)
    ax('menuitem', 'Set Icon…')
    wait_for(lambda: subprocess.run([AX, str(pid()), 'frame', 'sidebar-icon-picker-field'],
                                    capture_output=True).returncode == 0)
    ax('click', 'sidebar-icon-picker-field')  # activates c11 and focuses the field, as the operator would
    time.sleep(0.4)
    subprocess.run(['/opt/homebrew/bin/cliclick', '-w', '70', 't:test tube'], check=True)
    time.sleep(0.6)
    search = screen_shot('04-workspace-picker-search')
    ax('press', 'sidebar-icon-picker-cell-0')
    icon = wait_for(lambda: workspace_icon(s['workspaces']['Alpha']) == '🧪' and '🧪') or workspace_icon(s['workspaces']['Alpha'])
    # A symbol icon beside it, set the CLI way: the same slot width as the emoji.
    cli('set-workspace-icon', '--workspace', s['workspaces']['Beta'], 'sf:star.fill')
    time.sleep(0.6)
    record('workspace', icon == '🧪', icon=icon, search=search, shot=window_shot('05-workspace-set'))

elif PHASE == 'quit':
    before, gone = quit_app()
    record('quit', bool(gone), pid=before, shot=None if gone else screen_shot('06-quit-blocked'))

elif PHASE == 'relaunch':
    record('relaunch', relaunch_app(), pid=pid())

elif PHASE == 'after':
    s = load()
    time.sleep(2)
    g = groups()
    alpha = workspace_icon(s['workspaces']['Alpha'])
    beta = workspace_icon(s['workspaces']['Beta'])
    ok = (g['Emoji Group'].get('icon') == '🚀' and g['Old Symbol'].get('icon') == 'server.rack'
          and alpha == '🧪' and beta == 'sf:star.fill')
    record('after', ok, emoji_group=g['Emoji Group'].get('icon'), old_symbol=g['Old Symbol'].get('icon'),
           alpha=alpha, beta=beta, shot=window_shot('07-after-relaunch'))

elif PHASE in ('scale', 'scale-cards'):
    # Extra Large chrome: a card with no icon, then the same card with one, and
    # the card below it. Setting the icon must move nothing. `scale` leaves
    # density automatic (compact cards at this size); `scale-cards` pins Cards.
    s = load()
    bundle = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print CFBundleIdentifier',
                                      str(APP / 'Contents/Info.plist')], text=True).strip()
    quit_app()
    subprocess.run(['defaults', 'write', bundle, 'chromeScalePreset', 'extraLarge'], check=True)
    if PHASE == 'scale-cards':
        subprocess.run(['defaults', 'write', bundle, 'sidebarDensity', 'cards'], check=True)
    relaunch_app()
    tag = 'cards-' if PHASE == 'scale-cards' else ''
    gamma, alpha = s['workspaces']['Gamma'], s['workspaces']['Alpha']
    cli('clear-workspace-metadata', '--workspace', gamma, '--key', 'icon', check=False)
    time.sleep(1)
    no_icon = dict(gamma=card_frame(gamma), alpha=card_frame(alpha), shot=window_shot(f'10-scale-{tag}no-icon'))
    cli('set-workspace-icon', '--workspace', gamma, '🌱')
    time.sleep(1)
    with_icon = dict(gamma=card_frame(gamma), alpha=card_frame(alpha), shot=window_shot(f'11-scale-{tag}with-icon'))
    same = (no_icon['gamma']['h'] == with_icon['gamma']['h'] and no_icon['alpha']['y'] == with_icon['alpha']['y'])
    record(PHASE, same and workspace_icon(gamma) == '🌱', preset='extraLarge',
           density='cards' if PHASE == 'scale-cards' else 'automatic',
           no_icon=no_icon, with_icon=with_icon)

elif PHASE == 'viewer':
    # Opens a window, so it runs last: the picker's Emoji & Symbols button.
    s = load()
    activate()
    ax('showmenu', f'sidebar.workspace.{s["workspaces"]["Gamma"]}', check=False)
    time.sleep(0.6)
    ax('menuitem', 'Set Icon…')
    wait_for(lambda: subprocess.run([AX, str(pid()), 'frame', 'sidebar-icon-picker-field'],
                                    capture_output=True).returncode == 0)
    ax('click', 'sidebar-icon-picker-field')
    time.sleep(0.4)
    ax('press', 'sidebar-icon-picker-character-viewer')
    time.sleep(2.5)
    still_open = subprocess.run([AX, str(pid()), 'frame', 'sidebar-icon-picker-grid'], capture_output=True).returncode == 0
    record('viewer', True, picker_still_open=still_open, shot=screen_shot('08-character-viewer'))

else:
    raise SystemExit(f'unknown phase {PHASE}')
