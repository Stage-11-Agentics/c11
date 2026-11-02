#!/usr/bin/env python3
"""C11-563 native proof: the workspace context menu layout and rename to empty.

ONLY via scripts/sandbox-tests-v2.sh in a sandbox guest. Compile the AX helper
first: xcrun swiftc -O -target arm64-apple-macos14 tests_v2/ax_walk.swift -o tests_v2/.ax-walk

Socket/CLI calls seed workspaces and read oracles. Every UI action is a
timestamped HID event (click count 1) aimed at an element found by its
accessibility identifier or title. 240-second active / 280-second hard limit.
"""
import ctypes
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time
import traceback

OUT = Path('/Volumes/My Shared Files/out/c11-563-workspace-menu-proof')
ACTIVE_SECONDS, HARD_SECONDS = 240, 280
AX_WALK = Path(__file__).resolve().parent / '.ax-walk'
REMOVED = ['Remove Custom Workspace Name', 'Move Up', 'Move Down', 'Move to Top']
CUSTOM = 'Proof Custom'

PLAIN = ['Pin Workspace', 'Rename Workspace…', 'Workspace Root', 'Close Workspace', '',
         'Workspace Color', 'Move to Group', '',
         'Move Workspace to Window', '',
         'Hibernate Workspace', 'Mark Workspace as Read', 'Mark Workspace as Unread', 'Copy Link']
SSH_PREFIX = ['Pin Workspace', 'Rename Workspace…', 'Workspace Root', 'Close Workspace', '',
              'Workspace Color', 'Move to Group', '',
              'Move Workspace to Window', 'Reconnect Workspace', 'Disconnect Workspace']
SSH_SUFFIX = ['', 'Hibernate Workspace', 'Mark Workspace as Read', 'Mark Workspace as Unread', 'Copy Link']
MULTI = ['Pin Workspaces', 'Rename Workspace…', 'Close Workspaces', '',
         'Workspace Color', 'Move to Group', '',
         'Move Workspaces to Window', 'Reconnect Workspaces', 'Disconnect Workspaces']


class Point(ctypes.Structure):
    _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]


CG = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
CF = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
CG.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
CG.CGEventCreateMouseEvent.restype = ctypes.c_void_p
CG.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
CG.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
CG.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
CG.CGEventSetTimestamp.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
CG.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
CG.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
CG.CGEventSourceCreate.argtypes = [ctypes.c_int32]
CG.CGEventSourceCreate.restype = ctypes.c_void_p
CF.CFRelease.argtypes = [ctypes.c_void_p]
CMD = 1 << 20
# Key events need an HID-state source: a sourceless event carries keyboard
# type 0, which the text input system drops (NSMenu tracking still takes it).
HID_SOURCE = CG.CGEventSourceCreate(1)  # kCGEventSourceStateHIDSystemState


