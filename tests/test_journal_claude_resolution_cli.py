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

WORKSPACE = '11111111-1111-4111-8111-111111111111'
TAB = '22222222-2222-4222-8222-222222222222'


def main():
    cli = os.environ['C11_CLI_BIN']
    calls = []
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
                            'methods': ['tab.list', 'agent.event.append']}}
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
                    self.wfile.write(b'OK\n')
                self.wfile.flush()
    with tempfile.TemporaryDirectory(prefix='c11-resolution-', dir='/tmp') as temporary:
        root = Path(temporary); address = str(root / 'peer.sock')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
        env.update(CMUX_CLAUDE_HOOK_STATE_PATH=str(root / 'state.json'),
                   CMUX_CLI_SENTRY_DISABLED='1', CMUX_CLAUDE_HOOK_SENTRY_DISABLED='1',
                   CFFIXED_USER_HOME=str(root), HOME=str(root))
        server = socketserver.ThreadingUnixStreamServer(address, Handler)
        server.daemon_threads = True
        worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
        try:
            for event, tool in [('post-tool-use', 'AskUserQuestion'), ('post-tool-use', 'ExitPlanMode'),
                                ('pre-tool-use', 'Bash')]:
                calls.clear()
                result = subprocess.run([cli, '--socket', address, 'claude-hook', event,
                    '--workspace', WORKSPACE, '--tab', TAB], env=env, text=True, capture_output=True,
                    input=json.dumps({'session_id': 'synthetic-resolution', 'prompt_id': 'turn-a',
                        'tool_use_id': 'request-a', 'tool_name': tool,
                        'tool_response': {'body': 'PRIVATE-SENTINEL'}}), timeout=10)
                assert result.returncode == 0, result.stderr
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
            print('PASS correlated ask/plan resolution and status writes after successful journal append')
        finally:
            server.shutdown(); server.server_close(); worker.join(timeout=3)


if __name__ == '__main__':
    main()
