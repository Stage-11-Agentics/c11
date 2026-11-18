#!/usr/bin/env python3
"""C11H-325 captured-mouse terminal-link acceptance, ONLY via sandbox-tests-v2.sh.

A fixture program holds the mouse the way Claude Code's fullscreen view does
(alt screen 1049, mouse modes 1000/1002/1003, SGR 1006) and logs every mouse
press and release it receives. Native guest input then proves:

- a click on plain text and on an https OSC 8 link reaches the program;
- a plain click and a Cmd-click on a c11 OSC 8 link navigate, are logged as
  captured_click, and never reach the program;
- Cmd-hover shows the true-destination preview while the program holds the mouse;
- a drag that starts on a c11 link reaches the program as a press at its origin;
- a closed c11 target shows the notice and stays with c11.

It reuses the C11-525 proof's socket, geometry, HID-input and cleanup helpers.
No builds, agent sessions, external pages or tenant config writes.
"""
import json
from pathlib import Path
import shlex
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_terminal_panel_links_native as native  # noqa: E402

native.OUT = Path('/Volumes/My Shared Files/out/terminal-panel-link-captured-proof')
native.ACTIVE_SECONDS, native.HARD_SECONDS = 300, 350
COLUMN = native.COLUMN
ROWS = dict(plain=7, https=9, link=11, stale=13)
MOUSE_ON = '\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h'
MOUSE_OFF = '\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l'

PROGRAM = r'''import json, os, re, select, signal, sys, termios, tty
from pathlib import Path
root = Path(sys.argv[1])
old = termios.tcgetattr(0)
def stop(*args): raise SystemExit()
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGALRM, stop)
signal.alarm(320)
sgr = re.compile(rb'\x1b\[<(\d+);(\d+);(\d+)([Mm])')
try:
    tty.setraw(0)
    size = os.get_terminal_size(1)
    os.write(1, (root / 'payload.bin').read_bytes())
    (root / 'geometry.json').write_text(json.dumps(dict(columns=size.columns, rows=size.lines, pid=os.getpid())))
    pending = b''
    with open(root / 'reports.jsonl', 'a', buffering=1) as log:
        while not (root / 'stop').exists():
            if not select.select([0], [], [], .1)[0]:
                continue
            pending += os.read(0, 4096)
            end = 0
            for m in sgr.finditer(pending):
                end = m.end()
                button = int(m.group(1))
                if button & 32:
                    continue  # motion: hover and drag positions, not presses
                log.write(json.dumps(dict(button=button, col=int(m.group(2)), row=int(m.group(3)),
                                          kind='press' if m.group(4) == b'M' else 'release')) + '\n')
            pending = pending[end:][-256:]
finally:
    os.write(1, (MOUSE_OFF + '\x1b[0m\x1b[?25h\x1b[?1049l').encode())
    termios.tcsetattr(0, termios.TCSANOW, old)
'''.replace('MOUSE_OFF', repr(MOUSE_OFF))


