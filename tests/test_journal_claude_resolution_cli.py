#!/usr/bin/env python3
"""Exercise built Claude callbacks against an isolated accepting socket peer.

Verifies producer correlation and compatibility status writes, not app folding.
Run on the build host with C11_CLI_BIN pointing at this branch's built CLI.
"""
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time

WORKSPACE = '11111111-1111-4111-8111-111111111111'
TAB = '22222222-2222-4222-8222-222222222222'


def main():
    cli = os.environ['C11_CLI_BIN']
    # Warm dyld/code-signing caches before measuring the socket deadline.
    subprocess.run([cli, '--version'], check=True, capture_output=True, timeout=5)
    calls = []
    stall_clear = False
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            for line in self.rfile:
                command = line.decode().strip()
                if command.startswith('auth '):
                    self.wfile.write(b'OK\n'); self.wfile.flush(); continue
                if command.startswith('{'):
                    request = json.loads(command)
                    if request['method'] == 'system.capabilities':
                        response = {'id': request['id'], 'ok': True, 'result': {
                            'methods': ['panel.list', 'agent.event.append'],
                            'features': [{'id': 'vocabulary.workspace_area_panel', 'version': 1}]}}
                        self.wfile.write((json.dumps(response) + '\n').encode())
                        self.wfile.flush()
                        continue
                    assert request['method'] == 'agent.event.append', request['method']
                    calls.append(request)
                    response = {'id': request['id'], 'ok': True, 'result': {
                        'event_id': request['params']['event']['event_id'], 'sequence': len(calls),
                        'committed_at_ms': 1, 'replayed': False, 'projection_effect': 'applied'}}
                    self.wfile.write((json.dumps(response) + '\n').encode())
                else:
                    calls.append(command)
                    if stall_clear and command.startswith('clear_notifications '):
                        time.sleep(0.5)
                        return
                    self.wfile.write(b'OK\n')
                self.wfile.flush()
    with tempfile.TemporaryDirectory(prefix='c11-resolution-', dir='/tmp') as temporary:
        root = Path(temporary); address = str(root / 'peer.sock')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
        env.update(CMUX_CLAUDE_HOOK_STATE_PATH=str(root / 'state.json'),
                   CMUX_CLI_SENTRY_DISABLED='1', CMUX_CLAUDE_HOOK_SENTRY_DISABLED='1',
                   CMUX_SOCKET_PASSWORD='synthetic-responsive-secret',
                   CMUX_BUNDLE_ID='com.stage11.c11.resolution-test',
                   CFFIXED_USER_HOME=str(root), HOME=str(root))
        server = socketserver.ThreadingUnixStreamServer(address, Handler)
        server.daemon_threads = True
        worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
        try:
            for event, tool in [('post-tool-use', 'AskUserQuestion'), ('post-tool-use', 'ExitPlanMode'),
                                ('pre-tool-use', 'Bash')]:
                calls.clear()
                started = time.monotonic()
                result = subprocess.run([cli, '--socket', address, 'claude-hook', event,
                    '--workspace', WORKSPACE, '--tab', TAB], env=env, text=True, capture_output=True,
                    input=json.dumps({'session_id': 'synthetic-resolution', 'prompt_id': 'turn-a',
                        'tool_use_id': 'request-a', 'tool_name': tool,
                        'tool_response': {'body': 'PRIVATE-SENTINEL'}}), timeout=10)
                elapsed = time.monotonic() - started
                assert result.returncode == 0, result.stderr
                assert elapsed < 0.250, (tool, elapsed)
                appends = [c for c in calls if isinstance(c, dict)]
                assert len(appends) == 1, calls
                draft = appends[0]['params']['event']
                assert draft['turn_id'] == 'turn-a' and draft['request_id'] == 'request-a'
                assert 'PRIVATE-SENTINEL' not in json.dumps(appends)
                if event == 'post-tool-use':
                    assert draft['kind'] == 'agent.attention.resolved'
                    assert draft['native_event'] == 'PostToolUse' and draft['resolution'] == 'resumed'
                else:
                    assert draft['kind'] == 'agent.state.changed' and draft['signal'] == 'tool_activity'
                legacy = [c for c in calls if isinstance(c, str)]
                assert any(c.startswith('set_status ') and 'Running' in c for c in legacy), legacy
                assert any(c.startswith('clear_notifications ') for c in legacy), legacy
                assert not any(c.startswith('report_agent_activity ') for c in legacy), legacy
                print(f'PASS authenticated responsive {event}/{tool}: wall_ms={elapsed * 1000:.1f} budget_ms=250')
            calls.clear()
            ordinary = subprocess.run([cli, '--socket', address, 'claude-hook', 'post-tool-use',
                '--workspace', WORKSPACE, '--tab', TAB], env=env, text=True, capture_output=True,
                input=json.dumps({'session_id': 'synthetic-resolution', 'prompt_id': 'turn-a',
                    'tool_use_id': 'tool-9', 'tool_name': 'Bash',
                    'tool_response': {'body': 'PRIVATE-SENTINEL'}}), timeout=10)
            assert ordinary.returncode == 0, ordinary.stderr
            assert ordinary.stdout.strip() == 'OK', ordinary.stdout
            ordinary_appends = [c for c in calls if isinstance(c, dict)]
            assert len(ordinary_appends) == 1, calls
            ordinary_draft = ordinary_appends[0]['params']['event']
            assert ordinary_draft['kind'] == 'agent.state.changed'
            assert ordinary_draft['signal'] == 'tool_activity'
            assert ordinary_draft['native_event'] == 'PostToolUse'
            assert 'PRIVATE-SENTINEL' not in json.dumps(ordinary_appends)
            ordinary_legacy = [c for c in calls if isinstance(c, str)]
            assert not any(c.startswith('clear_notifications ') for c in ordinary_legacy), ordinary_legacy
            assert not any(c.startswith('set_status ') for c in ordinary_legacy), ordinary_legacy
            assert not any(c.startswith('report_agent_activity ') for c in ordinary_legacy), ordinary_legacy
            stall_clear = True
            spool = root / 'Library/Application Support/c11/journal/com.stage11.c11.resolution-test/spool'
            for tool in ('AskUserQuestion', 'ExitPlanMode'):
                calls.clear()
                prior_files = set(spool.glob('*.ready'))
                started = time.monotonic()
                stalled = subprocess.run([cli, '--socket', address, 'claude-hook', 'post-tool-use',
                    '--workspace', WORKSPACE, '--tab', TAB], env=env, text=True, capture_output=True,
                    input=json.dumps({'session_id': 'synthetic-resolution', 'prompt_id': 'turn-a',
                        'tool_use_id': 'request-a', 'tool_name': tool,
                        'tool_response': {'body': 'PRIVATE-SENTINEL'}}), timeout=2)
                elapsed = time.monotonic() - started
                assert stalled.returncode == 0, stalled.stderr
                assert stalled.stdout.strip() in ('', 'OK'), stalled.stdout
                # Includes process startup and atomic spool fsync in addition to
                # the 250 ms socket budget. Record the actual wall time.
                assert elapsed < 0.350, (tool, elapsed)
                committed = [c['params']['event'] for c in calls if isinstance(c, dict)]
                retained = [json.loads(p.read_text()) for p in set(spool.glob('*.ready')) - prior_files]
                assert len(committed) + len(retained) == 1, (calls, retained)
                draft = (committed + retained)[0]
                assert draft['kind'] == 'agent.attention.resolved'
                assert draft['resolution'] == 'resumed' and draft['request_id'] == 'request-a'
                assert 'PRIVATE-SENTINEL' not in json.dumps(draft)
                print(f'PASS authenticated stalled clear/{tool}: wall_ms={elapsed * 1000:.1f} socket_budget_ms=250 retained={len(retained)}')
            print('PASS correlated ask/plan resolution and status writes after successful journal append')
        finally:
            server.shutdown(); server.server_close(); worker.join(timeout=3)


if __name__ == '__main__':
    main()
