#!/usr/bin/env python3
"""C11-282, isolated tagged/sandbox artifact only.

setup creates a neutral terminal; word drives a verified mouse drag twenty
 times; large selects Unicode scrollback with real UI input and measures reads.
UI phases require PID/window-scoped tests/ghostty_patchset/ui-driver.m and run
only in a sandbox guest. Coordinates are window-local, established by screenshot.
All phases have a twelve-minute cap. cleanup closes the disposable workspace.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import subprocess
import time
import uuid
from cmux import cmux, cmuxError


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['setup', 'boundaries', 'word', 'large', 'copy', 'cleanup'])
    parser.add_argument('--coordinates', nargs=4, type=float)
    parser.add_argument('--state', default='/tmp/c11-282-fixture.json')
    parser.add_argument('--baseline', action='store_true')
    args = parser.parse_args()
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('fixture twelve-minute limit')))
    signal.alarm(720)
    target = os.environ['C11_282_SOCKET']
    assert re.fullmatch(r'/tmp/c11-(?:debug|sandbox)-[^/]+\.sock', target), 'explicit isolated socket required'
    state_path = Path(args.state)
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    cli = os.environ['C11_CLI']

    def ui(command, *extra):
        assert target.startswith('/tmp/c11-sandbox-'), 'mouse/activation requires sandbox guest'
        driver = os.environ['C11_282_UI_DRIVER']
        pid, tag, window = (os.environ[key] for key in ('C11_282_PID', 'C11_282_TAG', 'C11_282_WINDOW'))
        subprocess.run([driver, 'check', pid, tag, window], check=True, stdout=subprocess.DEVNULL, timeout=10)
        front = subprocess.check_output(['osascript', '-e', 'tell application "System Events" to get unix id of first application process whose frontmost is true'], timeout=10).decode().strip()
        assert front == pid, 'verified tagged app must be frontmost in isolated guest'
        if command in ('drag', 'click'):
            observed = json.loads(subprocess.check_output([driver, 'list', pid, tag], timeout=10))
            bounds = next(row['kCGWindowBounds'] for row in observed['windows'] if str(row['kCGWindowNumber']) == window)
            def point(x,y): return f'{round(bounds["X"]+x)},{round(bounds["Y"]+y)}'
            if command == 'drag':
                x1,y1,x2,y2 = extra
                events = ['dd:'+point(x1,y1), 'w:100', 'dm:'+point(x2,y2), 'w:100', 'du:'+point(x2,y2)]
            else: events = ['c:'+point(*extra)]
            subprocess.run(['/opt/homebrew/bin/cliclick', *events], check=True, timeout=10)
            return {}
        return json.loads(subprocess.check_output([driver, command, pid, tag, window, *map(str, extra)], timeout=10))

    with cmux(target) as client:
        def read():
            # Preserve UTF-8 across recv boundaries; the legacy helper decodes
            # each chunk separately and can corrupt large Unicode responses.
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(10)
                connection.connect(target)
                request = {'id': 1, 'method': 'tab.read_selection', 'params':
                           {'workspace_id': state['workspace'], 'tab_id': state['tab']}}
                connection.sendall((json.dumps(request)+'\n').encode())
                chunks = bytearray()
                while b'\n' not in chunks:
                    chunk = connection.recv(65536)
                    assert chunk, 'socket closed before complete response'
                    chunks.extend(chunk)
                response = json.loads(chunks)
                if not response['ok']:
                    raise cmuxError(response['error']['code']+': '+response['error']['message'])
                return response['result']

        def parity(value):
            assert value['kind'] == 'terminal'
            assert base64.b64decode(value['base64']) == value['text'].encode('utf-8'), 'selection text/base64 mismatch'

        def screen():
            return client._call('tab.read_text', {'workspace_id': state['workspace'], 'tab_id': state['tab']})['text']

        def send(text):
            client._call('tab.send_text', {'workspace_id': state['workspace'], 'tab_id': state['tab'], 'text': text, 'submit': True})

        def wait_marker(marker):
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if marker in screen(): return
                time.sleep(.1)
            raise AssertionError('fixture output not ready: ' + marker)

        def reject(params, code=None):
            try:
                client._call('tab.read_selection', params)
            except cmuxError as error:
                if code: assert code in str(error), str(error)
                return
            raise AssertionError('bad target was accepted')

        if args.phase == 'setup':
            state['workspace'] = client._call('workspace.create', {'title': 'Selection fixture'})['workspace_id']
            client._call('workspace.select', {'workspace_id': state['workspace']})
            state['tab'] = client._call('tab.list', {'workspace_id': state['workspace']})['tabs'][0]['id']
            state_path.write_text(json.dumps(state))
            # Neutral prompt and cleared scrollback, including any startup banner.
            send("export PS1='$ '; printf '\\033[H\\033[2J\\033[3JSELECTIONFIXTURE\\n'")
            wait_marker('SELECTIONFIXTURE')
            if not args.baseline:
                value = read(); parity(value)
                assert not value['has_selection'] and value['text'] == '' and not value['truncated']
                cap = client._call('system.capabilities')
                assert 'tab.read_selection' in cap['methods']
                assert any(row['id'] == 'read_selection.terminal' and row['version'] == 1 for row in cap['features'])
            print('PASS: neutral fixture ready; no-selection and discovery' if not args.baseline else 'PASS: baseline fixture ready')
            print(json.dumps(state))

        elif args.phase == 'boundaries':
            before = screen()
            for key in ['tab_id', 'workspace_id', 'window_id']:
                reject({key: ''}, 'invalid_params')
                reject({key: 'tab:999999999'}, 'invalid_params')
                reject({key: str(uuid.uuid4())}, 'not_found')
            for extra in [[], ['--tab', ''], ['--workspace', ''], ['--bad-flag']]:
                result = subprocess.run([cli, '--socket', target, 'read-selection', '--workspace', state['workspace'], '--tab', state['tab'], *extra], capture_output=True, text=True, timeout=10)
                if extra: assert result.returncode != 0, extra
                else: assert result.returncode == 0 and result.stdout.strip() == 'No selection.', result
            browser = client._call('tab.create', {'workspace_id': state['workspace'], 'type': 'browser', 'url': 'about:blank'})['tab_id']
            try:
                instrument = {'workspace_id': state['workspace'], 'tab_id': browser,
                    'script': 'window.selectionReadCalls=0;document.getSelection=()=>{window.selectionReadCalls++;return null};window.getSelection=document.getSelection;0'}
                client._call('browser.eval', instrument)
                reject({'workspace_id': state['workspace'], 'tab_id': browser}, 'invalid_params')
                observed = client._call('browser.eval', {'workspace_id': state['workspace'], 'tab_id': browser, 'script': 'window.selectionReadCalls'})
                assert observed['value'] == 0, observed
            finally:
                client._call('tab.close', {'workspace_id': state['workspace'], 'tab_id': browser})
            path = Path('/tmp/c11-282-selection.md'); path.write_text('# Selection fixture\n')
            markdown = client._call('tab.create', {'workspace_id': state['workspace'], 'type': 'markdown', 'file': str(path)})['tab_id']
            try:
                reject({'workspace_id': state['workspace'], 'tab_id': markdown}, 'invalid_params')
            finally:
                client._call('tab.close', {'workspace_id': state['workspace'], 'tab_id': markdown})
            legacy = client._call('surface.read_selection', {'workspace_id': state['workspace'], 'surface_id': state['tab']})
            parity(legacy); assert not legacy['has_selection']
            assert screen() == before, 'read or invalid target changed terminal'
            print('PASS: no selection, CLI output/errors, empty/stale targets, terminal-only and legacy worker route')

        elif args.phase == 'word':
            assert args.coordinates, 'screenshot-derived drag coordinates required'
            x1,y1,x2,y2 = args.coordinates
            ui('check')
            for iteration in range(20):
                ui('drag', x1,y1,x2,y2)
                value = read(); parity(value)
                assert value['has_selection'] and value['text'] == 'SELECTIONFIXTURE', repr(value['text'])
                assert not value['truncated']
                assert read()['text'] == value['text'], 'reader changed selection'
                result = subprocess.run([cli, '--socket', target, '--json', 'read-selection', '--workspace', state['workspace'], '--tab', state['tab']], capture_output=True, text=True, check=True, timeout=10)
                assert json.loads(result.stdout)['text'] == 'SELECTIONFIXTURE'
                ui('click', x2+20,y2)
                assert not read()['has_selection'], 'click did not clear selection'
            print('PASS: twenty real mouse select/read/read/CLI/clear cycles; word byte parity; process remains live')

        elif args.phase in ('large', 'copy'):
            body = "import sys;sys.stdout.write('\\033[H\\033[2J\\033[3J');sys.stdout.write(''.join('%06d '%i+('a'+'\\u0301'*8)*80+'\\n' for i in range(20000)));sys.stdout.write(''.join(map(chr,[76,65,82,71,69,95,83,69,76,69,67,84,73,79,78,95,82,69,65,68,89]))+'\\n');sys.stdout.flush()"
            if args.phase == 'large':
                send('python3 -c ' + shlex.quote(body))
                wait_marker('LARGE_SELECTION_READY')
            ui('check'); ui('key', 'a', 'cmd')
            timings=[]; lengths=[]; busy_timings=[]; clipped=[]
            if not args.baseline:
                for _ in range(30):
                    start=time.monotonic()
                    try: value=read()
                    except cmuxError as error:
                        assert str(error).startswith('busy:'), str(error)
                        busy_timings.append((time.monotonic()-start)*1000)
                        continue
                    timings.append((time.monotonic()-start)*1000)
                    parity(value); assert value['has_selection']
                    clipped.append(value['truncated'])
                    assert len(value['text'].encode()) <= 1048576
                    lengths.append(len(value['text'].encode()))
                assert timings, 'no successful large selection read'
                Path('/tmp/c11-282-selection-measurement.json').write_text(json.dumps({'caller_ms':timings, 'busy_ms':busy_timings, 'response_bytes':lengths, 'truncated':clipped, 'native_main_residual':'formatting/allocation unbounded; see debug stage timings', 'soak_gate':'not performed'}))
                print('PASS: large native user selection, capped UTF-8 response; thirty attempts without selection mutation; typed renderer BUSY allowed')
            # The existing native copy user path is comparable on both artifacts.
            copy_timings=[]; native_lengths=[]
            for _ in range(20):
                subprocess.run(['pbcopy'],input=b'COPY_PENDING',check=True)
                start=time.monotonic(); ui('key','c','cmd')
                deadline=time.monotonic()+10
                while time.monotonic()<deadline:
                    copied=subprocess.check_output(['pbpaste'])
                    if copied and copied != b'COPY_PENDING':break
                    time.sleep(.01)
                else:raise AssertionError('native copy did not complete')
                copy_timings.append((time.monotonic()-start)*1000);native_lengths.append(len(copied))
                assert len(copied)>=524288, len(copied)
            Path('/tmp/c11-282-copy-measurement.json').write_text(json.dumps({'copy_caller_ms':copy_timings,'native_selection_bytes':native_lengths,'includes':'PID event driver process and pasteboard oracle overhead; preliminary, not a typing/soak pass'}))
            print('PASS: same native copy UI path sampled; native selection byte count recorded (at least 512 KiB)')

        elif args.phase == 'cleanup':
            if state.get('workspace'):client.close_workspace(state['workspace'])
            state_path.unlink(missing_ok=True)
            print('PASS: disposable workspace removed')
    signal.alarm(0)


if __name__ == '__main__':
    main()
