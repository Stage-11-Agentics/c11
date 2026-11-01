#!/usr/bin/env python3
"""C11-523/C11-554 native acceptance: width alone picks Tiles. Only run through sandbox-tests-v2.sh."""
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import time
import atexit

signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('10-minute proof deadline')))
signal.alarm(600)
SOCKET = os.environ.get('C11_SOCKET_PATH', '')
assert re.fullmatch(r'/tmp/c11-sandbox-[A-Za-z0-9._-]+\.sock', SOCKET), 'sandbox socket required'
RUN = SOCKET.removeprefix('/tmp/c11-sandbox-').removesuffix('.sock')
for key in list(os.environ):
    if key.startswith(('C11_SOCKET', 'CMUX_SOCKET')):
        del os.environ[key]
APP_ROOT = f'/Users/admin/c11-sandbox/apps/{RUN}/'
PIDS = [int(line.strip().split(None, 1)[0]) for line in subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True).splitlines()
        if APP_ROOT in line and line.endswith('/Contents/MacOS/c11')]
assert len(PIDS) == 1, ('exact guest app missing', PIDS)
PID = PIDS[0]
OUT = Path('/Volumes/My Shared Files/out/sidebar-tiles')
assert OUT.parent.is_dir()
OUT.mkdir(exist_ok=True)
CLIENT = socket.socket(socket.AF_UNIX)
CLIENT.settimeout(12)
CLIENT.connect(SOCKET)
READER = CLIENT.makefile('rb')
SEQ = 0
RESULTS = []


def call(method, **params):
    global SEQ
    SEQ += 1
    CLIENT.sendall((json.dumps(dict(id=SEQ, method=method, params=params))+'\n').encode())
    result = json.loads(READER.readline())
    assert result['id'] == SEQ and result.get('ok'), (method, result)
    return result['result']


def osa(body):
    return subprocess.check_output(['osascript', '-e',
        f'tell application "System Events" to tell (first process whose unix id is {PID})\n{body}\nend tell'], text=True, timeout=20).strip()


