#!/usr/bin/env python3
"""C11-552 outside-link proof. ONLY through sandbox-tests-v2.sh.

Real Launch Services delivery, native confirmation clicks, and Safari links.
420-second active deadline; 470-second hard kill of the verified guest app.
"""
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import traceback
import uuid

import test_terminal_panel_links_native as native

native.OUT = Path('/Volumes/My Shared Files/out/external-panel-link-proof')
native.SOURCE_TITLE = 'C11-552 Source'
native.DESTINATION_TITLE = 'C11-552 Destination'
native.TARGET_TITLE = 'C11-552 Target'
OUT = native.OUT


class Proof(native.Proof):
    def accepts_bundle(self, identity):
        # Only the production Release product registers the scheme. The exact
        # PID/path/socket are still constrained to this disposable guest.
        return identity == 'com.stage11.c11'

    def seed(self):
        self.ui('activate')
        display = self.ui('displays')
        assert len(display['displays']) == len(display['windows']) == 1, display
        self.window_number = display['windows'][0]['kCGWindowNumber']
        windows = self.call('window.list')['windows']
        assert len(windows) == 1 and windows[0]['key'], windows
        self.window = windows[0]['id']
        self.source_workspace = self.focused()['workspace_id']
        self.source = self.focused()['panel_id']
        self.call('workspace.rename', workspace_id=self.source_workspace, title=native.SOURCE_TITLE)
        self.destination = self.call('workspace.create', window_id=self.window, title=native.DESTINATION_TITLE)['workspace_id']
        self.target = next(p['id'] for p in self.call('panel.list', workspace_id=self.destination)['panels'] if p['type'] == 'terminal')
        self.call('panel.action', workspace_id=self.destination, panel_id=self.target, action='rename', title=native.TARGET_TITLE)
        self.target_url = 'c11://panel/' + self.target.lower()
        self.workspace_url = 'c11://workspace/' + self.destination.lower()
        self.report['limitations'] = ['Single verified guest display; multiple physical displays not exercised.']
        self.report['identity'].update(source=self.source, destination=self.destination, target=self.target)
        schemes = [scheme for entry in self.bundle.get('CFBundleURLTypes', []) for scheme in entry.get('CFBundleURLSchemes', [])]
        assert 'c11' in schemes, 'built app must register c11'
        self.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(self.app)])
        self.passed('verified guest PID, display, socket and built URL registration', schemes=schemes)

    def capture(self, name):
        # This is the verified single-display guest, including the source app
        # and floating c11 prompt; never the host display or an unverified PID.
        self.run(['/usr/sbin/screencapture', '-x', '-D', '1', str(OUT / (name + '.png'))])

    def prompt(self):
        return self.ax('c11.external-link.confirmation')

    def click(self, identifier):
        hits = [x for x in self.ax() if x['id'] == identifier]
        assert len(hits) == 1, (identifier, hits)
        x, y = hits[0]['position']
        w, h = hits[0]['size']
        # Native mouse click, even if the source browser is still foreground.
        # The intentional Confirm path approaches afresh after the arming delay.
        if identifier == 'c11.external-link.confirm':
            self.run(['/opt/homebrew/bin/cliclick', f'm:{int(x-30)},{int(y-30)}'])
            time.sleep(1.1)
            self.run(['/opt/homebrew/bin/cliclick', f'm:{int(x+w/2)},{int(y+h/2)}'])
            time.sleep(.1)
        self.run(['/opt/homebrew/bin/cliclick', f'c:{int(x+w/2)},{int(y+h/2)}'])

    def outside(self, url=None):
        # No -a or -g: use the real registered OS scheme and normal activation.
        self.run(['/usr/bin/open', url or self.target_url])
        self.wait(self.prompt, 'outside request shows confirmation')

    def cancel(self):
        self.click('c11.external-link.cancel')
        self.wait(lambda: not self.prompt(), 'native Cancel dismisses')
        time.sleep(2.1)

    def terminal_origin(self):
        self.run(['/usr/bin/open', '-a', 'Terminal'])
        terminal_pid = int(self.run(['/usr/bin/osascript', '-e',
            'tell application "System Events" to get unix id of process "Terminal"'], text=True).stdout)
        self.wait(lambda: self.ui('foreground') == terminal_pid, 'Terminal.app is foreground before typing')
        self.run(['/opt/homebrew/bin/cliclick', 't:/usr/bin/open ' + self.target_url, 'kp:enter'])
        self.wait(self.prompt, 'Terminal.app open shows confirmation')
        self.capture('01-terminal-origin')
        assert self.selection()[0] == self.source_workspace.lower()
        labels = self.ax()
        assert any(x['id'] == 'c11.external-link.panel' and native.TARGET_TITLE in str(x.get('value')) for x in labels), labels
        assert any(x['id'] == 'c11.external-link.workspace' and native.DESTINATION_TITLE in str(x.get('value')) for x in labels), labels
        self.cancel()
        assert self.selection()[0] == self.source_workspace.lower()
        self.passed('Terminal.app outside link names panel/workspace; Cancel preserves selection')

    def safari_origin(self):
        page = self.fixture / 'outside.html'
        page.write_text('<!doctype html><html><head><title>C11-552 outside browser</title><link rel="icon" href="data:,"></head>'
                        '<body style="font:24px monospace;padding:70px"><h1>Outside link proof</h1>'
                        '<p><a href="' + self.target_url + '">OPEN C11 DESTINATION</a></p>'
                        '<input aria-label="Typing proof" style="font:24px monospace" placeholder="Typing stays here">'
                        '</body></html>')
        self.run(['/usr/bin/open', '-a', 'Safari', page.as_uri()])
        time.sleep(2)
        # AXPress is a real browser link activation; no JavaScript or c11
        # socket method triggers the outside link. Permission UI is recorded.
        script = '''tell application "System Events" to tell process "Safari"
set frontmost to true
set xs to entire contents of window 1
repeat with e in xs
try
if role of e is "AXLink" and description of e contains "OPEN C11" then
perform action "AXPress" of e
return "clicked"
end if
end try
end repeat
return "missing"
end tell'''
        result = self.run(['/usr/bin/osascript', '-e', script], text=True).stdout.strip()
        assert result == 'clicked', ('Safari AX link', result)
        time.sleep(.5)
        # Safari can ask whether to open this scheme. Accept only the native
        # browser permission; the c11 confirmation must still follow it.
        if not self.prompt():
            permission = '''tell application "System Events" to tell process "Safari"
if exists sheet 1 of window 1 then
if exists button "Allow" of sheet 1 of window 1 then
click button "Allow" of sheet 1 of window 1
else if exists button "Open" of sheet 1 of window 1 then
click button "Open" of sheet 1 of window 1
end if
end if
end tell'''
            self.run(['/usr/bin/osascript', '-e', permission])
        self.wait(self.prompt, 'real Safari link shows c11 confirmation')
        front = self.ui('foreground')
        safari_pid = int(self.run(['/usr/bin/osascript', '-e', 'tell application "System Events" to get unix id of process "Safari"'], text=True).stdout)
        self.capture('02-browser-confirmation')
        self.report['browser_focus'] = dict(safari_pid=safari_pid, foreground_before_confirm=front)
        assert front in (safari_pid, self.pid), ('unexpected foreground app', front)
        if front != safari_pid:
            self.report['limitations'].append('The real Safari scheme handoff activated c11 through Launch Services; background delivery separately checks that the prompt adds no activation.')
        assert self.selection()[0] == self.source_workspace.lower()
        self.call('panel.action', workspace_id=self.destination, panel_id=self.target,
                  action='rename', title='C11-552 live build title changed')
        self.click('c11.external-link.confirm')
        self.wait(lambda: self.selection() == (self.destination.lower(), self.target.lower()), 'Confirm selects exact destination despite live title change')
        self.wait(lambda: self.ui('foreground') == self.pid, 'Confirm activates target app')
        self.capture('03-confirmed-destination')
        self.passed('real Safari link requires native Confirm before exact destination selection',
                    source_stayed_foreground=front == safari_pid)
        time.sleep(2.1)
        self.back()
        self.run(['/usr/bin/open', '-a', 'Safari'])
        self.run(['/usr/bin/open', '-g', self.target_url])
        self.wait(self.prompt, 'background delivery shows visible confirmation')
        assert self.ui('foreground') == safari_pid, 'prompt itself activated c11'
        self.capture('03-background-prompt-over-browser')
        self.cancel()
        assert self.ui('foreground') == safari_pid, 'Cancel activated c11'
        self.passed('prompt visible and clickable over Safari without adding app activation')
        self.run(['/usr/bin/open', '-g', self.target_url])
        self.wait(self.prompt, 'background confirmation presented')
        assert self.ui('foreground') == safari_pid
        self.click('c11.external-link.confirm')
        self.wait(lambda: self.selection() == (self.destination.lower(), self.target.lower()),
                  'fresh Confirm works while Safari is foreground')
        self.wait(lambda: self.ui('foreground') == self.pid, 'intentional Confirm activates c11')
        self.passed('fresh native Confirm works while source app is foreground')
        time.sleep(2.1)
        self.back()
        self.ui('activate')

    def presentation_cancellation(self):
        before = self.selection()
        self.outside()
        # Move this exact confirmation through native AX, then verify the
        # presentation is revoked before any later click can authorize it.
        script = f'''tell application "System Events" to tell (first process whose unix id is {self.pid})
repeat with w in windows
if name of w is "Outside c11 link" then
set p to position of w
set position of w to {{(item 1 of p) + 30, (item 2 of p) + 30}}
return "moved"
end if
end repeat
return "missing"
end tell'''
        assert self.run(['/usr/bin/osascript', '-e', script], text=True).stdout.strip() == 'moved'
        self.wait(lambda: not self.prompt(), 'moving confirmation revokes it')
        assert self.selection() == before
        time.sleep(2.1)
        self.outside()
        self.ui('activate')
        self.key(4, 'command down')  # Native Cmd+H hides the app.
        self.wait(lambda: not self.prompt(), 'hiding app revokes confirmation')
        assert self.selection() == before
        self.ui('activate')
        time.sleep(2.1)
        self.passed('native movement and app hiding revoke pending confirmation')
        self.report['limitations'].append('Active-Space cancellation is source-reviewed; this single-Space guest pass does not exercise a Space transition.')

    def surprise_click(self):
        self.outside()
        button = next(x for x in self.ax() if x['id'] == 'c11.external-link.confirm')
        x, y = button['position']; w, h = button['size']
        cx, cy = int(x+w/2), int(y+h/2)
        self.cancel()
        # Safari's local fixture is the source surface underneath the future
        # confirmation. The native clicks start there, not in a c11 web view.
        self.run(['/usr/bin/open', '-a', 'Safari'])
        self.run(['/opt/homebrew/bin/cliclick', f'm:{cx},{cy}'])
        before = self.selection()
        self.run(['/usr/bin/open', self.target_url])
        self.run(['/opt/homebrew/bin/cliclick', f'dc:{cx},{cy}'])
        self.wait(self.prompt, 'surprise prompt present')
        time.sleep(1.1)
        self.run(['/opt/homebrew/bin/cliclick', f'c:{cx},{cy}'])
        assert self.selection() == before, 'carried-over click or parked pointer authorized navigation'
        self.capture('04-surprise-click-refused')
        self.click('c11.external-link.confirm')
        self.wait(lambda: self.selection() == (self.destination.lower(), self.target.lower()), 'fresh intentional click works after re-entry')
        self.passed('surprise double-click and parked pointer refused; fresh approach confirms')
        time.sleep(2.1)
        self.back()

    def mixed_event(self):
        before = self.selection()
        workspaces = self.call('workspace.list', window_id=self.window)['workspaces']
        folder = self.fixture / 'mixed-directory'
        folder.mkdir(exist_ok=True)
        for urls in [[self.target_url, folder.as_uri()], [folder.as_uri(), 'c11:invalid']]:
            # Explicit -a is needed to deliver file and c11 URLs in ONE Apple
            # Event to this verified guest app rather than separate handlers.
            self.run(['/usr/bin/open', '-a', str(self.app), *urls])
            self.wait(self.prompt, 'mixed event notice or confirmation')
            assert self.selection() == before
            assert self.call('workspace.list', window_id=self.window)['workspaces'] == workspaces
            self.run(['/usr/bin/open', '-a', str(self.app), *urls])  # pending
            assert self.selection() == before
            self.click('c11.external-link.cancel')
            self.wait(lambda: not self.prompt(), 'dismiss mixed event')
            self.run(['/usr/bin/open', '-a', str(self.app), *urls])  # cooldown
            assert self.selection() == before
            assert self.call('workspace.list', window_id=self.window)['workspaces'] == workspaces
            time.sleep(2.1)
        self.passed('mixed folder and c11 events never create a workspace, including pending/cooldown')

    def burst(self):
        self.ui('activate')
        before = self.selection()
        self.outside()
        prompts = [x for x in self.ax() if x['id'] == 'c11.external-link.confirmation']
        assert len(prompts) == 1
        # A raw terminal draft and Return must remain in the terminal; the
        # prompt neither becomes key nor interprets Return as confirmation.
        marker = 'C11_552_' + uuid.uuid4().hex
        self.native('t:' + marker)
        self.run(['/usr/bin/open', *([self.workspace_url] * 50)])
        self.native('t:_AFTER')
        assert self.selection() == before
        assert self.ui('foreground') == self.pid
        labels = self.ax()
        assert len([x for x in labels if x['id'] == 'c11.external-link.confirmation']) == 1
        assert any(x['id'] == 'c11.external-link.url' and self.target.lower() in str(x.get('value')).lower() for x in labels)
        assert marker + '_AFTER' in self.terminal_text(), self.terminal_text()
        self.capture('04-burst-keeps-input')
        self.key(0, 'control down')
        self.key(40, 'control down')  # Ctrl+K clears the fixture draft
        self.key(36)  # Return goes to the terminal, never Confirm.
        assert self.selection() == before and self.prompt()
        self.cancel()
        assert self.selection() == before
        self.passed('50 outside links keep one immutable prompt and terminal receives typed input')

    def refusals(self):
        before = self.selection()
        for i, url in enumerate([self.target_url+'?run=x', self.target_url+'#x', self.target_url+'/extra',
                                 'c11://panel/panel:1', 'c11://panel/'+str(uuid.uuid4()),
                                 'c11://panel/'+('x'*2048)]):
            self.outside(url)
            assert self.ax('c11.external-link.notice'), url[:100]
            assert not self.ax('c11.external-link.confirm'), url[:100]
            assert self.selection() == before
            if i == 0: self.capture('05-refused-parameter')
            self.cancel()
        self.outside()
        self.call('panel.close', workspace_id=self.destination, panel_id=self.target)
        self.click('c11.external-link.confirm')
        self.wait(lambda: self.ax('c11.external-link.notice'), 'closed pending target shows notice')
        assert self.selection() == before
        self.cancel()
        self.passed('invalid decorated oversized short unknown and closed targets never navigate')

    def execute(self):
        self.seed()
        self.terminal_origin()
        self.safari_origin()
        self.presentation_cancellation()
        self.surprise_click()
        self.mixed_event()
        self.burst()
        self.refusals()
        self.report['status'] = 'passed'

    def cleanup(self):
        signal.setitimer(signal.ITIMER_REAL, 0)
        try:
            if self.prompt(): self.click('c11.external-link.cancel')
            self.run(['/opt/homebrew/bin/cliclick', 'ku:cmd', 'ku:ctrl'])
        except Exception as error:
            self.report['cleanup_error'] = str(error)
        self.report['elapsed_seconds'] = round(time.monotonic()-self.started, 2)
        (OUT/'report.json').write_text(json.dumps(self.report, indent=2))
        self.sock.close()
        self.watchdog.cancel()


if __name__ == '__main__':
    proof = Proof()
    try:
        proof.execute()
        print('PASS C11-552 outside links', flush=True)
    except BaseException as error:
        proof.report.update(status='failed', error=str(error), traceback=traceback.format_exc())
        try: proof.capture('failure')
        except Exception: pass
        raise
    finally:
        proof.cleanup()
