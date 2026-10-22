#!/usr/bin/env python3
"""C11-356: run only via scripts/sandbox-tests-v2.sh in an isolated guest.

Exercises the bundled CLI and both socket protocols, not source text. Each
scenario gets a background workspace; the selected workspace is a sentinel.
"""
import json
import os
import signal
import socket
import subprocess
import time
import uuid
from pathlib import Path

from cmux import cmux, find_cli_binary

SOCKET = os.environ['C11_SOCKET']
if not SOCKET.startswith('/tmp/c11-sandbox-') or not Path('/Volumes/My Shared Files/out').is_dir():
    raise SystemExit('Run this probe through sandbox-tests-v2.sh in an isolated guest.')
CLI = find_cli_binary()
FAILURES = []
CHECKS = 0


def must(value, message):
    if not value:
        raise AssertionError(message)


def cli(args, workspace=None, check=True, json_output=False):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('C11_', 'CMUX_'))}
    if workspace is not None:
        env['C11_WORKSPACE_ID'] = workspace
    argv = [CLI, '--socket', SOCKET, '--id-format', 'uuids']
    if json_output:
        argv += ['--json']
    result = subprocess.run(argv + args, env=env, text=True,
                            capture_output=True, timeout=15)
    if check:
        must(result.returncode == 0, f'{args}: {result.stdout} {result.stderr}')
    return result


