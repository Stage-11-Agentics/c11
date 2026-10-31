#!/usr/bin/env python3
"""C11-525 native terminal-link acceptance, ONLY via sandbox-tests-v2.sh.

The 420-second active / 470-second hard limits include native input and cleanup.
Socket calls seed fixtures and read oracles; link/menu activation uses native
guest input. No builds, agent sessions, external pages or tenant config writes.

Claude 2.1.316 and Codex 0.165.0 were measured in actual interactive sessions on
2026-10-31 Pacific. This is a replay of their measured hyperlink byte forms,
substituting live UUIDs/titles, not a claim of new interactive-agent execution.
The original captures and rendering-summary.json are in C11-525's evidence dir.
"""
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import signal
import socket
import struct
import subprocess
import threading
import time
import traceback
import uuid
import zlib


OUT = Path('/Volumes/My Shared Files/out/terminal-panel-link-proof')
ACTIVE_SECONDS, HARD_SECONDS = 420, 470
SOURCE_TITLE = 'C11-525 Source'
DESTINATION_TITLE = 'C11-525 Destination'
TARGET_TITLE = 'Real Destination'
PREVIEW_ID = 'c11.panel-link.preview'
NOTICE_ID = 'c11.panel-link.notice'
COLUMN = 4
ROWS = dict(bare=7, claude=9, codex=11, workspace=13, deceptive=15,
            malformed=17, stale=19, opaque=21, current=23)

# The OSC parameters, BEL delimiters, SGR and horizontal cursor positioning
# reproduce the captured Claude output. Full TUI redraw streams are not replayed.
CLAUDE_CAPTURE_SHA256 = 'afc8d34c0996564deb944d480960df3ff8e44f5645268f5a89d0e850d82e370f'
CODEX_CAPTURE_SHA256 = '5ac817a7ff1f52ffa429010ccae567df248bf0e0029a3590198cb04fe4d4ad54'

UI = r'''
ObjC.import('AppKit');
ObjC.import('CoreGraphics');
ObjC.bindFunction('CGWindowListCopyWindowInfo', ['id', ['uint32', 'uint32']]);
function run(args) {
    var pid = Number(args[0]), op = args[1];
    var p = Application('System Events').processes.whose({unixId: pid})[0];
    if (!p.exists()) throw Error('Exact guest PID disappeared');
    if (op === 'activate') { p.frontmost = true; return JSON.stringify(p.frontmost()); }
    if (op === 'foreground') return JSON.stringify(Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier));
    if (op === 'displays') {
        var screens = $.NSScreen.screens, displays = [];
        for (var i = 0; i < Number(screens.count); ++i) {
            var s = screens.objectAtIndex(i), f = s.frame;
            displays.push({id: Number(ObjC.unwrap(s.deviceDescription.objectForKey('NSScreenNumber'))),
                x: f.origin.x, y: f.origin.y, width: f.size.width, height: f.size.height});
        }
        var ws = ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(0, 0));
        return JSON.stringify({displays: displays, windows: ws.filter(function(w) {
            return w.kCGWindowOwnerPID === pid && w.kCGWindowLayer === 0 &&
                w.kCGWindowIsOnscreen && w.kCGWindowBounds.Width > 300;
        })});
    }
    if (op === 'clipboard') {
        var pb = $.NSPasteboard.generalPasteboard;
        function value(type) { var v = pb.stringForType(type); return v.isNil() ? null : ObjC.unwrap(v); }
        return JSON.stringify({text: value('public.utf8-plain-text'), url: value('public.url')});
    }
    function attr(e, key) { try { return e.attributes.byName(key).value(); } catch (_) { return null; } }
    var hits = [], menuHits = [];
    function walk(e, depth) {
        if (depth > 18) return;
        if (op === 'menu') {
            if (menuHits.length) return;
            var menuRole = attr(e, 'AXRole');
            if (menuRole === 'AXMenuItem') {
                var menuTitle = attr(e, 'AXTitle'), menuDescription = attr(e, 'AXDescription');
                hits.push({role: menuRole, title: menuTitle, description: menuDescription});
                if (menuTitle === args[2] || menuDescription === args[2]) menuHits.push(e);
            }
            if (menuRole === 'AXTextArea' || menuRole === 'AXWebArea') return;
            try { e.uiElements().forEach(function(c) { walk(c, depth + 1); }); } catch (_) {}
            return;
        }
        if (op === 'find') {
            if (hits.length) return;
            var identifier = attr(e, 'AXIdentifier'), findRole = attr(e, 'AXRole');
            if (identifier === args[2]) {
                hits.push({id: identifier, role: findRole, value: attr(e, 'AXValue'), title: attr(e, 'AXTitle')});
                return;
            }
            if (findRole === 'AXTextArea' || findRole === 'AXWebArea') return;
            try { e.uiElements().forEach(function(c) { walk(c, depth + 1); }); } catch (_) {}
            return;
        }
        var role = attr(e, 'AXRole'), title = attr(e, 'AXTitle'), desc = attr(e, 'AXDescription');
        var info = {id: attr(e, 'AXIdentifier'), role: role, title: title, description: desc,
            value: attr(e, 'AXValue'), help: attr(e, 'AXHelp'), position: attr(e, 'AXPosition'), size: attr(e, 'AXSize')};
        hits.push(info);
        if (role === 'AXMenuItem' && (title === args[2] || desc === args[2])) menuHits.push(e);
        if (role === 'AXTextArea' || role === 'AXWebArea') return;
        try { e.uiElements().forEach(function(c) { walk(c, depth + 1); }); } catch (_) {}
    }
    if (op === 'menu') {
        // AppKit can expose a context menu on the process or beneath its
        // originating window/control. Search only role/title until found.
        p.menus().forEach(function(m) { walk(m, 0); });
        if (!menuHits.length) p.windows().forEach(function(w) { walk(w, 0); });
        if (menuHits.length !== 1) throw Error('Expected one native menu item ' + args[2] + ': ' + JSON.stringify(hits));
        menuHits[0].click();
        return JSON.stringify(hits);
    }
    p.windows().forEach(function(w) { walk(w, 0); });
    return JSON.stringify(hits);
}
'''


