#!/usr/bin/env python3
"""C11-510 native proof: a page's app link asks first. ONLY via sandbox-tests-v2.sh.

A localhost fixture page in a guest browser panel fires vnc:// links. Native,
timestamped HID clicks (located by accessibility role/title or by the web
area's AX frame plus the DOM rect) drive the page and the sheet. Socket calls
only seed the panel and read oracles. 240-second active / 280-second hard limit.
"""
import ctypes
import functools
import http.server
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
import traceback

OUT = Path('/Volumes/My Shared Files/out/browser-external-open-proof')
ACTIVE_SECONDS, HARD_SECONDS = 240, 280
SCREEN_SHARING = 'Screen Sharing'
FIXTURE = '''<!doctype html>
<html><head><meta charset="utf-8"><title>C11-510 app link fixture</title>
<style>body{font:18px -apple-system,sans-serif;margin:32px}a,button{display:block;margin:18px 0;font-size:20px}</style></head>
<body>
<h1>C11-510 app link fixture</h1>
<a id="vnc-link" href="vnc://c11-proof.invalid">Open Screen Sharing (link)</a>
<button id="vnc-burst" onclick="for(let i=0;i<10;i++){location.href='vnc://c11-proof.invalid/'+i}">Burst 10 requests</button>
<button id="vnc-popup" onclick="window.open('vnc://c11-proof.invalid')">Open via window.open</button>
<a id="nohandler" href="c11-no-such-scheme://x">No handler scheme</a>
</body></html>
'''

