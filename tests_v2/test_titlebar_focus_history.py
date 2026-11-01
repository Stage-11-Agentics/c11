#!/usr/bin/env python3
"""C11-551 native smoke; ONLY via sandbox-tests-v2.sh in an owned guest.

    scripts/sandbox-tests-v2.sh RUN tests_v2/test_titlebar_focus_history.py

Requires a fresh English tagged app with default shortcuts. Socket calls only
seed fixtures/read oracles; every tested navigation uses native guest input.
Dismiss any guest screen-recording consent dialog before starting this script.
Navigation: 360-second active / 390-second hard deadline.
Layout-only: 440-second active / 455-second hard deadline. Inspect the PNGs for arrow glyph
direction and legibility; AX labels alone cannot prove the rendered glyphs.
Evidence: /Volumes/My Shared Files/out/titlebar-history-proof (guest path).
"""
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import stat
import subprocess
import threading
import time
import traceback


OUT = Path('/Volumes/My Shared Files/out/titlebar-history-proof')
BACK = 'titlebarControl.historyBack'
FORWARD = 'titlebarControl.historyForward'
TITLE = 'workspace.titlebarTitle'
FOLDER = 'workspace.titlebarFolder'
CONTROL_IDS = {BACK, FORWARD, 'titlebarControl.toggleSidebar',
               'titlebarControl.doubleWideSidebar', 'titlebarControl.showNotifications', 'titlebarControl.newTab'}

# AX operations are scoped to the verified app PID and its front window. Do not
# traverse terminal/page content to locate native chrome controls.
UI = r'''
ObjC.import('AppKit');
function run(args) {
    var pid = Number(args[0]), op = args[1];
    var p = Application('System Events').processes.whose({unixId: pid})[0];
    if (!p.exists()) throw Error('Verified guest PID disappeared');
    if (op === 'activate') { p.frontmost = true; return JSON.stringify(p.frontmost()); }
    if (op === 'foreground') return JSON.stringify(Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier));
    if (!p.frontmost()) throw Error('Verified guest PID is not foreground');
    function attr(e, key) { try { return e.attributes.byName(key).value(); } catch (_) { return null; } }
    if (op === 'displays') {
        var screens = $.NSScreen.screens, rows = [];
        for (var i = 0; i < Number(screens.count); ++i) {
            var f = screens.objectAtIndex(i).frame;
            rows.push({x: f.origin.x, y: f.origin.y, width: f.size.width, height: f.size.height});
        }
        return JSON.stringify(rows);
    }
    if (op === 'frame') return JSON.stringify({position: p.windows[0].position(), size: p.windows[0].size()});
    if (op === 'textSize') {
        var attributes = $.NSMutableDictionary.alloc.init;
        attributes.setObjectForKey($.NSFont.boldSystemFontOfSize(13), $.NSFontAttributeName);
        var size = $(args[2]).sizeWithAttributes(attributes);
        return JSON.stringify({width: size.width, height: size.height});
    }
    if (op === 'appearance' || op === 'style') {
        var viewMenu = p.menuBars[0].menuBarItems.byName('View');
        viewMenu.click();
        var appearance = viewMenu.menus[0].menuItems.byName(op === 'style' ? 'Titlebar Controls' : 'Appearance');
        appearance.click();
        appearance.menus[0].menuItems.byName(args[2]).click();
        return JSON.stringify(args[2]);
    }
    if (op === 'menu') {
        var bar = p.menuBars[0].menuBarItems.byName('History');
        bar.click();
        var item = bar.menus[0].menuItems.byName(args[2]);
        if (!item.exists() || !item.enabled()) throw Error('History item unavailable: ' + args[2]);
        var info = {title: item.name(), enabled: item.enabled()};
        item.click();
        return JSON.stringify(info);
    }
    var found = [], controls = [];
    function walk(e, depth) {
        if (depth > 18 || (op !== 'controls' && op !== 'layout' && found.length)) return;
        var id = attr(e, 'AXIdentifier'), role = attr(e, 'AXRole');
        var subrole = role === 'AXButton' ? attr(e, 'AXSubrole') : null;
        var trafficLight = ['AXCloseButton', 'AXMinimizeButton', 'AXZoomButton'].indexOf(subrole) >= 0;
        if (op === 'layout' && trafficLight) id = 'native.' + subrole;
        var layoutTarget = op === 'layout' && (['titlebarControl.toggleSidebar', 'titlebarControl.doubleWideSidebar', 'titlebarControl.showNotifications',
            'titlebarControl.newTab', 'titlebarControl.historyBack', 'titlebarControl.historyForward'].indexOf(id) >= 0 ||
            String(id).indexOf('workspace.titlebar') === 0 || String(id).indexOf('sidebar.workspace.') === 0 ||
            trafficLight);
        if (layoutTarget || (op === 'controls' && String(id).indexOf('titlebarControl.history') === 0) || id === args[2]) {
            var info = {id: id, role: role, enabled: attr(e, 'AXEnabled'),
                position: attr(e, 'AXPosition'), size: attr(e, 'AXSize')};
            if (op !== 'layout' || id === 'workspace.titlebarTitle') info.value = attr(e, 'AXValue');
            if (op !== 'layout') {
                info.title = attr(e, 'AXTitle'); info.description = attr(e, 'AXDescription');
                info.help = attr(e, 'AXHelp');
            }
            found.push(e); controls.push(info);
        }
        if (role === 'AXTextArea' || role === 'AXWebArea') return;
        try { e.uiElements().forEach(function(c) { walk(c, depth + 1); }); } catch (_) {}
    }
    // Feed can be exposed as a separate popover window. Its exact row UUID is
    // unique; titlebar controls stay scoped to the front window after a jump.
    if (String(args[2]).indexOf('feed.quick.') === 0) p.windows().forEach(function(w) { walk(w, 0); });
    else walk(p.windows[0], 0);
    if (op === 'press') {
        if (found.length !== 1 || controls[0].enabled === false) throw Error('AX control unavailable: ' + args[2]);
        found[0].click();
    }
    if (op === 'layout') return JSON.stringify({rows: controls,
        frame: {position: p.windows[0].position(), size: p.windows[0].size()}});
    return JSON.stringify(controls);
}
'''