class CapturedProof(native.Proof):
    def seed(self):
        self.report['limitations'] = [
            'A fixture program sets the mouse modes Claude Code fullscreen sets; it is not a live Claude session.',
            'The program-side oracle is the SGR press/release reports the fixture received.']
        capabilities = self.call('system.capabilities')
        features = {entry['id']: entry['version'] for entry in capabilities['features']}
        assert features.get('links.terminal') == 1, features
        self.ui('activate')
        self.wait(lambda: self.ui('foreground') == self.pid, 'guest PID foreground')
        display = self.ui('displays')
        assert len(display['displays']) == len(display['windows']) == 1, display
        self.window_number = display['windows'][0]['kCGWindowNumber']
        windows = self.call('window.list')['windows']
        assert len(windows) == 1 and windows[0]['key'], windows
        self.window = windows[0]['id']
        self.source_workspace = self.focused()['workspace_id']
        assert len(self.call('workspace.list', window_id=self.window)['workspaces']) == 1, 'fresh QA guest required'
        self.call('workspace.rename', workspace_id=self.source_workspace, title=native.SOURCE_TITLE + ' Workspace')
        self.source = self.focused()['panel_id']
        for panel in self.call('panel.list', workspace_id=self.source_workspace)['panels']:
            if panel['id'] != self.source:
                self.call('panel.close', workspace_id=self.source_workspace, panel_id=panel['id'])
        self.call('panel.action', workspace_id=self.source_workspace, panel_id=self.source,
                  action='rename', title=native.SOURCE_TITLE)
        self.destination = self.call('workspace.create', window_id=self.window,
                                     title=native.DESTINATION_TITLE)['workspace_id']
        panels = self.call('panel.list', workspace_id=self.destination)['panels']
        self.target = next(p['id'] for p in panels if p['type'] == 'terminal')
        for panel in panels:
            if panel['id'] != self.target:
                self.call('panel.close', workspace_id=self.destination, panel_id=panel['id'])
        self.call('panel.action', workspace_id=self.destination, panel_id=self.target,
                  action='rename', title=native.TARGET_TITLE)
        self.target_url = 'c11://panel/' + self.target.lower()
        self.urls = dict(plain=None, https='https://example.com/c11h-325',
                         link=self.target_url, stale='c11://panel/' + str(uuid.uuid4()))
        self.labels = dict(plain='Plain text, no link here', https='Example dot com',
                           link=native.TARGET_TITLE, stale='Closed destination')
        output = '\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l'
        for row, col, color in [(2, 2, '255;0;255'), (2, 12, '0;255;255'), (4, 2, '255;255;0')]:
            output += f'\x1b[{row};{col}H\x1b[48;2;{color}m \x1b[0m'
        output += '\x1b[5;4HC11H-325 program holds the mouse'
        for kind, row in ROWS.items():
            label, url = self.labels[kind], self.urls[kind]
            # Claude Code's measured OSC 8 form (BEL-terminated, id parameter).
            form = f'\x1b]8;id=c{row};{url}\x07{label}\x1b]8;;\x07' if url else label
            output += f'\x1b[{row};{COLUMN}H' + form
        output += MOUSE_ON
        payload = self.fixture / 'payload.bin'
        payload.write_bytes(output.encode())
        (native.OUT / 'fixture-output.bin').write_bytes(payload.read_bytes())
        program = self.fixture / 'emit.py'  # base cleanup verifies this name
        program.write_text(PROGRAM)
        for name in ('stop', 'reports.jsonl', 'geometry.json'):
            (self.fixture / name).unlink(missing_ok=True)
        command = '/usr/bin/python3 ' + shlex.quote(str(program)) + ' ' + shlex.quote(str(self.fixture)) + '\n'
        self.call('panel.send_text', workspace_id=self.source_workspace, panel_id=self.source, text=command)
        self.wait(lambda: (self.fixture / 'geometry.json').exists()
                  and self.labels['stale'] in self.terminal_text(), 'fixture printed and holds the mouse')
        self.report['identity'].update(source_workspace=self.source_workspace, source=self.source,
            destination=self.destination, target=self.target, window=self.window,
            cg_window=self.window_number, display=display['displays'][0])
        self.calibrate()
        self.screenshot('01-source')

    def point(self, kind, offset=2):
        assert self.selection() == (self.source_workspace.lower(), self.source.lower())
        assert self.labels[kind] in self.terminal_text(), ('fixture text changed', kind)
        grid = self.grid
        column = COLUMN + offset
        x = self.terminal_frame['position'][0] + (grid['x'] + (column - .5) * grid['width']) / grid['scale']
        y = self.terminal_frame['position'][1] + (grid['y'] + (ROWS[kind] - .5) * grid['height']) / grid['scale']
        frame = self.terminal_frame
        assert all(lo < v < lo + size for v, lo, size in zip((x, y), frame['position'], frame['size']))
        return round(x), round(y)

    def reports(self):
        path = self.fixture / 'reports.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def program_got_click(self, kind, before, offset=2):
        cell = dict(col=COLUMN + offset, row=ROWS[kind])
        def got():
            new = self.reports()[before:]
            presses = [r for r in new if r['kind'] == 'press' and r['button'] == 0
                       and (r['col'], r['row']) == (cell['col'], cell['row'])]
            return new if presses and any(r['kind'] == 'release' for r in new) else None
        return self.wait(got, kind + ' click reached the program')

    def program_saw_nothing_on(self, kind, before):
        presses = [r for r in self.reports()[before:] if r['kind'] == 'press' and r['row'] == ROWS[kind]]
        assert not presses, (kind, presses)

    def plain_click(self, kind):
        x, y = self.point(kind)
        self.native_mouse(x, y, (5,))
        self.native_click(x, y)

    def to_program(self, kind):
        before, decisions, selection = len(self.reports()), len(self.decisions()), self.selection()
        self.plain_click(kind)
        new = self.program_got_click(kind, before)
        time.sleep(.3)
        assert self.selection() == selection and len(self.decisions()) == decisions
        self.passed(kind + ' click reaches the program; no navigation, no link decision', reports=new)

    def navigates(self, kind, command):
        before, decisions = len(self.reports()), len(self.decisions())
        if command:
            self.click_link(kind, command=True)  # waits for the Cmd-hover preview first
        else:
            self.plain_click(kind)
        self.wait(lambda: self.selection() == (self.destination.lower(), self.target.lower()), kind + ' landed')
        self.wait(lambda: len(self.decisions()) > decisions, kind + ' structured decision')
        new = self.decisions()[decisions:]
        assert len(new) == 1 and new[0]['activation'] == 'captured_click' and new[0]['result'] == 'opened' \
            and new[0]['target'] == self.target_url, new
        self.program_saw_nothing_on(kind, before)
        name = 'cmd' if command else 'plain'
        self.screenshot(f'02-{name}-landing')
        self.passed(f'{name} click on a c11 link navigates and never reaches the program'
                    + ('; Cmd-hover preview shown' if command else ''), decision=new[0])
        self.back()

    def drag_from_link(self):
        before, decisions, selection = len(self.reports()), len(self.decisions()), self.selection()
        x0, y0 = self.point('link')
        x1, _ = self.point('link', offset=5)
        x2, _ = self.point('link', offset=8)
        self.native_mouse(x0, y0, (5, 1))
        self.native_mouse(x1, y0, (6,))
        self.native_mouse(x2, y0, (6, 2))
        new = self.program_got_click('link', before)
        releases = [r for r in new if r['kind'] == 'release']
        assert releases and releases[-1]['col'] == COLUMN + 8, new
        time.sleep(.3)
        assert self.selection() == selection and len(self.decisions()) == decisions
        self.passed('a drag from a c11 link reaches the program as a press at its origin', reports=new)

    def stale(self):
        before, decisions, selection = len(self.reports()), len(self.decisions()), self.selection()
        self.plain_click('stale')
        self.wait(lambda: len(self.decisions()) > decisions, 'stale decision')
        new = self.decisions()[decisions:]
        assert len(new) == 1 and new[0]['result'] == 'unavailable' and new[0]['activation'] == 'captured_click', new
        self.wait(lambda: self.ax(native.NOTICE_ID), 'stale notice')
        assert self.selection() == selection
        self.program_saw_nothing_on('stale', before)
        self.screenshot('04-stale-notice')
        self.passed('a closed c11 target shows the notice and never reaches the program', decision=new[0])

    def execute(self):
        self.seed()
        self.run(['/opt/homebrew/bin/cliclick', 'ku:cmd', 'ku:alt', 'ku:shift', 'ku:ctrl'])
        self.to_program('plain')
        self.to_program('https')
        self.navigates('link', command=False)
        self.navigates('link', command=True)
        self.drag_from_link()
        self.stale()
        self.screenshot('05-final')
        self.report['status'] = 'passed'


if __name__ == '__main__':
    proof = CapturedProof()
    try:
        proof.execute()
        print('PASS C11H-325 captured terminal links; evidence=' + str(native.OUT), flush=True)
    except BaseException as error:
        proof.report.update(status='failed', error=str(error))
        try:
            proof.screenshot('failure')
        except Exception as capture_error:
            proof.report['failure_screenshot_error'] = str(capture_error)
        raise
    finally:
        proof.cleanup()
