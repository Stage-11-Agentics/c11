#!/usr/bin/env python3
"""Packaged keyboard proof for the Feed quick view without the System Events UI-tree walk.

Same safety envelope as feed_quick_view_probe.py (exact PID/bundle/socket, one verified guest display,
80 s active / 89 s hard limits, PID-scoped keys). Selection and outcomes are asserted through socket
state (system.identify, debug.terminal.is_focused); the rendered popover is captured as screenshots
for visual inspection. Synthetic facts only; no provider-native claim.
"""
import argparse
import json
import os
import signal
import threading
import time
import uuid

from feed_quick_view_probe import QuickProbe

TAB, DOWN, UP, RETURN, ESC, KEY_I = 48, 125, 126, 36, 53, 34


class KeyboardProbe(QuickProbe):
    def shown(self):
        # The popover is a second visible window of the tagged PID; no UI-tree walk needed.
        return len(self.ui('displays')['windows']) > 1

    def pause(self, seconds=0.5):
        time.sleep(seconds)

    def press(self, code, command=False):
        self.keys(code, command=command)
        self.pause()

    def focused(self):
        return self.rpc('system.identify')['focused'].get('tab_id')

    def open_view(self):
        self.ui('activate')
        self.press(KEY_I, command=True)  # Existing default Show Notifications, not a rebind.
        self.pause(0.8)

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
        self.pause(0.5)
        self.safe = True
        self.open_view()
        self.screenshot('01-empty-quick-view')
        self.press(ESC)
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
        append(newer, prompt='Synthetic multiline prompt\n' * 8)
        append(flagged)  # Missing prompt plus suppressed flag/ask still eligible.
        self.rpc('flag.suppress', {'tab_id': flagged, 'by': 'operator'})
        self.rpc('flag.raise', {'tab_id': flagged, 'reason': 'Synthetic priority flag', 'by': 'operator'})
        append(turn, kind='agent.turn.completed')
        self.pause(0.8)
        before = self.focused()

        # 1. Down moves selection; Return opens the exact selected tab (order: flagged, older, newer).
        self.open_view()
        self.screenshot('02-populated-first-selected')
        self.press(DOWN)
        self.screenshot('03-down-selects-second')
        self.check(self.focused() == before, 'Navigation alone never activates a tab')
        self.press(RETURN)
        self.eventually(lambda: self.focused() == older, 'Return did not open the exact selected ask')
        self.screenshot('04-return-opened-exact-tab')

        # 2. Live inserted flag preserves the selected UUID.
        self.open_view()
        self.press(DOWN); self.press(DOWN)  # Now on `older`... then flagged,older,newer -> index 2 is newer.
        self.rpc('flag.raise', {'tab_id': inserted, 'reason': 'Synthetic newly inserted flag', 'by': 'operator'})
        self.pause(0.8)
        self.screenshot('05-flag-inserted-selection-kept')
        self.press(RETURN)
        self.eventually(lambda: self.focused() == newer, 'Insertion changed the selected UUID')

        # 3. Removing the selected ask picks a defined neighbour without activating it.
        self.open_view()
        self.press(DOWN); self.press(DOWN)  # flagged, inserted, older, newer -> older
        self.rpc('agent.event.append', {'event': dict(drafts[older], event_id=str(uuid.uuid4()),
            kind='agent.attention.resolved', resolution='resumed', native_event='PostToolUse')})
        self.pause(0.8)
        self.screenshot('06-selected-ask-removed-neighbour')
        self.check(self.focused() == newer, 'Removal never activated the neighbour')
        self.press(RETURN)
        self.eventually(lambda: self.focused() == newer, 'Neighbour selection did not open the exact ask')

        # 4. Tab switches filters from the keyboard and never opens a row.
        self.open_view()
        selection = self.focused()
        self.press(TAB)
        self.screenshot('07-tab-to-turns')
        self.check(self.focused() == selection, 'Filter switch via Tab never opens a tab')
        self.press(TAB)
        self.screenshot('08-tab-back-to-asks')
        self.press(TAB)
        self.press(RETURN)  # Return on the Turns row opens exactly that finished turn.
        self.eventually(lambda: self.focused() == turn, 'Return on Turns opened the wrong tab')
        self.screenshot('09-turns-return-opened-turn')

        # 5. Closed target: unavailable status, no redirect, Escape restores the originating responder.
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': newer})
        self.pause(0.5)
        origin = self.focused()
        self.open_view()
        self.rpc('tab.close', {'workspace_id': self.workspace, 'tab_id': flagged})  # Selected first row.
        self.pause(0.8)
        self.screenshot('10-closed-target-unavailable')
        self.check(self.focused() == origin, 'Closed target never redirects focus')
        self.press(ESC)
        self.pause(0.8)
        self.screenshot('11-escape-restored-origin')
        self.eventually(lambda: self.rpc('debug.terminal.is_focused', {'tab_id': newer}).get('focused'),
                        'Escape did not restore the originating terminal responder')
        self.report['tree_no_layout'] = self.run([self.args.cli, '--socket', self.args.socket, 'tree', '--no-layout']).stdout
        self.report['fixture'] = 'Synthetic structural facts; actual packaged GUI keys; screenshots inspected visually; no provider-native claim'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ['run-id', 'pid', 'app', 'cli', 'socket']:
        parser.add_argument('--' + field, required=True, type=int if field == 'pid' else str)
    parser.add_argument('--output-name', default='quick-view-keyboard-probe')
    args = parser.parse_args()
    args.inspect_dialogs_only = False
    probe = KeyboardProbe(args)
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