def png_pixels(path):
    """Read Apple's non-interlaced RGB/RGBA PNG without extra guest packages."""
    data = Path(path).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    offset, compressed = 8, bytearray()
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        kind, body = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + length]
        if kind == b'IHDR':
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', body)
            assert depth == 8 and color in (2, 6) and (compression, filtering, interlace) == (0, 0, 0)
        elif kind == b'IDAT':
            compressed.extend(body)
        offset += length + 12
    channels = 3 if color == 2 else 4
    stride = width * channels
    raw = zlib.decompress(compressed)
    assert len(raw) == height * (stride + 1)
    previous, rows = bytearray(stride), []
    for y in range(height):
        start = y * (stride + 1)
        mode, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        assert 0 <= mode <= 4
        for x in range(stride):
            a = row[x - channels] if x >= channels else 0
            b = previous[x]
            c = previous[x - channels] if x >= channels else 0
            if mode == 1:
                predictor = a
            elif mode == 2:
                predictor = b
            elif mode == 3:
                predictor = (a + b) // 2
            elif mode == 4:
                p = a + b - c
                distances = [abs(p - a), abs(p - b), abs(p - c)]
                predictor = (a, b, c)[distances.index(min(distances))]
            else:
                predictor = 0
            row[x] = (row[x] + predictor) & 255
        rows.append(row)
        previous = row
    return width, height, channels, rows


