#!/usr/bin/env python3
"""C11-562 native proof. ONLY via sandbox-tests-v2.sh.

(a) An outside c11:// link's confirmation shows Confirm left of Cancel; a real
    HID click on Cancel dismisses it with the selection unchanged, and a fresh
    click on Confirm still opens the destination.
(b) Settings > Browser > Sites Allowed to Open Apps writes nothing until Save,
    and an invalid line is named while Save stays disabled.

Every control is located by its accessibility identifier through the compiled
tests_v2/ax_walk.swift (compile it to tests_v2/.ax-walk first) and clicked with
timestamped HID mouse events. Socket calls only seed a workspace and read
selection. 240-second active / 280-second hard limit (inherited).
"""
import ctypes
import json
import os
from pathlib import Path
import pwd
import subprocess
import time
import traceback

import test_browser_external_open_native as base

OUT = Path('/Volumes/My Shared Files/out/c11-562-proof')
base.OUT = OUT
PROMPT = 'c11.external-link.confirmation'
CONFIRM = 'c11.external-link.confirm'
CANCEL = 'c11.external-link.cancel'
FIELD = 'SettingsBrowserExternalSchemeAllowlistField'
SAVE = 'SettingsBrowserExternalSchemeAllowlistSaveButton'
INVALID = 'SettingsBrowserExternalSchemeAllowlistInvalidLine'
KEY = 'browserExternalSchemeAllowlist'


