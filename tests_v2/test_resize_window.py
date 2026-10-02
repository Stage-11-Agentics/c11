#!/usr/bin/env python3
"""C11-286 / cmux #9826: real tagged-window resize, read and no-focus checks.

Run only INSIDE an authorized Atlas sandbox guest, with its packaged CLI:
  C11_SOCKET=/tmp/c11-sandbox-<guest>.sock \
  C11_CLI='<tagged app>/Contents/Resources/bin/c11' \
    python3 tests_v2/test_resize_window.py --pid <app-pid> --source-head <sha>

The harness opens and closes one extra window. It does not enter fullscreen,
use computer input, launch providers, or touch installed skills. A forwarding
socket observes actual CLI requests; it supplies no simulated responses.
AppKit screen geometry is read through JXA to independently check the maximum
clamp. No screenshots or unrelated window titles/IDs enter public evidence.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def close_number(first, second):
    return math.isclose(first, second, abs_tol=0.001, rel_tol=0)


def geometry(reply):
    return tuple(reply[section][axis] for section, axis in (
        ('origin', 'x'), ('origin', 'y'), ('applied', 'width'), ('applied', 'height')))


def same_geometry(first, second):
    return all(close_number(a, b) for a, b in zip(geometry(first), geometry(second)))


class Forwarder(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path, target):
        self.target = target
        self.trace = []
        super().__init__(path, ForwardingConnection)


class ForwardingConnection(socketserver.StreamRequestHandler):
    def handle(self):
        with socket.socket(socket.AF_UNIX) as upstream:
            upstream.settimeout(8)
            upstream.connect(self.server.target)
            with upstream.makefile('rwb') as wire:
                for line in self.rfile:
                    if line.startswith(b'{'):
                        self.server.trace.append(json.loads(line))
                    else:
                        # Keep only the legacy verb, never its arguments.
                        verb = line.decode(errors='replace').split(' ', 1)[0].strip()
                        self.server.trace.append({'method': 'legacy.' + verb})
                    wire.write(line)
                    wire.flush()
                    response = wire.readline()
                    if not response:
                        return
                    self.wfile.write(response)
                    self.wfile.flush()


class Harness:
    def __init__(self, args):
        self.args = args
        self.client = None
        self.forwarder = None
        self.proxy = None
        self.first = None
        self.second = None
        self.original_key = None
        self.first_frame = None
        self.screens = []
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('C11_', 'CMUX_'))}
        self.report = {'suite': 'C11-286-tagged-window-resize', 'source_head': args.source_head,
                       'computer_use': False, 'cases': [], 'cleanup': {}}

    def cli(self, arguments, accepted=True):
        result = subprocess.run([self.args.cli, '--socket', self.proxy or self.args.socket,
                                 '--json', '--id-format', 'both', *arguments],
                                env=self.env, capture_output=True, text=True, timeout=8)
        if accepted:
            require(result.returncode == 0, 'bundled CLI failed: ' + arguments[0])
        return result

    def rpc(self, method, params=None):
        return self.client._call(method, params or {}, timeout_s=8) or {}

    def rpc_error(self, method, params, expected):
        try:
            self.rpc(method, params)
        except cmuxError as error:
            require(str(error).split(':', 1)[0] == expected, 'RPC returned the wrong error code')
        else:
            raise AssertionError('RPC unexpectedly accepted invalid input')

    def windows(self):
        return self.rpc('window.list').get('windows', [])

    def key_window(self):
        keys = [row['id'] for row in self.windows() if row.get('key')]
        require(len(keys) == 1, 'expected exactly one key window in the guest')
        return keys[0]

    def wait_key(self, target):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if [row['id'] for row in self.windows() if row.get('key')] == [target]:
                return
            time.sleep(.05)
        raise AssertionError('explicit focus did not make the expected guest window key')

    def validate(self):
        require(Path('/Volumes/My Shared Files/out').is_dir(), 'disposable sandbox guest required')
        path = Path(self.args.socket)
        require(path.is_socket() and path.parent == Path('/tmp') and
                re.fullmatch(r'(?:c11|cmux)-(?:debug|sandbox)-[^/]+\.sock', path.name),
                'explicit tagged/sandbox socket required')
        cli = Path(self.args.cli).absolute()
        require(cli.is_file() and cli.name == 'c11' and cli.parent.name == 'bin', 'bundled c11 CLI required')
        app = cli.parents[3]
        require(app.name.startswith('c11 DEV ') and app.suffix == '.app', 'tagged app bundle required')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        require('.debug.' in info.get('CFBundleIdentifier', ''), 'tagged debug bundle required')
        commit = info.get('C11Commit') or info.get('CMUXCommit')
        if self.args.source_head == 'not-supplied' and isinstance(commit, str) and re.fullmatch(r'[0-9a-fA-F]{7,40}', commit):
            self.report['source_head'] = commit.lower()
            self.report['source_head_provenance'] = 'built-bundle'
        else:
            self.report['source_head_provenance'] = 'caller-supplied' if self.args.source_head != 'not-supplied' else 'unavailable'
        executable = str(app / 'Contents/MacOS' / info['CFBundleExecutable'])
        if self.args.pid is None:
            owners = subprocess.run(['/usr/sbin/lsof', '-n', '-t', self.args.socket],
                                    capture_output=True, text=True, timeout=5)
            candidates = []
            for value in set(owners.stdout.splitlines()):
                if not value.isdigit():
                    continue
                process = subprocess.run(['/bin/ps', '-p', value, '-o', 'command='],
                                         capture_output=True, text=True, timeout=5)
                if process.returncode == 0 and process.stdout.strip().startswith(executable):
                    candidates.append(int(value))
            require(len(candidates) == 1, 'socket must have exactly one owner from the packaged tagged bundle')
            self.args.pid = candidates[0]
        process = subprocess.run(['/bin/ps', '-p', str(self.args.pid), '-o', 'command='],
                                 capture_output=True, text=True, timeout=5)
        require(process.returncode == 0 and process.stdout.strip().startswith(executable),
                'PID must belong to the exact tagged bundle')
        listeners = subprocess.run(['/usr/sbin/lsof', '-n', '-a', '-p', str(self.args.pid), '-U', '-Fn'],
                                   capture_output=True, text=True, timeout=5)
        require('n' + self.args.socket in listeners.stdout.splitlines(), 'tagged PID must own the socket')
        script = """ObjC.import('AppKit');
        var result = [], screens = $.NSScreen.screens;
        for (var i = 0; i < screens.count; i++) {
            var screen = screens.objectAtIndex(i), f = screen.frame, v = screen.visibleFrame;
            result.push({frame: f, visible: v});
        }
        JSON.stringify(result);"""
        result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script],
                                capture_output=True, text=True, timeout=5)
        require(result.returncode == 0, 'AppKit screen geometry read failed')
        self.screens = json.loads(result.stdout)
        require(bool(self.screens), 'guest screen geometry unavailable')

    def discovery(self):
        capabilities = self.rpc('system.capabilities')
        require('window.resize' in capabilities.get('methods', []), 'binary must advertise window.resize')
        feature = [row for row in capabilities.get('features', []) if row.get('id') == 'window.resize']
        require(len(feature) == 1 and feature[0].get('version') == 1,
                'binary must advertise the enabled window.resize feature')
        bundled = json.loads(self.cli(['capabilities']).stdout)
        require('window.resize' in bundled.get('methods', []), 'bundled CLI capability method missing')
        require(any(row.get('id') == 'window.resize' for row in bundled.get('features', [])),
                'bundled CLI capability feature missing')
        self.report['cli_server_sha_match'] = bundled.get('sha_match')
        require(bundled.get('sha_match') is True, 'CLI and server must identify the same build')
        help_text = self.cli(['resize-window', '--help']).stdout.lower()
        require(all(part in help_text for part in ('resize-window', '--window', 'width', 'height', 'keep')),
                'bundled subcommand help must describe explicit target, sizes and kept edges')
        require('resize-window' in self.cli(['--help']).stdout, 'top-level help must advertise resize-window')
        self.report['cases'].append({'case': 'built-capabilities-and-help', 'passed': True})

    def validate_reply(self, reply, target, width, height):
        require(reply.get('window_id') == target and str(reply.get('window_ref', '')).startswith('window:'),
                'resize response must identify the actual target window')
        requested = reply.get('requested', {})
        require(requested.get('width') == width and requested.get('height') == height,
                'resize response requested edges differ from the command')
        for value in geometry(reply):
            require(not isinstance(value, bool) and isinstance(value, (float, int)) and math.isfinite(value),
                    'frame response must contain finite geometry')
        require(reply['applied']['width'] > 0 and reply['applied']['height'] > 0, 'applied frame must be positive')
        require(close_number(reply['top_left']['x'], reply['origin']['x']) and
                close_number(reply['top_left']['y'], reply['origin']['y'] + reply['applied']['height']),
                'top-left must be expressed in AppKit frame coordinates')
        if width is None and height is None:
            require(reply.get('changed') is False and reply.get('clamped') is False,
                    'a read must report no change and no clamp')
        else:
            expected_clamp = ((width is not None and not close_number(width, reply['applied']['width'])) or
                              (height is not None and not close_number(height, reply['applied']['height'])))
            require(reply.get('clamped') is expected_clamp, 'clamped must describe requested, not kept, edges')

    def resize(self, target, width=None, height=None):
        floor = len(self.forwarder.trace)
        reply = json.loads(self.cli(['resize-window', '--window', target,
                                     '-' if width is None else str(width),
                                     '-' if height is None else str(height)]).stdout)
        requests = self.forwarder.trace[floor:]
        require(not any(row.get('method') in ('window.focus', 'workspace.select', 'tab.focus',
                                             'legacy.focus_window') for row in requests),
                'resize-window must never issue a focus command')
        resizes = [row for row in requests if row.get('method') == 'window.resize']
        require(len(resizes) == 1 and resizes[0].get('params', {}).get('window_id') == target,
                'resize-window must send one explicitly targeted request')
        params = resizes[0]['params']
        for key, value in (('width', width), ('height', height)):
            require(key not in params if value is None else params.get(key) == value,
                    'CLI must omit kept edges and send numeric requested edges')
        self.validate_reply(reply, target, width, height)
        return reply

    def assert_primary_unchanged(self):
        require(self.key_window() == self.first, 'resizing the second window stole the first window key state')
        require(same_geometry(self.first_frame, self.resize(self.first)), 'first window frame changed')

    def assert_top_left(self, initial, current):
        require(all(close_number(initial['top_left'][axis], current['top_left'][axis]) for axis in ('x', 'y')),
                'resize moved the target top-left')

    def fullscreen_checks(self, windows):
        normal = []
        checked = 0
        for row in windows:
            target = row['id']
            try:
                self.rpc('window.resize', {'window_id': target})
                normal.append(target)
            except cmuxError as error:
                require(str(error).split(':', 1)[0] == 'invalid_state', 'initial frame read returned unexpected error')
                self.rpc_error('window.resize', {'window_id': target, 'width': 1200, 'height': 800}, 'invalid_state')
                self.rpc_error('window.resize', {'window_id': target}, 'invalid_state')
                checked += 1
        self.report['fullscreen'] = {'existing_windows_checked': checked,
            'result': 'existing-fullscreen-rejected-and-retained' if checked else 'skipped-no-existing-fullscreen'}
        require(bool(normal), 'a normal existing guest window is required; harness does not leave fullscreen')
        return normal

    def exercise(self):
        self.discovery()
        windows = self.windows()
        require(bool(windows), 'guest app needs an existing first window')
        keys = [row['id'] for row in windows if row.get('key')]
        self.original_key = keys[0] if len(keys) == 1 else self.rpc('window.current').get('window_id')
        normal = self.fullscreen_checks(windows)
        self.first = self.original_key if self.original_key in normal else normal[0]
        self.second = self.rpc('window.create').get('window_id')
        require(bool(self.second) and self.second not in {row['id'] for row in windows}, 'second window was not created')
        # QA launches deliberately leave c11 inactive. Explicit socket focus
        # may reorder a window without activating the app, so establish the
        # guest's AppKit activation before asserting key-window preservation.
        self.client.activate_app()
        self.cli(['focus-window', '--window', self.first])
        self.wait_key(self.first)
        self.first_frame = self.resize(self.first)
        initial = self.resize(self.second)

        applied = self.resize(self.second, 1200, 800)
        self.assert_top_left(initial, applied)
        require(same_geometry(applied, self.resize(self.second)), 'applied resize must equal the next actual frame read')
        self.assert_primary_unchanged()
        self.report['cases'].append({'case': 'resize-second-top-left-and-first-key',
                                     'applied': applied['applied'], 'clamped': applied['clamped'], 'passed': True})

        first_read, second_read = self.resize(self.second), self.resize(self.second)
        require(geometry(first_read) == geometry(second_read), 'repeated reads changed exact origin or size')
        self.assert_top_left(initial, second_read)
        self.assert_primary_unchanged()
        self.report['cases'].append({'case': 'read-keeps-frame-and-omits-write-edges', 'changed': False, 'passed': True})

        minimum = self.resize(self.second, 0, 0)
        require(minimum['clamped'] is True, 'undersized request must clamp instead of failing')
        smaller = self.resize(self.second, -1000000, -1000000)
        require(minimum['applied'] == smaller['applied'], 'smaller requests must clamp to the same minimum')
        require(same_geometry(minimum, self.resize(self.second)), 'minimum clamp differs from the actual frame')
        self.assert_top_left(initial, minimum)
        self.assert_primary_unchanged()
        self.report['cases'].append({'case': 'minimum-clamp', 'applied': minimum['applied'], 'passed': True})

        maximum = self.resize(self.second, 1000000, 1000000)
        require(maximum['clamped'] is True, 'oversized request must clamp')
        require(same_geometry(maximum, self.resize(self.second)), 'maximum clamp differs from the actual frame')
        # Match visible dimensions to the independently observed AppKit screens.
        # This also works for multiple displays without guessing screen 0.
        candidates = [screen['visible']['size'] for screen in self.screens]
        require(any(close_number(maximum['applied']['width'], max(minimum['applied']['width'], size['width'])) and
                    close_number(maximum['applied']['height'], max(minimum['applied']['height'], size['height']))
                    for size in candidates), 'maximum clamp must match one current screen visible frame, respecting minimum')
        self.assert_top_left(initial, maximum)
        self.assert_primary_unchanged()
        self.report['cases'].append({'case': 'maximum-visible-screen-clamp', 'applied': maximum['applied'], 'passed': True})

        partial = self.resize(self.second, None, 900)
        require(close_number(partial['applied']['width'], maximum['applied']['width']), 'kept width changed')
        self.assert_top_left(initial, partial)
        self.assert_primary_unchanged()
        self.report['cases'].append({'case': 'keep-one-edge', 'passed': True})

        before = self.resize(self.first)
        result = self.cli(['resize-window', '--window', str(uuid.uuid4()), '1200', '800'], accepted=False)
        require(result.returncode != 0 and 'not_found' in result.stderr, 'unknown UUID must return not_found')
        require(same_geometry(before, self.resize(self.first)), 'invalid UUID modified the first window frame')
        self.assert_primary_unchanged()
        self.report['cases'].append({'case': 'unknown-uuid-preserves-first-frame', 'passed': True})

        invalid_cli = [
            ('missing-dimension', ['resize-window', '--window', self.second, '800']),
            ('extra-dimension', ['resize-window', '--window', self.second, '800', '600', '400']),
            ('bogus-size', ['resize-window', '--window', self.second, 'bogus', '600']),
            ('nan-size', ['resize-window', '--window', self.second, 'nan', '600']),
            ('inf-size', ['resize-window', '--window', self.second, 'inf', '600']),
            ('empty-window', ['resize-window', '--window', '', '800', '600']),
            ('global-window', ['--window', self.second, 'resize-window', '800', '600']),
        ]
        for label, arguments in invalid_cli:
            before_first, before_second = self.resize(self.first), self.resize(self.second)
            floor = len(self.forwarder.trace)
            rejected = self.cli(arguments, accepted=False)
            require(rejected.returncode != 0, 'invalid CLI resize arguments must fail')
            require(len(self.forwarder.trace) == floor, 'invalid CLI resize must issue zero forwarding requests')
            require(same_geometry(before_first, self.resize(self.first)) and
                    same_geometry(before_second, self.resize(self.second)), 'invalid CLI arguments changed a frame')
            self.assert_primary_unchanged()
            self.report['cases'].append({'case': 'invalid-cli-' + label, 'forwarded_requests': 0,
                                         'frames_and_key_unchanged': True, 'passed': True})

        before = self.resize(self.second)
        for key in ('width', 'height'):
            for value in (True, False, '800', 'not-a-size'):
                self.rpc_error('window.resize', {'window_id': self.second, key: value}, 'invalid_params')
                require(same_geometry(before, self.resize(self.second)), 'invalid RPC parameter modified the target frame')
                self.assert_primary_unchanged()
        self.report['cases'].append({'case': 'bool-and-string-rpc-params-rejected', 'invalid_params_count': 8, 'passed': True})

    def cleanup(self):
        if self.second:
            self.rpc('window.close', {'window_id': self.second})
            self.report['cleanup']['second_window_closed'] = all(row['id'] != self.second for row in self.windows())
        if self.original_key:
            self.rpc('window.focus', {'window_id': self.original_key})
            self.wait_key(self.original_key)
            self.report['cleanup']['original_key_restored'] = self.key_window() == self.original_key
        if self.first_frame and self.first:
            self.report['cleanup']['first_frame_unchanged'] = same_geometry(self.first_frame, self.resize(self.first))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', default=next((os.environ[key] for key in
        ('C11_SOCKET', 'C11_SOCKET_PATH', 'CMUX_SOCKET', 'CMUX_SOCKET_PATH') if os.environ.get(key)), None))
    parser.add_argument('--cli', default=os.environ.get('C11_CLI'))
    parser.add_argument('--pid', type=int, help='optional exact app PID; otherwise discover the packaged socket owner')
    parser.add_argument('--source-head', default='not-supplied')
    args = parser.parse_args()
    if not args.socket or not args.cli:
        parser.error('explicit tagged socket and packaged C11_CLI are required')
    if args.source_head != 'not-supplied' and not re.fullmatch(r'[0-9a-fA-F]{40}', args.source_head):
        parser.error('--source-head must be an exact 40-hex SHA')
    os.umask(0o077)
    harness = Harness(args)
    def expired(*_):
        raise TimeoutError('bounded runtime deadline')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(90)
    try:
        harness.validate()
        with tempfile.TemporaryDirectory(prefix='c11-286-resize-', dir='/tmp') as directory:
            harness.proxy = str(Path(directory) / 'forward.sock')
            harness.forwarder = Forwarder(harness.proxy, args.socket)
            worker = threading.Thread(target=lambda: harness.forwarder.serve_forever(poll_interval=.05), daemon=True)
            worker.start()
            try:
                with cmux(args.socket) as client:
                    harness.client = client
                    try:
                        harness.exercise()
                    finally:
                        signal.alarm(15)
                        harness.cleanup()
            finally:
                harness.forwarder.shutdown()
                harness.forwarder.server_close()
                worker.join(timeout=2)
    except Exception as error:
        harness.report['error_type'] = type(error).__name__
        # All AssertionError strings above are fixed structural descriptions.
        harness.report['failure'] = str(error) if isinstance(error, AssertionError) else 'runtime failure'
    finally:
        signal.alarm(0)
    harness.report['passed'] = bool('error_type' not in harness.report and
        harness.report['cleanup'].get('second_window_closed') and
        harness.report['cleanup'].get('original_key_restored') and
        harness.report['cleanup'].get('first_frame_unchanged'))
    print(json.dumps(harness.report, sort_keys=True))
    return 0 if harness.report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