class Proof:
    def __init__(self):
        self.started = time.monotonic()
        self.socket_path = os.environ.get('C11_SOCKET_PATH', '')
        assert re.fullmatch(r'/tmp/c11-sandbox-[A-Za-z0-9._-]+\.sock', self.socket_path), 'sandbox socket required'
        self.run_id = self.socket_path.removeprefix('/tmp/c11-sandbox-').removesuffix('.sock')
        assert OUT.parent.is_dir(), 'guest shared output required'
        self.app_root = Path('/Users/admin/c11-sandbox/apps') / self.run_id
        apps = list(self.app_root.glob('*.app'))
        assert len(apps) == 1, apps
        self.app = apps[0]
        self.executable = self.app / 'Contents/MacOS/c11'
        lines = subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True, timeout=5).splitlines()
        pids = [int(line.strip().split(None, 1)[0]) for line in lines
                if line.strip().split(None, 1)[-1] == str(self.executable)]
        assert len(pids) == 1, ('exact guest app missing', pids)
        self.pid = pids[0]
        self.cli = self.app / 'Contents/Resources/bin/c11'
        assert self.cli.is_file()
        with (self.app / 'Contents/Info.plist').open('rb') as stream:
            self.bundle = plistlib.load(stream)
        assert self.bundle['CFBundleIdentifier'].startswith('com.stage11.c11.debug.'), 'tagged dev bundle required'
        # No inherited live connection or panel context may affect a subprocess.
        for key in list(os.environ):
            if key.startswith(('C11_SOCKET', 'CMUX_SOCKET')) or key in (
                    'C11_PANEL_ID', 'CMUX_SURFACE_ID', 'C11_WORKSPACE_ID', 'CMUX_WORKSPACE_ID',
                    'C11_WINDOW_ID', 'CMUX_WINDOW_ID'):
                del os.environ[key]
        os.environ['C11_SOCKET_PATH'] = '/tmp/c11-525-no-default.sock'
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(8)
        self.sock.connect(self.socket_path)
        # Connect then identify the listener owner, before any native input.
        listeners = subprocess.check_output(['/usr/sbin/lsof', '-nP', '-a', '-p', str(self.pid), '-U'], text=True, timeout=5)
        assert self.socket_path in listeners, 'socket is not owned by exact guest PID'
        self.reader, self.sequence = self.sock.makefile('rb'), 0
        self.log = Path(f'/tmp/c11-sandbox-{self.run_id}.log')
        self.log_start = self.log.stat().st_size if self.log.exists() else 0
        self.fixture = Path('/tmp') / ('c11-525-fixture-' + self.run_id)
        self.fixture.mkdir(exist_ok=True)
        OUT.mkdir(exist_ok=True)
        self.report = dict(status='running', identity=dict(pid=self.pid, app=str(self.app),
            bundle=self.bundle['CFBundleIdentifier'], socket=self.socket_path), checks=[], limitations=[
                'Measured renderer byte-form replay; no new live Claude or Codex session.',
                'Rejected-link logs, unchanged native foreground and browser inventory are observed; no OS opener spy is installed.'])
        self.watchdog = threading.Timer(max(.1, HARD_SECONDS - (time.monotonic() - self.started)), self.hard_stop)
        self.watchdog.daemon = True
        self.watchdog.start()
        signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('420-second active deadline')))
        signal.setitimer(signal.ITIMER_REAL, max(.1, ACTIVE_SECONDS - (time.monotonic() - self.started)))

    def hard_stop(self):
        try:
            subprocess.run(['/opt/homebrew/bin/cliclick', 'ku:cmd'], timeout=2, check=False)
            os.kill(self.pid, signal.SIGTERM)
        finally:
            (OUT / 'hard-timeout.txt').write_text('470-second hard timeout; Command released; exact guest PID terminated.\n')
            os._exit(124)

    def run(self, command, **kwargs):
        return subprocess.run(command, check=True, capture_output=True, timeout=12, **kwargs)

    def ui(self, operation, *args):
        return json.loads(self.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', UI,
                                   str(self.pid), operation, *args], text=True).stdout)

    def raw(self, method, **params):
        self.sequence += 1
        self.sock.sendall((json.dumps(dict(id=self.sequence, method=method, params=params)) + '\n').encode())
        result = json.loads(self.reader.readline())
        assert result['id'] == self.sequence
        return result

    def call(self, method, **params):
        result = self.raw(method, **params)
        assert result.get('ok'), (method, result)
        return result.get('result')

    def wait(self, predicate, label, timeout=8):
        deadline, last = time.monotonic() + timeout, None
        while time.monotonic() < deadline:
            try:
                value = predicate()
                if value:
                    return value
            except (AssertionError, subprocess.CalledProcessError) as error:
                last = str(error)
            time.sleep(.12)
        raise AssertionError((label, last))

    def passed(self, label, **evidence):
        self.report['checks'].append(dict(label=label, elapsed=round(time.monotonic() - self.started, 2), **evidence))
        print('PASS', label, flush=True)

    def focused(self):
        return self.call('system.identify', window_id=self.window)['focused']

    def selection(self):
        state = self.focused()
        return state['workspace_id'].lower(), state['panel_id'].lower()

    def ensure_frontmost(self):
        assert self.ui('foreground') == self.pid, 'exact guest PID must be foreground'

    def native(self, *commands):
        self.ensure_frontmost()
        return self.run(['/opt/homebrew/bin/cliclick', *commands])

    def key(self, code, modifiers=''):
        self.ensure_frontmost()
        suffix = ' using {' + modifiers + '}' if modifiers else ''
        body = f'tell application "System Events" to tell (first process whose unix id is {self.pid}) to key code {code}{suffix}'
        self.run(['/usr/bin/osascript', '-e', body])

    def screenshot(self, name):
        self.ensure_frontmost()
        displays = self.ui('displays')
        assert len(displays['displays']) == 1
        matches = [w for w in displays['windows'] if w['kCGWindowNumber'] == self.window_number]
        assert len(matches) == 1, displays
        # The sole verified guest display avoids macOS's separate private-window
        # picker permission, which can steal focus after a window capture.
        self.run(['/usr/sbin/screencapture', '-x', '-D', '1', str(OUT / (name + '.png'))])

    def ax(self, identifier=None):
        # Query only the required attributes and stop at the target. A full
        # window inventory can outlast the five-second nonmodal notice.
        return self.ui('find', identifier) if identifier else self.ui('inspect')

    def terminal_text(self):
        result = self.call('panel.read_text', workspace_id=self.source_workspace, panel_id=self.source)
        return result.get('text') or base64.b64decode(result.get('base64', '')).decode(errors='replace')

    def decisions(self):
        if not self.log.exists():
            return []
        with self.log.open('rb') as stream:
            stream.seek(self.log_start)
            lines = stream.read().decode(errors='replace').splitlines()
        return [json.loads(line.split('panel_link ', 1)[1]) for line in lines if 'panel_link {' in line]

    def browser_inventory(self):
        result = {}
        for workspace in self.call('workspace.list', window_id=self.window)['workspaces']:
            result[workspace['id']] = sorted(p['id'] for p in self.call('panel.list', workspace_id=workspace['id'])['panels'] if p['type'] == 'browser')
        return result

    def back(self):
        # Fresh QA fixture has exactly two workspaces; verify the ordering each
        # time before invoking the real operator's Cmd+1 shortcut.
        workspaces = self.call('workspace.list', window_id=self.window)['workspaces']
        assert len(workspaces) == 2 and workspaces[0]['id'].lower() == self.source_workspace.lower(), workspaces
        self.key(18, 'command down')
        self.wait(lambda: self.selection() == (self.source_workspace.lower(), self.source.lower()), 'native return to source')
        time.sleep(.15)

    def seed(self):
        capabilities = self.call('system.capabilities')
        features = {entry['id']: entry['version'] for entry in capabilities['features']}
        assert features.get('links.panel') == features.get('links.terminal') == 1, features
        assert not any(re.search(r'^(?:terminal|panel|workspace)\.(?:link|open_link|click_link)', method)
                       or method in ('link.open', 'links.open', 'panel_link.activate')
                       for method in capabilities['methods']), capabilities['methods']
        (OUT / 'capabilities.json').write_text(json.dumps(capabilities, indent=2))
        self.passed('links.panel v1 and links.terminal v1 advertised; no dedicated link activation socket method')
        self.ui('activate')
        self.wait(lambda: self.ui('foreground') == self.pid, 'guest PID foreground')
        display = self.ui('displays')
        assert len(display['displays']) == len(display['windows']) == 1, display
        assert display['displays'][0]['width'] >= 1000 and display['displays'][0]['height'] >= 700
        self.window_number = display['windows'][0]['kCGWindowNumber']
        windows = self.call('window.list')['windows']
        assert len(windows) == 1 and windows[0]['key'], windows
        self.window = windows[0]['id']
        self.source_workspace = self.focused()['workspace_id']
        workspaces = self.call('workspace.list', window_id=self.window)['workspaces']
        assert len(workspaces) == 1, 'fresh QA guest required'
        self.call('workspace.rename', workspace_id=self.source_workspace, title=SOURCE_TITLE + ' Workspace')
        panels = self.call('panel.list', workspace_id=self.source_workspace)['panels']
        assert panels and all(p['type'] == 'terminal' for p in panels), panels
        self.source = self.focused()['panel_id']
        for panel in panels:
            if panel['id'] != self.source:
                self.call('panel.close', workspace_id=self.source_workspace, panel_id=panel['id'])
        self.call('panel.action', workspace_id=self.source_workspace, panel_id=self.source, action='rename', title=SOURCE_TITLE)
        self.destination = self.call('workspace.create', window_id=self.window, title=DESTINATION_TITLE)['workspace_id']
        self.target = next(p['id'] for p in self.call('panel.list', workspace_id=self.destination)['panels'] if p['type'] == 'terminal')
        for panel in self.call('panel.list', workspace_id=self.destination)['panels']:
            if panel['id'] != self.target:
                self.call('panel.close', workspace_id=self.destination, panel_id=panel['id'])
        self.call('panel.action', workspace_id=self.destination, panel_id=self.target, action='rename', title=TARGET_TITLE)
        self.browser = self.call('panel.create', workspace_id=self.destination, type='browser')['panel_id']
        self.call('panel.focus', workspace_id=self.destination, panel_id=self.browser)
        self.target_url = 'c11://panel/' + self.target.lower()
        self.workspace_url = 'c11://workspace/' + self.destination.lower()
        self.urls = dict(bare=self.target_url, claude=self.target_url, codex=self.target_url,
            workspace=self.workspace_url, deceptive=self.target_url,
            malformed='c11://panel/not-a-uuid', stale='c11://panel/' + str(uuid.uuid4()),
            opaque='c11:panel/' + self.target.lower(), current='c11://panel/' + self.source.lower())
        self.labels = dict(bare=self.target_url, claude=TARGET_TITLE,
            codex=TARGET_TITLE + ' (' + self.target_url + ')', workspace=self.workspace_url,
            deceptive='Harmless release notes', malformed='Malformed c11 target',
            stale='Closed destination', opaque='Opaque c11 target', current='This source panel')
        output = '\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l'
        for row, col, color in [(2, 2, '255;0;255'), (2, 12, '0;255;255'), (4, 2, '255;255;0')]:
            output += f'\x1b[{row};{col}H\x1b[48;2;{color}m \x1b[0m'
        output += '\x1b[5;4HC11-525 measured renderer form replay'
        forms = {}
        for kind, row in ROWS.items():
            label, url = self.labels[kind], self.urls[kind]
            if kind == 'claude':
                form = f'\x1b]8;id=1okfgqu;{url}\x07\x1b[94m{label}\x1b[{COLUMN + len(label) + 1}G\x1b]8;;\x07\x1b[39m'
            elif kind in ('deceptive', 'malformed', 'stale', 'opaque', 'current'):
                form = f'\x1b]8;;{url}\x07{label}\x1b]8;;\x07'
            else:
                form = label
            forms[kind] = form
            output += f'\x1b[{row};{COLUMN}H' + form
        payload = self.fixture / 'payload.bin'
        payload.write_bytes(output.encode())
        (OUT / 'fixture-output.bin').write_bytes(payload.read_bytes())
        (OUT / 'rendering-replay.json').write_text(json.dumps(dict(
            method='Measured hyperlink forms replayed with live UUID/title substitutions; not full interactive TUI replay',
            claude=dict(version='2.1.316', capture_sha256=CLAUDE_CAPTURE_SHA256),
            codex=dict(version='0.165.0', capture_sha256=CODEX_CAPTURE_SHA256), forms=forms,
            payload_sha256=hashlib.sha256(payload.read_bytes()).hexdigest()), indent=2))
        program = self.fixture / 'emit.py'
        program.write_text('''import json, os, select, signal, sys, termios, time, tty
from pathlib import Path
root = Path(sys.argv[1])
old = termios.tcgetattr(0)
def stop(*args): raise SystemExit()
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGALRM, stop)
signal.alarm(440)
try:
    tty.setraw(0)
    size = os.get_terminal_size(1)
    (root / 'geometry.json').write_text(json.dumps(dict(columns=size.columns, rows=size.lines, pid=os.getpid())))
    os.write(1, (root / 'payload.bin').read_bytes())
    while not (root / 'stop').exists():
        if select.select([0], [], [], .1)[0]: os.read(0, 4096)
finally:
    os.write(1, b'\\x1b[0m\\x1b[?25h\\x1b[?1049l')
    termios.tcsetattr(0, termios.TCSANOW, old)
''')
        (self.fixture / 'stop').unlink(missing_ok=True)
        command = '/usr/bin/python3 ' + shlex.quote(str(program)) + ' ' + shlex.quote(str(self.fixture)) + '\n'
        self.call('panel.send_text', workspace_id=self.source_workspace, panel_id=self.source, text=command)
        self.wait(lambda: (self.fixture / 'geometry.json').exists() and self.labels['codex'] in self.terminal_text(), 'fixture printed complete measured forms')
        self.report['identity'].update(source_workspace=self.source_workspace, source=self.source,
            destination=self.destination, target=self.target, remembered_browser=self.browser,
            window=self.window, cg_window=self.window_number, display=display['displays'][0])
        self.calibrate()
        self.screenshot('01-source')

    def calibrate(self):
        geometry = json.loads((self.fixture / 'geometry.json').read_text())
        assert geometry['columns'] >= max(map(len, self.labels.values())) + COLUMN and geometry['rows'] >= 25, geometry
        time.sleep(.2)
        snapshot = self.call('debug.panel_snapshot', panel_id=self.source, label='c11-525-calibration')
        image = Path(snapshot['path'])
        (OUT / 'calibration.png').write_bytes(image.read_bytes())
        width, height, channels, pixels = png_pixels(image)
        assert (width, height) == (snapshot['width'], snapshot['height'])
        boxes = {key: [] for key in ('magenta', 'cyan', 'yellow')}
        for y, row in enumerate(pixels):
            for x in range(width):
                r, g, b = row[x * channels:x * channels + 3]
                # The renderer snapshot is color-managed. Classify channel
                # dominance, then require unique solid one-cell rectangles,
                # instead of assuming literal sRGB bytes survive its profile.
                key = ('magenta' if min(r, b) > 200 and g + 80 < min(r, b) else
                       'cyan' if min(g, b) > 200 and r + 80 < min(g, b) else
                       'yellow' if min(r, g) > 200 and b + 80 < min(r, g) else None)
                if key:
                    boxes[key].append((x, y))
        bounds = {}
        for key, points in boxes.items():
            assert points, ('calibration color missing', key)
            xs, ys = zip(*points)
            box = (min(xs), min(ys), max(xs) + 1, max(ys) + 1)
            assert len(points) == (box[2] - box[0]) * (box[3] - box[1]), ('nonrectangular marker', key, box)
            bounds[key] = box
        magenta, cyan, yellow = (bounds[k] for k in ('magenta', 'cyan', 'yellow'))
        cell_width, cell_height = (cyan[0] - magenta[0]) / 10, (yellow[1] - magenta[1]) / 2
        assert 4 <= cell_width <= 80 and 8 <= cell_height <= 100
        assert magenta[1] == cyan[1] and magenta[0] == yellow[0]
        for box in bounds.values():
            assert abs(box[2] - box[0] - cell_width) <= 1 and abs(box[3] - box[1] - cell_height) <= 1
        text_areas = [e for e in self.ax() if e['role'] == 'AXTextArea' and e['help'] == 'Terminal content area'
                      and e['size'] and e['size'][0] > 100 and e['size'][1] > 100]
        assert len(text_areas) == 1, text_areas
        self.terminal_frame = text_areas[0]
        scale_x = width / self.terminal_frame['size'][0]
        scale_y = height / self.terminal_frame['size'][1]
        assert .9 <= scale_x <= 3.1 and abs(scale_x - scale_y) < .02, (snapshot, self.terminal_frame)
        self.grid = dict(x=magenta[0] - cell_width, y=magenta[1] - cell_height,
                         width=cell_width, height=cell_height, scale=scale_x)
        assert self.grid['x'] >= 0 and self.grid['y'] >= 0
        assert self.grid['x'] + geometry['columns'] * cell_width <= width + 1
        assert self.grid['y'] + geometry['rows'] * cell_height <= height + 1
        self.report['geometry'] = dict(terminal=self.terminal_frame, markers=bounds, grid=self.grid, tty=geometry)

    def point(self, kind):
        assert self.selection() == (self.source_workspace.lower(), self.source.lower())
        assert self.labels[kind] in self.terminal_text(), ('fixture text changed', kind)
        grid = self.grid
        # Pick safely inside the visible link; Codex clicks inside the URL,
        # which is the matcher path rather than its nonhyperlinked title.
        column = COLUMN + (len(TARGET_TITLE) + 4 if kind == 'codex' else 2)
        x = self.terminal_frame['position'][0] + (grid['x'] + (column - .5) * grid['width']) / grid['scale']
        y = self.terminal_frame['position'][1] + (grid['y'] + (ROWS[kind] - .5) * grid['height']) / grid['scale']
        assert all(lo < v < lo + size for v, lo, size in zip((x, y), self.terminal_frame['position'], self.terminal_frame['size']))
        return round(x), round(y)

    def click_link(self, kind, command=True):
        x, y = self.point(kind)
        try:
            if command:
                # Drive the real focused-terminal flow. Cmd flags must reach
                # this surface before Ghostty computes the hovered link.
                self.run(['/opt/homebrew/bin/cliclick', 'ku:cmd'])
                blank_x = self.terminal_frame['position'][0] + 20
                blank_y = self.terminal_frame['position'][1] + self.terminal_frame['size'][1] - 30
                self.native_click(blank_x, blank_y)
                self.native('kd:cmd')
                self.native_mouse(x, y, (5,), command=True)
                self.wait(lambda: any(self.urls[kind] in str(e.get('value', ''))
                                      for e in self.ax(PREVIEW_ID)), kind + ' actual link preview')
            else:
                self.native_mouse(x, y, (5,))
            self.native_click(x, y, command=command)
        finally:
            if command:
                self.run(['/opt/homebrew/bin/cliclick', 'ku:cmd'])

    def native_click(self, x, y, command=False):
        self.native_mouse(x, y, (1, 2), command=command)

    def native_mouse(self, x, y, event_types, command=False):
        # Explicit HID mouse events were independently proved against this
        # guest after cliclick's combined key/move/click did not activate links.
        self.ensure_frontmost()
        class Point(ctypes.Structure):
            _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]
        cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
        cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
        cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        for event_type in event_types:
            event = cg.CGEventCreateMouseEvent(None, event_type, Point(x, y), 0)
            assert event
            cg.CGEventSetFlags(event, (1 << 20) if command else 0)
            cg.CGEventSetIntegerValueField(event, 1, 1)
            cg.CGEventPost(0, event)
            cf.CFRelease(event)
            time.sleep(.12)

    def activation(self, kind, workspace, panel):
        before = len(self.decisions())
        # The existing debug counter resolves only the selected workspace and
        # counts terminal rings. Read it after native landing, retaining that
        # value for the next visit. Browser pulse evidence is its screenshot.
        terminal = panel in (self.source, self.target)
        flashes = self.flash_counts.get(panel, 0)
        if terminal and self.selection() == (workspace.lower(), panel.lower()):
            flashes = self.call('debug.flash.count', panel_id=panel)['count']
        self.click_link(kind)
        self.wait(lambda: self.selection() == (workspace.lower(), panel.lower()), kind + ' landed')
        if terminal:
            self.wait(lambda: self.call('debug.flash.count', panel_id=panel)['count'] > flashes, kind + ' flash')
            self.flash_counts[panel] = self.call('debug.flash.count', panel_id=panel)['count']
        self.wait(lambda: len(self.decisions()) > before, kind + ' structured decision')
        decisions = self.decisions()[before:]
        assert len(decisions) == 1 and decisions[0] == dict(target=self.urls[kind], origin='terminal',
            activation='native_command_click', result='opened'), decisions
        self.passed(kind + ' native landing' + (' and flash' if terminal else ''), target=panel,
                    flash_before=flashes if terminal else None,
                    flash_after=self.flash_counts.get(panel), decision=decisions[0])

    def hover(self):
        x, y = self.point('deceptive')
        before = self.selection()
        try:
            self.native('kd:cmd', f'm:{x},{y}')
            entries = self.wait(lambda: self.ax(PREVIEW_ID), 'native Command-hover preview')
            text = '\n'.join(str(e.get('value') or e.get('title') or '') for e in entries)
            assert TARGET_TITLE in text and DESTINATION_TITLE in text and self.target_url in text, text
            assert self.labels['deceptive'] not in text, text
            assert self.selection() == before
            self.screenshot('05-deceptive-preview')
            self.passed('5 deceptive OSC8 hover shows real title, workspace and URI', preview=text)
        finally:
            self.run(['/opt/homebrew/bin/cliclick', 'ku:cmd'])
            self.native('m:10,10')
        self.wait(lambda: not self.ax(PREVIEW_ID), 'preview dismissed by native pointer leave')

    def rejected_links(self):
        for kind in ('malformed', 'stale', 'opaque'):
            before, browsers, decision_count = self.selection(), self.browser_inventory(), len(self.decisions())
            self.click_link(kind)
            self.wait(lambda: len(self.decisions()) > decision_count, kind + ' consumed decision')
            decisions = self.decisions()[decision_count:]
            expected = 'unavailable' if kind == 'stale' else 'invalid_target'
            assert len(decisions) == 1 and decisions[0]['target'] == self.urls[kind] and decisions[0]['result'] == expected, decisions
            self.wait(lambda: self.ax(NOTICE_ID), kind + ' non-modal notice')
            assert self.selection() == before and self.browser_inventory() == browsers
            self.ensure_frontmost()
            self.screenshot('06-' + kind + '-notice')
            self.passed('6 ' + kind + ' consumed, notice shown, selection and browsers unchanged', decision=decisions[0])

    def cli_forms(self):
        before = self.selection()
        records = []
        for kind, target, workspace in [('panel', self.target, self.destination), ('workspace', self.destination, None)]:
            argv = [str(self.cli), '--socket', self.socket_path, 'link', '--' + kind, target]
            if workspace:
                argv += ['--workspace', workspace]
            payload = json.loads(self.run(argv + ['--json'], text=True).stdout)
            expected = f'c11://{kind}/{target.lower()}'
            assert payload['id'] == target.lower() and payload['url'] == expected
            assert payload['kind'] == kind and payload['workspace']['id'] == self.destination.lower()
            assert payload['ref'].startswith(kind + ':'), payload
            for form in ('url', 'markdown', 'osc8'):
                output = self.run(argv + ['--format', form]).stdout
                assert output == (payload[form] + '\n').encode(), (form, output, payload)
            ref_args = [str(self.cli), '--socket', self.socket_path, 'link', '--' + kind, payload['ref']]
            assert self.run(ref_args, text=True).stdout.strip() == expected
            records.append(payload)
        for kind in ('panel', 'workspace'):
            for missing in (str(uuid.uuid4()), kind + ':2147483647'):
                failed = subprocess.run([str(self.cli), '--socket', self.socket_path, 'link', '--' + kind, missing],
                                        capture_output=True, text=True, timeout=12)
                assert failed.returncode != 0 and 'not_found' in failed.stderr, failed
        assert self.selection() == before
        (OUT / 'cli-forms.json').write_text(json.dumps(records, indent=2))
        self.passed('7 CLI URL/Markdown/OSC8/JSON, live short refs and missing UUIDs; selection unchanged')
        guide = self.run([str(self.cli), 'guide'], text=True).stdout
        (OUT / 'bundled-guide.txt').write_text(guide)
        assert 'titled links' in guide and 'c11 link --panel' in guide and 'Cmd-click' in guide, 'built skill lacks terminal-link reporting contract'
        self.passed('10 bundled c11 guide teaches titled links and terminal activation')

    def copy_link(self, title, expected, sidebar=False):
        entries = self.ax()
        sidebars = [e for e in entries if e['id'] == 'Sidebar' and e['role'] == 'AXScrollArea']
        assert len(sidebars) == 1 and sidebars[0]['position'] and sidebars[0]['size'], sidebars
        edge = sidebars[0]['position'][0] + sidebars[0]['size'][0]
        def matches_title(entry):
            return any(isinstance(value, str) and re.fullmatch(r'(?:\d+: )?' + re.escape(title), value)
                       for value in (entry.get('title'), entry.get('description'), entry.get('value')))
        candidates = [e for e in entries if matches_title(e)
                      and e['position'] and e['size'] and e['size'][0] > 0 and e['size'][1] > 0
                      and ((e['position'][0] < edge) if sidebar else (e['position'][0] >= edge))]
        if not sidebar:
            candidates = [e for e in candidates if e['position'][1] < self.terminal_frame['position'][1]]
        if not candidates:
            # SwiftUI exposes these labels as anonymous controls on the guest.
            # Bind their AX rectangles to the independently verified fixture
            # order, then let the exact clipboard URI verify the target.
            if sidebar:
                workspaces = self.call('workspace.list', window_id=self.window)['workspaces']
                assert [w['id'].lower() for w in workspaces] == [self.source_workspace.lower(), self.destination.lower()]
                rows = sorted((e for e in entries if e['id'] == 'SidebarTabSurfaceMetricsPlaceholder'
                               and e['position'] and e['size']), key=lambda e: e['position'][1])
                assert len(rows) == 2 and rows[0]['position'][1] + rows[0]['size'][1] <= rows[1]['position'][1], rows
                assert title == DESTINATION_TITLE
                candidates = [rows[1]]
            else:
                panels = self.call('panel.list', workspace_id=self.source_workspace)['panels']
                assert len(panels) == 1 and panels[0]['id'].lower() == self.source.lower()
                candidates = [e for e in entries if e['role'] == 'AXButton' and e['position'] and e['size']
                              and e['position'][0] >= edge and e['position'][1] < self.terminal_frame['position'][1]
                              and e['size'][0] > 50 and e['size'][1] >= 20]
                assert len(candidates) == 1, candidates
        assert candidates, ('native context target missing', title, sidebar)
        # Nested AX wrappers can share the same label. The smallest labelled
        # rectangle is the actual title; its center must lie inside every
        # larger matching wrapper, otherwise ambiguity fails closed.
        target = min(candidates, key=lambda e: e['size'][0] * e['size'][1])
        point = [p + s / 2 for p, s in zip(target['position'], target['size'])]
        assert all(all(lo <= v <= lo + size for v, lo, size in zip(point, e['position'], e['size'])) for e in candidates), candidates
        before = self.selection()
        self.native(f'rc:{round(point[0])},{round(point[1])}')
        try:
            menu = self.ui('menu', 'Copy Link')
            clipboard = self.ui('clipboard')
            assert clipboard == dict(text=expected, url=expected), clipboard
            assert self.selection() == before
            self.passed('8 native Copy Link ' + ('nonselected workspace row' if sidebar else 'panel tab'), clipboard=clipboard, menu=menu)
        finally:
            self.key(53)

    def execute(self):
        self.seed()
        before, decisions = self.selection(), len(self.decisions())
        self.click_link('bare', command=False)
        time.sleep(.3)
        assert self.selection() == before and len(self.decisions()) == decisions
        self.passed('4 plain click leaves navigation unchanged')
        self.hover()
        self.call('debug.flash.reset')
        self.flash_counts = {}
        # The browser was made the destination's remembered panel during
        # setup. Visit it before terminal links replace that remembered panel.
        self.activation('workspace', self.destination, self.browser)
        self.screenshot('03-workspace-remembered-browser')
        self.back()
        for kind in ('bare', 'claude', 'codex'):
            for index in range(3):
                self.activation(kind, self.destination, self.target)
                self.screenshot(f'0{1 if kind == "bare" else 2}-{kind}-{index + 1}-landing')
                self.back()
        for _ in range(3):
            self.activation('current', self.source_workspace, self.source)
        self.rejected_links()
        self.cli_forms()
        self.copy_link(SOURCE_TITLE, 'c11://panel/' + self.source.lower())
        self.copy_link(DESTINATION_TITLE, self.workspace_url, sidebar=True)
        before = self.selection()
        denied = self.raw('workspace.select', workspace_id=self.destination)
        assert not denied['ok'] and denied['error']['code'] == 'workspace_switch_blocked', denied
        denied_link = self.raw('panel.action', workspace_id=self.source_workspace, panel_id=self.source,
                               action='open_link', url=self.target_url)
        assert not denied_link['ok'] and denied_link['error']['code'] == 'invalid_params', denied_link
        decision_count = len(self.decisions())
        self.call('panel.send_key', workspace_id=self.source_workspace, panel_id=self.source, key='cmd+enter')
        time.sleep(.2)
        assert self.selection() == before and len(self.decisions()) == decision_count
        self.passed('9 socket selection and link action refused; synthetic terminal key cannot activate link',
                    selection_error=denied, action_error=denied_link)
        self.native('m:10,10')
        self.key(53)
        self.wait(lambda: not self.ax(PREVIEW_ID) and not self.ax(NOTICE_ID), 'notice timeout and native preview dismissal', timeout=7)
        self.screenshot('09-dismissed')
        self.report['status'] = 'passed'

    def cleanup(self):
        signal.setitimer(signal.ITIMER_REAL, 0)
        errors = []
        try:
            # Request fixture exit even if a native input or evidence query
            # fails. Its own 440-second alarm is a second independent stop.
            (self.fixture / 'stop').write_text('stop\n')
            for operation in (
                lambda: self.run(['/opt/homebrew/bin/cliclick', 'ku:cmd']),
                lambda: (OUT / 'panel-link-decisions.json').write_text(json.dumps(self.decisions(), indent=2)),
                lambda: (OUT / 'final-tree.json').write_text(json.dumps(self.call('system.tree', scope='all'), indent=2)),
            ):
                try:
                    operation()
                except Exception as error:
                    errors.append(str(error))
            geometry_file = self.fixture / 'geometry.json'
            if geometry_file.exists():
                fixture_pid = json.loads(geometry_file.read_text())['pid']
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    result = subprocess.run(['ps', '-p', str(fixture_pid), '-o', 'command='], capture_output=True, text=True, timeout=2)
                    if result.returncode or str(self.fixture / 'emit.py') not in result.stdout:
                        break
                    time.sleep(.1)
                else:
                    # Kill only the still-verified fixture, never a shared shell.
                    os.kill(fixture_pid, signal.SIGTERM)
                    errors.append('Fixture required SIGTERM after stop-file timeout')
        finally:
            if errors:
                self.report['cleanup_errors'] = errors
                self.report['status'] = 'failed'
            self.report['elapsed_seconds'] = round(time.monotonic() - self.started, 2)
            (OUT / 'report.json').write_text(json.dumps(self.report, indent=2))
            self.sock.close()
            self.watchdog.cancel()
        if errors:
            raise AssertionError(('cleanup failed', errors))


if __name__ == '__main__':
    proof = Proof()
    try:
        proof.execute()
        print('PASS C11-525 terminal links; evidence=' + str(OUT), flush=True)
    except BaseException as error:
        proof.report.update(status='failed', error=str(error), traceback=traceback.format_exc())
        try:
            proof.screenshot('failure')
        except Exception as capture_error:
            proof.report['failure_screenshot_error'] = str(capture_error)
        raise
    finally:
        proof.cleanup()