class Proof(base.Proof):
    def ax(self, op='tree', *args):
        assert base.AX_WALK.is_file(), 'compile tests_v2/ax_walk.swift to tests_v2/.ax-walk first'
        result = json.loads(self.run([str(base.AX_WALK), str(self.pid), op, *args], text=True).stdout)
        assert not (isinstance(result, dict) and result.get('error')), result
        return result

    def ids(self):
        return self.ax('ids')

    def find(self, identifier, window_id=None):
        hits = [x for x in self.ids() if x.get('id') == identifier and (window_id is None or x.get('window_id') == window_id)]
        return hits[0] if len(hits) == 1 else None

    def center(self, element):
        (x, y), (w, h) = element['position'], element['size']
        return round(x + w / 2), round(y + h / 2)

    def hid(self, x, y, label, event_types=(5, 1, 2)):
        # Timestamped HID events, as C11-510 and C11-552 proved in this guest.
        # The prompt is nonactivating, so the foreground app is recorded, not required.
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
        foreground = self.ax('foreground')
        for event_type in event_types:
            event = cg.CGEventCreateMouseEvent(None, event_type, Point(x, y), 0)
            assert event
            if event_type != 5:
                cg.CGEventSetIntegerValueField(event, 1, 1)
            cg.CGEventSetTimestamp(event, time.monotonic_ns())
            cg.CGEventPost(0, event)
            cf.CFRelease(event)
            time.sleep(.12)
        self.report['clicks'].append(dict(label=label, x=x, y=y, foreground=foreground,
                                          elapsed=round(time.monotonic() - self.started, 2)))

    def click(self, identifier, window_id=None):
        element = self.wait(lambda: self.find(identifier, window_id), 'locate ' + identifier)
        x, y = self.center(element)
        self.hid(x, y, identifier)
        return element

    def keys(self, code, command=False):
        cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
        cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
        cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        for down in (True, False):
            event = cg.CGEventCreateKeyboardEvent(None, code, down)
            cg.CGEventSetFlags(event, (1 << 20) if command else 0)
            cg.CGEventPost(0, event)
            cf.CFRelease(event)
            time.sleep(.05)

    def wheel(self, x, y, pixels):
        # A real scroll-wheel event over the Settings page; SwiftUI's ScrollView
        # ignores AXScrollToVisible. Negative pixels scroll the content up.
        cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGEventCreateScrollWheelEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32]
        cg.CGEventCreateScrollWheelEvent.restype = ctypes.c_void_p
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        self.hid(x, y, 'pointer over Settings page', (5,))
        event = cg.CGEventCreateScrollWheelEvent(None, 0, 1, pixels)
        assert event
        cg.CGEventPost(0, event)
        cf.CFRelease(event)
        time.sleep(.4)

    def scroll_into_view(self, identifiers):
        window = self.wait(lambda: next((x for x in self.ids() if x.get('id') == 'cmux.settings'), None), 'Settings window')
        (wx, wy), (ww, wh) = window['position'], window['size']
        top, bottom = wy + 60, wy + wh - 30
        for _ in range(40):
            elements = [self.find(i) for i in identifiers]
            if all(elements):
                low = max(e['position'][1] + e['size'][1] for e in elements)
                high = min(e['position'][1] for e in elements)
                if high >= top and low <= bottom:
                    self.report.setdefault('scrolled', []).append(dict(ids=identifiers, frames=elements))
                    return elements
                self.wheel(round(wx + ww * .7), round(wy + wh / 2), -120 if low > bottom else 120)
            else:
                self.wheel(round(wx + ww * .7), round(wy + wh / 2), -120)
        raise AssertionError(('could not scroll into view', identifiers))

    def cliclick(self, *commands):
        # Typed keys through cliclick, as C11-552 did in this guest: CGEvent
        # Unicode strings did not reach the SwiftUI text editor.
        self.run(['/opt/homebrew/bin/cliclick', '-w', '40', *commands])
        time.sleep(.3)

    def stored(self):
        result = subprocess.run(['/usr/bin/defaults', 'read', self.bundle['CFBundleIdentifier'], KEY],
                                capture_output=True, text=True, timeout=5)
        return result.stdout.rstrip('\n') if result.returncode == 0 else None

    def console_open(self, *arguments):
        # A real console-user Launch Services send, as C11-552's proof does.
        uid = os.getuid()
        user = pwd.getpwuid(uid).pw_name
        assert user == 'admin', ('unexpected guest console user', user)
        return self.run(['/usr/bin/sudo', '-n', '/bin/launchctl', 'asuser', str(uid),
                         '/usr/bin/sudo', '-n', '-u', user, '/usr/bin/open', *arguments])

    def selected_workspace(self):
        return self.call('system.identify', window_id=self.window)['focused']['workspace_id'].lower()

    def prompt_buttons(self):
        controls = [x for x in self.ids() if x.get('window_id') == PROMPT]
        confirm = [x for x in controls if x.get('id') == CONFIRM]
        cancel = [x for x in controls if x.get('id') == CANCEL]
        return (confirm[0], cancel[0]) if len(confirm) == len(cancel) == 1 else None

    def outside_request(self):
        self.console_open('-b', self.bundle['CFBundleIdentifier'], self.url)
        return self.wait(self.prompt_buttons, 'outside link shows the confirmation', timeout=10)

    def link_prompt(self):
        confirm, cancel = self.outside_request()
        assert confirm['position'][0] + confirm['size'][0] <= cancel['position'][0], ('Confirm must sit left of Cancel', confirm, cancel)
        assert confirm['position'][1] == cancel['position'][1], ('buttons share one row', confirm, cancel)
        self.screenshot('01-prompt-confirm-left-of-cancel')
        self.passed('prompt shows Confirm left of Cancel', confirm=confirm, cancel=cancel)

        self.click(CANCEL, PROMPT)
        self.wait(lambda: not self.prompt_buttons(), 'native Cancel dismisses the prompt')
        assert self.selected_workspace() == self.source, 'Cancel must not change the selection'
        self.screenshot('02-after-cancel')
        self.passed('real Cancel click dismisses; selection unchanged', selected=self.source)

        time.sleep(2.2)  # the prompt's cooldown after a dismissal
        confirm, _ = self.outside_request()
        x, y = self.center(confirm)
        self.hid(x - 60, y - 60, 'approach from outside Confirm', (5,))
        time.sleep(1.2)  # past the arming delay
        self.hid(x, y, 'move onto Confirm', (5,))
        self.wait(lambda: (self.find(CONFIRM, PROMPT) or {}).get('enabled') is True, 'Confirm arms')
        self.hid(x, y, CONFIRM)
        self.wait(lambda: self.selected_workspace() == self.destination, 'fresh Confirm click opens the destination')
        self.screenshot('03-after-confirm')
        self.passed('fresh Confirm click at its new position opens the destination', selected=self.destination)

    def allowlist_editor(self):
        assert self.stored() in (None, ''), ('allowlist must start empty', self.stored())
        self.ax('activate')
        self.wait(lambda: self.ax('foreground') == self.pid, 'guest app frontmost')
        self.keys(43, command=True)  # Command-comma opens Settings
        self.click('settings.sidebar.browser')
        self.wait(lambda: self.find(FIELD), 'allowlist editor shown')
        self.scroll_into_view([FIELD, SAVE])
        self.click(FIELD)
        time.sleep(.4)
        self.cliclick('kd:cmd', 't:a', 'ku:cmd')  # select all
        self.cliclick('t:https://example.com vnc')
        self.wait(lambda: (self.find(FIELD) or {}).get('value') == 'https://example.com vnc', 'typed line reaches the editor')
        save = self.wait(lambda: self.find(SAVE), 'Save button shown')
        assert self.stored() in (None, ''), ('typing must not write the allowlist', self.stored())
        assert save.get('enabled') is True, ('Save enabled with a valid unsaved edit', save)
        self.screenshot('04-draft-unsaved')
        self.passed('typing a line writes nothing; Save is enabled', stored=self.stored())

        self.click(SAVE)
        self.wait(lambda: self.stored() == 'https://example.com vnc', 'Save writes the allowlist')
        self.wait(lambda: (self.find(SAVE) or {}).get('enabled') is False, 'Save disables once saved')
        self.passed('real Save click writes the allowlist', stored=self.stored())

        self.scroll_into_view([FIELD, SAVE])
        self.click(FIELD)
        time.sleep(.4)
        self.cliclick('kd:cmd', 'kp:arrow-down', 'ku:cmd', 'kp:return', 't:zoom.us')
        # Any one-word second line can never match; read back what actually landed.
        value = self.wait(lambda: (lambda v: v if v.startswith('https://example.com vnc\n') and len(v) > 24 else None)(
            (self.find(FIELD) or {}).get('value') or ''), 'invalid second line reaches the editor')
        line = value.split('\n')[1]
        caption = self.wait(lambda: self.find(INVALID), 'invalid line is reported')
        text = ' '.join(str(caption.get(k) or '') for k in ('value', 'title'))
        assert 'Line 2' in text and line in text, ('caption names line 2 and its text', caption, line)
        assert (self.find(SAVE) or {}).get('enabled') is False, 'Save stays disabled for an invalid line'
        assert self.stored() == 'https://example.com vnc', ('invalid edit must write nothing', self.stored())
        self.screenshot('05-invalid-line-reported')
        self.passed('invalid line is named, Save disabled, nothing written', caption=caption, stored=self.stored())

    def execute(self):
        # Guest only: a System Settings window would sit over the prompt.
        subprocess.run(['/usr/bin/pkill', '-x', 'System Settings'], capture_output=True, timeout=5)
        self.ax('activate')
        self.wait(lambda: self.ax('foreground') == self.pid, 'guest app frontmost')
        key = self.wait(lambda: next((w for w in self.call('window.list')['windows'] if w['key']), None),
                        'guest app key window', timeout=15)
        self.window = key['id']
        self.source = self.selected_workspace()
        self.destination = self.call('workspace.create', window_id=self.window, title='C11-562 Destination')['workspace_id'].lower()
        assert self.selected_workspace() == self.source
        self.url = 'c11://workspace/' + self.destination
        self.report['identity'].update(source=self.source, destination=self.destination)
        self.link_prompt()
        self.allowlist_editor()
        self.report['status'] = 'passed'

    def cleanup(self):
        subprocess.run(['/usr/bin/defaults', 'delete', self.bundle['CFBundleIdentifier'], KEY],
                       capture_output=True, timeout=5)
        super().cleanup()


if __name__ == '__main__':
    proof = Proof()
    try:
        proof.execute()
        print('PASS C11-562 native proof; evidence=' + str(OUT), flush=True)
    except BaseException as error:
        proof.report.update(status='failed', error=str(error), traceback=traceback.format_exc())
        try:
            proof.screenshot('failure')
            (OUT / 'ax-ids-at-failure.json').write_text(json.dumps(proof.ids(), indent=2))
        except Exception as capture_error:
            proof.report['failure_screenshot_error'] = str(capture_error)
        raise
    finally:
        proof.cleanup()
