#!/usr/bin/env python3
"""Explicit tagged guest UI proof for C11-273, with an 80-second active limit.

Run via sandbox-exec.sh with the same arguments as attention_menu_bar_probe.py.
Socket calls arrange synthetic state; real PID-targeted keys and AX menu clicks
exercise attention navigation. Public output contains only cropped windows and
check labels. Terminal prompts are neutralized before any screenshot.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time
import uuid

import attention_menu_bar_probe as base


EXTRA_JXA = r'''
    if (operation === 'unconfirmed-help') {
        var items = process.windows()[0].entireContents();
        var matches = [];
        items.forEach(function(item) {
            ['AXHelp', 'AXValue'].forEach(function(name) {
                try {
                    var value = String(item.attributes.byName(name).value());
                    if (value.indexOf('Unconfirmed') >= 0) matches.push(value);
                } catch (_) {}
            });
        });
        return JSON.stringify(matches);
    }
    if (operation === 'jump-key') {
        var down = $.CGEventCreateKeyboardEvent(null, 9, true);
        var up = $.CGEventCreateKeyboardEvent(null, 9, false);
        $.CGEventSetFlags(down, 0x80000); $.CGEventSetFlags(up, 0x80000);
        $.CGEventPostToPid(pid, down); $.CGEventPostToPid(pid, up);
        return '{}';
    }
    if (operation === 'notifications-menu' || operation === 'jump-menu') {
        var item = process.menuBars()[0].menuBarItems.byName('Notifications');
        item.click();
        var rows = item.menus()[0].menuItems();
        var jump = rows.filter(function(row) { return row.name() === 'Jump to Latest Unread'; });
        if (jump.length !== 1) throw new Error('Exact Jump row missing');
        var enabled = jump[0].enabled();
        if (operation === 'jump-menu') {
            if (!enabled) throw new Error('Journal-only Jump is disabled');
            jump[0].click();
        }
        return JSON.stringify({enabled: enabled});
    }
'''
base.JXA = base.JXA.replace('    var bars = process.menuBars()', EXTRA_JXA + '\n    var bars = process.menuBars()')


class JournalProbe(base.Probe):
    def screenshot(self, label):
        # Window-only capture is already a crop to the verified app, never the
        # desktop or another application's windows.
        path = self.output / (label + '.png')
        self.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(self.window_id), str(path)])
        self.check(path.is_file(), label + ' window crop captured')
        self.report['screenshots'].append(path.name)

    def execute(self):
        self.preflight()
        self.workspace = self.rpc('workspace.create', {'working_directory': '/tmp',
            'initial_command': "/usr/bin/env PS1='$ ' /bin/zsh -f"})['workspace_id']
        self.rpc('workspace.rename', {'workspace_id': self.workspace, 'title': 'Journal proof'})
        target = self.rpc('tab.list', {'workspace_id': self.workspace})['tabs'][0]['id']
        sibling = self.rpc('tab.create', {'workspace_id': self.workspace, 'type': 'terminal'})['tab_id']
        self.rpc('workspace.select', {'workspace_id': self.workspace})
        for tab, title in ((target, 'Blocked agent'), (sibling, 'Control terminal')):
            self.rpc('tab.set_metadata', {'tab_id': tab, 'metadata': {'title': title}})
            self.rpc('tab.send_text', {'tab_id': tab,
                'text': "unset precmd_functions; PROMPT='$ '; RPROMPT=''; printf '\\033[2J\\033[H'\n"})
        time.sleep(.5)
        owner = str(uuid.uuid4())
        self.rpc('conversation.push', {'tab_id': target, 'kind': 'claude-code', 'id': owner, 'source': 'hook'})
        draft = dict(schema_version=1, event_id=str(uuid.uuid4()), kind='agent.question.requested',
                     emitted_at_ms=int(time.time() * 1000), tab_id=target, workspace_id=self.workspace,
                     session_id=owner, agent_kind='claude-code', source='hook', adapter='claude_hook',
                     native_event='PreToolUse', request_id='synthetic-ui-ask')
        self.rpc('agent.event.append', {'event': draft})
        self.eventually(lambda: self.rpc('tab.get_metadata', {'tab_id': target})['metadata']['journal']['phase'] == 'blocked', 'blocked projection')
        self.check(not self.rpc('notification.list')['notifications'], 'Journal ask needs no routine unread notification')
        self.rpc('tab.focus', {'tab_id': sibling})
        self.ui('activate')
        self.screenshot('01-blocked-with-no-unread')
        self.check(self.ui('notifications-menu')['enabled'], 'Real menu enables Jump for journal-only attention')
        self.screenshot('02-journal-jump-menu')
        self.dismiss()
        self.ui('jump-key')
        self.eventually(lambda: self.rpc('system.identify')['focused']['tab_id'] == target, 'Option-V selects blocked target')
        self.check(self.rpc('tab.get_metadata', {'tab_id': target})['metadata']['journal']['phase'] == 'blocked', 'Seeing target does not resolve its ask')
        self.screenshot('03-seen-still-blocked')
        params = {'workspace_id': self.workspace, 'tab_id': target, 'by': 'operator'}
        self.rpc('flag.suppress', params)
        self.rpc('tab.focus', {'tab_id': sibling})
        self.ui('jump-key')
        time.sleep(.2)
        self.check(self.rpc('system.identify')['focused']['tab_id'] == sibling, 'Suppressed ask is excluded from Option-V')
        self.rpc('flag.raise', dict(params, reason='Synthetic decision'))
        self.ui('jump-key')
        self.eventually(lambda: self.rpc('system.identify')['focused']['tab_id'] == target, 'Flag overrides suppression')
        self.check(True, 'Operator flag retains precedence over journal suppression')
        self.screenshot('04-flag-precedence')
        self.rpc('flag.lower', params)
        self.rpc('flag.unsuppress', params)
        self.rpc('tab.focus', {'tab_id': sibling})
        self.ui('jump-menu')
        self.eventually(lambda: self.rpc('system.identify')['focused']['tab_id'] == target, 'Actual Jump menu selects target')
        self.check(True, 'Actual Jump menu click selects the journal target')
        self.dismiss()
        topology = self.run([self.args.cli, '--socket', self.args.socket, 'tree', '--no-layout']).stdout
        self.check('Blocked agent' in topology and 'Control terminal' in topology, 'Both named tabs remain present in workspace topology')
        self.screenshot('05-dismissed-and-readable')
        self.rpc('session.save', {'include_scrollback': False})
        os.kill(self.args.pid, signal.SIGKILL)
        time.sleep(.3)
        Path(self.args.socket).unlink(missing_ok=True)
        env = {key: os.environ[key] for key in ('HOME', 'USER', 'LOGNAME', 'PATH', 'TMPDIR') if key in os.environ}
        env.update(C11_SOCKET_MODE='automation', C11_ALLOW_SOCKET_OVERRIDE='1',
            C11_SOCKET=self.args.socket, C11_SOCKET_PATH=self.args.socket, C11_QA_LAUNCH='resume',
            CMUXD_UNIX_PATH='/tmp/c11-sandbox-journal-ui-daemon.sock')
        with open('/tmp/c11-sandbox-journal-ui.stdout', 'wb') as output:
            process = subprocess.Popen([str(Path(self.args.app) / 'Contents/MacOS/c11')],
                env=env, stdout=output, stderr=output, start_new_session=True)
        self.args.pid = process.pid
        self.eventually(lambda: Path(self.args.socket).is_socket(), 'Replay UI socket')
        self.eventually(lambda: self.rpc('tab.get_metadata', {'tab_id': target})['metadata']['journal']['confirmation'] == 'unconfirmed', 'Unconfirmed restored ask')
        self.ui('activate')
        windows = self.ui('displays')['windows']
        self.check(len(windows) == 1, 'Restored tagged window is uniquely identified on the guest display')
        self.window_id = windows[0]['kCGWindowNumber']
        for tab in (target, sibling):
            self.rpc('tab.send_text', {'tab_id': tab,
                'text': "unset precmd_functions; PROMPT='$ '; RPROMPT=''; printf '\\033[2J\\033[H'\n"})
        self.rpc('tab.focus', {'tab_id': target})
        self.eventually(lambda: bool(self.ui('unconfirmed-help')), 'Actual accessibility help exposes Unconfirmed')
        self.check(True, 'Restored waiting mark exposes Unconfirmed in actual UI accessibility help')
        self.screenshot('06-restored-unconfirmed')
        self.dismiss()

    def cleanup(self):
        super().cleanup()
        # The shared base report contains process/window identity for local
        # diagnosis. Only this allowlist is published as journal evidence.
        safe = {key: self.report[key] for key in ('result', 'checks', 'screenshots', 'elapsed_seconds') if key in self.report}
        safe['cleanup_ok'] = not self.report.get('cleanup_errors')
        if self.output:
            (self.output / 'report.json').write_text(json.dumps(safe, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('run-id', 'app', 'cli', 'socket'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--output-name', default='journal-ui')
    args = parser.parse_args()
    args.inspect_dialogs_only = False
    probe = JournalProbe(args)
    def expire(*_):
        raise TimeoutError('UI proof exceeded active time limit')
    signal.signal(signal.SIGALRM, expire)
    signal.alarm(80)
    watchdog = threading.Timer(89, lambda: os._exit(124)); watchdog.daemon = True; watchdog.start()
    try:
        probe.execute()
        probe.report['result'] = 'PASS'
    except Exception:
        probe.report['result'] = 'FAIL'
        raise
    finally:
        signal.alarm(0)
        probe.cleanup()
        watchdog.cancel()
    print('PASS journal attention UI, suppression, flag precedence and synthesized dismissal')


if __name__ == '__main__':
    main()