class Proof:
    def __init__(self, layout_only=False):
        self.active_deadline = 440 if layout_only else 360
        self.hard_deadline = 455 if layout_only else 390
        self.started = time.monotonic()
        self.created_window = self.created_workspace = None
        self.layout_target = None
        self.mouse_down = False
        self.last_mouse_point = (0, 0)
        self.fixture = None
        self.report = dict(status='running', checks=[], routes={name: 'not_run' for name in (
            'panel_link_immediate_back', 'titlebar_forward', 'history_menu', 'keyboard_history',
            'sidebar_workspace', 'feed_open', 'attention_jump', 'cross_window', 'titlebar_layout')}, limitations=[
            'Rendered arrow direction and legibility require review of the PNGs.',
            '200-entry cap, restore and closed-target/duplicate handling belong to the logic suite.',
            'Feed uses a synthetic flag; no live agent or permission request is created.'])
        # All guest identity checks precede activation, input and fixture writes.
        assert Path.home() == Path('/Users/admin'), 'sandbox guest account required'
        assert (Path.home() / 'c11-sandbox').is_dir(), 'sandbox marker missing'
        self.socket_path = os.environ.get('C11_SOCKET_PATH', '')
        assert re.fullmatch(r'/tmp/c11-sandbox-[A-Za-z0-9._-]+\.sock', self.socket_path), 'sandbox socket required'
        assert stat.S_ISSOCK(Path(self.socket_path).stat().st_mode), 'not a socket'
        run_id = self.socket_path.removeprefix('/tmp/c11-sandbox-').removesuffix('.sock')
        self.debug_log = Path('/tmp/c11-sandbox-' + run_id + '.log')
        app_root = Path.home() / 'c11-sandbox/apps' / run_id
        apps = list(app_root.glob('*.app'))
        assert len(apps) == 1, ('exact guest app required', apps)
        self.app = apps[0]
        executable = self.app / 'Contents/MacOS/c11'
        lines = subprocess.check_output(['/bin/ps', '-axo', 'pid,comm'], text=True, timeout=5).splitlines()
        pids = [int(line.strip().split(None, 1)[0]) for line in lines
                if line.strip().split(None, 1)[-1] == str(executable)]
        assert len(pids) == 1, ('exact guest PID required', pids)
        self.pid = pids[0]
        with (self.app / 'Contents/Info.plist').open('rb') as stream:
            bundle = plistlib.load(stream)
        assert bundle['CFBundleIdentifier'].startswith('com.stage11.c11.debug.'), 'tagged build required'
        assert OUT.parent.is_dir(), 'sandbox shared output missing'
        for key in list(os.environ):
            if key.startswith(('C11_SOCKET', 'CMUX_SOCKET')) or key in (
                    'C11_PANEL_ID', 'CMUX_SURFACE_ID', 'C11_WORKSPACE_ID',
                    'CMUX_WORKSPACE_ID', 'C11_WINDOW_ID', 'CMUX_WINDOW_ID'):
                del os.environ[key]
        os.environ['C11_SOCKET_PATH'] = '/tmp/c11-551-no-default.sock'
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(5)
        self.sock.connect(self.socket_path)
        owned = subprocess.check_output(['/usr/sbin/lsof', '-nP', '-a', '-p', str(self.pid), '-U', '-Fn'], text=True, timeout=5)
        assert 'n' + self.socket_path in owned.splitlines(), 'socket not owned by exact guest PID'
        self.reader, self.sequence = self.sock.makefile('rb'), 0
        self.out = OUT / ('layout' if layout_only else 'navigation') / ('pid-' + str(self.pid))
        self.out.mkdir(parents=True, exist_ok=True)
        self.report['identity'] = dict(socket=self.socket_path, pid=self.pid, app=str(self.app),
            bundle=bundle['CFBundleIdentifier'], version=bundle.get('CFBundleShortVersionString'),
            build=bundle.get('CFBundleVersion'))
        self.watchdog = threading.Timer(self.hard_deadline, self.hard_stop)
        self.watchdog.daemon = True
        self.watchdog.start()
        signal.signal(signal.SIGALRM, self.expired)
        signal.alarm(self.active_deadline)

    def expired(self, *_):
        raise TimeoutError(f'{self.active_deadline}-second active deadline')

    def hard_stop(self):
        try:
            if self.mouse_down:
                self.mouse(self.last_mouse_point, event_types=(2,), check_foreground=False)
        finally:
            try:
                (self.out / 'hard-timeout.txt').write_text(f'{self.hard_deadline}-second deadline; proof process terminated.\n')
            finally:
                os._exit(124)

    def ui(self, operation, *args):
        return json.loads(subprocess.check_output(['/usr/bin/osascript', '-l', 'JavaScript', '-e', UI,
            str(self.pid), operation, *args], text=True, timeout=12))

    def call(self, method, **params):
        self.sequence += 1
        self.sock.sendall((json.dumps(dict(id=self.sequence, method=method, params=params)) + '\n').encode())
        response = json.loads(self.reader.readline())
        assert response['id'] == self.sequence and response.get('ok'), (method, response)
        return response['result']

    def focus(self):
        # window.create changes socket defaults. Always resolve the real key window.
        windows = self.call('window.list')['windows']
        key = next((w for w in windows if w['key']), None)
        assert key, 'guest app has no key window'
        return self.call('system.identify', window_id=key['id'])['focused']

    def wait(self, predicate, label, seconds=6):
        end = time.monotonic() + seconds
        last = None
        while time.monotonic() < end:
            try:
                value = predicate()
                if value:
                    return value
            except AssertionError as error:
                last = str(error)
            time.sleep(.02)
        raise AssertionError((label, last))

    def at(self, workspace, panel, window=None):
        location = self.focus()
        return (location['workspace_id'] == workspace and location['panel_id'] == panel
                and (window is None or location['window_id'] == window))

    def landed(self, workspace, panel, label, window=None):
        self.wait(lambda: self.at(workspace, panel, window), label)
        self.wait(lambda: any(p['id'] == panel and p.get('being_seen')
                  for p in self.call('panel.list', workspace_id=workspace)['panels']), label + ' visible')

    def note(self, label, **evidence):
        route = self.report['active_route']
        self.report['routes'][route] = 'passed'
        self.report['checks'].append(dict(route=route, label=label,
            elapsed_seconds=round(time.monotonic() - self.started, 3), **evidence))
        self.save()
        print('PASS', label, flush=True)

    def begin(self, route):
        self.report['active_route'] = route
        self.report['routes'][route] = 'running'
        self.save()

    def save(self):
        temporary = self.out / 'result.tmp'
        temporary.write_text(json.dumps(self.report, indent=2, default=str) + '\n')
        temporary.replace(self.out / 'result.json')

    def key(self, code, modifiers=''):
        suffix = ' using {' + modifiers + '}' if modifiers else ''
        script = f'''tell application "System Events"
set p to first process whose unix id is {self.pid}
if not frontmost of p then error "Verified guest PID not foreground"
tell p to key code {code}{suffix}
end tell'''
        subprocess.run(['/usr/bin/osascript', '-e', script], check=True, timeout=8)

    def mouse(self, point, event_types=(1, 2), check_foreground=True):
        if check_foreground:
            assert self.ui('foreground') == self.pid, 'exact guest PID must be foreground'
        self.last_mouse_point = point
        class Point(ctypes.Structure):
            _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]
        cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
        cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        for event_type in event_types:
            event = cg.CGEventCreateMouseEvent(None, event_type, Point(*point), 0)
            assert event
            cg.CGEventSetIntegerValueField(event, 1, 1)
            cg.CGEventPost(0, event)
            if event_type in (1, 2):
                self.mouse_down = event_type == 1
            posted = time.monotonic()
            cf.CFRelease(event)
        return posted

    def control(self, identifier):
        rows = self.ui('find', identifier)
        if identifier == FOLDER and not rows:
            # NSViewRepresentable does not expose the SwiftUI identifier here.
            # This is a click target derived from the observed text frame, not an
            # AX measurement of the icon. folder_click requires the native mouseDown
            # log, and screenshot review must confirm the visible icon at this point.
            return self.folder_target(self.control(TITLE))
        assert len(rows) == 1, (identifier, rows)
        return rows[0]

    @staticmethod
    def folder_target(title):
        return dict(id=FOLDER, position=[title['position'][0] - 24,
                    title['position'][1] + title['size'][1] / 2 - 8], size=[16, 16],
                    geometry_source='click target from observed title frame, native hit log required')

    def center(self, identifier):
        row = self.control(identifier)
        x, y = row['position']
        width, height = row['size']
        assert width > 0 and height > 0, row
        return (x + width / 2, y + height / 2)

    def history(self, back=True):
        self.ui('press', BACK if back else FORWARD)

    def javascript(self, script):
        return self.call('browser.eval', workspace_id=self.a, panel_id=self.source, script=script)['value']

    def link_point(self, frame=None):
        rect = self.javascript('(() => { const r=document.querySelector("#jump").getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2,innerWidth,innerHeight]; })()')
        frame = frame or self.ui('frame')
        x, y = frame['position']
        width, height = frame['size']
        assert 100 < rect[2] < width and 100 < rect[3] < height, (frame, rect)
        # Fresh fixture has one area at 100% zoom, ending at inner right/bottom.
        return (x + width - rect[2] - 1 + rect[0], y + height - rect[3] - 1 + rect[1])

    def shot(self, name):
        assert self.ui('foreground') == self.pid
        assert len(self.ui('displays')) == 1, 'one verified guest display required'
        subprocess.run(['/usr/sbin/screencapture', '-x', '-D', '1', str(self.out / (name + '.png'))], check=True, timeout=8)

    def sidebar_width(self, width):
        layout = self.call('sidebar.state', workspace_id=self.a)['layout']
        assert not layout['double_wide'], 'normal single-column sidebar required'
        if abs(layout['effective_width'] - width) <= .5:
            return
        frame = self.ui('frame')
        x, y = frame['position']
        start, end = (x + layout['effective_width'], y + 220), (x + width, y + 220)
        self.mouse(start, event_types=(5, 1))
        try:
            time.sleep(.12)
            for step in range(1, 7):
                point = (start[0] + (end[0] - start[0]) * step / 6, end[1])
                self.mouse(point, event_types=(6,), check_foreground=False)
                time.sleep(.025)
        finally:
            self.mouse(end, event_types=(2,), check_foreground=False)
        self.wait(lambda: abs(self.call('sidebar.state', workspace_id=self.a)['layout']['effective_width'] - width) <= 1,
                  'native divider drag reaches ' + str(width))

    def minimal_mode(self, enabled):
        # Native command palette submission, with a read-only oracle proving the
        # selected command before Return. No debug palette activation method.
        title = ('Enable' if enabled else 'Disable') + ' Minimal Mode'
        command_id = 'palette.' + ('enable' if enabled else 'disable') + 'MinimalMode'
        self.key(35, 'command down, shift down')
        self.wait(lambda: self.call('debug.command_palette.visible', window_id=self.window)['visible'], 'palette opens')
        script = f'''tell application "System Events"
set p to first process whose unix id is {self.pid}
if not frontmost of p then error "Verified guest PID not foreground"
tell p to keystroke {json.dumps(title)}
end tell'''
        subprocess.run(['/usr/bin/osascript', '-e', script], check=True, timeout=8)

        def selected():
            state = self.call('debug.command_palette.results', window_id=self.window, limit=5)
            rows, index = state['results'], state['selected_index']
            return state['visible'] and index < len(rows) and rows[index]['command_id'] == command_id

        self.wait(selected, 'exact minimal-mode command selected')
        self.key(36)
        self.wait(lambda: not self.call('debug.command_palette.visible', window_id=self.window)['visible'], 'palette dismisses')

    @staticmethod
    def bounds(row):
        x, y = row['position']
        width, height = row['size']
        return x, y, x + width, y + height

    def layout_snapshot(self, minimal, hidden_shot=None, previous_hidden=None):
        if not minimal:
            return self.ui('layout')
        if previous_hidden is None:
            frame = self.ui('frame')
            self.mouse((frame['position'][0] + frame['size'][0] - 40,
                        frame['position'][1] + frame['size'][1] - 40), event_types=(5,))
            time.sleep(.18)
            hidden = self.ui('layout')
            if hidden_shot:
                self.shot(hidden_shot)
        else:
            hidden = previous_hidden
        # Input placement only, not a measurement of the SwiftUI host. Its AX
        # identifier is inherited by children rather than exposed as one group.
        lights = [self.bounds(r) for r in hidden['rows'] if r['id'].startswith('native.AX')]
        assert lights, ('native traffic-light bounds required', hidden)
        hover = (hidden['frame']['position'][0] + 16, max(box[3] for box in lights) + 10)
        self.mouse(hover, event_types=(5,))
        time.sleep(.18)
        snapshot = self.ui('layout')
        snapshot['before_hover'] = hidden
        snapshot['hover_input'] = hover
        return snapshot

    def assert_layout(self, snapshot, width, minimal, title, measured):
        if not minimal and not any(row['id'] == FOLDER for row in snapshot['rows']):
            title_row = next(row for row in snapshot['rows'] if row['id'] == TITLE)
            snapshot['rows'].append(self.folder_target(title_row))
        rows = {row['id']: row for row in snapshot['rows']}
        assert len(rows) == len(snapshot['rows']), ('duplicate visible AX ids', snapshot)
        assert CONTROL_IDS <= rows.keys(), ('six controls required', snapshot)
        frame = snapshot['frame']
        x, y = frame['position']
        assert abs(frame['size'][0] - 900) <= 1, ('900px window required', frame)
        controls = [rows[key] for key in CONTROL_IDS]
        assert all(r['size'][0] > 0 and r['size'][1] > 0 for r in controls), snapshot
        assert abs(self.call('sidebar.state', workspace_id=self.a)['layout']['effective_width'] - width) <= 1
        if minimal:
            boxes = [self.bounds(control) for control in controls]
            for control, box in zip(controls, boxes):
                assert box[0] >= x and box[2] <= x + width, (
                    'minimal control outside sidebar', control, width)
            lights = [self.bounds(r) for key, r in rows.items() if key.startswith('native.AX')]
            assert lights and min(b[1] for b in boxes) >= max(b[3] for b in lights) + 2, (
                'minimal controls overlap traffic lights', snapshot)
            cards = [self.bounds(r) for key, r in rows.items() if key.startswith('sidebar.workspace.')]
            assert cards and min(b[1] for b in cards) >= max(b[3] for b in boxes) + 2, (
                'minimal controls overlap workspace content', snapshot)
            card_bounds = lambda items: {r['id']: (r['position'], r['size']) for r in items
                                          if r['id'].startswith('sidebar.workspace.')}
            assert card_bounds(snapshot['before_hover']['rows']) == card_bounds(snapshot['rows']), (
                'hover changed workspace geometry', snapshot)
            row_counts = {}
            for control in controls:
                top = round(control['position'][1])
                row_counts[top] = row_counts.get(top, 0) + 1
            assert sorted(row_counts.values()) == [3, 3], ('minimal controls must form two rows of three', snapshot)
        else:
            text, folder = rows[TITLE], rows[FOLDER]
            assert text['value'] == title, ('long title not applied', text)
            controls_right = max(self.bounds(r)[2] for r in controls)
            assert folder['position'][0] >= controls_right + 4, ('controls overlap folder', snapshot)
            assert text['position'][0] >= self.bounds(folder)[2] + 4, ('folder overlaps title', snapshot)
            assert text['size'][0] >= measured['width'] - 1, ('long title is truncated', text, measured)
            assert self.bounds(text)[2] <= x + frame['size'][0] - 8, ('title outside narrow window', snapshot)
        return rows

    def folder_click(self, row):
        assert self.debug_log.exists(), 'guest DEBUG log required for folder click oracle'
        offset = self.debug_log.stat().st_size
        x, y, right, bottom = self.bounds(row)
        before = self.ui('frame')
        self.mouse((x + 2, (y + bottom) / 2))  # Left edge must clear the accessory hit area.
        self.key(53)  # Dismiss any folder drag session; never drop into another app.

        def logged():
            with self.debug_log.open() as stream:
                stream.seek(offset)
                return [line.strip() for line in stream if 'folder.mouseDown ' in line]

        lines = self.wait(logged, 'native folder click reaches DraggableFolderNSView')
        assert self.ui('frame') == before, 'folder click moved the window'
        assert self.at(self.a, self.source, self.window), 'folder click changed panel focus'
        return lines

    def layout_matrix(self):
        self.begin('titlebar_layout')
        # Prune only this test's fixtures so the same-workspace two-panel pair
        # has deterministic Back-disabled / Forward-disabled endpoints.
        if self.created_window:
            self.call('window.close', window_id=self.created_window)
            self.created_window = None
        self.call('workspace.close', workspace_id=self.created_workspace)
        self.created_workspace = None
        for panel in self.call('panel.list', workspace_id=self.a)['panels']:
            if panel['id'] != self.source:
                self.call('panel.close', workspace_id=self.a, panel_id=panel['id'])
        title = 'C11-551 Architecture, Delivery, and Navigation Review'
        self.call('workspace.rename', workspace_id=self.a, title=title)
        resized = self.call('window.resize', window_id=self.window, width=900, height=650)
        assert abs(resized['applied']['width'] - 900) <= 1, ('900px window required', resized)
        measured = self.ui('textSize', title)
        self.layout_target = self.call('panel.create', workspace_id=self.a, type='browser',
                                       url=self.fixture.as_uri(), focus=False)['panel_id']
        self.report['targets']['layout_target'] = self.layout_target
        self.landed(self.a, self.source, 'background layout target creation preserves source', self.window)
        # focusedDirectory falls back to workspace.currentDirectory for browsers;
        # require the actual folder AX element after closing the terminal fixture.
        self.control(FOLDER)
        self.javascript('document.querySelector("#jump").href=' + json.dumps('c11://panel/' + self.layout_target))
        self.ui('style', 'Classic')
        self.ui('press', 'titlebarControl.toggleSidebar')
        self.wait(lambda: not self.call('debug.sidebar.visible', window_id=self.window)['visible'],
                  'native sidebar hide')
        hidden_sidebar = self.ui('layout')
        folder = self.control(FOLDER)
        self.report['hidden_sidebar_folder'] = dict(snapshot=hidden_sidebar,
            click_log=self.folder_click(folder), click_x=folder['position'][0] + 2)
        self.save()
        self.shot('07-hidden-sidebar-folder-edge')
        self.ui('press', 'titlebarControl.toggleSidebar')
        self.wait(lambda: self.call('debug.sidebar.visible', window_id=self.window)['visible'],
                  'native sidebar restore')
        self.report['layout_matrix'] = [dict(
            case=f'{"minimal" if minimal else "standard"}-{style.lower()}-{width}-{appearance.lower()}',
            status='not_run', minimal=minimal, style=style, sidebar_width=width, appearance=appearance)
            for minimal in (False, True) for style in ('Classic', 'Roomy')
            for width in (180, 200) for appearance in ('Dark', 'Light')]
        self.save()
        for minimal in (False, True):
            if minimal:
                self.minimal_mode(True)
            for style in ('Classic', 'Roomy'):
                self.ui('style', style)
                for width in (180, 200):
                    self.sidebar_width(width)
                    for appearance in ('Dark', 'Light'):
                        self.ui('appearance', appearance)
                        name = f'{"minimal" if minimal else "standard"}-{style.lower()}-{width}-{appearance.lower()}'
                        case = next(row for row in self.report['layout_matrix'] if row['case'] == name)
                        case['status'] = 'running'
                        case['started_seconds'] = round(time.monotonic() - self.started, 3)
                        self.save()
                        try:
                            self.landed(self.a, self.source, 'layout baseline remains source', self.window)
                            before = self.layout_snapshot(minimal, hidden_shot=('07-' + name + '-hidden') if minimal else None)
                            case['back_disabled'] = before
                            self.save()
                            rows = self.assert_layout(before, width, minimal, title, measured)
                            assert rows[BACK]['enabled'] is False, ('source endpoint Back must be disabled', rows[BACK])
                            if not minimal:
                                case['folder_click_log'] = self.folder_click(rows[FOLDER])
                                self.save()
                            self.shot('07-' + name)
                            self.mouse(self.link_point(frame=before['frame']))
                            self.landed(self.a, self.layout_target, 'layout native link lands')
                            after = self.layout_snapshot(minimal, previous_hidden=before.get('before_hover'))
                            case['forward_disabled'] = after
                            self.save()
                            next_rows = self.assert_layout(after, width, minimal, title, measured)
                            assert next_rows[BACK]['enabled'] is True and next_rows[FORWARD]['enabled'] is False
                            geometry = lambda items: {key: (items[key]['position'], items[key]['size']) for key in CONTROL_IDS}
                            assert geometry(rows) == geometry(next_rows), ('disabled controls changed geometry', before, after)
                            bx, by, br, bb = self.bounds(next_rows[BACK])
                            self.mouse(((bx + br) / 2, (by + bb) / 2))
                            self.landed(self.a, self.source, 'layout Back returns to source')
                            case['status'] = 'passed'
                            case['finished_seconds'] = round(time.monotonic() - self.started, 3)
                            print('PASS layout', name, flush=True)
                            self.save()
                        except Exception:
                            case['status'] = 'failed'
                            self.save()
                            raise
            if minimal:
                self.minimal_mode(False)
        self.ui('style', 'Classic')
        self.note('16-case native layout matrix: styles, widths, appearances, minimal hover and stable disabled geometry',
                  resize=resized, measured_title=measured)

    def execute(self, layout_only=False):
        capabilities = self.call('system.capabilities')
        features = {entry['id']: entry['version'] for entry in capabilities['features']}
        assert features.get('links.panel') == 1, 'native panel links v1 required'
        self.report['capabilities'] = capabilities
        self.ui('activate')
        self.wait(lambda: bool(self.focus()), 'guest app becomes key')
        initial = self.focus()
        self.a, self.window = initial['workspace_id'], initial['window_id']
        assert len(self.call('window.list')['windows']) == 1, 'fresh single-window guest required'
        assert len(self.call('workspace.list', window_id=self.window)['workspaces']) == 1, 'fresh guest required'
        # The fresh golden image can start with the welcome quad. Collapse only
        # this owned fixture to one area before measuring browser coordinates.
        for panel in self.call('panel.list', workspace_id=self.a)['panels']:
            if panel['id'] != initial['panel_id']:
                self.call('panel.close', workspace_id=self.a, panel_id=panel['id'])
        self.wait(lambda: len(self.call('area.list', workspace_id=self.a)['areas']) == 1,
                  'single-area fixture prepared')
        self.call('workspace.rename', workspace_id=self.a, title='C11-551 A source')
        self.b = self.call('workspace.create', title='C11-551 B destination', window_id=self.window)['workspace_id']
        self.created_workspace = self.b
        self.target = next(p['id'] for p in self.call('panel.list', workspace_id=self.b)['panels'] if p['type'] == 'terminal')
        self.fixture = Path('/tmp') / ('c11-551-' + str(self.pid) + '.html')
        self.fixture.write_text(f'''<!doctype html><html><head><title>C11-551 history source</title><link rel="icon" href="data:,"></head>
<body style="padding:32px;background:#101418;color:#f3f4f5;font:24px monospace">
<h1>C11-551 history proof</h1><p><a id="jump" style="color:#ffb060" href="c11://panel/{self.target}">OPEN DESTINATION</a></p>
<p>Native link, then immediate titlebar Back.</p></body></html>''')
        self.source = self.call('panel.create', workspace_id=self.a, type='browser', url=self.fixture.as_uri())['panel_id']
        self.call('panel.focus', workspace_id=self.a, panel_id=self.source)
        self.wait(lambda: self.javascript('document.readyState') == 'complete', 'local fixture loads')
        self.landed(self.a, self.source, 'source browser visible')
        self.report['targets'] = dict(a=self.a, source=self.source, b=self.b, target=self.target, window=self.window)
        controls = self.ui('controls')
        assert {row['id'] for row in controls} == {BACK, FORWARD}, controls
        self.report['initial_controls'] = controls
        initial_title = self.control('workspace.titlebarTitle')
        initial_forward = next(row for row in controls if row['id'] == FORWARD)
        self.report['initial_title'] = initial_title
        assert initial_title['position'][0] >= initial_forward['position'][0] + initial_forward['size'][0] + 4, (
            'history controls overlap title before resizing', initial_title, initial_forward)
        self.shot('01-titlebar-source')
        if layout_only:
            self.report['mode'] = 'layout_only'
            self.report['routes'] = {'titlebar_layout': 'not_run'}
            self.layout_matrix()
            self.report.pop('active_route', None)
            self.report['status'] = 'passed'
            return

        # Cache chrome geometry before the jump: AX tree traversal must not add
        # destination dwell. Both points belong to the same verified window.
        self.begin('panel_link_immediate_back')
        back_point, link_point = self.center(BACK), self.link_point()
        clicked = self.mouse(link_point)
        self.wait(lambda: self.at(self.b, self.target), 'link lands at B', seconds=.8)
        returned = self.mouse(back_point)
        elapsed = returned - clicked
        assert elapsed < 1, ('not a sub-second return; rerun on an idle guest', elapsed)
        self.landed(self.a, self.source, 'immediate titlebar Back returns to exact source')
        assert self.control(FORWARD)['enabled'] is True
        self.note('Native panel link and titlebar Back before one-second dwell', click_to_back_seconds=elapsed)
        self.shot('02-immediate-back')
        self.begin('titlebar_forward')
        self.history(False)
        self.landed(self.b, self.target, 'titlebar Forward returns to exact destination')
        self.note('Titlebar Forward returns to B')
        self.shot('03-titlebar-forward')

        self.begin('history_menu')
        self.ui('menu', 'Back')
        self.landed(self.a, self.source, 'History menu Back')
        self.ui('menu', 'Forward')
        self.landed(self.b, self.target, 'History menu Forward')
        self.note('Native History menu shares the titlebar navigation stack')
        self.begin('keyboard_history')
        self.key(33, 'command down, option down')  # Option-Command-[
        self.landed(self.a, self.source, 'default keyboard Back')
        self.key(30, 'command down, option down')  # Option-Command-]
        self.landed(self.b, self.target, 'default keyboard Forward')
        self.history()
        self.landed(self.a, self.source, 'return before sidebar cases')
        self.note('Default Option-Command bracket shortcuts share history')

        self.begin('sidebar_workspace')
        self.mouse(self.center('sidebar.workspace.' + self.b.upper()))
        self.landed(self.b, self.target, 'native sidebar click selects B')
        self.history()
        self.landed(self.a, self.source, 'Back after sidebar click')
        order = self.call('workspace.list', window_id=self.window)['workspaces']
        assert [w['id'] for w in order] == [self.a, self.b], ('Cmd+2 fixture order changed', order)
        self.key(19, 'command down')  # Cmd+2, two unflagged workspaces in fresh guest.
        self.landed(self.b, self.target, 'native Cmd+2 selects B')
        self.history()
        self.landed(self.a, self.source, 'Back after workspace shortcut')
        self.note('Sidebar click and workspace shortcut preserve return location')

        self.begin('feed_open')
        self.call('flag.raise', workspace_id=self.b, panel_id=self.target,
                  caller_panel_id=self.source, reason='C11-551 synthetic history fixture')
        self.key(34, 'command down')  # Cmd+I opens Feed.
        row_id = 'feed.quick.row.' + self.target.upper()
        self.wait(lambda: bool(self.ui('find', row_id)), 'synthetic flagged Feed row appears')
        self.shot('04-feed-before-open')
        self.ui('press', row_id)
        self.landed(self.b, self.target, 'native Feed Open selects B')
        self.wait(lambda: not self.ui('find', 'feed.quick.view'), 'Feed dismissed after Open')
        self.history()
        self.landed(self.a, self.source, 'Back after Feed Open')
        self.note('Native Feed row Open and history return')
        self.begin('attention_jump')
        self.key(36, 'command down, control down')  # Cmd+Ctrl+Return attention jump.
        self.landed(self.b, self.target, 'native attention shortcut selects flagged B')
        self.history()
        self.landed(self.a, self.source, 'Back after attention jump')
        self.note('Native attention jump and history return')

        self.begin('cross_window')
        self.created_window = self.call('window.create')['window_id']
        c = self.call('workspace.list', window_id=self.created_window)['workspaces'][0]['id']
        target_c = self.call('panel.list', workspace_id=c)['panels'][0]['id']
        self.report['targets'].update(c=c, target_c=target_c, other_window=self.created_window)
        self.javascript('document.querySelector("#jump").href=' + json.dumps('c11://panel/' + target_c))
        assert self.at(self.a, self.source, self.window), 'background window creation stole focus'
        self.mouse(self.link_point())
        self.landed(c, target_c, 'cross-window native link', self.created_window)
        self.shot('05-cross-window-destination')
        self.history()
        self.landed(self.a, self.source, 'cross-window Back', self.window)
        self.history(False)
        self.landed(c, target_c, 'cross-window Forward', self.created_window)
        self.history()
        self.landed(self.a, self.source, 'final cross-window Back', self.window)
        self.note('Cross-window link, titlebar Back and Forward restore exact window/workspace/panel')
        self.shot('06-cross-window-return')

        self.report['routes'].pop('titlebar_layout', None)
        self.report['final_controls'] = self.ui('controls')
        self.report['final_history'] = self.call('history.list', limit=200)
        self.report.pop('active_route', None)
        self.report['status'] = 'passed'

    def finish(self):
        signal.alarm(0)
        errors = []
        for method, params in [('window.close', dict(window_id=self.created_window)),
                               ('workspace.close', dict(workspace_id=self.created_workspace)),
                               ('panel.close', dict(panel_id=self.layout_target, workspace_id=getattr(self, 'a', None)))]:
            if next(iter(params.values())) is not None:
                try:
                    self.call(method, **params)
                except Exception as error:
                    errors.append(str(error))
        if self.fixture:
            self.fixture.unlink(missing_ok=True)
        self.report['cleanup_errors'] = errors
        if errors:
            self.report['status'] = 'failed'
        self.report['elapsed_seconds'] = round(time.monotonic() - self.started, 3)
        self.save()
        self.reader.close()
        self.sock.close()
        self.watchdog.cancel()


def main(layout_only=False):
    proof = Proof(layout_only=layout_only)
    try:
        proof.execute(layout_only=layout_only)
    except Exception:
        proof.report['status'] = 'failed'
        if proof.report.get('active_route'):
            proof.report['routes'][proof.report['active_route']] = 'failed'
        proof.report['error'] = traceback.format_exc()
        try:
            proof.shot('failure')
        except Exception as error:
            proof.report['failure_screenshot_error'] = str(error)
        raise
    finally:
        proof.finish()
    assert not proof.report['cleanup_errors'], proof.report['cleanup_errors']
    print('PASS: native titlebar history smoke; glyph visual review pending; evidence=' + str(proof.out))


if __name__ == '__main__':
    main()
