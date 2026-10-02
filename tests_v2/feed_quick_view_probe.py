#!/usr/bin/env python3
"""Explicit C11-266 packaged UI proof in an owned Atlas guest (not test_ suite).

Supply exact run-id/PID/tagged bundle/CLI/socket. 80s active, 89s hard exit.
Synthetic facts are setup; actual Accessibility keys/buttons drive the view.
"""
import argparse
import base64
import json
import os
import signal
import threading
import time
import uuid

from feed_attention_probe import FeedProbe


QUICK_AX = r'''
function run(args) {
    var p = Application('System Events').processes.whose({unixId: Number(args[0])})[0];
    if (!p.exists()) throw Error('Verified PID missing');
    function attr(e, key) { try { return e.attributes.byName(key).value(); } catch (_) { return null; } }
    var hits = [], click = args[1] || '';
    function walk(e, depth) {
        if (depth > 14) return;
        var id = attr(e, 'AXIdentifier') || '';
        if (String(id).indexOf('feed.quick.') === 0) {
            if (id === click) { e.click(); return; }
            hits.push({id: id, title: attr(e, 'AXTitle'), description: attr(e, 'AXDescription'),
                value: attr(e, 'AXValue'), selected: attr(e, 'AXSelected'),
                position: attr(e, 'AXPosition'), size: attr(e, 'AXSize')});
        }
        if (attr(e, 'AXRole') === 'AXTextArea') return;
        try { e.uiElements().forEach(function(c) { walk(c, depth + 1); }); } catch (_) {}
    }
    p.windows().forEach(function(w) { walk(w, 0); });
    return JSON.stringify(hits);
}
'''