def legacy(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(15)
        s.connect(SOCKET)
        s.sendall((command + '\n').encode())
        data = b''
        while b'\n' not in data:
            part = s.recv(65536)
            if not part:
                break
            data += part
        return data.decode().strip()


def panels(c, ws):
    return c._call('panel.list', {'workspace_id': ws})['panels']


def areas(c, ws):
    return c._call('area.list', {'workspace_id': ws})['areas']


def focused(c, ws):
    rows = panels(c, ws)
    row = next(p for p in rows if p['focused'])
    area = next(a for a in areas(c, ws) if a['focused'])
    return row['id'], area['id']


def layout(c, ws):
    return [(a['id'], a['panel_ids'], a['selected_panel_id'], a['focused'])
            for a in areas(c, ws)]


def identify():
    return json.loads(cli(['identify'], json_output=True).stdout)['focused']


def events():
    return [json.loads(line) for line in cli(['events', 'tail']).stdout.splitlines() if line]


def scenario(c, label, action, *, rejects=False, move_focused=False, single=False, other_area=False):
    global CHECKS
    CHECKS += 1
    made = c._call('workspace.create', {})
    ws = made['workspace_id']
    try:
        keeper = panels(c, ws)[0]
        area = keeper['area_id']
        if single:
            moved = keeper
        else:
            pid = c._call('panel.create', {'workspace_id': ws, 'area_id': area,
                                           'type': 'terminal', 'focus': False})['panel_id']
            moved = next(p for p in panels(c, ws) if p['id'] == pid)
        c._call('panel.focus', {'workspace_id': ws,
                               'panel_id': moved['id'] if move_focused or single else keeper['id']})
        if other_area:
            other = c._call('panel.split', {'workspace_id': ws, 'panel_id': keeper['id'],
                                           'direction': 'right', 'focus': False})['panel_id']
            c._call('panel.focus', {'workspace_id': ws, 'panel_id': other})
        time.sleep(0.15)
        before_focus = focused(c, ws)
        selected = identify()
        must(selected['workspace_id'] != ws, 'fixture must be in a background workspace')
        selected_layout = layout(c, selected['workspace_id'])
        before_layout = layout(c, ws)
        count = len(areas(c, ws))
        # A logged creation is the vacuity guard for the event assertion.
        log = events()
        must(any(e['type'] == 'workspace.created' and e.get('workspace') == ws for e in log),
             'fixture creation absent from event log')
        seq = max(e['seq'] for e in log)
        action(c, made, moved)
        for delay in (0, 0.05, 0.25):
            time.sleep(delay)
            must(identify() == selected, f'{label}: selected focus changed')
            must(layout(c, selected['workspace_id']) == selected_layout,
                 f'{label}: selected workspace layout changed')
            after_focus = focused(c, ws)
            if move_focused or single:
                must(after_focus[0] == before_focus[0], f'{label}: moved focused panel lost focus')
            else:
                must(after_focus == before_focus,
                     f'{label}: workspace-local focus changed {before_focus} -> {after_focus}')
        if rejects:
            must(layout(c, ws) == before_layout, f'{label}: rejected request changed layout')
        else:
            must(len(areas(c, ws)) == count + 1, f'{label}: no new area')
            after = next(p for p in panels(c, ws) if p['id'] == moved['id'])
            must(after['area_id'] != moved['area_id'], f'{label}: panel did not move')
        emitted = [e for e in events() if e['seq'] > seq]
        must(not any(e['type'] == 'workspace.selected' for e in emitted),
             f'{label}: workspace.selected was emitted')
        print(f'PASS {label}', flush=True)
    except Exception as error:
        FAILURES.append(label)
        print(f'FAIL {label}: {error}', flush=True)
    finally:
        c._call('workspace.close', {'workspace_id': ws})


def cli_move(kind, command='drag-panel-to-split', flag='--panel', explicit=None, window=False):
    def action(c, made, panel):
        args = ['--window', made['window_id']] if window else []
        args += [command, flag, str(panel[kind]), 'down']
        if explicit:
            if explicit == 'index':
                rows = c._call('workspace.list', {'window_id': made['window_id']})['workspaces']
                value = str(next(r['index'] for r in rows if r['id'] == made['workspace_id']))
            else:
                value = made[explicit]
            args += ['--workspace', value]
        result = cli(args, workspace=None if explicit else made['workspace_id'])
        must(result.stdout.startswith('OK '), f'unexpected CLI output {result.stdout!r}')
    return action


def socket_move(method='panel.drag_to_split', v1=False, kind='ref'):
    def action(c, made, panel):
        if v1:
            result = legacy(f'drag_surface_to_split {panel[kind]} down --workspace={made["workspace_id"]}')
            must(result.startswith('OK '), result)
        else:
            c._call(method, {'workspace_id': made['workspace_id'],
                             'panel_id': panel['id'], 'direction': 'down'})
    return action


def reject_cli(panel_value=None, workspace_value=None, missing_workspace=False, missing_panel=False):
    def action(c, made, panel):
        args = ['drag-panel-to-split']
        if not missing_panel:
            args += ['--panel', panel['id'] if panel_value is None else panel_value]
        args += ['down']
        if workspace_value is not None:
            args += ['--workspace', workspace_value]
        result = cli(args, workspace=None if missing_workspace else made['workspace_id'], check=False)
        must(result.returncode != 0, f'invalid target succeeded: {result.stdout}')
    return action


def reject_rpc(key, value):
    def action(c, made, panel):
        params = {'workspace_id': made['workspace_id'], 'panel_id': panel['id'], 'direction': 'down'}
        params[key] = value
        try:
            c._call('panel.drag_to_split', params)
        except Exception:
            return
        raise AssertionError(f'invalid {key} succeeded: {value!r}')
    return action


def reject_foreign_panel(c, made, panel):
    foreign = identify()['panel_id']
    result = cli(['drag-panel-to-split', '--panel', foreign, 'down'],
                 workspace=made['workspace_id'], check=False)
    must(result.returncode != 0, 'panel outside caller workspace was accepted')


def refresh(c, made, panel):
    ws = made['workspace_id']
    result = cli(['refresh-panels', '--workspace', made['workspace_ref']], json_output=True)
    payload = json.loads(result.stdout)
    must(payload['workspace_id'] == ws, f'refresh reached wrong workspace: {payload}')
    must(payload['refreshed'] == len(panels(c, ws)), f'refresh count wrong: {payload}')
    result = cli(['refresh-panels'], workspace=ws, json_output=True)
    must(json.loads(result.stdout)['workspace_id'] == ws, 'refresh ignored caller workspace')
    result = cli(['refresh-panels'], check=False)
    must(result.returncode != 0, 'unscoped refresh must fail')
    result = cli(['refresh-panels', '--workspace'], workspace=ws, check=False)
    must(result.returncode != 0, 'missing refresh workspace value must fail')


def keyboard_focus(c):
    """Drive real keyboard input into the exact guest app after a visible move."""
    global CHECKS
    CHECKS += 1
    app_binary = CLI.split('.app/')[0] + '.app/Contents/MacOS/c11'
    processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True)
    pids = [int(line.strip().split(None, 1)[0]) for line in processes.splitlines()
            if line.strip().split(None, 1)[-1] == app_binary]
    must(len(pids) == 1, f'cannot identify exact guest app PID: {pids}')
    pid = pids[0]

    def aqua(args):
        result = subprocess.run(['sudo', '-n', '/bin/launchctl', 'asuser', str(os.getuid()),
                                 'sudo', '-n', '-u', os.environ['USER'], *args],
                                capture_output=True, text=True, timeout=15)
        must(result.returncode == 0, f'Aqua command failed: {result.stderr}')
        return result.stdout

    def type_marker():
        token = uuid.uuid4().hex[:12]
        script = f'''tell application "System Events"
tell (first process whose unix id is {pid})
set frontmost to true
if frontmost is false then error "Guest app did not become frontmost"
keystroke "u" using control down
keystroke "printf 'C11_TYPED_%s\\\\n' {token}"
key code 36
end tell
end tell'''
        aqua(['/usr/bin/osascript', '-e', script])
        marker = 'C11_TYPED_' + token
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            text = c._call('panel.read_text', {'workspace_id': ws, 'panel_id': keeper})['text']
            if marker in [line.strip() for line in text.splitlines()]:
                return marker
            time.sleep(0.1)
        raise AssertionError(f'keyboard output did not reach original panel: {marker}')

    def shot(name):
        script = "ObjC.import('CoreGraphics'); JSON.stringify(ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0))))"
        windows = json.loads(aqua(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script]))
        own = [w for w in windows if w.get('kCGWindowOwnerPID') == pid
               and w.get('kCGWindowLayer') == 0 and w['kCGWindowBounds']['Width'] > 300]
        must(len(own) == 1, f'expected one guest app window, found {len(own)}')
        aqua(['/usr/sbin/screencapture', '-x', '-o', '-l' + str(own[0]['kCGWindowNumber']),
              '/Volumes/My Shared Files/out/' + name + '.png'])

    selected = identify()
    ws, keeper = selected['workspace_id'], selected['panel_id']
    spare = c._call('panel.create', {'workspace_id': ws, 'type': 'terminal', 'focus': False})['panel_id']
    try:
        c._call('panel.focus', {'workspace_id': ws, 'panel_id': keeper})
        time.sleep(0.3)
        type_marker()
        shot('drag-focus-before')
        background = c._call('workspace.create', {})['workspace_id']
        try:
            other = c._call('panel.create', {'workspace_id': background, 'focus': False})['panel_id']
            cli(['drag-panel-to-split', '--panel', other, 'right'], workspace=background)
            time.sleep(0.25)
            type_marker()
        finally:
            c._call('workspace.close', {'workspace_id': background})
        cli(['drag-panel-to-split', '--workspace', ws, '--panel', spare, 'right'])
        time.sleep(0.25)
        must(identify() == selected, 'visible layout move changed focused panel or area')
        marker = type_marker()
        text = c._call('panel.read_text', {'workspace_id': ws, 'panel_id': spare})['text']
        must(marker not in text, 'keyboard output also reached dragged panel')
        shot('drag-focus-after')
        print(f'PASS real keyboard focus, PID {pid}, before/after window captures', flush=True)
    except Exception as error:
        FAILURES.append('real keyboard focus')
        print(f'FAIL real keyboard focus: {error}', flush=True)
    finally:
        c._call('panel.close', {'workspace_id': ws, 'panel_id': spare})


