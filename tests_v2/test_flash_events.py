#!/usr/bin/env python3
"""Flash delivery regression. Run only via scripts/sandbox-tests-v2.sh.

Checks the real sidebar renderer through its draw events. Frame-timed recording
is separate evidence: an event is not a measurement of display scanout.
"""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time

socket_path = os.environ.get('C11_SOCKET_PATH', '')
assert re.fullmatch(r'/tmp/c11-sandbox-[A-Za-z0-9._-]+\.sock', socket_path)
run = socket_path.removeprefix('/tmp/c11-sandbox-').removesuffix('.sock')
for key in list(os.environ):
    if key.startswith(('C11_SOCKET', 'CMUX_SOCKET')):
        del os.environ[key]
app_root = f'/Users/admin/c11-sandbox/apps/{run}/'
pids = [int(line.strip().split(None, 1)[0]) for line in
        subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True).splitlines()
        if app_root in line and line.endswith('/Contents/MacOS/c11')]
assert len(pids) == 1, 'exact sandbox app required'
pid = pids[0]
subprocess.run(['osascript', '-e', f'tell application "System Events" to tell (first process whose unix id is {pid}) to set frontmost to true'], check=True, timeout=10)
client = socket.socket(socket.AF_UNIX)
client.settimeout(10)
client.connect(socket_path)
reader = client.makefile('rb')
sequence = 0


def call(method, **params):
    global sequence
    sequence += 1
    client.sendall((json.dumps(dict(id=sequence, method=method, params=params))+'\n').encode())
    reply = json.loads(reader.readline())
    assert reply['id'] == sequence and reply.get('ok'), reply
    return reply['result']


def flash_events(ids):
    found = []
    for path in (Path.home()/'Library/Application Support/c11/events').glob('events-*.ndjson'):
        for line in path.read_text().splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue  # A concurrent append may leave the last line partial.
            if event.get('payload', {}).get('request_id') in ids:
                found.append(event)
    return found


try:
    initial = call('system.identify')['focused']
    source_ws = initial['workspace_id']
    for panel in call('panel.list', workspace_id=source_ws)['panels'][1:]:
        call('panel.close', workspace_id=source_ws, panel_id=panel['id'])
    target_ws = call('workspace.create', title='Flash target', window_id=initial['window_id'])['workspace_id']
    target = call('panel.list', workspace_id=target_ws)['panels'][0]['id']
    fixture = Path('/tmp/c11-flash-events.html')
    fixture.write_text('<!doctype html><title>Flash source</title><link rel="icon" href="data:,"><h1>Flash source</h1>')
    browser = call('panel.create', workspace_id=source_ws, type='browser', url=fixture.as_uri())['panel_id']
    call('panel.focus', workspace_id=source_ws, panel_id=browser)
    time.sleep(1)
    focused = call('system.identify')['focused']
    assert focused['workspace_id'] == source_ws and focused['panel_id'] == browser
    ids = []
    start = time.monotonic()
    for index in range(5):
        time.sleep(max(0, start+index*.3-time.monotonic()))
        reply = call('panel.trigger_flash', workspace_id=target_ws, panel_id=target, persistent=True)
        ids.append(reply['flash_id'])
    assert len(set(ids)) == 5 and all(ids)
    time.sleep(.5)
    call('panel.cancel_flash', workspace_id=target_ws, panel_id=target)
    events = flash_events(ids)
    for request_id in ids:
        requested = [e for e in events if e['type']=='flash.requested' and e['payload']['request_id']==request_id]
        drawn = [e for e in events if e['type']=='flash.drawn' and e['payload']['request_id']==request_id]
        assert len(requested)==len(drawn)==1, (request_id, requested, drawn)
        assert drawn[0]['workspace']==target_ws and drawn[0]['panel']==target
        assert drawn[0]['payload']['channel']=='sidebar'
        assert 0 <= drawn[0]['payload']['latency_ms'] <= 200, drawn[0]
    print('PASS five distinct rapid requests each reach the visible sidebar renderer within 200 ms')
    focused = call('system.identify')['focused']
    assert focused['workspace_id']==source_ws and focused['panel_id']==browser
    transparent = call('panel.trigger_flash', workspace_id=target_ws, panel_id=target,
                       color='#FFFF0000')['flash_id']
    time.sleep(.5)
    transparent_events = flash_events([transparent])
    assert len([e for e in transparent_events if e['type']=='flash.requested']) == 1
    assert not any(e['type']=='flash.drawn' for e in transparent_events), transparent_events
    print('PASS transparent pulse emits requested without a false drawn event')
    # New workspaces insert after the source; the original target is now below
    # the sidebar viewport. Rendering must not be claimed for that offscreen row.
    for index in range(48):
        call('workspace.create', title=f'Offscreen control {index}', window_id=initial['window_id'])
    time.sleep(1)
    hidden = call('panel.trigger_flash', workspace_id=target_ws, panel_id=target)['flash_id']
    time.sleep(2)
    hidden_events = flash_events([hidden])
    assert len([e for e in hidden_events if e['type']=='flash.requested']) == 1
    assert not any(e['type']=='flash.drawn' for e in hidden_events), hidden_events
    print('PASS offscreen row emits requested without a false drawn event')
finally:
    client.close()