class QuickProbe(FeedProbe):
    def keys(self, code, command=False):
        self.check(self.ui('foreground') == self.args.pid, 'Exact tagged PID foreground before keyboard action')
        action = 'key code %d%s' % (code, ' using {command down}' if command else '')
        script = 'tell application "System Events"\nset p to first process whose unix id is %d\n' \
                 'if not frontmost of p then error "Tagged PID not foreground"\ntell p to %s\nend tell' % (self.args.pid, action)
        self.run(['/usr/bin/osascript', '-e', script])

    def inspect(self, click=''):
        return json.loads(self.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', QUICK_AX,
                                   str(self.args.pid), click]).stdout)

    def shown(self):
        return any(e['id'] == 'feed.quick.filter.asks' for e in self.inspect())

    def open(self):
        self.ui('activate')
        self.keys(34, command=True) # Existing default Show Notifications, not a rebind.
        self.eventually(self.shown, 'Command-I did not open Feed')

    def dismiss(self):
        if not self.safe or not self.shown():
            return
        self.ui('activate')
        self.keys(53)
        self.eventually(lambda: not self.shown(), 'Escape did not dismiss Feed', seconds=2)
        self.report.setdefault('dismissals', []).append('PID-scoped Escape; Feed AX controls gone')

    def rows(self):
        return sorted([e for e in self.inspect() if e['id'].startswith('feed.quick.row.')], key=lambda e: e['position'][1])

    def geometry(self):
        items = {e['id']: e for e in self.inspect()}
        result = {key: {field: items[key][field] for field in ['position', 'size']}
                  for key in ['feed.quick.filter.asks', 'feed.quick.filter.turns', 'feed.quick.hint']}
        self.report.setdefault('geometry', []).append(result)
        return result

    def terminal_text(self, tab):
        result = self.rpc('tab.read_text', {'workspace_id': self.workspace, 'tab_id': tab})
        return result.get('text') or base64.b64decode(result.get('base64') or '').decode(errors='replace')

    def decline_settings(self, tab):
        self.ui('background')
        self.rpc('notification.create_for_tab', {'workspace_id': self.workspace, 'tab_id': tab,
                 'title': 'Synthetic setup', 'body': 'No permission changes'})
        self.ui('activate')
        end = time.monotonic() + 3
        while time.monotonic() < end:
            if any(w['sheets'] for w in self.ui('dialogs')['windows']):
                script = '''tell application "System Events"
set p to first process whose unix id is %d
set s to sheet 1 of window 1 of p
if name of button 1 of s is not "Open Settings" then error "Wrong sheet"
if name of button 2 of s is not "Not Now" then error "Wrong sheet"
set promptText to value of every static text of s
if promptText does not contain "Turn on notifications for c11" and promptText does not contain "Enable Notifications for c11" then error "Wrong title"
click button "Not Now" of s
return promptText
end tell''' % self.args.pid
                self.run(['/usr/bin/osascript', '-e', script])
                self.eventually(lambda: not any(w['sheets'] for w in self.ui('dialogs')['windows']), 'Settings sheet stayed open')
                self.report['settings_precondition'] = 'Verified c11-owned settings sheet declined Not Now; permissions unchanged'
                break
            time.sleep(0.1)
        self.rpc('notification.clear')

    def execute(self):
        self.preflight()
        self.workspace = self.rpc('workspace.create')['workspace_id']
        self.rpc('workspace.rename', {'workspace_id': self.workspace,
                 'title': 'Synthetic long workspace 日本語 한국어 中文 Українська Русский ' * 8})
        anchor = self.rpc('tab.list', {'workspace_id': self.workspace})['tabs'][0]['id']
        older, newer, flagged, turn, inserted = [self.rpc('tab.create', {'workspace_id': self.workspace,
            'type': 'terminal', 'focus': False})['tab_id'] for _ in range(5)]
        self.rpc('workspace.select', {'workspace_id': self.workspace})
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': anchor})
        self.decline_settings(turn)
        self.open()
        empty_geometry = self.geometry()
        self.check(not self.rows(), 'Empty Feed has no rows')
        self.screenshot('01-empty-quick-view')
        self.dismiss()
        drafts = {}

        def append(tab, kind='agent.question.requested', prompt=None):
            session = str(uuid.uuid4())
            self.rpc('conversation.push', {'tab_id': tab, 'kind': 'claude-code', 'id': session, 'source': 'hook', 'state': 'alive'})
            draft = dict(schema_version=1, event_id=str(uuid.uuid4()), kind=kind, emitted_at_ms=int(time.time() * 1000),
                tab_id=tab, workspace_id=self.workspace, session_id=session, agent_kind='claude-code', source='hook',
                adapter='claude_hook', native_event='Stop' if kind == 'agent.turn.completed' else 'PreToolUse')
            if kind != 'agent.turn.completed': draft['request_id'] = 'synthetic-' + tab
            drafts[tab] = draft
            receipt = self.rpc('agent.event.append', {'event': draft})
            if prompt is not None:
                self.rpc('feed.note_display', {'workspace_id': self.workspace, 'tab_id': tab, 'agent_kind': 'claude-code',
                    'session_id': session, 'event_id': receipt['event_id'], 'request_id': draft['request_id'], 'prompt': prompt})

        append(older, prompt='Short synthetic prompt')
        append(newer, prompt='Synthetic long multiline prompt\n' * 50)
        append(flagged) # Missing prompt plus suppressed flag/ask still eligible.
        self.rpc('flag.suppress', {'tab_id': flagged, 'by': 'operator'})
        self.rpc('flag.raise', {'tab_id': flagged, 'reason': 'Synthetic priority flag', 'by': 'operator'})
        append(turn, kind='agent.turn.completed')
        self.open()
        self.eventually(lambda: len(self.rows()) == 3, 'Live Feed rows missing')
        self.check([e['id'].split('.')[-1] for e in self.rows()] == [flagged, older, newer], 'Visible order matches shared Feed prefix')
        self.check(self.geometry() == empty_geometry, 'Empty/populated filters and hint retain exact frames')
        self.check(all(e['size'][1] == 64 for e in self.rows()), 'Short/multiline/missing row targets all 64pt')
        self.screenshot('02-populated-quick-view')
        before_text = {tab: self.terminal_text(tab) for tab in [anchor, older, newer, flagged, turn]}
        self.keys(125)
        self.keys(36)
        self.eventually(lambda: self.rpc('system.identify')['focused'].get('tab_id') == older, 'Enter failed exact selected ask')
        self.eventually(lambda: not self.shown(), 'Enter failed dismissal')
        self.check(all(self.terminal_text(tab) == text for tab, text in before_text.items()), 'Navigation/Enter sent no PTY reply or approval')
        self.open()
        self.keys(125) # Oldest ask selected.
        self.rpc('flag.raise', {'tab_id': inserted, 'reason': 'Synthetic newly inserted flag', 'by': 'operator'})
        self.eventually(lambda: len(self.rows()) == 4, 'Inserted row not visible')
        self.keys(36)
        self.eventually(lambda: self.rpc('system.identify')['focused'].get('tab_id') == older, 'Insertion changed selected UUID')
        self.open()
        self.keys(125)
        self.keys(125) # Older ask after two flags.
        self.rpc('agent.event.append', {'event': dict(drafts[older], event_id=str(uuid.uuid4()),
            kind='agent.attention.resolved', resolution='resumed', native_event='PostToolUse')})
        self.eventually(lambda: len(self.rows()) == 3, 'Removed ask stayed visible')
        self.check(self.rpc('system.identify')['focused'].get('tab_id') == older, 'Removal chose neighbor without activating it')
        self.keys(36)
        self.eventually(lambda: self.rpc('system.identify')['focused'].get('tab_id') == newer, 'Removed selection did not choose defined neighbor')
        self.open()
        selection = self.rpc('system.identify')['focused']
        self.keys(48) # Tab: keyboard-first filter switch (Asks -> Turns); the Asks return below uses the pointer.
        self.eventually(lambda: [e['id'].split('.')[-1] for e in self.rows()] == [turn], 'Turns filter missing finished turn')
        self.check(self.geometry() == empty_geometry, 'Turns filter (via Tab) retains exact control frames')
        self.check(self.rpc('system.identify')['focused'] == selection, 'Filter change never opens a tab')
        self.screenshot('03-turns-filter')
        self.inspect('feed.quick.filter.asks')
        self.eventually(lambda: len(self.rows()) == 3, 'Asks filter failed return')
        self.rpc('tab.close', {'workspace_id': self.workspace, 'tab_id': flagged}) # Selected first flag closes.
        self.eventually(lambda: any('unavailable' in str(e).lower() for e in self.inspect() if e['id'] == 'feed.quick.status'),
                        'Closed target unavailable status missing')
        self.check(self.rpc('system.identify')['focused'] == selection, 'Closed target never redirects current selection')
        self.check(self.geometry() == empty_geometry, 'Unavailable status retains exact control frames')
        self.screenshot('04-closed-target-unavailable')
        self.dismiss()
        self.eventually(lambda: self.rpc('debug.terminal.is_focused', {'tab_id': newer}).get('focused'), 'Escape did not restore originating terminal responder')
        self.report['tree_no_layout'] = self.run([self.args.cli, '--socket', self.args.socket, 'tree', '--no-layout']).stdout
        self.check('split=none' in self.report['tree_no_layout'], 'Readable unsplit destination inspected')
        self.screenshot('05-dismissed-origin-focus')
        self.report['fixture'] = 'Synthetic structural facts; actual packaged GUI keys/buttons; no provider-native emission claim'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ['run-id', 'pid', 'app', 'cli', 'socket']:
        parser.add_argument('--' + field, required=True, type=int if field == 'pid' else str)
    parser.add_argument('--output-name', default='quick-view-probe')
    args = parser.parse_args()
    args.inspect_dialogs_only = False
    probe = QuickProbe(args)
    def expire(_signal, _frame): raise TimeoutError('80-second active phase expired')
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


if __name__ == '__main__': raise SystemExit(main())