def main():
    started = time.monotonic()
    signal.alarm(300)
    with cmux(SOCKET) as c:
        for kind in ('ref', 'id', 'index'):
            scenario(c, f'caller-workspace {kind}', cli_move(kind))
        for scope in ('workspace_id', 'workspace_ref', 'index'):
            scenario(c, f'explicit {scope}', cli_move('ref', explicit=scope))
        scenario(c, 'window-scoped ref', cli_move('ref', explicit='workspace_id', window=True))
        scenario(c, 'window with caller workspace', cli_move('ref', window=True))
        for command, flag in [('drag-tab-to-split', '--tab'), ('drag-surface-to-split', '--surface')]:
            scenario(c, f'alias {command} {flag}', cli_move('ref', command, flag))
        scenario(c, 'v2 local focus', socket_move())
        scenario(c, 'v1 scoped ref and focus', socket_move(v1=True))
        scenario(c, 'v1 scoped UUID and focus', socket_move(v1=True, kind='id'))
        scenario(c, 'focus in another area', socket_move(), other_area=True)
        scenario(c, 'moving focused panel', socket_move(), move_focused=True)
        scenario(c, 'moving only panel', socket_move(), single=True)
        scenario(c, 'refresh sibling workspace routing', refresh, rejects=True)
        for value in ('', 'garbage', 'panel:999999', str(uuid.uuid4()), '-1'):
            scenario(c, f'reject CLI panel {value!r}', reject_cli(panel_value=value), rejects=True)
        for value in ('', 'garbage', 'workspace:999999', str(uuid.uuid4())):
            scenario(c, f'reject CLI workspace {value!r}', reject_cli(workspace_value=value), rejects=True)
        scenario(c, 'reject CLI absent workspace', reject_cli(panel_value='0', missing_workspace=True), rejects=True)
        scenario(c, 'reject CLI absent panel', reject_cli(missing_panel=True), rejects=True)
        scenario(c, 'reject panel in another workspace', reject_foreign_panel, rejects=True)
        for key in ('panel_id', 'workspace_id'):
            for value in ('', 'garbage', str(uuid.uuid4())):
                scenario(c, f'reject v2 {key} {value!r}', reject_rpc(key, value), rejects=True)
        keyboard_focus(c)
    print(f'summary checks={CHECKS} passed={CHECKS - len(FAILURES)} failed={len(FAILURES)} '
          f'elapsed_seconds={time.monotonic() - started:.1f}: {FAILURES}', flush=True)
    signal.alarm(0)
    return bool(FAILURES)


if __name__ == '__main__':
    raise SystemExit(main())
