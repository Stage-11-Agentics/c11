#!/usr/bin/env python3
"""Native c11:// acceptance smoke. Run ONLY with sandbox-tests-v2.sh.

Socket setup/oracles are pinned to the verified sandbox; activation uses the
sandbox's native mouse/keyboard. No socket command performs workspace switching.
"""
import json
import ctypes
import functools
import http.server
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess
import time
import threading
import uuid

START = time.monotonic()
SOCKET = os.environ.get('C11_SOCKET_PATH', '')
assert re.fullmatch(r'/tmp/c11-sandbox-[A-Za-z0-9._-]+\.sock', SOCKET), 'sandbox socket required'
RUN = SOCKET.removeprefix('/tmp/c11-sandbox-').removesuffix('.sock')
for key in list(os.environ):
    if key.startswith(('C11_SOCKET', 'CMUX_SOCKET')):
        del os.environ[key]
os.environ['C11_SOCKET_PATH'] = '/tmp/c11-515-no-default.sock'
APP_ROOT = f'/Users/admin/c11-sandbox/apps/{RUN}/'
lines = subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True).splitlines()
PIDS = [int(line.strip().split(None, 1)[0]) for line in lines
        if APP_ROOT in line and line.endswith('Contents/MacOS/c11')]
assert len(PIDS) == 1, ('exact guest app missing', PIDS)
PID = PIDS[0]
OUT = Path('/Volumes/My Shared Files/out/panel-link-proof')
assert OUT.parent.is_dir(), 'sandbox shared output is required'
OUT.mkdir(exist_ok=True)
LOG = Path(f'/tmp/c11-sandbox-{RUN}.log')
SOCK = socket.socket(socket.AF_UNIX)
SOCK.settimeout(12)
SOCK.connect(SOCKET)
READER = SOCK.makefile('rb')
SEQ = 0
FLAGGED_SIDEBAR = False


def raw(method, **params):
    global SEQ
    SEQ += 1
    SOCK.sendall((json.dumps(dict(id=SEQ, method=method, params=params)) + '\n').encode())
    result = json.loads(READER.readline())
    assert result['id'] == SEQ
    return result


def call(method, **params):
    result = raw(method, **params)
    assert result.get('ok'), (method, result)
    return result.get('result')


def osa(body):
    return subprocess.check_output(['osascript', '-e',
        f'tell application "System Events" to tell (first process whose unix id is {PID})\n{body}\nend tell'], text=True, timeout=15).strip()