# A compiled AX walk: System Events has no Accessibility grant in the guest.
AX_WALK = Path(__file__).resolve().parent / '.ax-walk'


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
        with (self.app / 'Contents/Info.plist').open('rb') as stream:
            self.bundle = plistlib.load(stream)
        assert self.bundle['CFBundleIdentifier'].startswith('com.stage11.c11.debug.'), self.bundle['CFBundleIdentifier']
        self.cli = str(self.app / 'Contents/Resources/bin/c11')
        for key in list(os.environ):
            if key.startswith(('C11_SOCKET', 'CMUX_SOCKET')) or key in ('C11_PANEL_ID', 'CMUX_SURFACE_ID',
                                                                       'C11_WORKSPACE_ID', 'CMUX_WORKSPACE_ID'):
                del os.environ[key]
        os.environ['C11_SOCKET_PATH'] = '/tmp/c11-510-no-default.sock'
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(8)
        self.sock.connect(self.socket_path)
        listeners = subprocess.check_output(['/usr/sbin/lsof', '-nP', '-a', '-p', str(self.pid), '-U'], text=True, timeout=5)
        assert self.socket_path in listeners, 'socket is not owned by exact guest PID'
        self.reader, self.sequence = self.sock.makefile('rb'), 0
        self.report = dict(status='running', identity=dict(pid=self.pid, app=str(self.app),
                           bundle=self.bundle['CFBundleIdentifier'], socket=self.socket_path), checks=[], clicks=[])
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

    def run(self, command, **kwargs):
        return subprocess.run(command, check=True, capture_output=True, timeout=15, **kwargs)

    def call(self, method, **params):
        self.sequence += 1
        self.sock.sendall((json.dumps(dict(id=self.sequence, method=method, params=params)) + '\n').encode())
        result = json.loads(self.reader.readline())
        assert result['id'] == self.sequence and result.get('ok'), (method, result)
        return result.get('result')

    def ax(self, op='tree'):
        assert AX_WALK.is_file(), 'compile tests_v2/ax_walk.swift to tests_v2/.ax-walk first'
        result = json.loads(self.run([str(AX_WALK), str(self.pid), op], text=True).stdout)
        assert not (isinstance(result, dict) and result.get('error')), result
        return result

    def wait(self, predicate, label, timeout=8):
        deadline, last = time.monotonic() + timeout, None
        while time.monotonic() < deadline:
            try:
                value = predicate()
                if value:
                    return value
            except (AssertionError, subprocess.CalledProcessError) as error:
                last = str(error)
            time.sleep(.15)
        raise AssertionError((label, last))

    def passed(self, label, **evidence):
        self.report['checks'].append(dict(label=label, elapsed=round(time.monotonic() - self.started, 2), **evidence))
        print('PASS', label, flush=True)

    def screenshot(self, name):
        self.run(['/usr/sbin/screencapture', '-x', '-D', '1', str(OUT / (name + '.png'))])

    def screen_sharing_pids(self):
        result = subprocess.run(['/usr/bin/pgrep', '-x', SCREEN_SHARING], capture_output=True, text=True, timeout=5)
        return [int(x) for x in result.stdout.split()]

    def native_click(self, x, y, label):
        assert self.ax('foreground') == self.pid, 'exact guest PID must be foreground'
        class Point(ctypes.Structure):
            _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]
        cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
        cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
        cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
        cg.CGEventSetTimestamp.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        posted = []
        for event_type in (5, 1, 2):  # move, left down, left up
            event = cg.CGEventCreateMouseEvent(None, event_type, Point(x, y), 0)
            assert event
            if event_type != 5:
                cg.CGEventSetIntegerValueField(event, 1, 1)  # kCGMouseEventClickState
            cg.CGEventSetTimestamp(event, time.monotonic_ns())
            cg.CGEventPost(0, event)
            posted.append(round(time.time() * 1000))
            cf.CFRelease(event)
            time.sleep(.12)
        self.report['clicks'].append(dict(label=label, x=x, y=y, posted_ms=posted,
                                          elapsed=round(time.monotonic() - self.started, 2)))

    def click_page(self, selector):
        rect = self.call('browser.eval', panel_id=self.browser, workspace_id=self.workspace, script=(
            f'(() => {{ const r=document.querySelector({json.dumps(selector)}).getBoundingClientRect();'
            ' return [r.x+r.width/2, r.y+r.height/2, innerWidth, innerHeight]; })()'))['value']
        areas = self.ax()['webAreas']
        assert len(areas) == 1, ('expected one web area', areas)
        (wx, wy), (ww, wh) = areas[0]['position'], areas[0]['size']
        x, y = wx + rect[0] * ww / rect[2], wy + rect[1] * wh / rect[3]
        self.native_click(round(x), round(y), 'page ' + selector)

    def sheets(self):
        return self.ax()['sheets']

    def click_sheet_button(self, title):
        sheets = self.sheets()
        assert len(sheets) == 1, ('expected exactly one sheet', sheets)
        buttons = [c for c in sheets[0]['children'] if c['role'] == 'AXButton' and c['title'] == title]
        assert len(buttons) == 1, (title, sheets[0]['children'])
        (x, y), (w, h) = buttons[0]['position'], buttons[0]['size']
        self.native_click(round(x + w / 2), round(y + h / 2), 'sheet ' + title)

    def reload_fixture(self):
        self.call('browser.navigate', panel_id=self.browser, workspace_id=self.workspace, url=self.url)
        self.wait(lambda: self.call('browser.eval', panel_id=self.browser, workspace_id=self.workspace,
                                    script='document.readyState')['value'] == 'complete', 'fixture loaded')
        time.sleep(.5)

    def workspace_log(self):
        result = self.run([self.cli, '--socket', self.socket_path, 'list-log', '--workspace', self.workspace], text=True)
        return result.stdout

    def execute(self):
        assert not self.screen_sharing_pids(), 'Screen Sharing must not be running before the proof'
        directory = Path('/tmp/c11-510-fixture')
        directory.mkdir(exist_ok=True)
        (directory / 'index.html').write_text(FIXTURE)
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
        handler.log_message = lambda *a: None
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f'http://127.0.0.1:{self.server.server_address[1]}/index.html'

        self.ax('activate')
        self.wait(lambda: self.ax('foreground') == self.pid, 'guest app frontmost')
        windows = self.call('window.list')['windows']
        key = next(w for w in windows if w['key'])
        focused = self.call('system.identify', window_id=key['id'])['focused']
        self.workspace = focused['workspace_id']
        opened = self.call('browser.open_split', workspace_id=self.workspace, url=self.url)
        self.browser = opened['surface_id']
        self.reload_fixture()
        self.passed('fixture served from localhost and loaded in a guest browser panel', url=self.url)

        # 1. A link click asks; the sheet names the site, app and URL.
        self.click_page('#vnc-link')
        sheet = self.wait(lambda: (lambda s: s[0] if len(s) == 1 else None)(self.sheets()), 'prompt sheet appeared')
        texts = ' '.join(str(c.get('value') or c.get('title') or '') for c in sheet['children'])
        titles = sorted(c['title'] for c in sheet['children'] if c['role'] == 'AXButton')
        assert 'Screen Sharing' in texts and '127.0.0.1' in texts and 'vnc://c11-proof.invalid' in texts, texts
        assert {'Open', 'Cancel'} <= set(titles), titles
        assert any(c['role'] == 'AXCheckBox' and 'Always allow' in (c['title'] or '') for c in sheet['children']), sheet
        self.screenshot('01-prompt')
        assert not self.screen_sharing_pids(), 'opened before consent'
        self.passed('link click shows one sheet naming site, app and URL; nothing opened yet', texts=texts, buttons=titles)

        # 2. Cancel opens nothing.
        self.click_sheet_button('Cancel')
        self.wait(lambda: not self.sheets(), 'sheet dismissed by Cancel')
        time.sleep(3)
        assert not self.screen_sharing_pids(), 'Cancel opened Screen Sharing'
        self.screenshot('02-after-cancel')
        self.passed('Cancel dismisses the sheet and Screen Sharing never launches')

        # 3. After the cooldown a fresh click asks again; Open launches the handler once.
        time.sleep(2.5)
        self.click_page('#vnc-link')
        self.wait(lambda: len(self.sheets()) == 1, 'second prompt sheet')
        self.click_sheet_button('Open')
        launched = self.wait(self.screen_sharing_pids, 'Screen Sharing launched after Open', timeout=15)
        time.sleep(1.5)
        self.screenshot('03-after-open')
        self.passed('Open launches Screen Sharing', pids=launched)
        # No Apple Events: quitting by signal needs no automation grant.
        subprocess.run(['/usr/bin/pkill', '-x', SCREEN_SHARING], timeout=5, check=False)
        self.wait(lambda: not self.screen_sharing_pids(), 'Screen Sharing stopped', timeout=8)
        self.ax('activate')
        self.wait(lambda: self.ax('foreground') == self.pid, 'guest app frontmost again')

        # 4. A burst of ten scripted requests yields one sheet and an explanatory log line.
        self.reload_fixture()
        self.click_page('#vnc-burst')
        self.wait(lambda: len(self.sheets()) == 1, 'burst prompt sheet')
        time.sleep(1)
        assert len(self.sheets()) == 1, 'burst stacked sheets'
        self.screenshot('04-burst-one-sheet')
        log = self.workspace_log()
        assert 'while a prompt was showing' in log, log
        self.click_sheet_button('Cancel')
        self.wait(lambda: not self.sheets(), 'burst sheet dismissed')
        time.sleep(1)
        assert not self.sheets() and not self.screen_sharing_pids()
        self.passed('burst of 10 shows exactly one sheet, logs the drop, Cancel leaves nothing queued', log=log.strip())

        # 5. window.open from the page asks through the same gate.
        time.sleep(2.5)
        self.reload_fixture()
        self.click_page('#vnc-popup')
        self.wait(lambda: len(self.sheets()) == 1, 'window.open prompt sheet')
        self.screenshot('05-window-open-prompt')
        self.click_sheet_button('Cancel')
        self.wait(lambda: not self.sheets(), 'window.open sheet dismissed')
        time.sleep(2)
        assert not self.screen_sharing_pids()
        self.passed('window.open to vnc: asks; Cancel opens nothing')

        # 6. A scheme no app handles shows a notice, not a prompt.
        time.sleep(2.5)
        self.click_page('#nohandler')
        notice = self.wait(lambda: self.ax()['notices'], 'no-handler notice')
        assert not self.sheets(), 'no-handler scheme prompted'
        self.screenshot('06-no-handler-notice')
        self.passed('unhandled scheme shows a notice and no sheet', notice=notice)
        self.report['status'] = 'passed'

    def cleanup(self):
        signal.setitimer(signal.ITIMER_REAL, 0)
        try:
            subprocess.run(['/usr/bin/pkill', '-x', SCREEN_SHARING], timeout=5, check=False)
            if getattr(self, 'server', None):
                self.server.shutdown()
        finally:
            self.report['elapsed_seconds'] = round(time.monotonic() - self.started, 2)
            (OUT / 'report.json').write_text(json.dumps(self.report, indent=2))
            self.sock.close()
            self.watchdog.cancel()


if __name__ == '__main__':
    proof = Proof()
    try:
        proof.execute()
        print('PASS C11-510 browser external open; evidence=' + str(OUT), flush=True)
    except BaseException as error:
        proof.report.update(status='failed', error=str(error), traceback=traceback.format_exc())
        try:
            proof.screenshot('failure')
        except Exception as capture_error:
            proof.report['failure_screenshot_error'] = str(capture_error)
        raise
    finally:
        proof.cleanup()
