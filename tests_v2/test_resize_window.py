#!/usr/bin/env python3
"""C11-286 / cmux #9826: tagged resize, dispatcher, geometry and focus evidence.

Run only INSIDE an authorized Atlas sandbox guest, with its packaged CLI:
  C11_SOCKET=/tmp/c11-sandbox-<guest>.sock \
  C11_CLI='<tagged app>/Contents/Resources/bin/c11' \
    python3 tests_v2/test_resize_window.py --pid <app-pid> --source-head <sha>

The harness opens and closes one extra window. It does not enter fullscreen,
use computer input, launch providers, or touch installed skills. A forwarding
socket observes actual CLI requests; it supplies no simulated responses.
The resize response reports the actual owning screen used for its clamp, and
JXA independently enumerates display geometry. OS frontmost PID and AppKit key
window are separate oracles; absent headless observations stay unproven.
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


def rect_values(rect):
    return tuple(rect[key] for key in ('x', 'y', 'width', 'height'))


def same_rect(first, second):
    return (isinstance(first, dict) and isinstance(second, dict) and
            all(close_number(a, b) for a, b in zip(rect_values(first), rect_values(second))))


def same_screen(first, second):
    return (isinstance(first, dict) and isinstance(second, dict) and
            first.get('display_id') == second.get('display_id') and
            same_rect(first.get('frame'), second.get('frame')) and
            same_rect(first.get('visible_frame'), second.get('visible_frame')))


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
        self.original_window = None
        self.first_frame = None
        self.screens = []
        self.main_display_id = None
        self.bundle_id = None
        self.dispatch_log = None
        self.dispatch_log_offset = 0
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('C11_', 'CMUX_'))}
        self.report = {'suite': 'C11-286-tagged-window-resize', 'source_head': args.source_head,
                       'computer_use': False, 'cases': [], 'cleanup': {},
                       'focus_evidence': {}, 'validator_scenarios': {}}

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

    def current_window(self):
        return self.rpc('window.current').get('window_id')

    def key_window_if_present(self):
        keys = [row['id'] for row in self.windows() if row.get('key')]
        require(len(keys) <= 1, 'expected at most one key window in the guest')
        return keys[0] if keys else None

    def frontmost_pid(self):
        result = subprocess.run(
            ['/usr/bin/osascript', '-e',
             'tell application "System Events" to get unix id of first process whose frontmost is true'],
            capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            return None
        try:
            return int(result.stdout.strip().splitlines()[-1])
        except (IndexError, ValueError):
            return None

    def process_pid_named(self, name):
        result = subprocess.run(
            ['/usr/bin/osascript', '-e',
             f'tell application "System Events" to get unix id of first process whose name is "{name}"'],
            capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            return None
        try:
            return int(result.stdout.strip().splitlines()[-1])
        except (IndexError, ValueError):
            return None

    def activate_app(self, bundle_id):
        result = subprocess.run(
            ['/usr/bin/osascript', '-e', f'tell application id "{bundle_id}" to activate'],
            capture_output=True, text=True, timeout=5)
        return result.returncode == 0

    def wait_frontmost(self, predicate, timeout=3):
        end = time.monotonic() + timeout
        last = None
        while time.monotonic() < end:
            last = self.frontmost_pid()
            if last is not None and predicate(last):
                return last
            time.sleep(.05)
        return last

    def screen_summary(self, screen):
        if not isinstance(screen, dict):
            return None
        enumerated = [item for item in self.screens if same_screen(item, screen)]
        return {
            'display_id': screen['display_id'],
            'frame': screen['frame'],
            'visible_frame': screen['visible_frame'],
            'enumeration_matches': len(enumerated),
            'is_main_screen': screen['display_id'] == self.main_display_id,
        }

    def wait_focus(self, target):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if self.current_window() == target:
                return
            time.sleep(.05)
        raise AssertionError('explicit focus did not make the expected guest window current')

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
        self.bundle_id = info.get('CFBundleIdentifier', '')
        require('.debug.' in self.bundle_id, 'tagged debug bundle required')
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
        function rect(r) { return {x: r.origin.x, y: r.origin.y,
                                   width: r.size.width, height: r.size.height}; }
        var result = [], screens = $.NSScreen.screens;
        var mainScreen = $.NSScreen.mainScreen;
        for (var i = 0; i < screens.count; i++) {
            var screen = screens.objectAtIndex(i), f = screen.frame, v = screen.visibleFrame;
            result.push({display_id: Number(screen.deviceDescription.objectForKey('NSScreenNumber')),
                         frame: rect(f), visible_frame: rect(v)});
        }
        JSON.stringify({screens: result,
                        main_display_id: Number(mainScreen.deviceDescription.objectForKey('NSScreenNumber'))});"""
        result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script],
                                capture_output=True, text=True, timeout=5)
        require(result.returncode == 0, 'AppKit screen geometry read failed')
        displays = json.loads(result.stdout)
        self.screens = displays.get('screens', [])
        self.main_display_id = displays.get('main_display_id')
        require(bool(self.screens), 'guest screen geometry unavailable')
        require(isinstance(self.main_display_id, int) and not isinstance(self.main_display_id, bool),
                'main display identity unavailable')

        explicit_log = os.environ.get('CMUX_DEBUG_LOG', '').strip()
        if explicit_log:
            log_path = explicit_log
        else:
            tag = os.environ.get('CMUX_TAG', '').strip()
            socket_path = os.environ.get('CMUX_SOCKET_PATH', '').strip()
            if tag:
                token = re.sub(r'[^A-Za-z0-9_.-]+', '-', tag).strip('-.') or 'debug'
                log_path = f'/tmp/cmux-debug-{token}.log'
            elif socket_path and Path(socket_path).stem.startswith('cmux-debug-'):
                log_path = f"/tmp/{Path(socket_path).stem}.log"
            else:
                token = re.sub(r'[^A-Za-z0-9_.-]+', '-', self.bundle_id).strip('-.') or 'debug'
                log_path = '/tmp/cmux-debug.log' if self.bundle_id == 'com.cmuxterm.app.debug' else f'/tmp/cmux-debug-{token}.log'
        self.dispatch_log = Path(log_path)
        try:
            self.dispatch_log_offset = self.dispatch_log.stat().st_size
        except FileNotFoundError:
            self.dispatch_log_offset = 0
        self.report['display_count'] = len(self.screens)

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
        screen = reply.get('screen')
        require(isinstance(screen, dict) and isinstance(screen.get('display_id'), int),
                'resize response must identify the target window owning screen')
        require(all(math.isfinite(value) for rect in (screen.get('frame'), screen.get('visible_frame'))
                    for value in rect_values(rect)), 'owning screen bounds must be finite')
        require(sum(1 for item in self.screens if same_screen(item, screen)) == 1,
                'owning screen identity must match exactly one independently enumerated NSScreen')
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

    def assert_worker_dispatch(self, trigger):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                contents = self.dispatch_log.read_bytes()
            except FileNotFoundError:
                contents = b''
            if len(contents) < self.dispatch_log_offset:
                self.dispatch_log_offset = 0
            new_lines = contents[self.dispatch_log_offset:].decode(errors='replace').splitlines()
            marker = next((line for line in new_lines if 'v2.window.resize isMain=' in line), None)
            if marker:
                self.dispatch_log_offset = len(contents)
                require('v2.window.resize isMain=false' in marker,
                        'window.resize reached the main-actor fallback instead of the socket worker')
                self.report['cases'].append({'case': 'window-resize-worker-dispatch',
                                             'trigger': trigger, 'dispatcher_thread': 'socket_worker', 'passed': True})
                return
            time.sleep(.05)
        raise AssertionError('executable dispatcher log did not record a window.resize worker invocation')

    def assert_logical_context_unchanged(self):
        require(self.current_window() == self.first,
                'resizing the second window changed the logical current window')
        require(same_geometry(self.first_frame, self.resize(self.first)), 'first window frame changed')

    def assert_top_left(self, initial, current):
        require(all(close_number(initial['top_left'][axis], current['top_left'][axis]) for axis in ('x', 'y')),
                'resize moved the target top-left')

    def publish_focus_evidence(self, first, second):
        self.report['focus_evidence'] = {
            'logical_window_current': {
                'status': 'passed',
                'scope': 'logical selection only; not an OS frontmost or key-window oracle',
            },
            'scenario_1': first,
            'scenario_2': second,
        }

    def record_secondary_display_scenario(self, initial):
        scenario = {'name': '3-secondary-display-edge-clamp'}
        self.report['validator_scenarios']['3'] = scenario
        if len(self.screens) < 2:
            scenario.update(status='unproven', reason='guest exposes fewer than two displays')
            return
        screen = initial.get('screen')
        if not isinstance(screen, dict) or screen['display_id'] == self.main_display_id:
            scenario.update(status='unproven', reason='disposable target is not on a secondary display')
            return

        visible = screen['visible_frame']
        origin = initial['origin']
        size = initial['applied']
        gaps = (
            origin['x'] - visible['x'],
            visible['x'] + visible['width'] - (origin['x'] + size['width']),
            origin['y'] - visible['y'],
            visible['y'] + visible['height'] - (origin['y'] + size['height']),
        )
        if not any(0 <= gap <= 100 for gap in gaps):
            scenario.update(status='unproven', reason='disposable target is not within 100 points of a visible-frame edge')
            return

        minimum = self.resize(self.second, 0, 0)
        maximum = self.resize(self.second, 1000000, 1000000)
        self.assert_top_left(initial, maximum)
        require(same_screen(initial['screen'], maximum['screen']),
                'secondary-display resize must clamp against the target owning screen')
        expected_width = max(minimum['applied']['width'], visible['width'])
        expected_height = max(minimum['applied']['height'], visible['height'])
        require(maximum['clamped'] and close_number(maximum['applied']['width'], expected_width) and
                close_number(maximum['applied']['height'], expected_height),
                'secondary-display resize must clamp both dimensions to its owning visible frame')
        restored = self.resize(self.second, size['width'], size['height'])
        require(same_geometry(initial, restored), 'secondary-display scenario must restore the disposable target frame')
        scenario.update(status='passed', owning_screen=self.screen_summary(screen),
                        initial=geometry(initial), applied=maximum['applied'],
                        expected={'width': expected_width, 'height': expected_height})

    def record_focus_scenarios(self):
        # Scenario 1: an unrelated app stays frontmost while the second c11
        # window is resized. Frontmost PID and c11 key identity are independent
        # observations; a missing key window is not reported as preserved.
        first = {'name': '1-another-app-frontmost'}
        self.report['validator_scenarios']['1'] = first
        if not self.activate_app('com.apple.finder'):
            first.update(status='unproven', reason='Finder activation was unavailable in this guest')
        else:
            finder_pid = self.process_pid_named('Finder')
            before_pid = self.wait_frontmost(lambda pid: pid == finder_pid) if finder_pid is not None else None
            if finder_pid is None or before_pid != finder_pid or before_pid == self.args.pid:
                first.update(status='unproven', reason='could not observe Finder frontmost by its real PID')
            else:
                before_key = self.key_window_if_present()
                self.resize(self.second, 1200, 800)
                after_pid = self.frontmost_pid()
                after_key = self.key_window_if_present()
                require(after_pid == before_pid,
                        'resizing a background c11 window changed the real frontmost application PID')
                require(after_key == before_key,
                        'resizing a background c11 window changed the c11 key-window identity')
                key_status = 'passed' if before_key is not None else 'unproven_no_key_window'
                first.update(status='passed' if before_key is not None else 'unproven',
                             frontmost_pid={'status': 'passed', 'before': before_pid, 'after': after_pid},
                             c11_key_window={'status': key_status, 'before': before_key, 'after': after_key})

        # Scenario 2: establish a real c11 frontmost PID and first-window key
        # identity before resizing the second window. Logical window.current is
        # deliberately not used as a substitute for either OS observation.
        second = {'name': '2-first-c11-window-key'}
        self.report['validator_scenarios']['2'] = second
        if not self.activate_app(self.bundle_id):
            second.update(status='unproven', reason='tagged c11 activation was unavailable in this guest')
            self.publish_focus_evidence(first, second)
            return
        before_pid = self.wait_frontmost(lambda pid: pid == self.args.pid)
        if before_pid != self.args.pid:
            second.update(status='unproven', reason='tagged c11 PID was not observed frontmost')
            self.publish_focus_evidence(first, second)
            return
        self.cli(['focus-window', '--window', self.first])
        self.wait_focus(self.first)
        before_key = self.key_window_if_present()
        if before_key is None:
            second.update(status='unproven', reason='headless guest reports no key window')
            self.publish_focus_evidence(first, second)
            return
        if before_key != self.first:
            second.update(status='unproven', reason='first c11 window could not be established as key')
            self.publish_focus_evidence(first, second)
            return

        self.resize(self.second, 1200, 800)
        after_pid = self.frontmost_pid()
        after_key = self.key_window_if_present()
        require(after_pid == before_pid,
                'resizing the second c11 window changed the real frontmost application PID')
        require(after_key == before_key,
                'resizing the second c11 window changed the first c11 key-window identity')
        second.update(status='passed',
                      frontmost_pid={'status': 'passed', 'before': before_pid, 'after': after_pid},
                      key_window={'status': 'passed', 'before': before_key, 'after': after_key})
        self.publish_focus_evidence(first, second)

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
        self.original_window = keys[0] if len(keys) == 1 else self.current_window()
        normal = self.fullscreen_checks(windows)
        self.first = self.original_window if self.original_window in normal else normal[0]
        self.second = self.rpc('window.create').get('window_id')
        require(bool(self.second) and self.second not in {row['id'] for row in windows}, 'second window was not created')
        self.cli(['focus-window', '--window', self.first])
        self.wait_focus(self.first)
        self.first_frame = self.resize(self.first)
        initial = self.resize(self.second)
        self.report['target_screen_at_start'] = self.screen_summary(initial['screen'])

        applied = self.resize(self.second, 1200, 800)
        self.assert_worker_dispatch('valid-cli-resize')
        self.assert_top_left(initial, applied)
        require(same_geometry(applied, self.resize(self.second)), 'applied resize must equal the next actual frame read')
        self.assert_logical_context_unchanged()
        self.report['cases'].append({'case': 'resize-second-top-left-and-logical-context',
                                     'applied': applied['applied'], 'clamped': applied['clamped'], 'passed': True})

        first_read, second_read = self.resize(self.second), self.resize(self.second)
        require(geometry(first_read) == geometry(second_read), 'repeated reads changed exact origin or size')
        self.assert_top_left(initial, second_read)
        self.assert_logical_context_unchanged()
        self.report['cases'].append({'case': 'read-keeps-frame-and-omits-write-edges', 'changed': False, 'passed': True})

        minimum = self.resize(self.second, 0, 0)
        require(minimum['clamped'] is True, 'undersized request must clamp instead of failing')
        smaller = self.resize(self.second, -1000000, -1000000)
        require(minimum['applied'] == smaller['applied'], 'smaller requests must clamp to the same minimum')
        require(same_geometry(minimum, self.resize(self.second)), 'minimum clamp differs from the actual frame')
        self.assert_top_left(initial, minimum)
        self.assert_logical_context_unchanged()
        self.report['cases'].append({'case': 'minimum-clamp', 'applied': minimum['applied'], 'passed': True})

        self.record_secondary_display_scenario(initial)

        maximum = self.resize(self.second, 1000000, 1000000)
        require(maximum['clamped'] is True, 'oversized request must clamp')
        require(same_geometry(maximum, self.resize(self.second)), 'maximum clamp differs from the actual frame')
        require(same_screen(initial['screen'], maximum['screen']),
                'maximum clamp must use the same owning screen as the target before resize')
        visible = maximum['screen']['visible_frame']
        require(close_number(maximum['applied']['width'], max(minimum['applied']['width'], visible['width'])) and
                close_number(maximum['applied']['height'], max(minimum['applied']['height'], visible['height'])),
                'maximum clamp must match this target window owning screen visible frame, respecting minimum')
        self.assert_top_left(initial, maximum)
        self.assert_logical_context_unchanged()
        self.report['cases'].append({'case': 'maximum-target-owning-screen-clamp',
                                     'owning_screen': self.screen_summary(maximum['screen']),
                                     'applied': maximum['applied'], 'passed': True})

        partial = self.resize(self.second, None, 900)
        require(close_number(partial['applied']['width'], maximum['applied']['width']), 'kept width changed')
        self.assert_top_left(initial, partial)
        self.assert_logical_context_unchanged()
        self.report['cases'].append({'case': 'keep-one-edge', 'passed': True})

        before = self.resize(self.first)
        result = self.cli(['resize-window', '--window', str(uuid.uuid4()), '1200', '800'], accepted=False)
        require(result.returncode != 0 and 'not_found' in result.stderr, 'unknown UUID must return not_found')
        require(same_geometry(before, self.resize(self.first)), 'invalid UUID modified the first window frame')
        self.assert_logical_context_unchanged()
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
            self.assert_logical_context_unchanged()
            self.report['cases'].append({'case': 'invalid-cli-' + label, 'forwarded_requests': 0,
                                         'frames_and_logical_context_unchanged': True, 'passed': True})

        before = self.resize(self.second)
        for key in ('width', 'height'):
            for value in (True, False, '800', 'not-a-size'):
                self.rpc_error('window.resize', {'window_id': self.second, key: value}, 'invalid_params')
                require(same_geometry(before, self.resize(self.second)), 'invalid RPC parameter modified the target frame')
                self.assert_logical_context_unchanged()
        self.assert_worker_dispatch('invalid-RPC-dimensions')
        self.report['cases'].append({'case': 'bool-and-string-rpc-params-rejected', 'invalid_params_count': 8, 'passed': True})

        self.record_focus_scenarios()

    def cleanup(self):
        if self.second:
            self.rpc('window.close', {'window_id': self.second})
            self.report['cleanup']['second_window_closed'] = all(row['id'] != self.second for row in self.windows())
        if self.original_window:
            self.rpc('window.focus', {'window_id': self.original_window})
            self.wait_focus(self.original_window)
            self.report['cleanup']['original_window_selected'] = self.current_window() == self.original_window
            key = self.key_window_if_present()
            self.report['cleanup']['key_window_identity'] = (
                {'status': 'passed', 'window_id': key} if key == self.original_window else
                {'status': 'failed', 'window_id': key} if key is not None else
                {'status': 'unproven_no_key_window'}
            )
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
        harness.report['cleanup'].get('original_window_selected') and
        harness.report['cleanup'].get('first_frame_unchanged'))
    print(json.dumps(harness.report, sort_keys=True))
    return 0 if harness.report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
