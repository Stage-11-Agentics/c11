#!/usr/bin/env python3
"""C11H-427 plain-click terminal-link acceptance, ONLY via sandbox-tests-v2.sh.

A plain zsh panel prints an OSC 8 link to c11h://panel/<uuid>, an https OSC 8
link and plain words, with mouse reporting off. Native guest HID input then
proves:

- a plain click on the c11h link navigates, logged as plain_click/opened;
- a Cmd-click on it still navigates through Ghostty (native_command_click);
- a plain click on the https link and on plain text never navigates and makes
  no link decision (https keeps Cmd-click);
- on the link and off it, a drag, a double-click and a triple-click select
  (read back with panel.read_selection) and never navigate;
- Shift-click extends a selection onto the link and never navigates;
- a c11 link in the live zsh prompt navigates and sends the shell no input;
- replayed clicks leave Ghostty's mouse state balanced;
- under a 1000 ms click-repeat-interval: a slow double click selects; a key
  or a click elsewhere cancels a waiting open; a key typed before the next
  click keeps the held click from ever reaching the shell; a long-held press
  is never replayed into a later Shift-click; a link clicked just after a
  click elsewhere navigates; a link in an unfocused panel navigates.

It reuses the C11-525 proof's socket, geometry, HID-input and cleanup helpers.
It tolerates a guest an earlier proof already used (it returns to its source
workspace with the operator's own Cmd+<n>), and closes the workspace it made.
No builds, agent sessions or external pages. In this disposable guest it adds
one marked click-repeat-interval line to ~/.config/ghostty/config and removes
only that line again at the end.
"""
import ctypes
import json
from pathlib import Path
import shlex
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_terminal_panel_links_native as native  # noqa: E402

native.OUT = Path('/Volumes/My Shared Files/out/terminal-panel-link-plain-proof')
native.ACTIVE_SECONDS, native.HARD_SECONDS = 300, 350
COLUMN = native.COLUMN
ROWS = dict(plain=7, https=9, link=11, edge=13, blank=18, prompt=21)
EDGE_LABEL, EDGE_TAIL = 'Edge link', 'Xtail'  # plain text right after the link, no gap
PROMPT_LABEL = 'C11H427DEST'

DIGIT_KEYS = {1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25}
LEFT_DOWN, LEFT_UP, MOVED, DRAGGED = 1, 2, 5, 6
SHIFT, COMMAND = 1 << 17, 1 << 20
# Longer than Ghostty's repeat interval, including the 1000 ms the proof
# configures: a plain-click navigation that was going to happen has by then.
QUIET = 2.0
SLOW_INTERVAL_MS = 1000


