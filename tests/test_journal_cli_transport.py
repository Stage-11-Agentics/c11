#!/usr/bin/env python3
"""Built-CLI journal transport: auth, lost ack/spool, permanent errors and privacy.

Hermetic Unix peer on Atlas; no live app and no provider config writes.
"""
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time
import uuid


def main():
    cli = os.environ['C11_CLI_BIN']
    with tempfile.TemporaryDirectory(prefix='c11-journal-transport-', dir='/tmp') as temporary:
        root = Path(temporary)
        address = str(root / 'peer.sock')
        calls = []
        mode = 'commit'
        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                for line in self.rfile:
                    if line.startswith(b'auth '):
                        # Do not retain or print credential bytes.
                        calls.append('auth')
                        self.wfile.write(b'OK\n'); self.wfile.flush(); continue
                    message = json.loads(line)
                    calls.append(message)
                    method = message['method']
                    if method == 'system.capabilities':
                        response = {'ok': True, 'result': {'methods': ['panel.list', 'agent.event.append'],
                                                                'features': [{'id': 'vocabulary.workspace_area_panel', 'version': 1}]}}
                    elif mode == 'stall':
                        time.sleep(2)
                        return
                    elif mode in ('method_not_found', 'idempotency_conflict', 'expired'):
                        response = {'ok': False, 'error': {'code': mode, 'message': mode}}
                    else:
                        event = message['params']['event']
                        response = {'ok': True, 'result': {'event_id': event['event_id'], 'sequence': 7,
                                    'committed_at_ms': 1000, 'replayed': False, 'projection_effect': 'applied'}}
                    self.wfile.write((json.dumps(response) + '\n').encode()); self.wfile.flush()
        server = socketserver.ThreadingUnixStreamServer(address, Handler)
        server.daemon_threads = True
        worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
        env = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
        bundle = 'com.stage11.c11.debug.journal-transport'
        env.update(CFFIXED_USER_HOME=str(root), CMUX_BUNDLE_ID=bundle, C11_AGENT_INTERACTIVE_PID='12345')
        spool = root / 'Library/Application Support/c11/journal' / bundle / 'spool'
        draft = {'schema_version': 1, 'event_id': str(uuid.uuid4()), 'kind': 'agent.turn.started',
                 'emitted_at_ms': int(time.time() * 1000), 'tab_id': str(uuid.uuid4()),
                 'workspace_id': str(uuid.uuid4()), 'session_id': 'synthetic-root', 'agent_kind': 'claude-code',
                 'source': 'hook', 'adapter': 'claude_hook', 'native_event': 'UserPromptSubmit'}
        def run(event):
            start = time.monotonic()
            result = subprocess.run([cli, '--socket', address, '--password', 'synthetic-fixture-password',
                                     'agent-event', 'append', '--stdin'], input=json.dumps(event), text=True,
                                    capture_output=True, env=env, timeout=2)
            return result, (time.monotonic() - start) * 1000
        try:
            result, ms = run(draft)
            assert result.returncode == 0, result.stderr
            assert json.loads(result.stdout)['sequence'] == 7
            assert calls[0] == 'auth'
            append = next(c for c in calls if isinstance(c, dict) and c['method'] == 'agent.event.append')
            assert append['params']['interactive_pid'] == 12345
            assert 'interactive_pid' not in append['params']['event']
            print(f'PASS authenticated commit and transport-only PID ({ms:.1f} ms)')
            for failure in ('method_not_found', 'idempotency_conflict', 'expired'):
                mode = failure
                result, _ = run(draft)
                assert result.returncode != 0 and failure in result.stderr
                assert not list(spool.glob('*.ready')), 'permanent rejection was spooled'
            print('PASS explicit unsupported/conflict/expired are returned without spooling')
            before = len(calls)
            result, _ = run({**draft, 'body': 'PRIVATE-SENTINEL'})
            assert result.returncode != 0 and len(calls) == before
            print('PASS body rejected before connecting')
            mode = 'stall'
            result, ms = run(draft)
            assert result.returncode == 0 and json.loads(result.stdout)['spooled'], result.stderr
            # The 250 ms transport deadline plus process startup and best-effort spool.
            assert ms < 1000, f'process exceeded fixture allowance: {ms:.1f}ms'
            files = list(spool.glob('*.ready'))
            assert len(files) == 1, 'spool must be under the isolated Foundation home'
            saved = json.loads(files[0].read_text())
            assert saved['event_id'].lower() == draft['event_id']
            assert 'interactive_pid' not in saved
            assert 'synthetic-fixture-password' not in files[0].read_text()
            print(f'PASS ambiguous timeout spools original structural identity ({ms:.1f} ms)')
        finally:
            server.shutdown(); server.server_close(); worker.join(timeout=3)


if __name__ == '__main__':
    main()