def wait_for(predicate, label, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except AssertionError:
            pass
        time.sleep(.1)
    raise AssertionError(label)


def focus():
    # window.create changes the socket's default context even when the new
    # window is behind the operator. Resolve the actual key window explicitly.
    windows = call('window.list')['windows']
    key = next((w for w in windows if w['key']), None)
    assert key is not None, 'guest app window is not key yet'
    return call('system.identify', window_id=key['id'])['focused']


def shot(name):
    assert osa('get frontmost') == 'true', 'guest app must be frontmost'
    subprocess.run(['screencapture', '-x', '-o', str(OUT / (name + '.png'))], check=True)


def javascript(script):
    return call('browser.eval', panel_id=SOURCE, workspace_id=A, script=script)['value']


def coordinates(selector, page_zoom=1):
    # The fixture has exactly one area in A. Its web view ends at the
    # window's right/bottom inner border (verified in the source screenshot).
    # AX supplies the native window frame; DOM supplies only geometry, not input.
    rect = javascript(f'(() => {{ const r=document.querySelector({json.dumps(selector)}).getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2,innerWidth,innerHeight]; }})()')
    numbers = [float(x) for x in osa('get {position, size} of window 1').split(', ')]
    assert len(numbers) == 4, numbers
    x, y, width, height = numbers
    assert 100 < rect[2] < width and 100 < rect[3] < height, (numbers, rect)
    viewport_x = x + width - rect[2] * page_zoom - 1
    viewport_y = y + height - rect[3] * page_zoom - 1
    return round(viewport_x+rect[0]*page_zoom), round(viewport_y+rect[1]*page_zoom)


def post_mouse(x, y, middle=False):
    class Point(ctypes.Structure):
        _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
    cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
    cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    # Native HID events in this verified guest, not a WebKit/DOM click.
    for event_type in ((25, 26) if middle else (1, 2)):
        event = cg.CGEventCreateMouseEvent(None, event_type, Point(x, y), 2 if middle else 0)
        assert event
        cg.CGEventSetIntegerValueField(event, 1, 1)  # kCGMouseEventClickState
        posted_ms = time.time_ns() / 1_000_000
        cg.CGEventPost(0, event)
        cf.CFRelease(event)
    return posted_ms  # exact mouse-up post; avoids subprocess-start uncertainty


def ui_click(selector, modifier=None, middle=False, page_zoom=1):
    x, y = coordinates(selector, page_zoom=page_zoom)
    if middle:
        post_mouse(x, y, middle=True)
        return
    args = ['/opt/homebrew/bin/cliclick']
    if modifier:
        args.append('kd:' + modifier)
    try:
        subprocess.run(args + [f'c:{x},{y}'], check=True)
    finally:
        if modifier:
            subprocess.run(['/opt/homebrew/bin/cliclick', 'ku:' + modifier], check=True)



def back_to_a():
    # Real operator workspace shortcut, scoped to the guest app.
    # Raising B's flag sorts it ahead of A in the visible sidebar.
    key = '2' if FLAGGED_SIDEBAR else '1'
    osa(f'keystroke "{key}" using command down')
    wait_for(lambda: focus()['workspace_id'] == A, 'native Cmd+1 must select A')
    call('panel.focus', panel_id=SOURCE, workspace_id=A)
    time.sleep(.15)


def unchanged(action, label, pause=.35):
    before = focus()
    action()
    time.sleep(pause)
    after = focus()
    assert (before['workspace_id'], before['panel_id']) == (after['workspace_id'], after['panel_id']), (label, before, after)
    print('PASS', label, flush=True)


try:
    osa('set frontmost to true')
    wait_for(lambda: bool(focus()), 'guest window becomes key')
    initial = focus()
    A = initial['workspace_id']
    WINDOW = initial['window_id']
    call('workspace.rename', workspace_id=A, title='C11-515 A source')
    B = call('workspace.create', title='C11-515 B destination', window_id=WINDOW)['workspace_id']
    panels = call('panel.list', workspace_id=B)['panels']
    TERMINAL = next(p['id'] for p in panels if p['type'] == 'terminal')
    BROWSER = call('panel.create', workspace_id=B, type='browser')['panel_id']
    fixture_dir = Path('/tmp/c11-515-fixture')
    fixture_dir.mkdir(exist_ok=True)
    source_path = fixture_dir / 'source.html'
    source_path.write_text(f'''<!doctype html><html><head><title>C11-515 source</title><link rel="icon" href="data:,"></head>
<body style="margin:0;padding:28px;background:#101418;color:#f3f4f5;font:20px monospace">
<h1 style="margin-top:70px">C11-515 link proof</h1>
<p><a id="target" style="color:#ffb060" href="c11://panel/{TERMINAL}">OPEN B TERMINAL</a></p>
<p><a id="workspace" style="color:#ffb060" href="c11://workspace/{B}">OPEN B WORKSPACE</a></p>
<p id="blank" style="height:80px">Blank space for stale native input</p>
<p id="clock" style="position:fixed;bottom:10px;left:28px;font:30px monospace"></p>
<script>requestAnimationFrame(function tick() {{ document.querySelector('#clock').textContent=Date.now(); requestAnimationFrame(tick); }});</script>
</body></html>''')
    SOURCE = call('panel.create', workspace_id=A, type='browser', url=source_path.as_uri())['panel_id']
    for p in call('panel.list', workspace_id=A)['panels']:
        if p['id'] != SOURCE:
            call('panel.close', workspace_id=A, panel_id=p['id'])
    call('panel.focus', workspace_id=A, panel_id=SOURCE)
    wait_for(lambda: javascript('document.readyState') == 'complete', 'source page load')
    time.sleep(.25)
    (OUT / 'identity.json').write_text(json.dumps(dict(socket=SOCKET, pid=PID, A=A, B=B, terminal=TERMINAL, browser=BROWSER, source=SOURCE, window=WINDOW), indent=2))
    shot('01-source')
    ui_click('#target')
    wait_for(lambda: focus()['workspace_id'] == B and focus()['panel_id'] == TERMINAL, 'native link must select B terminal')
    time.sleep(.25)
    assert focus()['panel_id'] == TERMINAL, 'target focus must survive queued browser requests'
    shot('02-terminal-landing')
    print('PASS 1 native click selects B terminal', flush=True)
    back_to_a()
    call('panel.focus', workspace_id=B, panel_id=BROWSER)
    ui_click('#workspace')
    wait_for(lambda: focus()['workspace_id'] == B and focus()['panel_id'] == BROWSER, 'workspace link must preserve B focused browser')
    shot('03-workspace-landing')
    print('PASS 3 workspace link preserves focused panel', flush=True)
    back_to_a()
    for href in ['c11://panel/', 'c11://panel/not-a-uuid', 'c11://panel/panel:10',
                 f'c11://panel/{TERMINAL}/extra', f'c11://panel/{uuid.uuid4()}']:
        javascript('document.querySelector("#target").href=' + json.dumps(href))
        unchanged(lambda: ui_click('#target'), '5 invalid/stale ' + href)
    shot('04-invalid-notice')
    javascript('document.querySelector("#target").href=' + json.dumps(f'c11://panel/{TERMINAL}'))
    for script in [
        'location.href=' + json.dumps(f'c11://panel/{TERMINAL}'),
        'setTimeout(()=>document.querySelector("#target").click(),20)',
        'window.open(' + json.dumps(f'c11://panel/{TERMINAL}') + ')',
        '(()=>{const m=document.createElement("meta");m.httpEquiv="refresh";m.content="0;url=c11://panel/' + TERMINAL + '";document.head.append(m)})()',
        '(()=>{const f=document.createElement("form");f.action="c11://panel/' + TERMINAL + '";document.body.append(f);f.submit()})()'
    ]:
        unchanged(lambda s=script: javascript(s), '6 script navigation refused', pause=.6)
    unchanged(lambda: (ui_click('#blank'), call('browser.click', workspace_id=A, panel_id=SOURCE, selector='#target')), '7 stale native click cannot authorize browser.click')
    assert javascript('typeof window.webkit?.messageHandlers?.c11PanelLink') == 'undefined'
    print('PASS private handler inaccessible from page world', flush=True)
    denied = raw('browser.navigate', workspace_id=A, panel_id=SOURCE, url=f'c11://panel/{TERMINAL}')
    assert not denied['ok'] and denied['error']['code'] == 'operator_activation_required', denied
    assert call('browser.url.get', workspace_id=A, panel_id=SOURCE)['url'] == source_path.as_uri()
    print('PASS 11 direct navigation refused and source URL preserved', flush=True)
    panel_count = len(call('panel.list', workspace_id=A)['panels'])
    with socket.socket(socket.AF_UNIX) as legacy:
        legacy.settimeout(12)
        legacy.connect(SOCKET)
        legacy.sendall(f'open_browser c11://panel/{TERMINAL}\n'.encode())
        response = legacy.makefile('rb').readline().decode()
    assert 'operator_activation_required' in response, response
    assert len(call('panel.list', workspace_id=A)['panels']) == panel_count
    print('PASS repair 5 legacy open_browser refuses before creating a panel', flush=True)
    before = focus()
    denied = raw('workspace.select', workspace_id=B)
    assert not denied['ok'] and denied['error']['code'] == 'workspace_switch_blocked', denied
    assert focus()['workspace_id'] == before['workspace_id']
    print('PASS 13 socket workspace switch still blocked', flush=True)
    print(f'PASS CORE elapsed={time.monotonic()-START:.1f}s artifacts={OUT}', flush=True)

    # Timestamped, self-terminating native screen recording; no audio capture.
    # Display 1 is the sandbox's sole 1440x900 display, verified by source PNG.
    clicks = []
    (OUT / '14-latency.mov').unlink(missing_ok=True)
    recording_start_wall = time.time()
    recording_start = time.monotonic()
    recorder = subprocess.Popen(['screencapture', '-x', '-v', '-V18', '-D1', '-k', str(OUT / '14-latency.mov')],
                                stdout=subprocess.DEVNULL, stderr=(OUT / '14-recorder.log').open('w'))
    try:
        for index in range(5):
            # Recreate the measured focus-steal precondition for every jump.
            call('panel.focus', workspace_id=B, panel_id=BROWSER)
            deadline = recording_start + 2 + index * 3
            time.sleep(max(0, deadline - time.monotonic()))
            assert focus()['workspace_id'] == A and focus()['panel_id'] == SOURCE
            point = coordinates('#target')
            before = time.monotonic()
            wall_before = time.time()
            mouse_up_ms = post_mouse(*point)
            after = time.monotonic()
            wall_after = time.time()
            wait_for(lambda: focus()['workspace_id'] == B and focus()['panel_id'] == TERMINAL, '14 native click lands')
            clicks.append(dict(index=index+1, command_start=before-recording_start,
                               command_end=after-recording_start, wall_start_ms=wall_before*1000,
                               wall_end_ms=wall_after*1000, mouse_up_ms=mouse_up_ms, point=point))
            time.sleep(.8)
            assert focus()['workspace_id'] == B and focus()['panel_id'] == TERMINAL, '14 target focus remains stable'
            back_to_a()
        recorder.wait(timeout=7)
        assert recorder.returncode == 0
    finally:
        if recorder.poll() is None:
            recorder.terminate()
            recorder.wait(timeout=3)
        (OUT / '14-click-times.json').write_text(json.dumps(dict(clock='monotonic seconds since recorder launch',
            recorder_wall_ms=recording_start_wall*1000, clicks=clicks), indent=2))
    print('RECORDED 14 five clicks three seconds apart; frame analysis required', flush=True)

    for href in (f'c11://panel/{SOURCE}', f'c11://workspace/{A}'):
        javascript('document.querySelector("#target").href=' + json.dumps(href))
        for index in range(3):
            unchanged(lambda: ui_click('#target'), f'4/16 current target activation {index+1}', pause=.2)
            shot(f'16-current-{href.split("/")[2]}-{index+1}')
    shot('04-current-target-flash')
    javascript('document.querySelector("#target").href=' + json.dumps(f'c11://panel/{TERMINAL}'))
    normal_width = javascript('innerWidth')
    for _ in range(5):
        osa('keystroke "=" using command down')
    wait_for(lambda: 1.49 < normal_width / javascript('innerWidth') < 1.51, 'native page zoom reaches 1.5')
    (OUT / 'repair-zoom-150.json').write_text(json.dumps(dict(normal_width=normal_width,
        zoomed_width=javascript('innerWidth'), native_zoom_in_steps=5, page_zoom=1.5), indent=2))
    shot('repair-zoom-150-source')
    ui_click('#target', page_zoom=1.5)
    wait_for(lambda: focus()['workspace_id'] == B and focus()['panel_id'] == TERMINAL, '150 percent page link lands')
    back_to_a()
    osa('keystroke "0" using command down')
    wait_for(lambda: abs(javascript('innerWidth') - normal_width) <= 1, 'native zoom reset')
    print('PASS addendum C native link at pageZoom 1.5', flush=True)
    closed = call('panel.create', workspace_id=B, type='browser')['panel_id']
    call('panel.close', workspace_id=B, panel_id=closed)
    javascript('document.querySelector("#target").href=' + json.dumps(f'c11://panel/{closed}'))
    unchanged(lambda: ui_click('#target'), '5 closed UUID refused')
    for href in (f'c11://panel/{TERMINAL.lower()}', f'c11://panel/{TERMINAL.upper()}', f' \tc11://panel/{TERMINAL}\n '):
        javascript('document.querySelector("#target").href=' + json.dumps(href))
        ui_click('#target')
        wait_for(lambda: focus()['workspace_id'] == B and focus()['panel_id'] == TERMINAL, '5 UUID case accepted')
        back_to_a()
    print('PASS 5 uppercase, lowercase, and surrounding-whitespace native links', flush=True)
    javascript('window.addEventListener("mouseup",()=>document.querySelector("#target").click(),{once:true})')
    ui_click('#target')
    wait_for(lambda: focus()['workspace_id'] == B and focus()['panel_id'] == TERMINAL,
             'synthetic mouseup click must not consume the real click intent')
    back_to_a()
    print('PASS repair 3 synthetic click during native mouseup preserves real activation', flush=True)
    javascript('window.addEventListener("mouseup",()=>{const until=performance.now()+1200;while(performance.now()<until){}},{once:true})')
    unchanged(lambda: ui_click('#target'), 'repair 2 expired native input leaves focus unchanged', pause=1.5)
    assert any(json.loads(line.split('panel_link ', 1)[1]).get('result') == 'input_expired'
               for line in LOG.read_text().splitlines() if 'panel_link ' in line)
    shot('repair-expired-activation-notice')
    javascript('document.querySelector("#target").focus()')
    osa('key code 36')
    wait_for(lambda: focus()['workspace_id'] == B and focus()['panel_id'] == TERMINAL, 'native Return must select B terminal')
    print('PASS native Return activation', flush=True)
    # Inspect only the named native menu item. A fixed offset plus cliclick
    # did not prove Back was dispatched; this path uses observed bounds and
    # a complete native HID pair, with history snapshots on both sides.
    history_before = call('history.list', limit=200)
    hx, hy, hw, hh = [float(x) for x in osa('get {position, size} of menu bar item "History" of menu bar 1').split(', ')]
    post_mouse(round(hx+hw/2), round(hy+hh/2))
    time.sleep(.15)
    bx, by, bw, bh = [float(x) for x in osa('''set backItem to menu item "Back" of menu 1 of menu bar item "History" of menu bar 1
if not enabled of backItem then error "History Back is disabled"
get {position, size} of backItem''').split(', ')]
    assert bw > 0 and bh > 0
    shot('focus-history-menu')
    post_mouse(round(bx+bw/2), round(by+bh/2))
    try:
        wait_for(lambda: focus()['workspace_id'] == A and focus()['panel_id'] == SOURCE,
                 'native History Back must return to exact browser source')
    finally:
        actual = focus()
        history_returned = actual['workspace_id'] == A and actual['panel_id'] == SOURCE
        (OUT / 'focus-history.json').write_text(json.dumps(dict(returned_to_source=history_returned,
            actual=actual, before=history_before, after=call('history.list', limit=200),
            back_item_bounds=[bx, by, bw, bh], transport='native_hid_click_count_1'), indent=2))
    assert history_returned
    print('PASS native History Back returns to exact source', flush=True)
    back_to_a()

    repeat_target = call('panel.split', workspace_id=A, panel_id=SOURCE, direction='left', force=True)['panel_id']
    time.sleep(.4)
    javascript('document.querySelector("#target").href=' + json.dumps(f'c11://panel/{repeat_target}'))
    for index in range(3):
        previous_flashes = call('debug.flash.count', panel_id=repeat_target)['count']
        ui_click('#target')
        wait_for(lambda: focus()['workspace_id'] == A and focus()['panel_id'] == repeat_target, '15 repeated same-workspace target')
        time.sleep(.2)
        assert focus()['panel_id'] == repeat_target
        assert call('debug.flash.count', panel_id=repeat_target)['count'] > previous_flashes
        shot(f'15-repeated-target-{index+1}')
    call('panel.close', workspace_id=A, panel_id=repeat_target)
    call('panel.focus', workspace_id=A, panel_id=SOURCE)
    time.sleep(.3)
    javascript('document.querySelector("#target").href=' + json.dumps(f'c11://panel/{TERMINAL}'))
    print('PASS 15 repeated same-workspace link lands each time; screenshots record each pulse', flush=True)

    def navigate(url, script_attempt=False, **extra):
        call('browser.navigate', workspace_id=A, panel_id=SOURCE, url=url, **extra)
        if script_attempt:
            # A deliberately cancelled load-time navigation may delay WebKit's
            # load completion; the marker proves the attempted script ran.
            wait_for(lambda: javascript('document.title') == 'script-attempted', 'fixture script ran', timeout=20)
        else:
            wait_for(lambda: javascript('document.readyState') == 'complete', 'fixture load', timeout=20)
        time.sleep(.25)

    # Actual document load and timer navigations, plus native subframe input.
    for suffix, script in [('onload', 'document.title="script-attempted";location.href=target'),
                           ('timer', 'setTimeout(()=>{document.title="script-attempted";location.href=target},20)')]:
        path = fixture_dir / (suffix + '.html')
        path.write_text('<body>Script navigation must not move focus<script>const target=' +
                        json.dumps(f'c11://panel/{TERMINAL}') + ';' + script + '</script>')
        unchanged(lambda p=path: navigate(p.as_uri(), script_attempt=True), '6 ' + suffix + ' location refused', pause=.6)
    navigate(source_path.as_uri())
    javascript('''(()=>{const f=document.createElement('iframe');f.id='child';
        f.style='width:400px;height:100px';f.srcdoc='<a style="display:block;height:90px" href="c11://panel/''' + TERMINAL + '''">FRAME LINK</a>';
        document.querySelector('#blank').replaceWith(f)})()''')
    time.sleep(.3)
    unchanged(lambda: ui_click('#child'), '6 real subframe click refused')
    navigate(source_path.as_uri())

    panel_count = len(call('panel.list', workspace_id=A)['panels'])
    unchanged(lambda: ui_click('#target', modifier='cmd'), '9 Cmd-click refused')
    unchanged(lambda: ui_click('#target', middle=True), '9 middle-click refused')
    javascript('document.querySelector("#target").target="_blank"')
    unchanged(lambda: ui_click('#target'), '9 target blank refused')
    assert len(call('panel.list', workspace_id=A)['panels']) == panel_count
    javascript('document.querySelector("#target").removeAttribute("target")')

    def context_open_link():
        x, y = coordinates('#target')
        subprocess.run(['/opt/homebrew/bin/cliclick', f'rc:{x},{y}', 'w:200'], check=True)
        # Native keyboard chooses the first, screenshot-verified Open Link item.
        subprocess.run(['screencapture', '-x', '-o', str(OUT / 'repair-context-menu.png')], check=True)
        subprocess.run(['/opt/homebrew/bin/cliclick', 'kp:arrow-down', 'kp:enter'], check=True)
    unchanged(context_open_link, 'addendum A context-menu link refused', pause=.5)
    assert any(json.loads(line.split('panel_link ', 1)[1]).get('result') == 'context_menu_refused'
               for line in LOG.read_text().splitlines() if 'panel_link ' in line)
    shot('repair-context-menu-notice')
    ordinary = fixture_dir / 'context.html'
    ordinary.write_text('<title>ordinary-context-link</title><body>Ordinary Open Link still works</body>')
    javascript('document.querySelector("#target").href=' + json.dumps(ordinary.as_uri()))
    before_panels = {p['id'] for p in call('panel.list', workspace_id=A)['panels']}
    context_open_link()
    # Preserve WebKit's existing routing, which may open the ordinary link in
    # a new browser panel. Verify the destination document, not a fixed panel.
    wait_for(lambda: any(p['title'] == 'ordinary-context-link' for p in call('panel.list', workspace_id=A)['panels']),
             'ordinary context Open Link preserved', timeout=20)
    opened = next(p['id'] for p in call('panel.list', workspace_id=A)['panels'] if p['title'] == 'ordinary-context-link')
    assert call('browser.url.get', workspace_id=A, panel_id=opened)['url'] == ordinary.as_uri()
    assert call('browser.eval', workspace_id=A, panel_id=opened, script='document.title')['value'] == 'ordinary-context-link'
    if opened != SOURCE:
        assert opened not in before_panels
        call('panel.close', workspace_id=A, panel_id=opened)
    call('panel.focus', workspace_id=A, panel_id=SOURCE)
    navigate(source_path.as_uri())
    print('PASS addendum A ordinary context-menu Open Link preserved', flush=True)

    slow_started = threading.Event()
    slow_release = threading.Event()
    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            if self.path != '/slow.gif':
                return super().do_GET()
            self.send_response(200)
            self.send_header('Content-Type', 'image/gif')
            self.send_header('Content-Length', '1')
            self.end_headers()
            slow_started.set()
            slow_release.wait(timeout=20)
            try:
                self.wfile.write(b'x')
            except OSError:
                pass
    # Port 0 chooses an unused guest port atomically; serves only fixture files.
    server = http.server.ThreadingHTTPServer(('0.0.0.0', 0), functools.partial(Handler, directory=str(fixture_dir)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        ip = subprocess.check_output(['/usr/sbin/ipconfig', 'getifaddr', 'en0'], text=True).strip()
        navigate(f'http://{ip}:{server.server_port}/source.html', allow_insecure_http=True)
        unchanged(lambda: ui_click('#target'), '8 real LAN origin refused')
        shot('08-LAN-origin-notice')
        navigate(f'http://127.0.0.1:{server.server_port}/source.html', allow_insecure_http=True)
        ui_click('#target')
        wait_for(lambda: focus()['workspace_id'] == B, 'loopback origin allowed')
        print('PASS loopback HTTP native link', flush=True)
        back_to_a()
        (fixture_dir / 'loading.html').write_text(source_path.read_text() + '<img id="slow" src="/slow.gif">')
        call('browser.navigate', workspace_id=A, panel_id=SOURCE,
             url=f'http://127.0.0.1:{server.server_port}/loading.html', allow_insecure_http=True)
        assert slow_started.wait(timeout=8), 'slow resource requested'
        wait_for(lambda: javascript('document.readyState') == 'interactive', 'committed page still loading')
        assert javascript('document.querySelector("#slow").complete') is False
        ui_click('#target')
        wait_for(lambda: focus()['workspace_id'] == B and focus()['panel_id'] == TERMINAL,
                 'committed loading page must allow native activation')
        slow_release.set()
        back_to_a()
        print('PASS repair 1 native link while committed page resource is still loading', flush=True)
        navigate(source_path.as_uri())
    finally:
        slow_release.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)

    # Compare ordinary native sidebar shortcut and link visits on identical data.
    call('panel.focus', workspace_id=B, panel_id=TERMINAL)
    call('flag.raise', workspace_id=B, panel_id=TERMINAL, caller_panel_id=SOURCE, reason='C11-515 parity fixture')
    FLAGGED_SIDEBAR = True
    parity = {}
    for mode in ('sidebar', 'link'):
        for panel in (TERMINAL, BROWSER):
            call('notification.create_for_target', workspace_id=B, panel_id=panel,
                 title='C11-515 ' + mode, body='attention parity')
        if mode == 'sidebar':
            # Screenshot-verified B title in the first sidebar row after flag sort.
            wx, wy, _, _ = [float(x) for x in osa('get {position, size} of window 1').split(', ')]
            subprocess.run(['/opt/homebrew/bin/cliclick', f'c:{round(wx+90)},{round(wy+100)}'], check=True)
        else:
            ui_click('#target')
        wait_for(lambda: focus()['workspace_id'] == B, '10 visit B')
        time.sleep(.5)
        parity[mode] = {n['panel_id']: n['is_read'] for n in call('notification.list')['notifications']
                        if n['title'] == 'C11-515 ' + mode}
        assert len(parity[mode]) == 2, parity
        assert any(f['panel_id'] == TERMINAL for f in call('flag.list')['flags'])
        back_to_a()
    assert parity['sidebar'] == parity['link'], parity
    (OUT / '10-attention-parity.json').write_text(json.dumps(parity, indent=2))
    print('PASS 10 flags retained and unread parity ' + json.dumps(parity), flush=True)

    original_window_name = osa('get name of window 1')
    second_window = call('window.create')['window_id']
    try:
        second_workspace = call('workspace.list', window_id=second_window)['workspaces'][0]['id']
        second_panel = call('panel.list', workspace_id=second_workspace)['panels'][0]['id']
        if focus()['window_id'] != WINDOW:
            osa('perform action "AXRaise" of (first window whose name is ' + json.dumps(original_window_name) + ')')
        wait_for(lambda: focus()['window_id'] == WINDOW, 'native window raise returns to source')
        assert focus()['window_id'] == WINDOW, focus()
        javascript('document.querySelector("#target").href=' + json.dumps(f'c11://panel/{second_panel}'))
        ui_click('#target')
        wait_for(lambda: focus()['window_id'] == second_window and focus()['panel_id'] == second_panel, '2 second window comes forward')
        time.sleep(.25)
        shot('02-second-window-landing')
        print('PASS 2 second window selected and focused', flush=True)
    finally:
        call('window.close', window_id=second_window)
    back_to_a()
    javascript('document.querySelector("#target").href=' + json.dumps(f'c11://panel/{TERMINAL}'))

    markdown_path = fixture_dir / 'panel-links.md'
    markdown_path.write_text('# C11-515 Markdown proof\n\n[OPEN B TERMINAL](c11://panel/' + TERMINAL + ')\n')
    MARKDOWN = call('markdown.open', workspace_id=A, path=str(markdown_path))['panel_id']
    call('panel.focus', workspace_id=A, panel_id=MARKDOWN)
    wait_for(lambda: call('markdown.visible', workspace_id=A, panel_id=MARKDOWN)['file'] == str(markdown_path), '12 markdown renderer ready')
    time.sleep(.5)
    shot('12-markdown-source')
    (OUT / '12-markdown-identity.json').write_text(json.dumps(dict(panel=MARKDOWN, target=TERMINAL, workspace=A, destination=B), indent=2))
    # Screenshot-verified geometry of this short document in the standard
    # 1120px fixture window. Refuse a different layout instead of guessing.
    mx, my, mw, mh = [float(x) for x in osa('get {position, size} of window 1').split(', ')]
    assert abs(mw-1120) < 2 and 780 <= mh <= 800, (mw, mh)
    point = f'{round(mx+435)},{round(my+196)}'
    unchanged(lambda: subprocess.run(['/opt/homebrew/bin/cliclick', 'm:' + point], check=True),
              '12 Markdown hover/peek cannot navigate', pause=.8)
    shot('12-markdown-hover')
    # Native Option-Tab visits the heading copy button, then the only link.
    subprocess.run(['/opt/homebrew/bin/cliclick', f'c:{round(mx+540)},{round(my+249)}',
                    'kd:alt', 'kp:tab', 'kp:tab', 'ku:alt'], check=True)
    shot('12-markdown-keyboard-focus')
    osa('key code 36')
    wait_for(lambda: focus()['workspace_id'] == B and focus()['panel_id'] == TERMINAL, '12 Markdown Return lands')
    last_decision = json.loads([line.split('panel_link ', 1)[1] for line in LOG.read_text().splitlines() if 'panel_link ' in line][-1])
    assert last_decision['origin'].startswith('c11md://') and last_decision['activation'] == 'native_keyboard', last_decision
    print('PASS 12 Markdown native Return uses the same router', flush=True)
    back_to_a()
    call('panel.focus', workspace_id=A, panel_id=MARKDOWN)
    time.sleep(.3)
    subprocess.run(['/opt/homebrew/bin/cliclick', 'c:' + point], check=True)
    wait_for(lambda: focus()['workspace_id'] == B and focus()['panel_id'] == TERMINAL, '12 Markdown native link lands')
    time.sleep(.25)
    assert focus()['panel_id'] == TERMINAL
    last_decision = json.loads([line.split('panel_link ', 1)[1] for line in LOG.read_text().splitlines() if 'panel_link ' in line][-1])
    assert last_decision['origin'].startswith('c11md://') and last_decision['result'] == 'opened', last_decision
    shot('12-markdown-landing')
    print('PASS 12 Markdown native click uses the same router and visibly flashes target', flush=True)
    back_to_a()
    call('panel.close', workspace_id=A, panel_id=MARKDOWN)

    call('debug.session.save_and_load')
    plists = list(Path(APP_ROOT).glob('*.app/Contents/Info.plist'))
    assert len(plists) == 1
    with plists[0].open('rb') as bundle_file:
        bundle_id = plistlib.load(bundle_file)['CFBundleIdentifier']
    snapshot_path = Path.home() / 'Library/Application Support/c11' / ('session-' + bundle_id + '.json')
    snapshot = json.loads(snapshot_path.read_text())
    def check_saved(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if isinstance(child, str) and ('url' in key.lower() or 'history' in key.lower()):
                    assert not child.lower().startswith('c11:'), (key, child)
                check_saved(child)
        elif isinstance(value, list):
            for child in value:
                assert not isinstance(child, str) or not child.lower().startswith('c11:'), child
                check_saved(child)
    check_saved(snapshot)
    (OUT / '11-session.json').write_text(json.dumps(snapshot, indent=2))
    print('PASS 11 serialized session has no c11 page URL/history', flush=True)
    restored = call('debug.session.round_trip', workspace_id=A)
    assert restored['before'] == restored['after'], restored
    wait_for(lambda: call('browser.url.get', workspace_id=A, panel_id=SOURCE)['url'] == source_path.as_uri(), '11 restores source page')
    for method in ('browser.back', 'browser.forward'):
        call(method, workspace_id=A, panel_id=SOURCE)
        time.sleep(.4)
        assert not call('browser.url.get', workspace_id=A, panel_id=SOURCE)['url'].lower().startswith('c11:')
        assert focus()['workspace_id'] == A
    print('PASS 11 actual workspace restore and back/forward keep ordinary page URLs', flush=True)
    print(f'PASS EXTENDED elapsed={time.monotonic()-START:.1f}s artifacts={OUT}', flush=True)
finally:
    if LOG.exists():
        (OUT / 'panel-link-decisions.log').write_text('\n'.join(line for line in LOG.read_text().splitlines() if 'panel_link ' in line)+'\n')
    try:
        (OUT / 'final-tree.json').write_text(json.dumps(call('system.tree', scope='all'), indent=2))
    finally:
        SOCK.close()
