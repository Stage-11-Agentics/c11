#!/usr/bin/env python3
"""Built-CLI SessionStart socket budget (C11-580).

A c11 that takes longer than an ordinary hook's 250 ms window to answer must
still receive SessionStart's session id, journal event and agent PID, because
nothing else reports them. Other hooks keep the short window.

Hermetic Unix peer; no live app and no provider config writes.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()
import json
from pathlib import Path
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import uuid

STALL_SECONDS = 0.6
# The 2 s SessionStart window plus process start and teardown.
WORST_CASE_SECONDS = 3.0


def main():
    cli = os.environ['C11_CLI_BIN']
    with tempfile.TemporaryDirectory(prefix='c11-580-', dir='/tmp') as temporary:
        root = Path(temporary)
        address = str(root / 'peer.sock')
        seen = []
        stalled = {'pending': True}

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                while True:
                    raw = self.rfile.readline()
                    if not raw:
                        return
                    # c11 is busy: the first request of a run waits.
                    if stalled['pending']:
                        stalled['pending'] = False
                        time.sleep(STALL_SECONDS)
                    line = raw.decode().strip()
                    if not line.startswith('{'):
                        seen.append(line.split(' ', 1)[0])
                        try:
                            self.wfile.write(b'OK\n'); self.wfile.flush()
                        except BrokenPipeError:
                            return
                        continue
                    message = json.loads(line)
                    method = message['method']
                    seen.append(method)
                    if method == 'system.capabilities':
                        result = {'methods': ['panel.list', 'agent.event.append', 'conversation.push'],
                                  'features': [{'id': 'vocabulary.workspace_area_panel', 'version': 1}]}
                    elif method == 'agent.event.append':
                        result = {'event_id': message['params']['event']['event_id'], 'sequence': 1,
                                  'committed_at_ms': 1000, 'replayed': False, 'projection_effect': 'applied'}
                    else:
                        result = {}
                    response = {'id': message.get('id'), 'ok': True, 'result': result}
                    try:
                        self.wfile.write((json.dumps(response) + '\n').encode()); self.wfile.flush()
                    except BrokenPipeError:
                        return  # the hook already gave up on this request

        server = socketserver.ThreadingUnixStreamServer(address, Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()

        panel, workspace, session = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
        bundle = 'com.stage11.c11.debug.session-start-window'
        env = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
        env.update(CFFIXED_USER_HOME=str(root), HOME=str(root), CMUX_BUNDLE_ID=bundle,
                   CMUX_SURFACE_ID=panel, CMUX_WORKSPACE_ID=workspace, CMUX_CLAUDE_PID='12345',
                   C11_AGENT_INTERACTIVE_PID='12345',
                   CMUX_CLAUDE_HOOK_STATE_PATH=str(root / 'hook-sessions.json'))
        spool = root / 'Library/Application Support/c11/journal' / bundle / 'spool'

        def hook(subcommand):
            seen.clear()
            stalled['pending'] = True
            start = time.monotonic()
            result = subprocess.run(
                [cli, '--socket', address, 'claude-hook', subcommand],
                input=json.dumps({'session_id': session, 'cwd': str(root), 'source': 'startup'}),
                text=True, capture_output=True, env=env, timeout=10)
            return result, time.monotonic() - start

        try:
            result, elapsed = hook('session-start')
            assert result.returncode == 0, result.stderr
            assert 'conversation.push' in seen, f'session id never sent: {seen}'
            assert 'agent.event.append' in seen, f'journal event never sent: {seen}'
            assert 'set_agent_pid' in seen, f'agent PID never sent: {seen}'
            assert not list(spool.glob('*.ready')), 'SessionStart was spooled'
            assert 'additionalContext' in result.stdout
            print(f'PASS session-start survives a {STALL_SECONDS} s stall ({elapsed:.2f} s)')

            result, elapsed = hook('prompt-submit')
            assert result.returncode == 0, result.stderr
            assert 'agent.event.append' not in seen, f'ordinary hook outlived its window: {seen}'
            assert elapsed < STALL_SECONDS + 0.4, f'ordinary hook took {elapsed:.2f} s'
            assert list(spool.glob('*.ready')), 'ordinary hook did not spool its event'
            print(f'PASS ordinary hook keeps its short window ({elapsed:.2f} s)')

            # Worst case: c11 accepts the connection and never answers.
            hung_address = str(root / 'hung.sock')
            hung_conns = []
            hung = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            hung.bind(hung_address); hung.listen(8)
            def accept_forever():
                while True:
                    try:
                        conn, _ = hung.accept()
                    except OSError:
                        return
                    hung_conns.append(conn)
            threading.Thread(target=accept_forever, daemon=True).start()
            start = time.monotonic()
            result = subprocess.run(
                [cli, '--socket', hung_address, 'claude-hook', 'session-start'],
                input=json.dumps({'session_id': session, 'cwd': str(root), 'source': 'startup'}),
                text=True, capture_output=True, env=env, timeout=10)
            elapsed = time.monotonic() - start
            assert result.returncode == 0, result.stderr
            assert elapsed < WORST_CASE_SECONDS, f'hung c11 held session-start {elapsed:.2f} s'
            print(f'PASS hung c11 holds session-start at most {elapsed:.2f} s (bound {WORST_CASE_SECONDS} s)')
            hung.close()

            # A socket file with no listener refuses at once.
            dead_address = str(root / 'dead.sock')
            dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            dead.bind(dead_address); dead.close()
            start = time.monotonic()
            result = subprocess.run(
                [cli, '--socket', dead_address, 'claude-hook', 'session-start'],
                input=json.dumps({'session_id': session, 'cwd': str(root), 'source': 'startup'}),
                text=True, capture_output=True, env=env, timeout=10)
            elapsed = time.monotonic() - start
            assert result.returncode == 0, result.stderr
            assert elapsed < 1.0, f'dead socket held session-start {elapsed:.2f} s'
            print(f'PASS dead socket returns at once ({elapsed:.2f} s)')
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
