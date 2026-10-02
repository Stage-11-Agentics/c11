#!/usr/bin/env python3
"""C11-308 / cmux #15928 and #15980: executable tagged-PTY key checks.

Run INSIDE the disposable Atlas guest, using the same filesystem as its app:
  C11_SOCKET=/tmp/c11-sandbox-<guest>.sock C11_CLI='<tagged app>/Contents/Resources/bin/c11' \
    python3 tests_v2/test_send_key_ctrl.py --pid <tagged-app-pid> --source-head <sha>

An explicit tagged socket, packaged CLI and PID are required. The harness
creates one owned workspace, selects its terminal, restores the prior selection
and closes its workspace. It never uses a provider, authentication or macOS
computer use. Public output contains synthetic bytes, counts and timing only.

Root's companion native proof (not performed by this harness): on the same
tagged artifact, interrupt a running Claude Code turn and a running Codex turn
with the packaged CLI's send-key ctrl-c. Save synthetic read-screen evidence of
the actual interrupt, then send a new synthetic turn and prove it runs. Record
artifact/source SHA and provider versions; this raw reader is not that proof.

Latency is CLI-start to first PTY byte, including CLI startup and scheduling.
Samples are evidence, not a C11-270 baseline/budget comparison or typing soak.
For matched base/candidate samples, add --latency-only: five warmups followed
by twenty legacy raw-PTY space samples, with guest load averages recorded. This
mode excludes the C11-308 Kitty, rejection, prose and interrupt assertions.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux


# This child runs in the real c11 terminal. Its files are private, synthetic
# test oracles; they avoid matching readiness in an unexecuted shell echo.
READER = r'''import json, os, re, select, signal, sys, termios, time, tty
from pathlib import Path
root, mode = Path(sys.argv[1]), sys.argv[2]
old = termios.tcgetattr(0)
def publish(name, value):
    path = root / name
    temporary = path.with_suffix('.pending')
    temporary.write_text(json.dumps(value))
    os.replace(str(temporary), str(path))
def expired(*_):
    raise TimeoutError('fixture deadline')
signal.signal(signal.SIGALRM, expired)
signal.alarm(100)
try:
    if mode in ('kitty', 'raw-legacy'):
        tty.setraw(0)
        # Disambiguate + report events + report all; bracketed paste is off so
        # the text test compares only its synthetic payload.
        os.write(1, b'\x1b[?2004l' + (b'\x1b[>11u' if mode == 'kitty' else b'\x1b[=0u') + b'\x1b[?u')
        answer = b''
        deadline = time.monotonic() + 5
        flags = None
        while time.monotonic() < deadline:
            if select.select([0], [], [], .1)[0]:
                answer += os.read(0, 4096)
                match = re.search(rb'\x1b\[\?(\d+)u', answer)
                if match:
                    flags = int(match.group(1))
                    break
        if flags is None or (mode == 'kitty' and flags & 11 != 11) or (mode == 'raw-legacy' and flags != 0):
            raise RuntimeError('keyboard mode negotiation failed')
        publish('ready.json', {'mode': mode, 'kitty_flags': flags})
        with (root / 'bytes.jsonl').open('a') as output:
            while not (root / 'stop').exists():
                if select.select([0], [], [], .05)[0]:
                    data = os.read(0, 4096)
                    if not data:
                        break
                    output.write(json.dumps({'hex': data.hex(), 't_ns': time.monotonic_ns()}) + '\n')
                    output.flush()
    else:
        # Legacy line discipline, not a signal sent by the test controller.
        tty.setcbreak(0)
        attributes = termios.tcgetattr(0)
        attributes[3] |= termios.ISIG
        attributes[6][termios.VINTR] = b'\x03'
        termios.tcsetattr(0, termios.TCSANOW, attributes)
        os.write(1, b'\x1b[=0u')
        def interrupted(*_):
            publish('sigint.json', {'signal': 'SIGINT', 't_ns': time.monotonic_ns()})
            raise SystemExit(0)
        signal.signal(signal.SIGINT, interrupted)
        publish('ready.json', {'mode': mode, 'isig': True})
        while True:
            signal.pause()
except Exception as error:
    publish('fixture-error.json', {'error_type': type(error).__name__})
finally:
    signal.alarm(0)
    if mode == 'kitty':
        os.write(1, b'\x1b[<u')
    termios.tcsetattr(0, termios.TCSANOW, old)
    publish('finished.json', {'mode': mode})
'''


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class Harness:
    def __init__(self, args):
        self.args = args
        self.client = None
        self.root = None
        self.workspace = None
        self.tab = None
        self.original_workspace = None
        self.original_tab = None
        self.window = None
        self.env = dict(os.environ)
        for key in ('C11_SOCKET', 'C11_SOCKET_PATH', 'CMUX_SOCKET', 'CMUX_SOCKET_PATH'):
            self.env[key] = args.socket
        for key in ('C11_TAB_ID', 'CMUX_SURFACE_ID', 'CMUX_PANEL_ID',
                    'C11_WORKSPACE_ID', 'CMUX_WORKSPACE_ID'):
            self.env.pop(key, None)
        self.report = {'suite': 'C11-308-tagged-PTY', 'source_head': args.source_head,
                       'mode': 'latency-only' if args.latency_only else 'full',
                       'native_provider_proof': 'not-performed', 'computer_use': False,
                       'baseline_comparison': 'not-performed', 'cases': [], 'cleanup': {}}

    def cli(self, arguments, success=True):
        result = subprocess.run([self.args.cli, *arguments], env=self.env,
                                capture_output=True, text=True, timeout=8)
        if success:
            require(result.returncode == 0, 'packaged CLI command failed: ' + arguments[0])
        return result

    def rpc(self, method, params=None):
        return self.client._call(method, params or {}, timeout_s=8) or {}

    def target(self, **extra):
        return {'workspace_id': self.workspace, 'tab_id': self.tab, **extra}

    def wait(self, predicate, description, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.root and (self.root / 'fixture-error.json').exists():
                raise AssertionError('owned PTY fixture reported an error')
            time.sleep(.025)
        raise AssertionError('timeout: ' + description)

    def validate(self):
        require(Path(self.args.socket).is_socket(), 'explicit socket does not exist')
        require(Path(self.args.socket).parent == Path('/tmp') and
                ('c11-debug-' in Path(self.args.socket).name or
                 'c11-sandbox-' in Path(self.args.socket).name), 'tagged/guest socket required')
        cli = Path(self.args.cli).absolute()
        require(cli.name == 'c11' and cli.parent.name == 'bin', 'packaged c11 CLI required')
        app = cli.parents[3]
        require(app.name.startswith('c11 DEV ') and app.suffix == '.app', 'tagged app required')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        require('.debug.' in info.get('CFBundleIdentifier', ''), 'debug tagged bundle required')
        executable = str(app / 'Contents/MacOS' / info['CFBundleExecutable'])
        command = subprocess.run(['/bin/ps', '-p', str(self.args.pid), '-o', 'command='],
                                 capture_output=True, text=True, timeout=5)
        require(command.returncode == 0 and command.stdout.strip().startswith(executable),
                'PID must be the exact packaged app')
        listeners = subprocess.run(['/usr/sbin/lsof', '-n', '-a', '-p', str(self.args.pid), '-U', '-Fn'],
                                   capture_output=True, text=True, timeout=5)
        require('n' + self.args.socket in listeners.stdout.splitlines(), 'PID must own the exact socket')
        if not self.args.event_instance:
            logs = list((Path.home() / 'Library/Application Support/c11/events').glob(
                'events-*-' + str(self.args.pid) + '.ndjson'))
            require(len(logs) == 1, 'supply --event-instance for the exact app event log')
            self.args.event_instance = logs[0].name[len('events-'):-len('.ndjson')]
        events = self.events()
        require(any(row.get('type') == 'log.opened' and row.get('payload', {}).get('pid') == self.args.pid
                    for row in events), 'event instance must begin with the exact app PID')

    def offline_rejections(self):
        # No app/listener exists at this path. The extra-key error therefore
        # establishes ordering before connect/auth/window.focus, not merely a
        # server-side rejection after a command reached a working app.
        identity = '00000000-0000-0000-0000-000000000308'
        with tempfile.TemporaryDirectory(prefix='c11-308-dead-socket-') as directory:
            dead_socket = str(Path(directory) / 'no-listener.sock')
            environment = dict(self.env)
            for key in ('C11_SOCKET', 'C11_SOCKET_PATH', 'CMUX_SOCKET', 'CMUX_SOCKET_PATH'):
                environment[key] = dead_socket
            for command in ('send-key', 'send-key-tab', 'send-key-panel'):
                for separator in (False, True):
                    for with_window in (False, True):
                        flag = '--panel' if command == 'send-key-panel' else '--tab'
                        arguments = ([ '--window', identity ] if with_window else []) + [
                            command, '--workspace', identity, flag, identity]
                        if separator:
                            arguments.append('--')
                        arguments.extend(['ctrl-c', 'enter'])
                        result = subprocess.run([self.args.cli, *arguments], env=environment,
                                                capture_output=True, text=True, timeout=8)
                        require(result.returncode != 0 and 'enter' in result.stderr and
                                'extra argument' in result.stderr.lower() and
                                'socket' not in result.stderr.lower(),
                                'dead-socket command must report the extra argument before wire access')
                        self.report['cases'].append({'case': 'dead-socket-' + command,
                            'separator': separator, 'window_option': with_window,
                            'extra_named': True, 'return_code': result.returncode,
                            'rejected_before_connection': True, 'passed': True})

    def events(self, floor=0):
        result = self.cli(['events', 'tail', '--instance', self.args.event_instance,
                           '--since', str(floor)])
        rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        require(not any(row.get('type') in ('log.dropped', 'log.rotated') for row in rows),
                'event gap/rotation prevents a complete count')
        return rows

    def event_floor(self):
        return 1 + max((row['seq'] for row in self.events()), default=-1)

    def scoped_inputs(self, floor):
        return [row for row in self.events(floor) if row.get('type') == 'tab.input_sent'
                and row.get('workspace') == self.workspace and row.get('surface') == self.tab]

    def assert_one_event(self, floor, kind, text):
        self.wait(lambda: len(self.scoped_inputs(floor)) >= 1, 'input event persisted')
        time.sleep(.2)
        rows = self.scoped_inputs(floor)
        require(len(rows) == 1, 'successful command must emit exactly one tab.input_sent')
        payload = rows[0].get('payload', {})
        require(payload.get('kind') == kind and payload.get('text') == text,
                'input event must name the actual synthetic command')
        require(not payload.get('queued'), 'fixture requires an attached PTY')

    def setup(self):
        workspace_list = self.rpc('workspace.list')
        self.window = workspace_list.get('window_id')
        current = [row for row in workspace_list.get('workspaces', []) if row.get('selected')]
        require(len(current) == 1, 'original workspace selection unavailable')
        self.original_workspace = current[0]['id']
        tabs = self.rpc('tab.list', {'workspace_id': self.original_workspace}).get('tabs', [])
        focused = [row for row in tabs if row.get('focused')]
        require(len(focused) == 1, 'original focused tab unavailable')
        self.original_tab = focused[0]['id']
        self.root = Path(tempfile.mkdtemp(prefix='c11-308-pty-'))
        (self.root / 'reader.py').write_text(READER)
        self.workspace = self.rpc('workspace.create', {'cwd': str(self.root), 'title': '308 Synthetic Keys'}).get('workspace_id')
        require(bool(self.workspace), 'owned workspace was not created')
        tabs = self.rpc('tab.list', {'workspace_id': self.workspace}).get('tabs', [])
        require(len(tabs) == 1, 'owned workspace needs exactly one terminal')
        self.tab = tabs[0]['id']
        self.rpc('workspace.select', {'workspace_id': self.workspace})
        self.rpc('tab.focus', self.target())
        self.start_reader('raw-legacy' if self.args.latency_only else 'kitty')

    def start_reader(self, mode):
        for name in ('ready.json', 'finished.json', 'fixture-error.json'):
            (self.root / name).unlink(missing_ok=True)
        command = shlex.join([sys.executable, str(self.root / 'reader.py'), str(self.root), mode])
        floor = self.event_floor()
        self.rpc('tab.send_text', self.target(text=command + '\n', submit=False))
        self.wait(lambda: (self.root / 'ready.json').exists(), 'real PTY reader readiness')
        ready = json.loads((self.root / 'ready.json').read_text())
        require(ready.get('mode') == mode, 'wrong PTY reader mode')
        if mode == 'kitty':
            require(ready.get('kitty_flags', 0) & 11 == 11, 'Kitty mode was not acknowledged')
        elif mode == 'raw-legacy':
            require(ready.get('kitty_flags') == 0, 'legacy keyboard mode was not acknowledged')
        # The setup send emits asynchronously too: consume its event before
        # taking a floor for the first command under test.
        self.assert_one_event(floor, 'text', command + '\n')

    def captured(self):
        path = self.root / 'bytes.jsonl'
        rows = []
        if path.exists():
            for line in path.read_text().splitlines():
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass  # One in-flight write; the quiet-window read follows.
        return rows

    def byte_cursor(self):
        return len(self.captured())

    def received(self, cursor):
        rows = self.captured()[cursor:]
        return b''.join(bytes.fromhex(row['hex']) for row in rows), rows

    def send_key(self, key, command='send-key', separator=False, extra=None, with_window=False):
        target_flag = '--panel' if command == 'send-key-panel' else '--tab'
        arguments = [command, '--workspace', self.workspace, target_flag, self.tab]
        if with_window:
            require(bool(self.window), 'exact window ID required for window-intent test')
            arguments = ['--window', self.window, *arguments]
        if separator:
            arguments.append('--')
        arguments.extend([key, *([] if extra is None else [extra])])
        return self.cli(arguments, success=extra is None)

    def focus_snapshot(self):
        windows = self.rpc('window.list').get('windows', [])
        focused = self.rpc('tab.list', {'workspace_id': self.workspace}).get('tabs', [])
        return {
            'windows': sorted((row['id'], bool(row.get('key')), row.get('selected_workspace_id')) for row in windows),
            'tabs': sorted((row['id'], bool(row.get('focused')), bool(row.get('selected_in_pane'))) for row in focused),
        }

    def capture_command(self, label, action, expected, kind, event_text):
        floor, cursor = self.event_floor(), self.byte_cursor()
        started = time.monotonic_ns()
        action()
        self.wait(lambda: len(self.received(cursor)[0]) >= len(expected), label + ' PTY bytes')
        self.assert_one_event(floor, kind, event_text)
        actual, rows = self.received(cursor)
        require(actual == expected, label + ' did not deliver the exact expected bytes once')
        latency = (rows[0]['t_ns'] - started) / 1000000
        require(latency >= 0, 'invalid command-to-PTY clock sample')
        self.report['cases'].append({'case': label, 'pty_hex': actual.hex(), 'input_events': 1,
                                     'command_to_pty_ms': round(latency, 3), 'passed': True})

    def exercise(self):
        for key, codepoint, modifiers in [('ctrl-c', 99, 5), ('enter', 13, 1),
                                          ('tab', 9, 1), ('space', 32, 1)]:
            press = '\x1b[' + str(codepoint) + (';' + str(modifiers) if modifiers > 1 else '') + 'u'
            release = '\x1b[' + str(codepoint) + ';' + str(modifiers) + ':3u'
            self.capture_command('kitty-' + key, lambda key=key: self.send_key(key),
                                 (press + release).encode(), 'key', key)
        prose = 'Synthetic prose once.'
        self.capture_command('kitty-prose-no-duplicate', lambda: self.cli([
            'send', '--workspace', self.workspace, '--tab', self.tab, '--no-submit', prose]),
            prose.encode(), 'text', prose)

        # All rejects precede a successful event fence. The persisted fence
        # proves the emitter/writer processed this command interval; zero is
        # not inferred from an immediate read of an asynchronous event log.
        floor, cursor = self.event_floor(), self.byte_cursor()
        rejected = []
        for command in ('send-key', 'send-key-tab', 'send-key-panel'):
            for separator in (False, True):
                for with_window in (False, True):
                    before = self.focus_snapshot()
                    result = self.send_key('ctrl-c', command, separator, extra='enter', with_window=with_window)
                    require(result.returncode != 0, 'extra key must be rejected before any send')
                    require('enter' in result.stderr, 'extra-key error must identify enter')
                    time.sleep(.1)
                    require(self.received(cursor)[0] == b'', 'a rejected command delivered PTY bytes')
                    require(self.focus_snapshot() == before, 'rejection changed in-app window/tab selection')
                    rejected.append({'case': command + ('-separator' if separator else '-extra'),
                                     'window_option': with_window, 'in_app_selection_preserved': True,
                                     'return_code': result.returncode, 'extra_named': True,
                                     'pty_byte_count': 0, 'input_events': 0, 'passed': True})
        self.send_key('ctrl-k')
        self.assert_one_event(floor, 'key', 'ctrl-k')
        self.wait(lambda: bool(self.received(cursor)[0]), 'event-fence PTY bytes')
        require(self.received(cursor)[0] == b'\x1b[107;5u\x1b[107;5:3u',
                'rejection interval must contain only the successful fence key')
        self.report['cases'].extend(rejected)

        for sample in range(5):
            self.capture_command('latency-ctrl-c-' + str(sample + 1), lambda: self.send_key('ctrl-c'),
                                 b'\x1b[99;5u\x1b[99;5:3u', 'key', 'ctrl-c')
        (self.root / 'stop').touch()
        self.wait(lambda: (self.root / 'finished.json').exists(), 'Kitty reader stopped')
        self.start_reader('legacy')
        floor = self.event_floor()
        started = time.monotonic_ns()
        self.send_key('ctrl-c')
        self.wait(lambda: (self.root / 'sigint.json').exists(), 'legacy line discipline SIGINT')
        self.wait(lambda: (self.root / 'finished.json').exists(), 'legacy reader stopped')
        self.assert_one_event(floor, 'key', 'ctrl-c')
        result = json.loads((self.root / 'sigint.json').read_text())
        require(result.get('signal') == 'SIGINT', 'real legacy SIGINT required')
        # Prove a following send can execute through the shell after SIGINT.
        follow = self.root / 'follow-up'
        command = 'printf synthetic-follow-up > ' + shlex.quote(str(follow))
        self.cli(['send', '--workspace', self.workspace, '--tab', self.tab, command])
        self.wait(follow.exists, 'shell command after legacy interrupt')
        require(follow.read_text() == 'synthetic-follow-up', 'following shell send did not run')
        self.report['cases'].append({'case': 'legacy-sigint-and-following-send', 'signal': 'SIGINT',
            'input_events': 1, 'command_to_signal_ms': round((result['t_ns'] - started) / 1000000, 3),
            'following_send_executed': True, 'passed': True})

    def latency_only(self):
        self.report['guest_load_before'] = list(os.getloadavg())
        samples = []
        for index in range(25):
            warmup = index < 5
            label = ('warmup-space-' + str(index + 1) if warmup else
                     'sample-space-' + str(index - 4))
            self.capture_command(label, lambda: self.send_key('space'), b' ', 'key', 'space')
            row = self.report['cases'][-1]
            row['warmup'] = warmup
            row['guest_load_1m'] = os.getloadavg()[0]
            if not warmup:
                samples.append(row['command_to_pty_ms'])
        ordered = sorted(samples)
        self.report['latency'] = {
            'metric': 'CLI-start-to-first-PTY-byte-ms', 'keyboard_mode': 'legacy-raw',
            'key': 'space', 'warmups': 5, 'sample_count': 20, 'samples_ms': samples,
            'median_ms': round((ordered[9] + ordered[10]) / 2, 3),
            'p95_nearest_rank_ms': ordered[18], 'p99_nearest_rank_ms': ordered[19],
            'maximum_ms': ordered[-1],
        }
        self.report['guest_load_after'] = list(os.getloadavg())
        (self.root / 'stop').touch()
        self.wait(lambda: (self.root / 'finished.json').exists(), 'latency reader stopped')

    def cleanup(self):
        if self.root:
            (self.root / 'stop').touch()
        if self.original_workspace and self.original_tab:
            try:
                self.rpc('workspace.select', {'workspace_id': self.original_workspace})
                self.rpc('tab.focus', {'workspace_id': self.original_workspace, 'tab_id': self.original_tab})
                workspaces = self.rpc('workspace.list').get('workspaces', [])
                tabs = self.rpc('tab.list', {'workspace_id': self.original_workspace}).get('tabs', [])
                self.report['cleanup']['original_selection_restored'] = (
                    any(row.get('id') == self.original_workspace and row.get('selected') for row in workspaces)
                    and any(row.get('id') == self.original_tab and row.get('focused') for row in tabs))
            except Exception as error:
                self.report['cleanup']['restore_error_type'] = type(error).__name__
        if self.workspace:
            self.rpc('workspace.close', {'workspace_id': self.workspace})
            remaining = self.rpc('workspace.list').get('workspaces', [])
            self.report['cleanup']['workspace_removed'] = all(row.get('id') != self.workspace for row in remaining)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', default=os.environ.get('C11_SOCKET') or os.environ.get('C11_SOCKET_PATH'))
    parser.add_argument('--cli', default=os.environ.get('C11_CLI'))
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--event-instance', default=os.environ.get('C11_EVENT_INSTANCE'))
    parser.add_argument('--source-head', default='not-supplied')
    parser.add_argument('--latency-only', action='store_true')
    args = parser.parse_args()
    if not args.socket or not args.cli:
        parser.error('explicit tagged C11_SOCKET and packaged C11_CLI are required')
    if args.source_head != 'not-supplied' and not re.fullmatch(r'[0-9a-fA-F]{40}', args.source_head):
        parser.error('--source-head must be an exact SHA')
    if args.event_instance and not re.fullmatch(r'[A-Za-z0-9_.-]+', args.event_instance):
        parser.error('invalid event instance')
    os.umask(0o077)
    harness = Harness(args)
    def expired(*_):
        raise TimeoutError('bounded harness deadline')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(90)
    try:
        if not args.latency_only:
            harness.offline_rejections()
        harness.validate()
        with cmux(args.socket) as client:
            harness.client = client
            try:
                harness.setup()
                if args.latency_only:
                    harness.latency_only()
                else:
                    harness.exercise()
            finally:
                signal.alarm(15)
                harness.cleanup()
    except Exception as error:
        # Never dump unrelated terminal output, event bodies, runtime IDs or
        # subprocess stderr. Root can inspect the private synthetic fixture.
        harness.report['error_type'] = type(error).__name__
        harness.report['failure'] = str(error) if isinstance(error, AssertionError) else 'runtime failure'
    finally:
        signal.alarm(0)
    complete = ('error_type' not in harness.report and
                harness.report['cleanup'].get('workspace_removed') and
                harness.report['cleanup'].get('original_selection_restored'))
    harness.report['passed'] = bool(complete)
    if harness.root:
        (harness.root / 'report.json').write_text(json.dumps(harness.report, indent=2) + '\n')
    print(json.dumps(harness.report, sort_keys=True))
    return 0 if complete else 1


if __name__ == '__main__':
    raise SystemExit(main())