class PlainProof(native.Proof):
    def seed(self):
        self.set_proof_interval(None)  # an earlier run's line, if it was cut off
        self.report['limitations'] = [
            'Selection is read through panel.read_selection, Ghostty\'s own selection, not the pasteboard.',
            'HID events carry an explicit click state; macOS derives clickCount from it.']
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
        self.call('workspace.rename', workspace_id=self.source_workspace, title='C11H-427 Source Workspace')
        self.source = self.focused()['panel_id']
        for panel in self.call('panel.list', workspace_id=self.source_workspace)['panels']:
            if panel['id'] != self.source:
                self.call('panel.close', workspace_id=self.source_workspace, panel_id=panel['id'])
        self.call('panel.action', workspace_id=self.source_workspace, panel_id=self.source,
                  action='rename', title='C11H-427 Source')
        self.destination = self.call('workspace.create', window_id=self.window,
                                     title='C11H-427 Destination')['workspace_id']
        panels = self.call('panel.list', workspace_id=self.destination)['panels']
        self.target = next(p['id'] for p in panels if p['type'] == 'terminal')
        self.call('panel.action', workspace_id=self.destination, panel_id=self.target,
                  action='rename', title=native.TARGET_TITLE)
        self.target_url = 'c11h://panel/' + self.target.lower()  # c11-2.0:keep (the alias the ticket names)
        self.urls = dict(plain=None, https='https://example.com/c11h-427', link=self.target_url)
        self.labels = dict(plain='Plain words for selection', https='Example dot com',
                           link=native.TARGET_TITLE + ' panel link', prompt=PROMPT_LABEL)
        # The live prompt itself carries a c11 link, as a prompt that prints one would.
        prompt = f"PROMPT=$'%{{\\e]8;;{self.target_url}\\a%}}{PROMPT_LABEL}%{{\\e]8;;\\a%}} %# '"
        self.call('panel.send_text', workspace_id=self.source_workspace, panel_id=self.source, text=prompt, submit=True)
        self.wait(lambda: PROMPT_LABEL + ' %' in self.terminal_text(), 'prompt carries the link')
        output = ''
        for row, col, color in [(2, 2, '255;0;255'), (2, 12, '0;255;255'), (4, 2, '255;255;0')]:
            output += f'\x1b[{row};{col}H\x1b[48;2;{color}m \x1b[0m'
        output += '\x1b[5;4HC11H-427 plain zsh, mouse reporting off'
        for kind in ('plain', 'https', 'link'):
            label, url = self.labels[kind], self.urls[kind]
            form = f'\x1b]8;id=c{ROWS[kind]};{url}\x07{label}\x1b]8;;\x07' if url else label
            output += f'\x1b[{ROWS[kind]};{COLUMN}H' + form
        output += (f'\x1b[{ROWS["edge"]};{COLUMN}H\x1b]8;id=c{ROWS["edge"]};{self.target_url}\x07'
                   f'{EDGE_LABEL}\x1b]8;;\x07{EDGE_TAIL}')
        output += '\x1b[21;1H'  # the prompt returns below the fixture
        payload = self.fixture / 'payload.bin'
        payload.write_bytes(output.encode())
        (native.OUT / 'fixture-output.bin').write_bytes(output.encode())
        for name in ('geometry.json', 'size.txt'):
            (self.fixture / name).unlink(missing_ok=True)
        size = shlex.quote(str(self.fixture / 'size.txt'))
        command = (f'clear; printf %s "$(< {shlex.quote(str(payload))})"; '
                   f'echo "$(stty size) $$" > {size}')
        self.fixture_command = command
        self.call('panel.send_text', workspace_id=self.source_workspace, panel_id=self.source, text=command)
        self.wait(lambda: (self.fixture / 'size.txt').exists()
                  and self.labels['link'] in self.terminal_text(), 'zsh printed the fixture')
        rows, columns, shell = (self.fixture / 'size.txt').read_text().split()
        # The base cleanup reads this pid and stops only a process running emit.py; zsh never is.
        (self.fixture / 'geometry.json').write_text(json.dumps(dict(columns=int(columns), rows=int(rows), pid=int(shell))))
        self.report['identity'].update(source_workspace=self.source_workspace, source=self.source,
            destination=self.destination, target=self.target, window=self.window,
            cg_window=self.window_number, display=display['displays'][0])
        self.calibrate()
        self.screenshot('01-source')

    def point(self, kind, offset=2, focused=True):
        if focused:
            assert self.selection() == (self.source_workspace.lower(), self.source.lower())
        grid, frame = self.grid, self.terminal_frame
        column = offset if kind == 'prompt' else COLUMN + offset  # the prompt row starts at column 1
        x = frame['position'][0] + (grid['x'] + (column - .5) * grid['width']) / grid['scale']
        y = frame['position'][1] + (grid['y'] + (ROWS[kind] - .5) * grid['height']) / grid['scale']
        assert all(lo < v < lo + size for v, lo, size in zip((x, y), frame['position'], frame['size']))
        return round(x), round(y)

    def mouse(self, x, y, event_type, clicks=1, flags=0):
        """One HID mouse event with an explicit click state and modifier flags.
        Callers check the foreground once per gesture: the osascript check
        takes long enough to push a double click past Ghostty's interval."""
        class Point(ctypes.Structure):
            _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]
        cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
        cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
        cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
        cg.CGEventSetTimestamp.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        event = cg.CGEventCreateMouseEvent(None, event_type, Point(x, y), 0)
        assert event
        cg.CGEventSetFlags(event, flags)
        cg.CGEventSetIntegerValueField(event, 1, clicks)  # kCGMouseEventClickState
        cg.CGEventSetTimestamp(event, time.monotonic_ns())
        cg.CGEventPost(0, event)
        cf.CFRelease(event)
        time.sleep(.06)

    def click(self, kind, offset=2, count=1, flags=0):
        x, y = self.point(kind, offset)
        self.ensure_frontmost()
        self.mouse(x, y, MOVED, flags=flags)
        for clicks in range(1, count + 1):
            self.mouse(x, y, LEFT_DOWN, clicks, flags)
            self.mouse(x, y, LEFT_UP, clicks, flags)

    def drag(self, kind, start, end):
        x0, y = self.point(kind, start)
        x1, _ = self.point(kind, end)
        self.ensure_frontmost()
        self.mouse(x0, y, MOVED)
        self.mouse(x0, y, LEFT_DOWN)
        steps = 6
        for step in range(1, steps + 1):
            self.mouse(x0 + (x1 - x0) * step / steps, y, DRAGGED)
        self.mouse(x1, y, LEFT_UP)

    def read_selection(self):
        result = self.call('panel.read_selection', workspace_id=self.source_workspace, surface_id=self.source)
        return result['text'] if result.get('has_selection') else None

    # Out of Ghostty's repeat interval, so the next press starts a new click
    # sequence; it grows when the proof configures a slower interval.
    gap = .6

    def clear_selection(self):
        time.sleep(self.gap)
        self.click('blank', offset=30)
        self.wait(lambda: self.read_selection() in (None, ''), 'selection cleared')
        time.sleep(self.gap)

    def stays_put(self, label, decisions):
        time.sleep(QUIET)
        assert self.selection() == (self.source_workspace.lower(), self.source.lower()), (label, 'navigated')
        # A double or triple click on a link cancels the held click's open
        # (logged as cancelled); nothing may open.
        new = self.decisions()[decisions:]
        assert all(d['result'] == 'cancelled' for d in new), (label, new)

    def back(self):
        workspaces = self.call('workspace.list', window_id=self.window)['workspaces']
        index = next(i for i, w in enumerate(workspaces, 1) if w['id'].lower() == self.source_workspace.lower())
        self.key(DIGIT_KEYS[index], 'command down')
        self.wait(lambda: self.selection() == (self.source_workspace.lower(), self.source.lower()), 'native return to source')
        time.sleep(.3)

    def no_navigation_on_plain_click(self, kind):
        decisions = len(self.decisions())
        self.click(kind)
        self.stays_put(kind, decisions)
        self.passed(f'a plain click on {kind} never navigates and makes no link decision')
        self.clear_selection()

    def plain_click_navigates(self, check_shell_input=False):
        decisions = len(self.decisions())
        if check_shell_input:
            # A half-typed command at the zsh prompt below the link. If the
            # click sent the shell anything (cursor-click-to-move arrows), the
            # next keystroke would land inside the word instead of after it.
            self.call('panel.send_text', workspace_id=self.source_workspace, panel_id=self.source,
                      text='echo C11H427MARK', submit=False)
            self.wait(lambda: 'echo C11H427MARK' in self.terminal_text(), 'half-typed command shown')
        self.click('link')
        released = time.monotonic()
        self.wait(lambda: self.selection() == (self.destination.lower(), self.target.lower()), 'plain click landed')
        latency = round(time.monotonic() - released, 3)
        self.wait(lambda: len(self.decisions()) > decisions, 'plain click decision')
        new = self.decisions()[decisions:]
        assert len(new) == 1 and new[0]['activation'] == 'plain_click' and new[0]['result'] == 'opened' \
            and new[0]['target'] == self.target_url, new
        self.screenshot('02-plain-landing')
        self.passed('a plain click on a c11h OSC 8 link navigates in a plain zsh panel',
                    decision=new[0], seconds_after_release=latency)
        self.back()
        if check_shell_input:
            self.call('panel.send_text', workspace_id=self.source_workspace, panel_id=self.source, text='Z', submit=True)
            self.wait(lambda: '\nC11H427MARKZ' in self.terminal_text(), 'command ran as typed')
            assert 'C11H427MARZ' not in self.terminal_text()
            self.passed('the navigating click sent the shell no input: the half-typed command ran as typed')
            self.redraw()

    def redraw(self):
        """Reprint the fixture; the prompt returns to its row."""
        (self.fixture / 'size.txt').unlink(missing_ok=True)
        self.call('panel.send_text', workspace_id=self.source_workspace, panel_id=self.source,
                  text=self.fixture_command, submit=True)
        self.wait(lambda: (self.fixture / 'size.txt').exists(), 'fixture redrawn')
        time.sleep(.4)
        self.calibrate()

    def typed(self, text):
        self.call('panel.send_text', workspace_id=self.source_workspace, panel_id=self.source, text=text, submit=False)
        self.wait(lambda: PROMPT_LABEL + ' % ' + text in self.terminal_text(), 'typed at the prompt: ' + text)

    def ran(self, output, label):
        self.call('panel.send_text', workspace_id=self.source_workspace, panel_id=self.source, text='Z', submit=True)
        self.wait(lambda: '\n' + output in self.terminal_text(), label)

    def prompt_link_navigates(self):
        # The C11H-427 v1 gap: Ghostty's cursor-click-to-move acts on a click
        # on the live prompt line. The held click never reaches Ghostty.
        decisions = len(self.decisions())
        self.typed('echo C11H427PROMPT')
        self.click('prompt', offset=3)
        self.wait(lambda: self.selection() == (self.destination.lower(), self.target.lower()), 'prompt link landed')
        self.wait(lambda: len(self.decisions()) > decisions, 'prompt link decision')
        new = self.decisions()[decisions:]
        assert len(new) == 1 and new[0]['activation'] == 'plain_click' and new[0]['result'] == 'opened', new
        self.screenshot('02-prompt-landing')
        self.back()
        self.ran('C11H427PROMPTZ', 'prompt command ran as typed')
        self.passed('a plain click on a c11 link in the live prompt navigates and sends the shell no input',
                    decision=new[0])
        self.redraw()

    def replayed_clicks_leave_ghostty_balanced(self):
        # After held clicks were replayed (the double click just below), a
        # plain click elsewhere clears the selection and places the shell
        # cursor exactly as before: the next key lands where it was clicked.
        self.typed('echo C11H427CTRL')
        line = [l for l in self.terminal_text().splitlines() if 'echo C11H427CTRL' in l][-1]
        column = line.index('C11H427CTRL') + 1
        self.clear_selection()
        self.click('link', count=2)
        self.wait(lambda: self.read_selection(), 'double click on the link selected')
        time.sleep(.7)
        decisions = len(self.decisions())
        self.click('prompt', offset=column)
        self.wait(lambda: self.read_selection() in (None, ''), 'plain click cleared the selection')
        self.ran('ZC11H427CTRL', 'plain click placed the shell cursor')
        assert not [d for d in self.decisions()[decisions:] if d['result'] == 'opened']
        self.passed("after replayed clicks Ghostty's mouse state is balanced: a plain click clears the selection "
                    'and places the shell cursor (cursor-click-to-move)', column=column)
        self.redraw()

    CONFIG = Path.home() / '.config/ghostty/config'
    MARK = '# C11H-427 proof'

    def set_proof_interval(self, milliseconds):
        """Add or remove the proof's own config line, then reload Ghostty's config."""
        text = self.CONFIG.read_text() if self.CONFIG.exists() else ''
        lines, skip = [], False
        for line in text.splitlines():
            # The marker line and the setting under it are the proof's own.
            if line == self.MARK or skip:
                skip = line == self.MARK
                continue
            lines.append(line)
        if milliseconds:
            lines += [self.MARK, f'click-repeat-interval = {milliseconds}']
        self.CONFIG.parent.mkdir(parents=True, exist_ok=True)
        self.CONFIG.write_text('\n'.join(lines) + ('\n' if lines else ''))
        self.sock.sendall(b'reload_config\n')
        reply = self.reader.readline().decode().strip()
        assert reply.startswith('OK'), reply
        time.sleep(1)

    def cleanup(self):
        try:
            self.set_proof_interval(None)
        except Exception as error:
            self.report['config_restore_error'] = str(error)
        super().cleanup()

    def configure_slow_interval(self):
        self.set_proof_interval(SLOW_INTERVAL_MS)
        self.redraw()  # a fresh prompt after the reload
        self.gap = SLOW_INTERVAL_MS / 1000 + .2
        self.report['click_repeat_interval_ms'] = SLOW_INTERVAL_MS

    def slow_double_click_selects(self):
        # 700 ms apart: AppKit (500 ms) calls the second press a new click;
        # Ghostty, at 1000 ms, a double click. Ghostty decides.
        self.clear_selection()
        time.sleep(.6)
        decisions = len(self.decisions())
        x, y = self.point('link')
        self.ensure_frontmost()
        self.mouse(x, y, MOVED)
        self.mouse(x, y, LEFT_DOWN)
        self.mouse(x, y, LEFT_UP)
        time.sleep(.58)
        self.mouse(x, y, LEFT_DOWN)
        self.mouse(x, y, LEFT_UP)
        text = self.wait(lambda: self.read_selection(), 'slow double click selected')
        assert text.strip() == 'Real', text
        time.sleep(QUIET)
        assert self.selection() == (self.source_workspace.lower(), self.source.lower()), 'navigated'
        assert not [d for d in self.decisions()[decisions:] if d['result'] == 'opened']
        self.screenshot('03-slow-double-link')
        self.passed(f'a 700 ms double click selects under click-repeat-interval = {SLOW_INTERVAL_MS}', selection=text)

    def key_cancels(self):
        self.clear_selection()
        decisions = len(self.decisions())
        self.click('link')
        self.run(['/opt/homebrew/bin/cliclick', 't:q'])
        time.sleep(QUIET)
        assert self.selection() == (self.source_workspace.lower(), self.source.lower()), 'navigated after a key'
        new = self.decisions()[decisions:]
        assert [d['result'] for d in new] == ['cancelled'], new
        def typed_q():
            text = self.terminal_text()
            self.report['key_cancel_text_tail'] = text[-400:]
            # The prompt's own cells can read back blank here (seen on the
            # guest), so the oracle is the source screen's last line: the key.
            lines = [l for l in text.splitlines() if l.strip()]
            return lines[-1] if lines and lines[-1].rstrip().endswith(' q') and 'panel link' not in lines[-1] else None
        line = self.wait(typed_q, 'the key reached the source prompt')
        self.call('panel.send_text', workspace_id=self.source_workspace, panel_id=self.source, text='\x15', submit=False)
        self.passed('a key pressed before the open lands cancels it, and the key reached the source panel',
                    decision=new[0], prompt=line)

    def press_pair_with_key(self, first, second):
        """Press and release at `first`, type X, press and release at
        `second`; returns the seconds between the two presses."""
        self.ensure_frontmost()
        self.mouse(*first, MOVED)
        started = time.monotonic()
        self.mouse(*first, LEFT_DOWN)
        self.mouse(*first, LEFT_UP)
        self.run(['/opt/homebrew/bin/cliclick', 't:X'])
        self.mouse(*second, MOVED)
        gap = time.monotonic() - started
        self.mouse(*second, LEFT_DOWN)
        self.mouse(*second, LEFT_UP)
        assert gap < SLOW_INTERVAL_MS / 1000 - .1, ('second press outside the interval', gap)
        return round(gap, 3)

    def key_then_click_never_replays(self):
        # Fix 1 of repair 2: a held click, a key, then a press that continues
        # its sequence by time and distance. Only the key rule stops the
        # replay; each step asserts the press gap is inside the interval.
        # (a) The prompt-line link, clicked again on the same cell: replayed,
        # cursor-click-to-move would land after the key. The second click is
        # a fresh click and navigates.
        time.sleep(self.gap)
        self.typed('echo C11H427KS')
        decisions = len(self.decisions())
        spot = self.point('prompt', 3)
        gap = self.press_pair_with_key(spot, spot)
        self.wait(lambda: self.selection() == (self.destination.lower(), self.target.lower()), 're-click landed')
        self.back()
        results = [d['result'] for d in self.decisions()[decisions:]]
        assert results[:2] == ['cancelled', 'opened'], results
        self.ran('C11H427KSXZ', 'same link: the command ran as typed with the key')
        self.passed('held prompt-line click, a key, then the same link within the interval: the held click never '
                    'reaches the shell; the new click navigates', decisions=results, press_gap=gap)
        self.redraw()
        # (b) An output link's last cell, then plain text 0.6 cell away: a
        # replay would make Ghostty count a double click and select a word.
        self.clear_selection()
        self.typed('echo C11H427KO')
        decisions = len(self.decisions())
        held = self.point('edge', len(EDGE_LABEL) - .8)
        after = self.point('edge', len(EDGE_LABEL) - .2)
        cell = self.grid['width'] / self.grid['scale']
        assert 0 < after[0] - held[0] < cell, (held, after, cell)
        gap = self.press_pair_with_key(held, after)
        time.sleep(QUIET)
        assert self.selection() == (self.source_workspace.lower(), self.source.lower()), 'navigated'
        assert self.read_selection() in (None, ''), ('the second click selected', self.read_selection())
        results = [d['result'] for d in self.decisions()[decisions:]]
        assert results == ['cancelled'], results
        self.ran('C11H427KOXZ', 'output: the command ran as typed with the key')
        self.passed('held output-link click, a key, then plain text 0.6 cell away within the interval: no replay, '
                    'no selection, nothing opens', decisions=results, press_gap=gap,
                    distance_points=after[0] - held[0], cell_points=round(cell, 2))
        self.redraw()

    def shift_extend_then_triple_on_link(self):
        # Repair 3: a Shift press that only extends a selection is not counted
        # by Ghostty, so a triple click on the link right after it is still a
        # triple click: the line is selected and nothing opens.
        self.clear_selection()
        decisions = len(self.decisions())
        self.drag('plain', 0, 8)
        self.wait(lambda: self.read_selection(), 'drag selected output')
        time.sleep(SLOW_INTERVAL_MS / 1000 + .3)
        x, y = self.point('link', 6)
        self.ensure_frontmost()
        self.mouse(x, y, MOVED, flags=SHIFT)
        self.mouse(x, y, LEFT_DOWN, flags=SHIFT)
        self.mouse(x, y, LEFT_UP, flags=SHIFT)
        extended = self.wait(lambda: (lambda t: t if t and '\n' in t else None)(self.read_selection()), 'Shift extended')
        time.sleep(.3)
        for clicks in (1, 2, 3):
            self.mouse(x, y, LEFT_DOWN, clicks)
            self.mouse(x, y, LEFT_UP, clicks)
            time.sleep(.03)
        line = self.wait(lambda: (lambda t: t if t and t.strip() == self.labels['link'] else None)(self.read_selection()),
                         'triple click selected the link line')
        time.sleep(QUIET)
        assert self.read_selection().strip() == self.labels['link'], self.read_selection()
        assert self.selection() == (self.source_workspace.lower(), self.source.lower()), 'navigated'
        results = [d['result'] for d in self.decisions()[decisions:]]
        assert 'opened' not in results, results
        self.screenshot('04-shift-then-triple')
        self.passed('Shift-extend onto a link, then a triple click on it: the line is selected, nothing opens',
                    extended=extended, selection=line, decisions=results)

    def long_hold_then_shift_click(self):
        # Fix 2: held 1.2 s, released, Shift-click 0.3 s later on the same
        # cell. 1.5 s after the held press it continues nothing, so the held
        # click is dropped; replayed, it would turn the Shift-click into a
        # double click that selects a word.
        self.clear_selection()
        decisions = len(self.decisions())
        x, y = self.point('link')
        self.ensure_frontmost()
        self.mouse(x, y, MOVED)
        self.mouse(x, y, LEFT_DOWN)
        time.sleep(1.2)
        self.mouse(x, y, LEFT_UP)
        time.sleep(.3)
        self.mouse(x, y, LEFT_DOWN, flags=SHIFT)
        self.mouse(x, y, LEFT_UP, flags=SHIFT)
        time.sleep(QUIET)
        assert self.read_selection() in (None, ''), ('Shift-click selected', self.read_selection())
        assert self.selection() == (self.source_workspace.lower(), self.source.lower()), 'navigated'
        assert not [d for d in self.decisions()[decisions:] if d['result'] == 'opened']
        self.passed('a press held 1.2 s, then a Shift-click 0.3 s after release: no replay, nothing selected, '
                    'nothing opens', decisions=[d['result'] for d in self.decisions()[decisions:]])

    def link_right_after_click_elsewhere(self):
        # Fix 3: Ghostty restarts its count more than a cell away, so a link
        # clicked 0.3 s after a click on other text is a single click.
        self.clear_selection()
        decisions = len(self.decisions())
        self.click('plain')
        time.sleep(.3)
        self.click('link')
        self.wait(lambda: self.selection() == (self.destination.lower(), self.target.lower()), 'link landed')
        self.wait(lambda: 'opened' in [d['result'] for d in self.decisions()[decisions:]], 'link opened')
        self.passed('a link clicked 0.3 s after a click four rows away navigates')
        self.back()

    def plain_click_right_after_shift_click(self):
        # Repair 4, the fail-safe rule: c11 can't see how Ghostty counts a
        # Shift press, so a plain click on the link within its window is not
        # held and goes to Ghostty: no decision, no navigation.
        self.clear_selection()
        decisions = len(self.decisions())
        x, y = self.point('link', 4)
        self.ensure_frontmost()
        self.mouse(x, y, MOVED, flags=SHIFT)
        self.mouse(x, y, LEFT_DOWN, flags=SHIFT)
        self.mouse(x, y, LEFT_UP, flags=SHIFT)
        time.sleep(.3)
        self.mouse(x, y, MOVED)
        self.mouse(x, y, LEFT_DOWN)
        self.mouse(x, y, LEFT_UP)
        time.sleep(QUIET)
        assert self.selection() == (self.source_workspace.lower(), self.source.lower()), 'navigated'
        results = [d['result'] for d in self.decisions()[decisions:]]
        assert results == [], ('the plain click was held', results)
        self.passed('a plain click on a link 0.3 s after a Shift-click on it goes to Ghostty: not held, '
                    'nothing opens', selection=self.read_selection())

    def click_elsewhere_cancels(self):
        self.clear_selection()
        before = {p['id'] for p in self.call('panel.list', workspace_id=self.source_workspace)['panels']}
        self.sock.sendall(f'new_split right {self.source}\n'.encode())
        reply = self.reader.readline().decode().strip()
        assert reply.startswith('OK'), reply
        other = self.wait(lambda: ([p['id'] for p in self.call('panel.list', workspace_id=self.source_workspace)['panels']
                                    if p['id'] not in before] or [None])[0], 'split panel')
        self.call('panel.focus', workspace_id=self.source_workspace, panel_id=self.source)
        self.wait(lambda: self.selection() == (self.source_workspace.lower(), self.source.lower()), 'source focused')
        areas = [e for e in self.ax() if e['role'] == 'AXTextArea' and e['help'] == 'Terminal content area'
                 and e['size'] and e['size'][0] > 100 and e['size'][1] > 100]
        right = [e for e in areas if e['position'][0] > self.terminal_frame['position'][0] + 50]
        assert len(right) == 1, areas
        ox = right[0]['position'][0] + right[0]['size'][0] / 2
        oy = right[0]['position'][1] + right[0]['size'][1] / 2
        decisions = len(self.decisions())
        self.click('link')
        self.mouse(ox, oy, MOVED)
        self.mouse(ox, oy, LEFT_DOWN)
        self.mouse(ox, oy, LEFT_UP)
        time.sleep(QUIET)
        assert self.selection() == (self.source_workspace.lower(), other.lower()), 'focus left where it was clicked'
        new = self.decisions()[decisions:]
        assert [d['result'] for d in new] == ['cancelled'], new
        self.screenshot('04-click-elsewhere')
        self.passed('a click in another panel before the open lands cancels it; focus stays where it was clicked',
                    decision=new[0])
        # The other panel has focus: a plain click on the link in the
        # unfocused source panel navigates.
        time.sleep(self.gap)
        decisions = len(self.decisions())
        x, y = self.point('link', focused=False)
        self.mouse(x, y, MOVED)
        self.mouse(x, y, LEFT_DOWN)
        self.mouse(x, y, LEFT_UP)
        self.wait(lambda: self.selection() == (self.destination.lower(), self.target.lower()), 'unfocused link landed')
        new = self.decisions()[decisions:]
        self.wait(lambda: [d['result'] for d in self.decisions()[decisions:]] == ['opened'], 'unfocused link opened')
        self.passed('a plain click on a link in an unfocused panel navigates')
        self.back()
        self.call('panel.close', workspace_id=self.source_workspace, panel_id=other)
        self.call('panel.focus', workspace_id=self.source_workspace, panel_id=self.source)
        self.wait(lambda: self.selection() == (self.source_workspace.lower(), self.source.lower()), 'source refocused')
        time.sleep(.5)
        self.calibrate()

    def command_click_navigates(self):
        decisions = len(self.decisions())
        time.sleep(.6)
        # The preview shows the canonical c11:// URL whatever alias the cell holds.
        self.urls = dict(self.urls, link='c11://panel/' + self.target.lower())
        self.click_link('link', command=True)  # base helper: waits for Ghostty's Cmd-hover preview
        self.wait(lambda: self.selection() == (self.destination.lower(), self.target.lower()), 'Cmd-click landed')
        self.wait(lambda: len(self.decisions()) > decisions, 'Cmd-click decision')
        new = self.decisions()[decisions:]
        assert len(new) == 1 and new[0]['activation'] == 'native_command_click' and new[0]['result'] == 'opened', new
        self.passed('a Cmd-click on the c11h link still navigates through Ghostty', decision=new[0])
        self.back()

    def selects(self, kind, gesture, expect):
        self.clear_selection()
        decisions = len(self.decisions())
        if gesture == 'drag':
            self.drag(kind, 0, 8)
        else:
            self.click(kind, count=dict(double=2, triple=3)[gesture])
        text = self.wait(lambda: self.read_selection(), f'{gesture} on {kind} selected')
        assert expect(text.strip()), (kind, gesture, text)
        self.stays_put(f'{gesture} on {kind}', decisions)
        assert self.read_selection() == text, 'selection survived'
        name = f'03-{gesture}-{kind}'
        self.screenshot(name)
        self.passed(f'{gesture} on {kind} selects and never navigates', selection=text)

    def shift_extends(self, start_kind, end_kind):
        self.clear_selection()
        decisions = len(self.decisions())
        self.drag(start_kind, 0, 4)
        first = self.wait(lambda: self.read_selection(), 'first selection')
        time.sleep(.6)
        self.click(end_kind, offset=6, flags=SHIFT)
        extended = self.wait(lambda: (lambda t: t if t and t != first and '\n' in t else None)(self.read_selection()),
                             f'Shift-click on {end_kind} extended the selection')
        label = self.labels[end_kind]
        assert label[:4] in extended or label[7:12] in extended, (first, extended)
        self.stays_put(f'Shift-click on {end_kind}', decisions)
        self.screenshot(f'04-shift-{end_kind}')
        self.passed(f'Shift-click on {end_kind} extends a selection and never navigates',
                    first=first, extended=extended)

    def execute(self):
        self.seed()
        self.run(['/opt/homebrew/bin/cliclick', 'ku:cmd', 'ku:alt', 'ku:shift', 'ku:ctrl'])
        self.no_navigation_on_plain_click('https')
        self.no_navigation_on_plain_click('plain')
        self.plain_click_navigates(check_shell_input=True)
        self.prompt_link_navigates()
        self.command_click_navigates()
        link, plain = self.labels['link'], self.labels['plain']
        self.selects('link', 'drag', lambda t: len(t) >= 6 and link.startswith(t))
        self.selects('link', 'double', lambda t: t and t in link and ' ' not in t)
        self.selects('link', 'triple', lambda t: t == link)
        self.selects('plain', 'drag', lambda t: len(t) >= 6 and plain.startswith(t))
        self.selects('plain', 'double', lambda t: t and t in plain and ' ' not in t)
        self.selects('plain', 'triple', lambda t: t == plain)
        self.shift_extends('plain', 'link')
        self.shift_extends('plain', 'https')  # off any c11 link
        self.replayed_clicks_leave_ghostty_balanced()
        self.configure_slow_interval()
        self.slow_double_click_selects()
        self.key_cancels()
        self.key_then_click_never_replays()
        self.long_hold_then_shift_click()
        self.link_right_after_click_elsewhere()
        self.shift_extend_then_triple_on_link()
        self.plain_click_right_after_shift_click()
        self.click_elsewhere_cancels()
        self.clear_selection()
        self.plain_click_navigates()  # still navigates after all the selection traffic
        self.call('workspace.close', workspace_id=self.destination)
        self.screenshot('05-final')
        self.report['status'] = 'passed'


if __name__ == '__main__':
    proof = PlainProof()
    try:
        proof.execute()
        print('PASS C11H-427 plain-click terminal links; evidence=' + str(native.OUT), flush=True)
    except BaseException as error:
        proof.report.update(status='failed', error=str(error))
        try:
            proof.screenshot('failure')
        except Exception as capture_error:
            proof.report['failure_screenshot_error'] = str(capture_error)
        raise
    finally:
        proof.cleanup()
