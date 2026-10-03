#!/usr/bin/env python3
"""Packaged check that the Feed quick view's Return, an operator action, still switches workspaces.

C11-323 stops agents from changing the selected workspace; the operator's own jump paths must
still switch. Workspace A stays selected, a flagged tab sits in background workspace B, and the
real Command-I then Return (PID-scoped System Events keys) must land in B on that exact tab.
Same safety envelope as feed_quick_view_keyboard_probe.py. Synthetic facts only.
"""
import argparse
import json
import os
import signal
import threading

from feed_quick_view_keyboard_probe import KeyboardProbe, RETURN


class WorkspaceSwitchProbe(KeyboardProbe):
    def close_workspace(self):
        # Return left the new workspace selected; C11-323 refuses an agent close that would change the
        # operator's selection (workspace_switch_blocked). The disposable guest is deleted instead.
        self.report['cleanup_note'] = 'workspace left in place: socket close of the selected workspace is blocked by design'

    def execute(self):
        self.preflight()
        self.safe = True
        origin = self.rpc('workspace.current')['workspace_id']
        self.workspace = self.rpc('workspace.create')['workspace_id']  # Background: agents cannot select it.
        tab = self.rpc('tab.create', {'workspace_id': self.workspace, 'type': 'terminal', 'focus': False})['tab_id']
        self.check(self.rpc('workspace.current')['workspace_id'] == origin, 'Setup left the operator workspace selected')
        self.rpc('flag.raise', {'tab_id': tab, 'reason': 'Synthetic cross-workspace flag', 'by': 'operator'})
        self.pause(0.8)
        self.open_view()
        self.screenshot('01-quick-view-before-return')
        self.check(self.rpc('workspace.current')['workspace_id'] == origin, 'Opening the quick view never switches workspaces')
        self.press(RETURN)
        self.eventually(lambda: self.rpc('workspace.current')['workspace_id'] == self.workspace,
                        'Return did not switch to the tab\'s workspace')
        self.eventually(lambda: self.focused() == tab, 'Return did not focus the exact tab')
        self.screenshot('02-after-return-other-workspace')
        self.report['fixture'] = 'Synthetic; actual packaged Command-I and Return; operator action switches workspace'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ['run-id', 'pid', 'app', 'cli', 'socket']:
        parser.add_argument('--' + field, required=True, type=int if field == 'pid' else str)
    parser.add_argument('--output-name', default='quick-view-workspace-switch')
    args = parser.parse_args()
    args.inspect_dialogs_only = False
    probe = WorkspaceSwitchProbe(args)
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
