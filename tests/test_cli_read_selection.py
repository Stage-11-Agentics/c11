#!/usr/bin/env python3
"""C11-282: built CLI accepts the skill's trailing --json argv, without an app."""
import base64
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
from fake_server_env import fake_server_env


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        while line := self.rfile.readline():
            if not line.startswith(b'{'):
                response = 'OK'
            else:
                request = json.loads(line)
                method = request['method']
                if method == 'system.capabilities':
                    result = {'methods': ['tab.list', 'tab.read_selection']}
                else:
                    assert method == 'tab.read_selection', method
                    self.server.requests.append(request['params'])
                    result = self.server.selection
                response = json.dumps({'id': request['id'], 'ok': True, 'result': result})
            self.wfile.write((response+'\n').encode())
            self.wfile.flush()


def main():
    cli = os.environ['C11_CLI_BIN']
    with tempfile.TemporaryDirectory(prefix='c11-selection-cli-') as directory:
        path = str(Path(directory)/'fixture.sock')
        with socketserver.ThreadingUnixStreamServer(path, Handler) as server:
            server.daemon_threads = True
            server.requests = []
            server.selection = {'kind': 'terminal', 'has_selection': True,
                'text': 'SELECTIONFIXTURE', 'base64': base64.b64encode(b'SELECTIONFIXTURE').decode(),
                'truncated': False}
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                def run(args):
                    return subprocess.run([cli, '--socket', path, *args], env=fake_server_env(path),
                                          capture_output=True, text=True, timeout=10)
                for args in [['read-selection', '--tab', 'tab:2', '--json'],
                             ['--json', 'read-selection', '--tab', 'tab:2']]:
                    result = run(args)
                    assert result.returncode == 0, result.stderr
                    assert json.loads(result.stdout) == server.selection, result.stdout
                    assert server.requests[-1] == {'tab_id': 'tab:2'}, server.requests[-1]
                result = run(['read-selection', '--tab', 'tab:2'])
                assert result.returncode == 0 and result.stdout == 'SELECTIONFIXTURE\n'
                server.selection.update(has_selection=False, text='', base64='')
                result = run(['read-selection', '--tab', 'tab:2', '--json'])
                assert result.returncode == 0 and json.loads(result.stdout) == server.selection
                count = len(server.requests)
                result = run(['read-selection', '--tab', 'tab:2', '--json', '--bad-flag'])
                assert result.returncode != 0 and 'unexpected arguments' in result.stderr
                assert len(server.requests) == count
                print('PASS: exact skill trailing --json argv, global --json, human/empty output and unknown flag rejection')
            finally:
                server.shutdown()
                worker.join(timeout=2)


if __name__ == '__main__':
    main()
