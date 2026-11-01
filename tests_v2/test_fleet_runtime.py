#!/usr/bin/env python3
"""C11-549: 50 workspaces, 200 synthetic agent terminals and real typing in a guest.

Only sandbox-tests-v2.sh may run this probe. Tagged PID/display checks precede
input. Active phase is capped at 180 seconds; hard exit including cleanup 225s.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import threading
import time

from attention_menu_bar_probe import Probe


class FleetProbe(Probe):
    def __init__(self, args):
        super().__init__(args)
        self.deadline = self.started + 180
        self.created = []
        self.stop = threading.Event()
        self.poller = None
        self.samples = []
        self.poll_errors = []

    def timeout(self):
        remaining = self.started + (215 if self.cleanup_mode else 180) - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Fleet probe deadline reached')
        return min(8, remaining)

    def text(self):
        reply = self.rpc('panel.read_text', {'workspace_id': self.control_workspace, 'panel_id': self.control})
        return reply.get('text') or base64.b64decode(reply.get('base64') or '').decode(errors='replace')

    def key(self, text=None):
        self.check(self.ui('foreground') == self.args.pid, 'Tagged PID is foreground before input')
        action = 'keystroke "' + text + '"' if text else 'keystroke "u" using control down'
        script = 'tell application "System Events"\nset p to first process whose unix id is %d\n' \
                 'if not frontmost of p then error "Tagged PID is not foreground"\n' \
                 'tell p to %s\nend tell' % (self.args.pid, action)
        self.run(['/usr/bin/osascript', '-e', script])

    def typing(self):
        self.key()
        token = 'fleettyping' * 4
        started = time.monotonic()
        self.key(token)
        self.eventually(lambda: token in self.text(), 'Typed burst did not echo', seconds=3)
        elapsed = (time.monotonic() - started) * 1000
        return elapsed

    def execute(self):
        self.preflight()
        caps = self.rpc('system.capabilities')
        self.check({'id': 'fleet', 'version': 1} in caps['features'], 'Fleet capability advertised')
        focused = self.rpc('system.identify')['focused']
        self.control_workspace = focused['workspace_id']
        self.control = focused['panel_id']
        window = self.report['display_enumeration']['windows'][0]['kCGWindowBounds']
        self.run(['/opt/homebrew/bin/cliclick', 'c:%d,%d' % (window['X'] + 550, window['Y'] + 200)])
        self.eventually(lambda: self.rpc('debug.terminal.is_focused', {'panel_id': self.control}).get('focused'),
                        'Terminal click did not establish first responder')
        baseline = [self.typing() for _ in range(3)]
        self.key()
        ids = []
        for index in range(50):
            if index == 0:
                workspace = self.control_workspace
                terminals = []
            else:
                workspace = self.rpc('workspace.create', {'initial_command': '/bin/sleep 300',
                    'working_directory': '/tmp'})['workspace_id']
                self.created.append(workspace)
                terminals = [self.rpc('panel.list', {'workspace_id': workspace})['panels'][0]['id']]
            for _ in range(4 - len(terminals)):
                terminals.append(self.rpc('panel.create', {'workspace_id': workspace, 'type': 'terminal',
                    'focus': False, 'initial_input': 'exec /bin/sleep 300'})['panel_id'])
            for panel in terminals:
                ids.append(panel)
                self.rpc('panel.set_metadata', {'workspace_id': workspace, 'panel_id': panel,
                    'metadata': {'terminal_type': 'codex', 'model': 'synthetic-fleet',
                                 'description': 'Synthetic sleeping terminal for fleet load'}, 'source': 'explicit'})
        before = self.rpc('system.identify')['focused']
        document = self.rpc('system.fleet')
        self.check(set(ids) == {p['panel_id'] for p in document['panels']}, 'All 200 synthetic agent terminals included')
        self.check(document['workspace_count'] == 50, 'All 50 workspaces included')
        (self.output / 'fleet.json').write_text(json.dumps(document, indent=2) + '\n')
        self.check(self.control not in {p['panel_id'] for p in document['panels']}, 'Plain typing terminal excluded')
        def poll():
            try:
                while not self.stop.is_set():
                    start = time.monotonic()
                    doc = self.rpc('system.fleet')
                    self.samples.append({'request_ms': (time.monotonic() - start) * 1000,
                                         'main_ms': doc['main_copy_duration_ms'], 'panels': len(doc['panels'])})
                    self.stop.wait(.01)
            except Exception as error:
                self.poll_errors.append(str(error))
        self.poller = threading.Thread(target=poll, daemon=True)
        self.poller.start()
        loaded = [self.typing() for _ in range(3)]
        self.screenshot('01-typing-during-fleet')
        self.stop.set(); self.poller.join(timeout=10)
        self.check(not self.poll_errors and not self.poller.is_alive(), 'Fleet polling finished without errors')
        self.check(self.rpc('system.identify')['focused'] == before, 'Fleet polling preserves focused window/workspace/panel')
        self.check(all(s['panels'] == 200 for s in self.samples), 'Repeated fleet reads keep all 200 agent identities')
        self.check(max(s['main_ms'] for s in self.samples) < 50, 'Every observed main copy below 50 ms')
        self.check(max(loaded) < max(max(baseline) * 2, max(baseline) + 250), 'Typing echo under load stays within baseline tolerance')
        self.key()
        self.eventually(lambda: 'fleettyping' * 4 not in self.text(), 'Synthesized Control-U failed to dismiss typed input')
        self.screenshot('02-input-dismissed')
        self.report['benchmark'] = {'baseline_typing_ms': baseline, 'loaded_typing_ms': loaded,
            'requests': len(self.samples), 'main_max_ms': max(s['main_ms'] for s in self.samples),
            'main_p95_ms': sorted(s['main_ms'] for s in self.samples)[int(.95 * (len(self.samples)-1))],
            'request_max_ms': max(s['request_ms'] for s in self.samples),
            'typing_measurement': 'PID-scoped synthesized burst to observed terminal echo, including AX and readback overhead',
            'load': self.run(['/usr/bin/uptime']).stdout.strip()}

    def dismiss(self):
        self.stop.set()
        if self.poller:
            self.poller.join(timeout=10)
        self.ui('dismiss')

    def close_workspace(self):
        for workspace in reversed(self.created):
            self.rpc('workspace.close', {'workspace_id': workspace})
        self.created = []


def main():
    socket = os.environ['C11_SOCKET']
    prefix = '/tmp/c11-sandbox-'
    if not socket.startswith(prefix) or not socket.endswith('.sock'):
        raise RuntimeError('Only the scheduled sandbox guest is allowed')
    run_id = socket[len(prefix):-5]
    cli = Path(os.environ['C11_CLI']).resolve()
    app = cli.parents[3]
    executable = app / 'Contents/MacOS/c11'
    processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True).splitlines()
    matches = [int(row.strip().split(None, 1)[0]) for row in processes if row.strip().split(None, 1)[-1] == str(executable)]
    if len(matches) != 1:
        raise RuntimeError('Cannot identify exact tagged app PID')
    args = argparse.Namespace(run_id=run_id, pid=matches[0], app=str(app), cli=str(cli), socket=socket,
                              output_name='fleet-runtime', inspect_dialogs_only=False)
    probe = FleetProbe(args)
    def expire(_signal, _frame):
        raise TimeoutError('Fleet active phase reached 180 seconds')
    signal.signal(signal.SIGALRM, expire); signal.alarm(180)
    watchdog = threading.Timer(225, lambda: os._exit(124)); watchdog.daemon = True; watchdog.start()
    try:
        probe.execute(); probe.report['result'] = 'PASS'
    except Exception as error:
        probe.report.update(result='FAIL', error=str(error))
    finally:
        signal.alarm(0); probe.cleanup(); watchdog.cancel()
    print(json.dumps(probe.report, indent=2))
    return 0 if probe.report.get('result') == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
