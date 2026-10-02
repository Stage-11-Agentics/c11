#!/usr/bin/env python3
"""Explicit C11-263 guest UI probe; never part of the automatic test_ suite.

Stage this file into the disposable guest, then run with sandbox-exec.sh:
  python3 attention_menu_bar_probe.py --run-id c11-263-r1 --pid PID \
    --app '/Users/admin/c11-sandbox/apps/c11-263-r1/c11 DEV TAG.app' \
    --cli 'APP/Contents/Resources/bin/c11' \
    --socket /tmp/c11-sandbox-c11-263-r1.sock

Requires a single-display Tart guest, stock osascript JXA/AppKit/CoreGraphics,
System Events Accessibility permission and Screen Recording permission.
No PyObjC, Xcode, cliclick or third-party Python packages are required.
Enable showMenuBarExtra in the tagged guest domain before launch if external
defaults writes do not install the status item in an already-running app.
This probe does not launch/restart an app or change any agent-tool settings.
It uses socket setup/oracles, Accessibility menu clicks and PID-targeted Escape.
Screenshots and report.json land in /Volumes/My Shared Files/out/menu-probe.
--inspect-dialogs-only reads the tagged PID's AX windows/sheets/button labels;
it does not activate the app, write preferences, click or dismiss a prompt.
The active phase expires at 80s; a hard exit guard fires at 89s including cleanup.
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
import threading
import time
import uuid


JXA = r'''
ObjC.import('AppKit');
ObjC.import('CoreGraphics');
// Bind the toll-free CFArray result as an Objective-C array for deepUnwrap.
ObjC.bindFunction('CGWindowListCopyWindowInfo', ['id', ['uint32', 'uint32']]);
function run(args) {
    var pid = Number(args[0]), operation = args[1];
    if (operation === 'foreground') {
        return JSON.stringify(Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier));
    }
    if (operation === 'background') {
        var finder = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('com.apple.finder');
        if (Number(finder.count) !== 1) throw new Error('Cannot uniquely identify guest Finder');
        var app = finder.objectAtIndex(0);
        app.activateWithOptions(0);
        return JSON.stringify(Number(app.processIdentifier));
    }
    if (operation === 'popup-windows') {
        var windows = ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(1, 0));
        return JSON.stringify(windows.filter(function(w) {
            return w.kCGWindowOwnerPID === pid && w.kCGWindowIsOnscreen &&
                w.kCGWindowNumber !== Number(args[2]) &&
                w.kCGWindowBounds.Width > 100 && w.kCGWindowBounds.Height > 60;
        }).map(function(w) { return w.kCGWindowNumber; }));
    }
    if (operation === 'displays') {
        var screens = $.NSScreen.screens, displays = [];
        for (var i = 0; i < Number(screens.count); i++) {
            var screen = screens.objectAtIndex(i), rect = screen.frame;
            displays.push({id: Number(ObjC.unwrap(screen.deviceDescription.objectForKey('NSScreenNumber'))),
                x: rect.origin.x, y: rect.origin.y,
                width: rect.size.width, height: rect.size.height});
        }
        var windows = ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(0, 0));
        windows = windows.filter(function(w) {
            return w.kCGWindowOwnerPID === pid && w.kCGWindowLayer === 0 &&
                w.kCGWindowIsOnscreen && w.kCGWindowBounds.Width > 200;
        });
        return JSON.stringify({displays: displays, windows: windows});
    }
    var se = Application('System Events');
    var process = se.processes.whose({unixId: pid})[0];
    if (!process.exists()) throw new Error('Tagged PID has no Accessibility process');
    if (operation === 'dialogs') {
        // Inspect only the exact tagged process. OS-owned permission prompts
        // require a separately verified owner; this never searches/clicks them.
        var windows = process.windows().map(function(window) {
            function buttons(owner) {
                return owner.buttons().map(function(button) {
                    return {name: button.name() || '', enabled: button.enabled()};
                });
            }
            return {name: window.name() || '', buttons: buttons(window),
                sheets: window.sheets().map(function(sheet) {
                    return {name: sheet.name() || '', buttons: buttons(sheet)};
                })};
        });
        return JSON.stringify({pid: pid, windows: windows,
            scope: 'Tagged PID only; no authorization state inferred from missing dialogs'});
    }
    if (operation === 'activate') {
        process.frontmost = true;
        return JSON.stringify({frontmost: process.frontmost()});
    }
    if (operation === 'dismiss') {
        // CGEventPostToPid targets the tagged process even if focus changes.
        $.CGEventPostToPid(pid, $.CGEventCreateKeyboardEvent(null, 53, true));
        $.CGEventPostToPid(pid, $.CGEventCreateKeyboardEvent(null, 53, false));
        return '{}';
    }
    function attr(element, name) {
        try { return element.attributes.byName(name).value(); } catch (_) { return ''; }
    }
    var bars = process.menuBars(), entries = [], candidates = [];
    bars.forEach(function(bar, b) {
        // Inspect only the status bar; walking every app-menu row is slow AX IPC.
        if (b === 0) return;
        var buttons = bar.menuBarItems();
        buttons.forEach(function(button, i) {
            var menus = button.menus(), rows = [];
            menus.forEach(function(menu) {
                menu.menuItems().forEach(function(row) {
                    rows.push({name: row.name() || '', enabled: row.enabled()});
                });
            });
            var entry = {bar: b, item: i, name: button.name() || '',
                help: attr(button, 'AXHelp'), description: attr(button, 'AXDescription'),
                position: button.position(), size: button.size(), rows: rows};
            entries.push(entry);
            // Status extras belong to the owning app's second menu bar.
            // Require a c11 tooltip/name, or its sole second-bar item.
            if (b > 0 && (String(entry.help).indexOf('c11') === 0 || entry.name === 'c11' ||
                buttons.length === 1)) candidates.push({button: button, entry: entry});
        });
    });
    if (operation === 'inspect') return JSON.stringify({frontmost: process.frontmost(),
        entries: entries, candidates: candidates.map(function(c) { return c.entry; })});
    if (candidates.length !== 1) throw new Error('Cannot uniquely identify tagged status extra');
    var target = candidates[0];
    if (operation === 'dismiss-menu') {
        var dismissRows = target.button.menus()[0].menuItems().filter(function(row) {
            return row.name() === 'Show c11';
        });
        if (dismissRows.length !== 1) throw new Error('Exact tagged dismiss row missing');
        dismissRows[0].click();
        return '{}';
    }
    if (operation === 'open') {
        target.button.click();
        return '{}';
    }
    if (operation === 'click-flag') {
        var hits = [];
        target.button.menus().forEach(function(menu) {
            menu.menuItems().forEach(function(row) {
                var name = row.name() || '';
                if (name.indexOf('⚑ ') === 0 && name.indexOf(args[2]) >= 0) hits.push(row);
            });
        });
        if (hits.length !== 1 || !hits[0].enabled()) throw new Error('Exact synthetic flag row missing');
        hits[0].click();
        return '{}';
    }
    throw new Error('Unknown UI operation');
}
'''


class Probe:
    def __init__(self, args):
        self.args = args
        self.started = time.monotonic()
        self.deadline = self.started + 80
        self.cleanup_mode = False
        self.safe = False
        self.workspace = None
        self.saved_preferences = {}
        self.report = {"run_id": args.run_id, "pid": args.pid, "checks": [], "screenshots": []}
        self.output = None

    def timeout(self):
        remaining = self.started + 88 - time.monotonic() if self.cleanup_mode else self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Probe deadline reached')
        return min(3, remaining)

    def run(self, argv, check=True):
        try:
            result = subprocess.run(argv, text=True, capture_output=True, timeout=self.timeout())
        except subprocess.TimeoutExpired as error:
            raise TimeoutError('%s exceeded the probe operation deadline' % Path(argv[0]).name) from error
        if check and result.returncode:
            raise RuntimeError('%s failed: %s' % (Path(argv[0]).name, result.stderr.strip()))
        return result

    def ui(self, operation, *args):
        result = self.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', JXA,
                           str(self.args.pid), operation, *args])
        return json.loads(result.stdout)

    def rpc(self, method, params=None):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(self.timeout())
            connection.connect(self.args.socket)
            request = {"id": str(uuid.uuid4()), "method": method, "params": params or {}}
            connection.sendall((json.dumps(request) + '\n').encode())
            data = b''
            while not data.endswith(b'\n'):
                chunk = connection.recv(65536)
                if not chunk:
                    raise RuntimeError('Socket closed before response')
                data += chunk
                if len(data) > 2_000_000:
                    raise RuntimeError('Socket response exceeded probe limit')
        response = json.loads(data)
        if not response.get('ok'):
            raise RuntimeError('%s: %s' % (method, response.get('error')))
        return response.get('result') or {}

    def eventually(self, predicate, label, seconds=5):
        end = min(time.monotonic() + seconds, self.deadline)
        while time.monotonic() < end:
            value = predicate()
            if value:
                return value
            time.sleep(0.1)
        raise AssertionError(label)

    def status(self):
        state = self.ui('inspect')
        candidates = state['candidates']
        if len(candidates) != 1:
            raise AssertionError('Status extra unavailable; enable tagged showMenuBarExtra before launch')
        return candidates[0]

    def check(self, condition, label):
        if not condition:
            raise AssertionError(label)
        self.report['checks'].append(label)

    def screenshot(self, label):
        # Exactly one enumerated guest display: capture menus as well as the app.
        display_path = self.output / (label + '-display.png')
        self.run(['/usr/sbin/screencapture', '-x', '-D', '1', str(display_path)])
        window_path = self.output / (label + '-window.png')
        self.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(self.window_id), str(window_path)])
        self.check(display_path.is_file() and window_path.is_file(), label + ' screenshots captured')
        self.report['screenshots'].extend([str(display_path), str(window_path)])

    def dismiss(self):
        before = self.ui('popup-windows', str(self.window_id))
        self.ui('dismiss')
        time.sleep(0.1)
        method = 'PID-targeted Escape'
        if self.ui('popup-windows', str(self.window_id)):
            self.ui('dismiss-menu')
            method = 'PID-scoped Show c11 menu click'
        end = time.monotonic() + min(2, self.timeout())
        while time.monotonic() < end:
            if not self.ui('popup-windows', str(self.window_id)):
                self.report.setdefault('dismissals', []).append({'before': before, 'after': []})
                self.report['checks'].append(method + ' dismissed menu')
                return
            time.sleep(0.1)
        raise AssertionError('Synthesized Escape did not dismiss tagged menu')

    def preference(self, key, enabled):
        old = self.run(['/usr/bin/defaults', 'read', self.domain, key], check=False)
        self.saved_preferences[key] = old.stdout.strip() if old.returncode == 0 else None
        self.run(['/usr/bin/defaults', 'write', self.domain, key, '-bool', 'YES' if enabled else 'NO'])

    def preflight(self, read_only=False):
        args = self.args
        if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', args.run_id):
            raise RuntimeError('Invalid sandbox run ID')
        expected_app_root = Path.home() / 'c11-sandbox/apps' / args.run_id
        app = Path(args.app).resolve()
        if app.parent != expected_app_root.resolve() or not app.name.startswith('c11 DEV '):
            raise RuntimeError('App must be a tagged bundle in this guest sandbox run')
        if args.socket != '/tmp/c11-sandbox-' + args.run_id + '.sock':
            raise RuntimeError('Socket must belong to the explicit sandbox run')
        expected_cli = app / 'Contents/Resources/bin/c11'
        if Path(args.cli).resolve() != expected_cli.resolve() or not os.access(args.cli, os.X_OK):
            raise RuntimeError('CLI must be the supplied tagged bundle executable')
        mounts = self.run(['/sbin/mount']).stdout
        if not any('applevirtiofs' in line.lower() and
                   ' on /Volumes/My Shared Files (' in line for line in mounts.splitlines()) or \
                not Path('/Volumes/My Shared Files/out').is_dir():
            raise RuntimeError('Refusing UI outside the Tart guest shared out mount')
        model = self.run(['/usr/sbin/sysctl', '-n', 'hw.model']).stdout.strip()
        self.report['guest_model'] = model
        # The run-specific virtiofs mount plus staged app/socket identify the guest.
        self.output = Path('/Volumes/My Shared Files/out') / args.output_name
        if self.output.parent.resolve() != Path('/Volumes/My Shared Files/out').resolve():
            raise RuntimeError('Output must be a direct child of guest shared out')
        self.output.mkdir(exist_ok=True)
        with (app / 'Contents/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        self.domain = info['CFBundleIdentifier']
        if not self.domain.startswith('com.stage11.c11.debug.'):
            raise RuntimeError('Refusing a production or untagged preferences domain')
        executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
        command = self.run(['/bin/ps', '-p', str(args.pid), '-o', 'command=']).stdout.strip()
        self.check(command == str(executable), 'Tagged PID matches exact bundle executable')
        listeners = self.run(['/usr/sbin/lsof', '-n', '-a', '-p', str(args.pid), '-U']).stdout
        self.check(args.socket in listeners.split(), 'Explicit socket listener belongs to tagged PID')
        brand = self.rpc('system.brand')['bundle']['identifier']
        self.check(brand == self.domain, 'Socket reports the exact tagged bundle identity')
        if read_only:
            return
        self.check(not self.rpc('notification.list').get('notifications'), 'Guest starts with zero routine history')
        self.check(not self.rpc('flag.list').get('flags'), 'Guest starts with zero flags')
        topology = self.ui('displays')
        self.report['display_enumeration'] = topology
        self.check(len(topology['displays']) == 1, 'Exactly one guest display enumerated')
        self.check(len(topology['windows']) == 1, 'Exactly one visible tagged main window enumerated')
        self.window_id = topology['windows'][0]['kCGWindowNumber']
        screen = topology['displays'][0]
        window = topology['windows'][0]['kCGWindowBounds']
        self.check(window['X'] >= 0 and window['Y'] >= 0
                   and window['X'] + window['Width'] <= screen['width']
                   and window['Y'] + window['Height'] <= screen['height'],
                   'Entire tagged window fits on the verified single guest display')
        # All display/PID/window checks precede preferences and GUI activation.
        self.safe = True
        self.preference('showMenuBarExtra', True)
        self.preference('menubarDebugPreviewEnabled', False)
        self.ui('activate')
        self.check(self.ui('inspect')['frontmost'], 'Exact tagged PID is frontmost')

    def execute(self):
        if self.args.inspect_dialogs_only:
            self.preflight(read_only=True)
            self.report['mode'] = 'read-only AX dialog query'
            self.report['dialogs'] = self.ui('dialogs')
            self.report['authorization_note'] = (
                'An Allow button can be targeted safely only after its exact owning PID, '
                'window/sheet and notification-permission context are verified. '
                'This query performs no approval and does not inspect OS-owned dialogs.')
            return
        self.preflight()
        self.workspace = self.rpc('workspace.create')['workspace_id']
        self.rpc('workspace.rename', {"workspace_id": self.workspace, "title": 'Synthetic menu probe'})
        target = self.rpc('tab.list', {"workspace_id": self.workspace})['tabs'][0]['id']
        sibling = self.rpc('tab.create', {"workspace_id": self.workspace, "type": 'terminal'})['tab_id']
        self.rpc('workspace.select', {"workspace_id": self.workspace})
        self.rpc('tab.focus', {"workspace_id": self.workspace, "tab_id": sibling})
        self.eventually(lambda: len(self.ui('inspect')['candidates']) == 1,
                        'Tagged status extra did not appear; set showMenuBarExtra before launching')
        baseline_size = self.status()['size']
        self.screenshot('01-zero-routine-before')
        params = {"workspace_id": self.workspace, "tab_id": target, "by": 'operator'}
        reason = 'Synthetic menu decision'
        self.rpc('flag.raise', dict(params, reason=reason))
        self.eventually(lambda: reason in str(self.status()['help']), 'Flag tooltip did not refresh')
        self.check(self.status()['size'] == baseline_size, 'Flag icon preserves status-item dimensions')
        self.ui('open')
        rows = self.eventually(lambda: self.status()['rows'], 'Flag menu did not open')
        self.check(any(row['name'].startswith('⚑ ') and reason in row['name'] for row in rows),
                   'Zero-routine flag appears as a separate UI menu row')
        self.screenshot('02-zero-routine-flag-menu')
        self.dismiss()
        self.rpc('flag.suppress', params)
        self.check(self.rpc('flag.list')['flags'][0]['suppressed'], 'Flag remains indexed while suppressed')
        self.ui('open')
        rows = self.eventually(lambda: self.status()['rows'], 'Suppressed flag menu did not open')
        self.check(any(row['name'].startswith('⚑ ') and reason in row['name'] for row in rows),
                   'Suppressed flag stays visible in actual menu')
        self.screenshot('03-suppressed-flag-menu')
        self.ui('click-flag', reason)
        focused = self.eventually(lambda: (self.rpc('system.identify').get('focused') or {}).get('tab_id') == target,
                                  'Actual flag-row click did not select exact target tab')
        self.check(bool(focused), 'Flag-row click selected exact target tab')
        selected = self.rpc('system.identify')['focused']
        self.check(selected.get('workspace_id') == self.workspace, 'Flag-row click selected exact workspace')
        self.dismiss()
        self.screenshot('04-exact-target-after-click')
        self.rpc('flag.lower', params)
        self.eventually(lambda: reason not in str(self.status()['help']), 'Lowered flag tooltip stayed stale')
        self.check(not self.rpc('flag.list')['flags'], 'Lower removes flag from index')
        self.ui('open')
        rows = self.eventually(lambda: self.status()['rows'], 'Lowered menu did not open')
        self.check(not any(row['name'].startswith('⚑ ') for row in rows), 'Lowered flag disappears from actual menu')
        self.check(not self.rpc('notification.list')['notifications'], 'Flags never entered routine history')
        self.screenshot('05-lowered-menu')
        self.dismiss()
        self.screenshot('06-dismissed-after')
        self.rpc('tab.focus', {"workspace_id": self.workspace, "tab_id": sibling})
        finder = self.ui('background')
        self.eventually(lambda: self.ui('foreground') == finder, 'Guest Finder did not become frontmost')
        selection = self.rpc('system.identify')['focused']
        reason = 'Synthetic background decision'
        self.rpc('flag.raise', dict(params, reason=reason))
        self.eventually(lambda: reason in str(self.status()['help']), 'Background flag tooltip did not refresh')
        self.check(self.ui('foreground') == finder, 'Background flag mutation preserves foreground app')
        self.check(self.rpc('system.identify')['focused'] == selection,
                   'Background flag mutation preserves selected workspace and tab')
        self.ui('open')
        rows = self.eventually(lambda: self.status()['rows'], 'Background flag menu did not open')
        self.check(any(row['name'].startswith('⚑ ') and reason in row['name'] for row in rows),
                   'Background flag appears in actual menu')
        self.screenshot('07-background-flag-menu')
        self.ui('click-flag', reason)
        self.eventually(lambda: (self.rpc('system.identify').get('focused') or {}).get('tab_id') == target,
                        'Background flag-row click did not select exact target tab')
        self.check(self.ui('foreground') == self.args.pid, 'Explicit background flag-row click activates tagged app')
        self.screenshot('08-background-exact-target')
        self.rpc('flag.lower', params)
        self.dismiss()

    def cleanup(self):
        self.cleanup_mode = True
        errors = []
        if self.safe:
            for operation in [self.dismiss, self.close_workspace, self.restore_preferences]:
                try:
                    operation()
                except Exception as error:
                    errors.append(str(error))
        self.report['cleanup_errors'] = errors
        if errors:
            self.report['result'] = 'FAIL'
        self.report['elapsed_seconds'] = round(time.monotonic() - self.started, 3)
        if self.output:
            (self.output / 'report.json').write_text(json.dumps(self.report, indent=2) + '\n')

    def close_workspace(self):
        if self.workspace:
            self.rpc('workspace.close', {"workspace_id": self.workspace})
            self.workspace = None

    def restore_preferences(self):
        for key, old in self.saved_preferences.items():
            argv = ['/usr/bin/defaults', 'delete', self.domain, key] if old is None else [
                '/usr/bin/defaults', 'write', self.domain, key, '-bool',
                'YES' if old.lower() in ('1', 'true', 'yes') else 'NO']
            self.run(argv)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--app', required=True)
    parser.add_argument('--cli', default=os.environ.get('C11_CLI'), required=not os.environ.get('C11_CLI'))
    parser.add_argument('--socket', default=os.environ.get('C11_SOCKET_PATH'), required=not os.environ.get('C11_SOCKET_PATH'))
    parser.add_argument('--output-name', default='menu-probe')
    parser.add_argument('--inspect-dialogs-only', action='store_true')
    probe = Probe(parser.parse_args())
    def expire(_signal, _frame):
        raise TimeoutError('80-second active-phase limit reached; dismissing tagged menu')
    signal.signal(signal.SIGALRM, expire)
    signal.alarm(80)
    watchdog = threading.Timer(89, lambda: os._exit(124))
    watchdog.daemon = True
    watchdog.start()
    try:
        probe.execute()
        probe.report['result'] = 'PASS'
    except Exception as error:
        probe.report.update(result='FAIL', error=str(error))
    finally:
        signal.alarm(0)
        probe.cleanup()
        watchdog.cancel()
    print(json.dumps(probe.report, indent=2))
    return 0 if probe.report.get('result') == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