def wait_for(predicate, label, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError(label)


def note(name, **data):
    RESULTS.append(dict(case=name, **data))
    (OUT/'result.json').write_text(json.dumps(dict(pid=PID, socket=SOCKET, cases=RESULTS), indent=2))
    print('PASS', name, json.dumps(data), flush=True)


def ax(identifier, action='return {position of e, size of e}'):
    body = f'''set es to entire contents of window 1
repeat with e in es
try
if (value of attribute "AXIdentifier" of e) is {json.dumps(identifier)} then
{action}
end if
end try
end repeat
error "missing AX target: {identifier}"'''
    return osa(body)


def rect(identifier):
    values = [float(v) for v in ax(identifier).split(', ')]
    assert len(values) == 4, values
    return values


def press(identifier):
    return ax(identifier, 'perform action "AXPress" of e\nreturn "pressed"')


def mouse(command):
    subprocess.run(['/opt/homebrew/bin/cliclick', *command], check=True, timeout=10)


def layout(ws=None):
    return call('sidebar.state', workspace_id=ws or WS)['layout']


def shot(name):
    assert osa('get frontmost') == 'true'
    subprocess.run(['screencapture', '-x', '-o', str(OUT/(name+'.png'))], check=True, timeout=10)


def stop_recording():
    if RECORDING.poll() is None:
        RECORDING.send_signal(signal.SIGINT)
        RECORDING.wait(timeout=8)


def preview_count():
    return int(osa('count of (windows whose subrole is "AXSystemDialog")'))


def drag_width(width):
    # Resolve the host even if a non-key preview is first in the AX window list.
    # Let mouse-down establish the native gesture before sending movement.
    osa('key code 53')
    current = layout()['effective_width']
    win = [float(v) for v in osa('get {position, size} of (first window whose subrole is "AXStandardWindow")').split(', ')]
    start = (round(win[0]+current), round(win[1]+220))
    finish = (round(win[0]+width), start[1])
    mouse([f'm:{start[0]},{start[1]}', 'w:150', f'dd:{start[0]},{start[1]}', 'w:150'])
    try:
        for i in range(1, 11):
            x = round(start[0]+(finish[0]-start[0])*i/10)
            mouse([f'dm:{x},{start[1]}', 'w:30'])
    finally:
        mouse([f'du:{finish[0]},{finish[1]}'])
    wait_for(lambda: abs(layout()['effective_width']-width) <= 1, 'drag width')


def measure(expected_width, expected_columns):
    state = layout()
    assert state['double_wide']
    assert abs(state['effective_width']-expected_width) <= 1, state
    assert state['columns'] == expected_columns, state
    frames = {ws: rect('sidebar.workspace.'+ws) for ws in FLEET}
    for frame in frames.values():
        assert abs(frame[3]-75) <= 1, frame
    win = [float(v) for v in osa('get {position, size} of window 1').split(', ')]
    assert state['effective_width'] <= min(600, win[2]/3)+1
    if expected_width == 400:
        assert all(win[1]+30 <= r[1] and r[1]+r[3] <= win[1]+win[3]-40 for r in frames.values()), (win, frames)
    note(f'geometry-{expected_width}', layout=state, frames=frames)


osa('set frontmost to true')
time.sleep(.3)
initial = call('system.identify')['focused']
WS, WINDOW, TERMINAL = initial['workspace_id'], initial['window_id'], initial['panel_id']
osa('set position of window 1 to {20, 40}')
display = call('window.resize', window_id=WINDOW, width=1600, height=1000)
note('verified-display', window=display)
for panel in call('panel.list', workspace_id=WS)['panels']:
    if panel['id'] != TERMINAL:
        call('panel.close', workspace_id=WS, panel_id=panel['id'])
for ws in call('workspace.list', window_id=WINDOW)['workspaces']:
    if ws['id'] != WS:
        call('workspace.close', workspace_id=ws['id'])
call('workspace.rename', workspace_id=WS, title='Tiles 01 terminal')
FLEET = [WS]
for i in range(2, 14):
    FLEET.append(call('workspace.create', window_id=WINDOW, title=f'Tiles {i:02}')['workspace_id'])
group = call('workspace.group.create', window_id=WINDOW, name='Tiles fixture folder')['group_id']
for ws in FLEET[-3:]:
    call('workspace.group.move', window_id=WINDOW, workspace_id=ws, to_group_id=group)
# Bounded presentation fixtures: an overflow roster, a long flagged reason,
# and ordinary shell-only workspaces. These are metadata fixtures, not agents.
for index, ws in enumerate(FLEET[:4]):
    panels = [] if index == 0 else [call('panel.list', workspace_id=ws)['panels'][0]['id']]
    for _ in range((9 if index == 0 else 3)-len(panels)):
        panels.append(call('panel.create', workspace_id=ws, type='terminal', focus=False)['panel_id'])
    for n, panel in enumerate(panels):
        metadata = dict(terminal_type=['claude-code', 'codex', 'grok'][n % 3],
                        title=f'Fixture agent {n+1}', description='Tiles presentation fixture')
        call('panel.set_metadata', panel_id=panel, workspace_id=ws,
             mode='merge', source='explicit', metadata=metadata)
        # An unknown foreground command lets the declared fixture kind render;
        # an idle shell correctly overrides a stale agent declaration.
        call('panel.send_text', panel_id=panel, workspace_id=ws,
             text="python3 -u -c 'import time; time.sleep(600)'\n")
        if index == 1 and n == 0:
            call('flag.raise', workspace_id=ws, panel_id=panel, by='operator',
                 reason='A long review request that must truncate inside the tile')
        if index == 2 and n == 0:
            call('notification.create_for_panel', workspace_id=ws, panel_id=panel,
                 title='Tiles unread fixture', body='Check the existing attention treatment')
time.sleep(11)
(OUT/'fixture.json').write_text(json.dumps(dict(workspace=WS, window=WINDOW, terminal=TERMINAL,
                                              fleet=FLEET, group=group), indent=2))
assert not layout()['double_wide']
shot('off-baseline')
# Self-terminating recording on the already verified isolated guest display.
recording_path = OUT/f'tiles-toggle-drag-{PID}.mov'
RECORDING = subprocess.Popen(['screencapture', '-x', '-v', '-V60', '-D1', '-k', str(recording_path)])
atexit.register(stop_recording)
# No mode control remains: no titlebar button and no View > Sidebar menu.
assert 'missing AX target' in subprocess.run(['osascript', '-e',
    f'tell application "System Events" to tell (first process whose unix id is {PID})\n'
    'set es to entire contents of window 1\nrepeat with e in es\ntry\n'
    'if (value of attribute "AXIdentifier" of e) is "titlebarControl.doubleWideSidebar" then return "present"\n'
    'end try\nend repeat\nerror "missing AX target"\nend tell'], capture_output=True, text=True).stderr
view_items = osa('get name of menu items of menu 1 of menu bar item "View" of menu bar 1')
assert 'Sidebar' not in [item.strip() for item in view_items.split(',')] and 'Double Wide' not in view_items, view_items
note('no-mode-control', view_menu=view_items)
# One drag across the two-column edge flips the layout live, both ways.
drag_width(323)
assert not layout()['double_wide'] and layout()['columns'] == 1, layout()
shot('drag-323-cards')
drag_width(324)
assert layout()['double_wide'] and layout()['columns'] == 2, layout()
shot('drag-324-tiles')
drag_width(323)
assert not layout()['double_wide'], layout()
note('drag-threshold', below=323, at=324)
for theme in ['Light', 'Dark']:
    osa(f'click menu item "{theme}" of menu 1 of menu item "Appearance" of menu 1 of menu bar item "View" of menu bar 1')
    for width, cols in [(400, 2), (486, 3), (200, 1)]:
        drag_width(width)
        if width != 200:
            measure(width, cols)
        else:
            assert not layout()['double_wide'] and layout()['columns'] == 1
            note('geometry-200-cards', layout=layout())
        shot(f'{theme.lower()}-{width}')
drag_width(400)
for width, cols in [(971, 1), (972, 2), (1050, 2), (1200, 2), (1600, 2)]:
    call('window.resize', window_id=WINDOW, width=width, height=1000)
    wait_for(lambda: layout()['columns'] == cols, f'window {width} columns')
    state = layout()
    assert state['effective_width'] <= min(600, width/3)+1
    note(f'window-{width}', layout=state)
drag_width(200)
assert not layout()['double_wide']
drag_width(400)
assert layout()['double_wide']
# A real pointer hover while the terminal is focused must not take typing focus.
call('panel.focus', workspace_id=WS, panel_id=TERMINAL)
time.sleep(.5)
frame = rect('sidebar.workspace.'+FLEET[-3])
mouse(['m:800,500', 'w:150', f'm:{round(frame[0]+45)},{round(frame[1]+40)}', 'w:700'])
wait_for(lambda: preview_count() == 1, 'full hover card is actually visible')
assert call('system.identify')['focused']['panel_id'] == TERMINAL
shot('hover')
osa('keystroke "tiles-hover-input"')
time.sleep(.1)
screen = call('panel.read_text', workspace_id=WS, panel_id=TERMINAL)
assert 'tiles-hover-input' in json.dumps(screen), screen
assert call('system.identify')['focused']['panel_id'] == TERMINAL
osa('key code 53')
wait_for(lambda: preview_count() == 0, 'Escape dismisses hover')
note('hover-keeps-terminal-input', focused=call('system.identify')['focused'])
# The oracle resolves the requested window even when a second window exists.
second = call('window.create')
second_id = second['window_id']
second_ws = call('workspace.list', window_id=second_id)['workspaces'][0]['id']
assert not layout(second_ws)['double_wide'] and layout(WS)['double_wide']
call('session.save', include_scrollback=False)
(OUT/'restore-expected.json').write_text(json.dumps(dict(first=WS, second=second_ws, first_layout=layout(WS), second_layout=layout(second_ws)), indent=2))
note('two-window-isolation', first=layout(WS), second=layout(second_ws))
assert RECORDING.wait(timeout=65) == 0, 'native recording failed'
assert recording_path.stat().st_size > 1000, 'native recording is empty'
note('native-recording', path=str(recording_path))
CLIENT.close()
print('PASS core Tiles acceptance; restore and extended action proofs are separate phases', flush=True)