class Proof:
    def __init__(self):
        self.started = time.monotonic()
        self.socket_path = os.environ.get('C11_SOCKET_PATH', '')
        assert re.fullmatch(r'/tmp/c11-sandbox-[A-Za-z0-9._-]+\.sock', self.socket_path), 'sandbox socket required'
        self.run_id = self.socket_path.removeprefix('/tmp/c11-sandbox-').removesuffix('.sock')
        assert OUT.parent.is_dir(), 'guest shared output required'
        OUT.mkdir(exist_ok=True)
        apps = list((Path('/Users/admin/c11-sandbox/apps') / self.run_id).glob('*.app'))
        assert len(apps) == 1, apps
        self.app = apps[0]
        executable = str(self.app / 'Contents/MacOS/c11')
        lines = subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True, timeout=5).splitlines()
        pids = [int(l.strip().split(None, 1)[0]) for l in lines if l.strip().split(None, 1)[-1] == executable]
        assert len(pids) == 1, ('exact guest app missing', pids)
        self.pid = pids[0]
        self.cli = str(self.app / 'Contents/Resources/bin/c11')
        for key in list(os.environ):
            if key.startswith(('C11_SOCKET', 'CMUX_SOCKET')) or key in ('C11_PANEL_ID', 'CMUX_SURFACE_ID',
                                                                       'C11_WORKSPACE_ID', 'CMUX_WORKSPACE_ID'):
                del os.environ[key]
        self.env = dict(os.environ, C11_SOCKET_PATH=self.socket_path)
        self.report = dict(status='running', identity=dict(pid=self.pid, app=str(self.app), socket=self.socket_path),
                           checks=[], events=[])
        self.watchdog = threading.Timer(HARD_SECONDS, self.hard_stop)
        self.watchdog.daemon = True
        self.watchdog.start()
        signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('active deadline')))
        signal.setitimer(signal.ITIMER_REAL, ACTIVE_SECONDS)

    def hard_stop(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
        finally:
            (OUT / 'hard-timeout.txt').write_text('hard timeout; exact guest PID terminated.\n')
            os._exit(124)

    # -- plumbing ---------------------------------------------------------

    def c11(self, *args):
        result = subprocess.run([self.cli, *args], env=self.env, capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return result.stdout

    def workspaces(self):
        data = json.loads(self.c11('--id-format', 'both', 'list-workspaces', '--json'))
        return data['workspaces'] if isinstance(data, dict) else data

    def ax(self, op):
        assert AX_WALK.is_file(), 'compile tests_v2/ax_walk.swift to tests_v2/.ax-walk first'
        out = subprocess.run([str(AX_WALK), str(self.pid), op], check=True, capture_output=True, text=True, timeout=15)
        result = json.loads(out.stdout)
        assert not (isinstance(result, dict) and result.get('error')), result
        return result

    def wait(self, predicate, label, timeout=8):
        deadline, last = time.monotonic() + timeout, None
        while time.monotonic() < deadline:
            try:
                value = predicate()
                if value:
                    return value
            except (AssertionError, subprocess.CalledProcessError, KeyError) as error:
                last = str(error)
            time.sleep(.15)
        raise AssertionError((label, last))

    def passed(self, label, **evidence):
        self.report['checks'].append(dict(label=label, elapsed=round(time.monotonic() - self.started, 2), **evidence))
        print('PASS', label, flush=True)

    def screenshot(self, name):
        subprocess.run(['/usr/sbin/screencapture', '-x', '-D', '1', str(OUT / (name + '.png'))], check=True, timeout=15)

    def post(self, event, flags=0):
        assert event
        if flags:
            CG.CGEventSetFlags(event, flags)
        CG.CGEventSetTimestamp(event, time.monotonic_ns())
        CG.CGEventPost(0, event)
        CF.CFRelease(event)

    def click(self, x, y, label, right=False, flags=0):
        assert self.ax('foreground') == self.pid, 'exact guest PID must be foreground'
        down, up, button = (3, 4, 1) if right else (1, 2, 0)
        stamps = []
        for kind in (5, down, up):
            event = CG.CGEventCreateMouseEvent(None, kind, Point(x, y), button)
            if kind != 5:
                CG.CGEventSetIntegerValueField(event, 1, 1)  # kCGMouseEventClickState
            self.post(event, flags if kind != 5 else 0)
            stamps.append(round(time.time() * 1000))
            time.sleep(.12)
        self.report['events'].append(dict(kind='right-click' if right else 'click', label=label, x=x, y=y,
                                          flags=flags, posted_ms=stamps))

    def key(self, code, label):
        assert self.ax('foreground') == self.pid, 'exact guest PID must be foreground'
        for down in (True, False):
            self.post(CG.CGEventCreateKeyboardEvent(HID_SOURCE, code, down))
            time.sleep(.06)
        self.report['events'].append(dict(kind='key', label=label, code=code,
                                          posted_ms=round(time.time() * 1000)))

    def chord(self, label, *commands):
        # Modifier chords go through cliclick kd/ku. Command flags set on an
        # HID-state key event latch Command in the guest, so every later key
        # becomes a shortcut.
        assert self.ax('foreground') == self.pid, 'exact guest PID must be foreground'
        subprocess.run(['/opt/homebrew/bin/cliclick', '-w', '70', *commands], check=True, timeout=15)
        self.report['events'].append(dict(kind='chord', label=label, commands=list(commands),
                                          posted_ms=round(time.time() * 1000)))

    @staticmethod
    def center(element):
        (x, y), (w, h) = element['position'], element['size']
        return round(x + w / 2), round(y + h / 2)

    def row(self, workspace_id):
        rows = [r for r in self.ax('fields')['rows'] if r['id'] == 'sidebar.workspace.' + workspace_id.upper()]
        assert len(rows) == 1, ('sidebar row', workspace_id, rows)
        return rows[0]

    def open_menu(self, workspace_id, label):
        self.click(*self.center(self.row(workspace_id)), label, right=True)
        menus = self.wait(lambda: self.ax('menus')['menus'], 'context menu opens')
        assert len(menus) == 1, ('one open menu', menus)
        return menus[0]

    @staticmethod
    def titles(items):
        # AppKit appends a trailing separator to context menus; drop it.
        titles = [i['title'] or '' for i in items]
        while titles and titles[-1] == '':
            titles.pop()
        return titles

    def close_menu(self):
        self.key(53, 'escape closes menu')
        self.wait(lambda: not self.ax('menus')['menus'], 'menu closed')

    def click_item(self, items, title):
        found = [i for i in items if i['title'] == title]
        assert len(found) == 1, (title, [i['title'] for i in items])
        self.click(*self.center(found[0]), 'menu ' + title)

    def rename_field(self):
        fields = [f for f in self.ax('fields')['fields'] if f.get('placeholder')]
        assert len(fields) == 1, ('one rename field', fields)
        return fields[0]

    def click_button(self, title):
        found = [b for b in self.ax('fields')['buttons'] if b['title'] == title]
        assert len(found) == 1, (title, found)
        self.click(*self.center(found[0]), 'button ' + title)

    # -- scenario ---------------------------------------------------------

    def execute(self):
        subprocess.run(['/usr/bin/pkill', '-x', 'System Settings'], timeout=5, check=False)
        # Release any modifier an earlier run left down.
        subprocess.run(['/opt/homebrew/bin/cliclick', 'ku:cmd', 'ku:alt', 'ku:shift', 'ku:ctrl'], timeout=15, check=False)
        before = self.workspaces()
        assert before, 'guest has a workspace'
        plain = before[0]
        plain_id = plain['id']
        # The automatic name of an unnamed workspace is "Workspace N" for workspace:N.
        automatic = 'Workspace ' + plain['ref'].split(':')[1]
        self.c11('rename-workspace', '--workspace', plain_id, '--', CUSTOM)
        # A blackhole address keeps ssh connecting, so the remote workspace
        # stays open for the whole proof (a refused host ends it at once).
        self.c11('ssh', '10.255.255.1', '--name', 'SSH Proof',
                 '--ssh-option', 'ConnectTimeout=200', '--ssh-option', 'BatchMode=yes')
        ssh = self.wait(lambda: [w for w in self.workspaces() if w['title'] == 'SSH Proof'], 'ssh workspace')[0]
        ssh_id = ssh['id']
        self.passed('seeded plain and SSH workspaces', automatic=automatic, plain=plain_id, ssh=ssh_id)
        assert self.ax('activate')
        self.wait(lambda: self.ax('foreground') == self.pid, 'guest c11 foreground')
        time.sleep(1.0)

        # Select the plain workspace with a real click (agents cannot select it).
        self.click(*self.center(self.row(plain_id)), 'select plain workspace')
        self.wait(lambda: [w for w in self.workspaces() if w['id'] == plain_id and w.get('selected')], 'plain selected')

        # 1. Plain workspace menu: Atin's layout, removed items gone.
        items = self.open_menu(plain_id, 'plain workspace menu')
        titles = self.titles(items)
        self.screenshot('01-menu-plain')
        assert titles == PLAIN, ('plain layout', titles)
        assert not set(REMOVED) & set(titles), titles
        self.passed('plain workspace menu matches the layout', titles=titles)
        self.close_menu()

        # 2. SSH workspace menu: reconnect/disconnect sit under Move Workspace to Window.
        time.sleep(2.0)
        items = self.open_menu(ssh_id, 'ssh workspace menu')
        titles = self.titles(items)
        self.screenshot('02-menu-ssh')
        assert titles[:len(SSH_PREFIX)] == SSH_PREFIX, ('ssh prefix', titles)
        assert titles[-len(SSH_SUFFIX):] == SSH_SUFFIX, ('ssh suffix', titles)
        middle = titles[len(SSH_PREFIX):-len(SSH_SUFFIX)]
        assert middle in ([], ['Copy SSH Error']), ('ssh middle', titles)
        assert not set(REMOVED) & set(titles), titles
        self.passed('SSH workspace menu matches the layout', titles=titles)
        self.close_menu()

        # 3. Rename shows the custom name over the automatic placeholder; empty Save resets.
        items = self.open_menu(plain_id, 'plain menu for rename')
        self.click_item(items, 'Rename Workspace…')
        field = self.wait(self.rename_field, 'rename field appears')
        self.screenshot('03-rename-custom')
        assert field['value'] == CUSTOM, field
        assert field['placeholder'] == automatic, (field, automatic)
        self.passed('rename field holds the custom name with the automatic name as placeholder',
                    value=field['value'], placeholder=field['placeholder'])
        self.click(*self.center(field), 'focus rename field')
        self.chord('select all', 'kd:cmd', 't:a', 'ku:cmd')
        self.key(51, 'delete')
        self.wait(lambda: self.rename_field()['value'] == '', 'field cleared')
        self.screenshot('04-rename-empty')
        self.click_button('Rename')
        self.wait(lambda: not [f for f in self.ax('fields')['fields'] if f.get('placeholder') == automatic],
                  'rename prompt closed')
        renamed = self.wait(lambda: [w for w in self.workspaces() if w['id'] == plain_id and w['title'] == automatic],
                            'title back to automatic')[0]
        self.screenshot('05-after-empty-rename')
        self.passed('saving an empty name restores the automatic name', title=renamed['title'])

        # 4. Reopened, the field is empty: no custom name is left.
        items = self.open_menu(plain_id, 'plain menu for second rename')
        self.click_item(items, 'Rename Workspace…')
        field = self.wait(self.rename_field, 'rename field appears again')
        self.screenshot('06-rename-reopened')
        assert field['value'] == '' and field['placeholder'] == automatic, field
        self.passed('reopened rename field is empty over the automatic placeholder', field=field)
        self.click_button('Cancel')
        self.wait(lambda: not [f for f in self.ax('fields')['fields'] if f.get('placeholder') == automatic],
                  'rename cancelled')

        # 5. Multi-selection keeps plural labels in the new order.
        self.click(*self.center(self.row(ssh_id)), 'cmd-click ssh workspace', flags=CMD)
        time.sleep(.5)
        items = self.open_menu(plain_id, 'multi-selection menu')
        titles = self.titles(items)
        self.screenshot('07-menu-multi')
        assert titles[:len(MULTI)] == MULTI, ('multi prefix', titles)
        rest = titles[len(MULTI):]
        assert rest[-4:] == ['Hibernate Workspace', 'Mark Workspaces as Read', 'Mark Workspaces as Unread', 'Copy Link'], titles
        self.passed('multi-selection menu keeps plural labels in the new order', titles=titles)
        self.close_menu()
        self.report['status'] = 'passed'

    def cleanup(self):
        signal.setitimer(signal.ITIMER_REAL, 0)
        self.report['elapsed_seconds'] = round(time.monotonic() - self.started, 2)
        (OUT / 'report.json').write_text(json.dumps(self.report, indent=2, ensure_ascii=False))
        self.watchdog.cancel()


if __name__ == '__main__':
    proof = Proof()
    try:
        proof.execute()
        print('PASS C11-563 workspace menu; evidence=' + str(OUT), flush=True)
    except BaseException as error:
        proof.report.update(status='failed', error=str(error), traceback=traceback.format_exc())
        try:
            proof.screenshot('failure')
        except Exception as capture_error:
            proof.report['failure_screenshot_error'] = str(capture_error)
        raise
    finally:
        proof.cleanup()
