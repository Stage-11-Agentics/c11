#!/usr/bin/env python3
"""C11-551 native smoke; ONLY via sandbox-tests-v2.sh in an owned guest.

    scripts/sandbox-tests-v2.sh RUN tests_v2/test_titlebar_focus_history.py

Requires a fresh English tagged app with default shortcuts. Socket calls only
seed fixtures/read oracles; every tested navigation uses native guest input.
Dismiss any guest screen-recording consent dialog before starting this script.
180-second active / 200-second hard deadline. Inspect the PNGs for arrow glyph
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
        if (depth > 18 || (op !== 'controls' && found.length)) return;
        var id = attr(e, 'AXIdentifier'), role = attr(e, 'AXRole');
        if ((op === 'controls' && String(id).indexOf('titlebarControl.history') === 0) || id === args[2]) {
            var info = {id: id, role: role, title: attr(e, 'AXTitle'), description: attr(e, 'AXDescription'),
                enabled: attr(e, 'AXEnabled'), help: attr(e, 'AXHelp'),
                position: attr(e, 'AXPosition'), size: attr(e, 'AXSize')};
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
    return JSON.stringify(controls);
}
'''


class Proof:
    def __init__(self):
        self.started = time.monotonic()
        self.created_window = self.created_workspace = None
        self.fixture = None
        self.report = dict(status='running', checks=[], routes={name: 'not_run' for name in (
            'panel_link_immediate_back', 'titlebar_forward', 'history_menu', 'keyboard_history',
            'sidebar_workspace', 'feed_open', 'attention_jump', 'cross_window')}, limitations=[
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
        OUT.mkdir(exist_ok=True)
        self.report['identity'] = dict(socket=self.socket_path, pid=self.pid, app=str(self.app),
            bundle=bundle['CFBundleIdentifier'], version=bundle.get('CFBundleShortVersionString'),
            build=bundle.get('CFBundleVersion'))
        self.watchdog = threading.Timer(200, self.hard_stop)
        self.watchdog.daemon = True
        self.watchdog.start()
        signal.signal(signal.SIGALRM, self.expired)
        signal.alarm(180)

    def expired(self, *_):
        raise TimeoutError('180-second active deadline')

    def hard_stop(self):
        # No key remains held: all synthetic input is a complete key/click pair.
        (OUT / 'hard-timeout.txt').write_text('200-second deadline; proof process terminated.\n')
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
        (OUT / 'result.json').write_text(json.dumps(self.report, indent=2, default=str) + '\n')

    def key(self, code, modifiers=''):
        suffix = ' using {' + modifiers + '}' if modifiers else ''
        script = f'''tell application "System Events"
set p to first process whose unix id is {self.pid}
if not frontmost of p then error "Verified guest PID not foreground"
tell p to key code {code}{suffix}
end tell'''
        subprocess.run(['/usr/bin/osascript', '-e', script], check=True, timeout=8)

    def mouse(self, point):
        assert self.ui('foreground') == self.pid, 'exact guest PID must be foreground'
        class Point(ctypes.Structure):
            _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]
        cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
        cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        for event_type in (1, 2):
            event = cg.CGEventCreateMouseEvent(None, event_type, Point(*point), 0)
            assert event
            cg.CGEventSetIntegerValueField(event, 1, 1)
            cg.CGEventPost(0, event)
            posted = time.monotonic()
            cf.CFRelease(event)
        return posted

    def control(self, identifier):
        rows = self.ui('find', identifier)
        assert len(rows) == 1, (identifier, rows)
        return rows[0]

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

    def link_point(self):
        rect = self.javascript('(() => { const r=document.querySelector("#jump").getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2,innerWidth,innerHeight]; })()')
        frame = self.ui('frame')
        x, y = frame['position']
        width, height = frame['size']
        assert 100 < rect[2] < width and 100 < rect[3] < height, (frame, rect)
        # Fresh fixture has one area at 100% zoom, ending at inner right/bottom.
        return (x + width - rect[2] - 1 + rect[0], y + height - rect[3] - 1 + rect[1])

    def shot(self, name):
        assert self.ui('foreground') == self.pid
        assert len(self.ui('displays')) == 1, 'one verified guest display required'
        subprocess.run(['/usr/sbin/screencapture', '-x', '-D', '1', str(OUT / (name + '.png'))], check=True, timeout=8)

    def execute(self):
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
        assert len(self.call('area.list', workspace_id=self.a)['areas']) == 1, 'single-area fixture required'
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
        self.shot('01-titlebar-source')

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
        self.report['final_controls'] = self.ui('controls')
        self.report['final_history'] = self.call('history.list', limit=200)
        self.report.pop('active_route', None)
        self.report['status'] = 'passed'

    def finish(self):
        signal.alarm(0)
        errors = []
        for method, params in [('window.close', dict(window_id=self.created_window)),
                               ('workspace.close', dict(workspace_id=self.created_workspace))]:
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


def main():
    proof = Proof()
    try:
        proof.execute()
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
    print('PASS: native titlebar history smoke; glyph visual review pending; evidence=' + str(OUT))


if __name__ == '__main__':
    main()
