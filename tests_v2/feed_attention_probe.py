#!/usr/bin/env python3
"""Explicit C11-265 Atlas guest UI probe; not an automatic test_ suite.

Uses the C11-263 PID/display/screenshot/dismissal safety preflight. Run via
sandbox-exec with --run-id, --pid, --app, --cli, --socket. Active limit 80s.
Only synthetic journal facts are seeded; shortcuts and menu are actual UI.
"""
import argparse
import json
import os
import signal
import base64
import statistics
import threading
import time
import uuid

from attention_menu_bar_probe import Probe, JXA


class FeedProbe(Probe):
    def ui(self, operation, *args):
        if operation in ('jump-shortcut', 'type-burst'):
            if super().ui('foreground') != self.args.pid:
                raise RuntimeError('Exact tagged PID must be foreground for keyboard action')
            action = 'key code 36 using {command down, control down}' if operation == 'jump-shortcut' else \
                'keystroke "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
            script = 'tell application "System Events"\nset p to first process whose unix id is %d\n' \
                     'if not frontmost of p then error "Tagged PID is not foreground"\n' \
                     'tell p to %s\nend tell' % (self.args.pid, action)
            self.run(['/usr/bin/osascript', '-e', script])
            return {}
        result = self.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', JXA,
                           str(self.args.pid), operation, *args])
        return json.loads(result.stdout)

    def execute(self):
        self.preflight()
        if self.args.benchmark_only:
            return self.benchmark()
        self.workspace = self.rpc('workspace.create')['workspace_id']
        self.rpc('workspace.rename', {'workspace_id': self.workspace, 'title': 'Synthetic attention order'})
        anchor = self.rpc('tab.list', {'workspace_id': self.workspace})['tabs'][0]['id']
        tabs = [self.rpc('tab.create', {'workspace_id': self.workspace, 'type': 'terminal', 'focus': False})['tab_id'] for _ in range(4)]
        older, newer, flagged, completion = tabs
        self.rpc('workspace.select', {'workspace_id': self.workspace})
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': anchor})
        self.eventually(lambda: len(self.ui('inspect')['candidates']) == 1, 'Status extra unavailable')
        self.ui('background')
        self.ui('open')
        self.eventually(lambda: any('No flags · no open asks' in r['name'] for r in self.status()['rows']), 'Missing zero attention UI')
        self.screenshot('01-zero-attention')
        self.dismiss()
        drafts = {}

        def ask(tab):
            session = str(uuid.uuid4())
            self.rpc('conversation.push', {'tab_id': tab, 'kind': 'claude-code', 'id': session, 'source': 'hook', 'state': 'alive'})
            draft = dict(schema_version=1, event_id=str(uuid.uuid4()), kind='agent.question.requested',
                         emitted_at_ms=int(time.time() * 1000), tab_id=tab, workspace_id=self.workspace,
                         session_id=session, agent_kind='claude-code', source='hook', adapter='claude_hook',
                         native_event='PreToolUse', request_id='synthetic-' + tab)
            drafts[tab] = draft
            self.rpc('agent.event.append', {'event': draft})

        ask(older)
        time.sleep(0.02)
        ask(newer)
        time.sleep(0.02)
        ask(flagged)
        self.rpc('flag.suppress', {'tab_id': flagged, 'by': 'operator'})
        self.rpc('flag.raise', {'tab_id': flagged, 'reason': 'Synthetic priority decision', 'by': 'operator'})
        self.eventually(lambda: '1 flag · 3 open asks' in str(self.status()['help']), 'Live ask count not published')
        rows = self.rpc('feed.list')['rows']
        self.check([r['tab_id'] for r in rows] == [flagged, older, newer], 'Feed flags then oldest asks')
        self.ui('background')
        self.ui('open')
        self.check(any('1 flag · 3 open asks' in r['name'] for r in self.status()['rows']), 'Actual menu shows separate flag/ask counts')
        self.screenshot('02-flag-and-asks-menu')
        self.dismiss()

        def jump(tab, label):
            self.ui('activate')
            self.ui('jump-shortcut')
            self.eventually(lambda: self.rpc('system.identify')['focused'].get('tab_id') == tab, label)
            focused = self.rpc('system.identify')['focused']
            self.check(focused.get('workspace_id') == self.workspace, label + ' exact workspace/tab')

        jump(flagged, 'Configured shortcut chooses flag before older ask')
        self.rpc('flag.lower', {'tab_id': flagged, 'by': 'operator'})
        self.eventually(lambda: '0 flags · 2 open asks' in str(self.status()['help']), 'Suppressed lowered ask stayed eligible')
        closed = self.rpc('tab.create', {'workspace_id': self.workspace, 'type': 'terminal', 'focus': False})['tab_id']
        self.rpc('flag.raise', {'tab_id': closed, 'reason': 'Synthetic closed target', 'by': 'operator'})
        self.rpc('tab.close', {'workspace_id': self.workspace, 'tab_id': closed})
        before_failed_open = self.rpc('system.identify')['focused']
        try:
            self.rpc('feed.open', {'workspace_id': self.workspace, 'tab_id': closed})
            raise AssertionError('Closed Feed target unexpectedly opened')
        except RuntimeError as error:
            self.check('unavailable' in str(error), 'Closed Feed target returns unavailable')
        self.check(self.rpc('system.identify')['focused'] == before_failed_open, 'Closed Feed target never redirects selection')
        jump(older, 'Configured shortcut chooses oldest eligible ask')

        def resolve(tab):
            self.rpc('agent.event.append', {'event': dict(drafts[tab], event_id=str(uuid.uuid4()),
                kind='agent.attention.resolved', resolution='resumed', native_event='PostToolUse')})
            self.eventually(lambda: not any(r['tab_id'] == tab for r in self.rpc('feed.list')['rows']), 'Resolved ask stayed in Feed')

        resolve(older)
        jump(newer, 'Configured shortcut continues to next ask')
        resolve(newer)
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': anchor})
        finder = self.ui('background')
        self.eventually(lambda: self.ui('foreground') == finder, 'Finder failed foreground')
        selection = self.rpc('system.identify')['focused']
        self.rpc('notification.create_for_tab', {'workspace_id': self.workspace, 'tab_id': completion,
            'title': 'Synthetic older completion', 'body': 'Synthetic unread tail'})
        self.rpc('notification.create_for_tab', {'workspace_id': self.workspace, 'tab_id': newer,
            'title': 'Synthetic newer completion', 'body': 'Synthetic unread tail'})
        self.rpc('flag.raise', {'tab_id': flagged, 'reason': 'Synthetic background decision', 'by': 'operator'})
        self.eventually(lambda: '1 flag · 1 open ask' in str(self.status()['help']), 'Background menu stale')
        self.check(self.ui('foreground') == finder, 'Feed/flag/notification updates never activate c11')
        self.check(self.rpc('system.identify')['focused'] == selection, 'Updates preserve in-app selection')
        self.rpc('flag.lower', {'tab_id': flagged, 'by': 'operator'})
        completion_session = str(uuid.uuid4())
        self.rpc('conversation.push', {'tab_id': completion, 'kind': 'claude-code', 'id': completion_session, 'source': 'hook', 'state': 'alive'})
        self.rpc('agent.event.append', {'event': dict(schema_version=1, event_id=str(uuid.uuid4()),
            kind='agent.turn.completed', emitted_at_ms=int(time.time() * 1000), tab_id=completion,
            workspace_id=self.workspace, session_id=completion_session, agent_kind='claude-code', source='hook',
            adapter='claude_hook', native_event='Stop')})
        self.eventually(lambda: not self.rpc('feed.list')['rows'], 'Suppressed ask remained in jump prefix')
        self.check(any(r['tab_id'] == completion and r['kind'] == 'turn_end' and r['blocking'] is False
                       for r in self.rpc('feed.list', {'scope': 'all'})['rows']), 'Finished turn is not a blocking ask')
        jump(completion, 'Completion-only unread tail remains reachable oldest first')
        self.eventually(lambda: all(n['is_read'] for n in self.rpc('notification.list')['notifications'] if n.get('tab_id') == completion),
                        'Successful unread-tail jump did not mark exact notification read')
        self.check(any(not n['is_read'] and n.get('tab_id') == newer for n in self.rpc('notification.list')['notifications']),
                   'Unread-tail jump leaves sibling unread untouched')
        jump(newer, 'Second unread completion remains reachable')
        self.screenshot('03-shortcut-completion-target')
        self.report['tree_no_layout'] = self.run([self.args.cli, '--socket', self.args.socket, 'tree', '--no-layout']).stdout
        self.check('area:' in self.report['tree_no_layout'], 'Readable unsplit topology inspected')
        self.report['fixture'] = 'Synthetic structural facts; no native provider emission claim'

    def benchmark(self):
        self.workspace = self.rpc('workspace.create')['workspace_id']
        anchor = self.rpc('tab.list', {'workspace_id': self.workspace})['tabs'][0]['id']
        worker = self.rpc('tab.create', {'workspace_id': self.workspace, 'type': 'terminal', 'focus': False})['tab_id']
        self.rpc('workspace.select', {'workspace_id': self.workspace})
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': anchor})
        session = str(uuid.uuid4())
        self.rpc('conversation.push', {'tab_id': worker, 'kind': 'claude-code', 'id': session, 'source': 'hook', 'state': 'alive'})
        self.eventually(lambda: self.status(), 'Extra unavailable for benchmark')
        times = []
        for index in range(40):
            start = time.monotonic()
            self.rpc('agent.event.append', {'event': dict(schema_version=1, event_id=str(uuid.uuid4()),
                kind='agent.question.requested', emitted_at_ms=int(time.time() * 1000), tab_id=worker,
                workspace_id=self.workspace, session_id=session, agent_kind='claude-code', source='hook',
                adapter='claude_hook', native_event='PreToolUse', request_id='synthetic-perf-' + str(index))})
            self.rpc('tab.list', {'workspace_id': self.workspace}) # Synchronous main-query latency proxy.
            times.append((time.monotonic() - start) * 1000)
        self.ui('activate')
        # Selection is a setup oracle, not proof of AppKit first-responder focus.
        # Click inside the verified tagged window's terminal before typing.
        window = self.report['display_enumeration']['windows'][0]['kCGWindowBounds']
        self.check(self.ui('foreground') == self.args.pid, 'Exact tagged PID foreground before terminal click')
        self.run(['/opt/homebrew/bin/cliclick', 'c:%d,%d' % (window['X'] + 550, window['Y'] + 200)])
        self.eventually(lambda: self.rpc('debug.terminal.is_focused', {'tab_id': anchor}).get('focused'),
                        'Actual terminal click did not establish first responder')
        time.sleep(0.2)
        started = time.monotonic()
        self.ui('type-burst')
        def echoed():
            result = self.rpc('tab.read_text', {'workspace_id': self.workspace, 'tab_id': anchor})
            text = result.get('text') or base64.b64decode(result.get('base64') or '').decode(errors='replace')
            return 'a' * 40 in text
        self.eventually(echoed, 'Real PID-targeted typing burst did not echo', seconds=3)
        self.report['benchmark'] = dict(updates=40, update_plus_main_query_median_ms=round(statistics.median(times), 3),
            update_plus_main_query_p95_ms=round(sorted(times)[37], 3),
            update_plus_main_query_max_ms=round(max(times), 3),
            typing_burst_to_observed_echo_ms=round((time.monotonic() - started) * 1000, 3),
            load=self.run(['/usr/bin/uptime']).stdout.strip(),
            scope='Small synthetic churn; main-query and typing-echo proxies, not fleet soak or keystroke-only latency')
        self.screenshot('benchmark-typed-echo')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--app', required=True)
    parser.add_argument('--cli', required=True)
    parser.add_argument('--socket', required=True)
    parser.add_argument('--output-name', default='feed-probe')
    parser.add_argument('--benchmark-only', action='store_true')
    args = parser.parse_args()
    args.inspect_dialogs_only = False
    probe = FeedProbe(args)
    def expire(_signal, _frame):
        raise TimeoutError('80-second active phase expired')
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


if __name__ == '__main__':
    raise SystemExit(main())
