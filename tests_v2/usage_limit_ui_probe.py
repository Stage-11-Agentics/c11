#!/usr/bin/env python3
"""Replay recorded Claude limit records through a packaged app in an owned guest.

Requires an idle real Claude panel; no provider exhaustion is induced or claimed.
Uses the shared PID/display preflight, actual Command-I and Escape, 240s active
deadline and 250s hard exit. Socket facts seed only owner and hook edges; the
packaged transcript reader must produce the limit itself.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import threading
import time
import uuid

from feed_quick_view_probe import QuickProbe


HELP_AX = r'''
function run(args) {
    var p = Application('System Events').processes.whose({unixId: Number(args[0])})[0];
    if (!p.exists()) throw Error('Exact tagged PID missing');
    function attr(e,k) { try { return e.attributes.byName(k).value(); } catch (_) { return null; } }
    var hits = [];
    function walk(e,n) {
        if (n > 14) return;
        var role=attr(e,'AXRole');
        if (role === 'AXTextArea' || role === 'AXWebArea') return;
        var item={role:role,id:attr(e,'AXIdentifier'),help:attr(e,'AXHelp'),
            value:attr(e,'AXValue'),description:attr(e,'AXDescription')};
        if (JSON.stringify(item).indexOf(args[1]) >= 0) hits.push(item);
        try { e.uiElements().forEach(function(c) { walk(c,n+1); }); } catch (_) {}
    }
    p.windows().forEach(function(w) { walk(w,0); });
    return JSON.stringify(hits);
}
'''


class LimitProbe(QuickProbe):
    def __init__(self, args):
        super().__init__(args)
        self.deadline = self.started + 240

    def timeout(self):
        remaining = (self.started + 249 if self.cleanup_mode else self.deadline) - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Usage-limit probe deadline reached')
        return min(12, remaining)

    def close_workspace(self):
        # The guest owns the existing workspace. sandbox-down retires it.
        pass

    def metadata(self):
        return self.rpc('panel.get_metadata', {'panel_id': self.args.target})['metadata']

    def feed(self):
        return [r for r in self.rpc('feed.list', {'scope': 'attention'})['rows']
                if r['panel_id'].lower() == self.args.target.lower()]

    def hook(self, kind, turn):
        event = dict(schema_version=1, event_id=str(uuid.uuid4()), kind=kind,
            emitted_at_ms=int(time.time()*1000), tab_id=self.args.target,
            workspace_id=self.workspace, session_id=self.session, agent_kind='claude-code',
            source='hook', adapter='claude_hook', turn_id=turn,
            native_event='UserPromptSubmit' if kind == 'agent.turn.started' else 'Stop')
        result = self.rpc('agent.event.append', {'event': event})
        self.check(result['projection_effect'] == 'applied', kind + ' hook applied')

    def records(self, records):
        with self.transcript.open('a') as stream:
            for record in records:
                stream.write(json.dumps(record) + '\n')

    def stamp(self):
        return datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

    def root(self, turn):
        return dict(type='user', isSidechain=False, sessionId=self.session,
            promptId=turn, uuid='user-' + turn, timestamp=self.stamp(),
            message={'role': 'user', 'content': 'Synthetic guest replay prompt'})

    def recorded_limit(self, filename, turn):
        self.hook('agent.turn.started', turn)
        error = json.loads((Path(self.args.fixtures) / filename).read_text())
        error.update(sessionId=self.session, timestamp=self.stamp(), parentUuid='user-' + turn)
        records = [self.root(turn)]
        if error.get('quotaLimits'):
            records.append(dict(type='user', isSidechain=False, isMeta=True, turnCompanion=True,
                usageLimitNote='release', sessionId=self.session, promptId=turn, uuid='companion-' + turn))
            error['parentUuid'] = 'companion-' + turn
        self.records(records + [error])

    def visible_limit(self, kind, label, screenshot):
        started = time.monotonic()
        self.eventually(lambda: self.metadata().get('journal', {}).get('usage_limit') == kind,
                        'Packaged transcript sweep did not observe ' + kind, seconds=20)
        self.report.setdefault('detection_seconds', {})[kind] = round(time.monotonic() - started, 3)
        self.eventually(lambda: any(r.get('usage_limit') == kind and r.get('kind') == 'error'
                                   for r in self.feed()), 'Error Feed row missing')
        self.rpc('panel.focus', {'workspace_id': self.workspace, 'panel_id': self.args.target})
        help_hits = json.loads(self.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e',
            HELP_AX, str(self.args.pid), label]).stdout)
        self.report.setdefault('tooltip_accessibility', {})[kind] = help_hits
        if help_hits:
            self.check(True, 'Native mark accessibility contains ' + label)
        else:
            self.report.setdefault('unresolved', []).append('Native mark tooltip not exposed through AX: ' + label)
        self.open()
        self.eventually(lambda: any(label in str(r) for r in self.rows()), 'Native Feed label missing')
        self.report.setdefault('feed_accessibility', {})[kind] = self.rows()
        self.screenshot(screenshot)
        self.dismiss()

    def cli(self, panel, *args):
        return self.run(['/usr/bin/env', 'C11_PANEL_ID=' + panel,
            'C11_WORKSPACE_ID=' + self.workspace, self.args.cli, '--socket', self.args.socket,
            *args]).stdout.strip()

    def execute(self):
        self.preflight(read_only=True)
        # The real Claude launch may have left a completed-turn notification.
        # Clear only this verified disposable guest's routine history.
        self.rpc('notification.clear')
        self.preflight()
        self.workspace = self.args.workspace
        focused = self.rpc('system.identify')['focused']
        self.check(focused['workspace_id'].lower() == self.workspace.lower(), 'Replay uses already selected guest workspace')
        self.check(self.metadata().get('terminal_type') == 'claude-code', 'Real foreground Claude detected before replay')
        self.session = str(uuid.uuid4())
        self.transcript = Path.home() / '.claude/projects/-tmp' / (self.session + '.jsonl')
        self.transcript.parent.mkdir(parents=True, exist_ok=True)
        self.transcript.write_text('')
        self.rpc('conversation.push', {'tab_id': self.args.target, 'kind': 'claude-code',
            'id': self.session, 'source': 'hook', 'state': 'alive', 'cwd': '/tmp'})
        self.hook('agent.turn.started', 'quote')
        quote = json.loads((Path(self.args.fixtures) / 'claude-monthly-spend.json').read_text())
        quote.pop('isApiErrorMessage')
        quote['message']['model'] = 'claude-test-ordinary-output'
        quote.update(sessionId=self.session, timestamp=self.stamp(), parentUuid='user-quote')
        self.records([self.root('quote'), quote])
        # At least one normal ten-second sweep must read the ordinary output.
        until = time.monotonic() + 11
        while time.monotonic() < until:
            self.check(self.metadata().get('journal', {}).get('usage_limit') is None, 'Quoted output remains unclassified')
            time.sleep(1)
        self.hook('agent.turn.completed', 'quote')
        self.check(not self.feed(), 'Normal idle has no limit Feed row')
        self.screenshot('01-normal-idle')
        self.recorded_limit('claude-monthly-spend.json', 'monthly')
        self.visible_limit('monthly_spend', 'Monthly spend limit reached', '02-monthly-feed')
        sender = self.rpc('panel.create', {'workspace_id': self.workspace,
            'type': 'terminal', 'focus': False})['panel_id']
        body = 'Synthetic C11-500 envelope: keep unread until explicit claim.'
        envelope = self.cli(sender, 'mailbox', 'send', '--to', 'id:' + self.args.target, '--body', body)
        self.check(len(envelope) == 26, 'Exactly one mailbox envelope sent')
        inbox = Path(self.cli(self.args.target, 'mailbox', 'inbox-dir', '--panel', self.args.target))
        pending = self.eventually(lambda: list(inbox.glob(envelope + '.msg')), 'Envelope missing from recipient inbox')
        trace = self.cli(sender, '--json', 'mailbox', 'trace', envelope)
        trace_rows = [json.loads(line) for line in trace.splitlines()]
        self.check(any(r.get('recipient_usage_limit') == 'monthly_spend' for r in trace_rows),
                   'Sender trace exposes recipient limit')
        self.report['mail_before'] = dict(id=envelope, trace=trace_rows, pending=[p.name for p in pending])
        self.recorded_limit('claude-session-limit.json', 'session')
        self.visible_limit('session_usage', 'Session usage limit reached', '03-session-feed')
        self.check(all(p.exists() for p in pending), 'Same envelope remains unread across two limit states')
        received = self.cli(self.args.target, 'mailbox', 'recv', '--panel', self.args.target, '--ack')
        self.check(body in received and envelope in received, 'Explicit recv claims the envelope and body')
        self.check(not any(p.exists() for p in pending), 'Claim removes only pending copy')
        self.check(bool(list((inbox / '_read').glob(envelope + '.msg'))), 'Claim retains envelope in read history')
        self.check(not self.cli(self.args.target, 'mailbox', 'recv', '--panel', self.args.target, '--ack'),
                   'Second explicit claim returns no duplicate')
        self.hook('agent.turn.started', 'recovered')
        self.check(self.metadata().get('journal', {}).get('usage_limit') == 'session_usage', 'Retry start retains limit')
        self.hook('agent.turn.completed', 'recovered')
        self.eventually(lambda: self.metadata().get('journal', {}).get('usage_limit') is None and not self.feed(),
                        'Successful later turn did not clear limit')
        self.open()
        self.check(not self.rows(), 'Native Feed is empty after recovery')
        self.screenshot('04-recovered-feed')
        self.dismiss()
        self.report['tree_no_layout'] = self.cli(self.args.target, 'tree', '--no-layout')
        self.report['fixture'] = 'Recorded sanitized Claude errors replayed through real packaged transcript reader; synthetic owner/hook setup; actual native UI. Provider exhaustion not induced.'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ['run-id', 'pid', 'app', 'cli', 'socket', 'target', 'workspace', 'fixtures']:
        parser.add_argument('--' + field, required=True, type=int if field == 'pid' else str)
    parser.add_argument('--output-name', default='usage-limit-probe')
    args = parser.parse_args()
    args.inspect_dialogs_only = False
    for key in list(os.environ):
        if key.startswith(('C11_SOCKET', 'CMUX_SOCKET')):
            del os.environ[key]
    probe = LimitProbe(args)
    def expire(_signal, _frame):
        raise TimeoutError('240-second active phase expired')
    signal.signal(signal.SIGALRM, expire)
    signal.alarm(240)
    watchdog = threading.Timer(250, lambda: os._exit(124))
    watchdog.daemon = True
    watchdog.start()
    try:
        probe.execute()
        probe.report['result'] = 'PARTIAL' if probe.report.get('unresolved') else 'PASS'
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
