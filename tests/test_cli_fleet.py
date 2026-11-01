#!/usr/bin/env python3
"""Fleet is one app-wide request, including when caller/window env is present."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

from fake_server_env import fake_server_env


def main():
    cli = os.environ['C11_CLI']
    fixture = {'schema_version': 1, 'scope': 'agents', 'panels': [
        {'panel_id': '11111111-2222-4333-8444-555555555555', 'panel_title': 'Fleet\x1b[31m\nAgent',
         'workspace_title': 'Hidden workspace', 'agent_type': 'codex', 'model': None,
         'lifecycle': 'working', 'flag': False, 'mailbox_unread_count': 3}]}
    with tempfile.TemporaryDirectory(prefix='c11-fleet-') as directory:
        path = str(Path(directory) / 'fixture.sock')
        requests, errors = [], []
        stopped = threading.Event()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(8)
        server.settimeout(.1)

        def serve():
            while not stopped.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                try:
                    with conn, conn.makefile('rwb') as stream:
                        for line in stream:
                            if not line.startswith(b'{'):
                                stream.write(b'OK\n'); stream.flush(); continue
                            request = json.loads(line)
                            requests.append(request)
                            response = {'id': request['id'], 'ok': True, 'result': fixture}
                            stream.write((json.dumps(response) + '\n').encode())
                            stream.flush()
                except Exception as error:
                    errors.append(repr(error))
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        env = fake_server_env(path)
        env.update(C11_PANEL_ID='77777777-2222-4333-8444-555555555555', C11_QUIET_DISCOVERY='1',
                   C11_WORKSPACE_ID='88888888-2222-4333-8444-555555555555')

        def run(args):
            return subprocess.run([cli, '--socket', path, *args], env=env,
                                  capture_output=True, text=True, timeout=10)
        try:
            for args in [['fleet', '--json'], ['--json', 'fleet'], ['--window', 'window:999', 'fleet', '--json']]:
                before = len(requests)
                result = run(args)
                assert result.returncode == 0, result.stderr
                assert json.loads(result.stdout) == fixture, result.stdout
                actual = requests[before:]
                assert len(actual) == 1 and actual[0]['method'] == 'system.fleet' and actual[0]['params'] == {}, actual
            result = run(['fleet'])
            assert result.returncode == 0, result.stderr
            assert 'workspace_title' in result.stdout and 'Hidden workspace' in result.stdout
            assert 'working' in result.stdout and '\x1b' not in result.stdout
            assert len(result.stdout.splitlines()) == 2, result.stdout
            for args in [['fleet', '--workspace', 'workspace:1'], ['fleet', 'extra'], ['fleet', '--bogus']]:
                before = len(requests)
                result = run(args)
                assert result.returncode != 0, args
                assert len(requests) == before, requests[before:]
            assert not errors, errors
            print('PASS: fleet JSON/table; one request; all-window scope; control escaping; argument preflight')
        finally:
            stopped.set(); worker.join(timeout=2); server.close()


if __name__ == '__main__':
    main()
