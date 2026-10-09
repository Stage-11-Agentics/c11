#!/usr/bin/env python3
"""Offline behavioral checks through a built, real c11 CLI. No app or socket needed.

C11_CLI=/path/to/tagged.app/Contents/Resources/bin/c11 python3 tests/test_cli_activity_analysis.py
All inputs are synthetic and confined to a system temporary directory.
"""
import json
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import re
import tempfile
import unittest


class ActivityCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='c11-activity-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        self.claude = self.root / 'claude'
        self.codex = self.root / 'codex'
        for path in (self.state / 'events', self.claude, self.codex):
            path.mkdir(parents=True)
        self.journal = self.root / 'lifecycle.sqlite3'
        with closing(sqlite3.connect(self.journal)) as db, db:
            db.execute('CREATE TABLE journal_events(tab_id TEXT,session_id TEXT,agent_kind TEXT,workspace_id TEXT,committed_at_ms INTEGER NOT NULL DEFAULT 0)')
        self.zone = 'UTC'
        self.cli = os.environ.get('C11_CLI_BIN', os.environ.get('C11_CLI', 'c11'))

    def run_cli(self, command, *args, ok=True):
        proc = subprocess.run([self.cli, '--socket', str(self.root / 'absent.sock'), command,
                               '--state-root', str(self.state), '--claude-root', str(self.claude),
                               '--codex-root', str(self.codex), '--journal', str(self.journal), *args],
                              capture_output=True, text=True, timeout=20, env={**os.environ, 'TZ': self.zone})
        self.assertEqual(proc.returncode == 0, ok, proc.stderr + proc.stdout)
        return json.loads(proc.stdout) if ok and ('--json' in args or 'json' in args) else proc.stdout

    def write(self, path, rows):
        path.write_text(''.join(json.dumps(row) + '\n' for row in rows))

    def link(self, panel, session, kind, workspace='workspace-a', committed_at_ms=0):
        with closing(sqlite3.connect(self.journal)) as db, db:
            db.execute('INSERT INTO journal_events VALUES(?,?,?,?,?)', (panel, session, kind, workspace, committed_at_ms))

    def claude_row(self, msg='message-a', request='request-a', session='session-a', output=10, **usage):
        return {'type': 'assistant', 'timestamp': '2026-01-02T01:00:00Z', 'sessionId': session,
                'requestId': request, 'message': {'id': msg, 'model': 'test-model',
                'usage': {'input_tokens': 100, 'output_tokens': output, **usage}}}

    def test_claude_dedup_request_and_final_snapshot(self):
        rows = [self.claude_row(output=1), self.claude_row(output=10), self.claude_row(output=10),
                self.claude_row(request='request-b', output=20)]
        self.write(self.claude / 'session-a.jsonl', rows)
        self.write(self.claude / 'duplicate.jsonl', rows)
        self.link('panel-a', 'session-a', 'claude-code')
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['totals']['input_tokens'], 200)
        self.assertEqual(result['totals']['output_tokens'], 30)
        self.assertEqual(result['totals']['calls'], 2)
        self.assertEqual(result['groups'][0]['key'], 'panel-a')
        self.assertEqual(result['unattributed']['total_tokens'], 0)
        self.assertIsNone(result['groups'][0]['estimated_api_usd'])

    def test_unknown_identity_does_not_collapse_requests(self):
        self.write(self.claude / 'session-a.jsonl', [self.claude_row(msg=None), self.claude_row(msg=None)])
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['calls'], 2)
        self.assertIn('claude_dedup_identity_missing', result['coverage_gaps'])
        self.assertEqual(result['unattributed']['total_tokens'], result['totals']['total_tokens'])

    def test_ambiguous_session_remains_unattributed(self):
        self.write(self.claude / 'session-a.jsonl', [self.claude_row()])
        self.link('panel-a', 'session-a', 'claude-code')
        self.link('panel-b', 'session-a', 'claude-code')
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['groups'][0]['key'], 'unattributed')
        self.assertEqual(result['unattributed']['total_tokens'], 110)
        self.assertIn('ambiguous_session_attribution', result['coverage_gaps'])

    def test_cache_ttl_is_preserved_and_prices_are_not_assumed(self):
        (self.state / 'model-costs.json').write_text(json.dumps({'test-model': {
            'in_usd': 2, 'out_usd': 10, 'cache_read_usd': .1,
            'cache_write_usd': 2.5, 'cache_write_1h_usd': 4}}))
        self.write(self.claude / 'session-a.jsonl', [self.claude_row(cache_read_input_tokens=200,
            cache_creation_input_tokens=70, cache_creation={
                'ephemeral_5m_input_tokens': 30, 'ephemeral_1h_input_tokens': 40})])
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['total_tokens'], 380)
        self.assertAlmostEqual(result['groups'][0]['estimated_api_usd'], .000555)
        self.write(self.claude / 'session-a.jsonl', [self.claude_row(cache_creation_input_tokens=70)])
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['cache_write_unknown_ttl_tokens'], 70)
        self.assertIsNone(result['groups'][0]['estimated_api_usd'])

    def test_codex_cumulative_deltas_since_and_reset(self):
        def usage(ts, i, cached, out, last=None):
            return {'type': 'event_msg', 'timestamp': ts, 'payload': {'type': 'token_count', 'info': {
                'total_token_usage': {'input_tokens': i, 'cached_input_tokens': cached,
                                      'output_tokens': out, 'reasoning_output_tokens': out // 2},
                'last_token_usage': last or {}}}}
        rows = [{'type': 'session_meta', 'payload': {'id': 'codex-a'}},
                {'type': 'turn_context', 'payload': {'model': 'test-model'}},
                usage('2026-01-01T00:00:00Z', 100, 30, 20),
                usage('2026-01-02T00:00:00Z', 150, 40, 30),
                usage('2026-01-02T00:00:01Z', 150, 40, 30),
                usage('2026-01-02T00:01:00Z', 10, 2, 4,
                      {'input_tokens': 10, 'cached_input_tokens': 2, 'output_tokens': 4})]
        self.write(self.codex / 'rollout.jsonl', rows)
        self.write(self.codex / 'copy.jsonl', rows)
        self.link('panel-c', 'codex-a', 'codex')
        result = self.run_cli('usage', '--since', '2026-01-02T00:00:00Z', '--by', 'panel', '--json')
        self.assertEqual(result['totals']['input_tokens'], 48)
        self.assertEqual(result['totals']['cache_read_tokens'], 12)
        self.assertEqual(result['totals']['output_tokens'], 14)
        self.assertEqual(result['totals']['calls'], 2)
        self.assertEqual(result['groups'][0]['key'], 'panel-c')
        self.assertIn('codex_counter_reset_last_usage_only', result['coverage_gaps'])

    def events(self, gap=False, presence=True):
        rows = []
        def add(ts, kind, payload=None, panel=None, workspace=None):
            rows.append({'v': 2, 'instance': 'synthetic', 'seq': len(rows) + 1, 'ts': ts,
                         'type': kind, 'payload': payload or {}, 'panel': panel, 'workspace': workspace})
        add('2026-01-02T00:00:00Z', 'log.opened', {'app_active': True, 'screen_locked': False, 'system_asleep': False} if presence else {})
        add('2026-01-02T00:00:00Z', 'workspace.created', {'title': 'Test workspace'}, workspace='workspace-a')
        add('2026-01-02T00:00:00Z', 'panel.created', {'kind': 'terminal'}, panel='panel-a', workspace='workspace-a')
        add('2026-01-02T00:00:00Z', 'liveness.derived', {'state': 'working'}, panel='panel-a')
        add('2026-01-02T00:30:00Z', 'hang.precursor')
        add('2026-01-02T01:00:00Z', 'panel.closed', panel='panel-a')
        add('2026-01-02T01:00:00Z', 'workspace.closed', {'title': 'Test workspace'}, workspace='workspace-a')
        if gap:
            rows[4]['seq'] += 1
            for row in rows[5:]: row['seq'] += 1
        self.write(self.state / 'events/events-synthetic.ndjson', rows)

    def test_report_replays_rotation_foreground_lifetime_and_load(self):
        self.events()
        path = self.state / 'events/events-synthetic.ndjson'
        lines = path.read_text().splitlines()
        Path(str(path) + '.1').write_text('\n'.join(lines[:4]) + '\n')
        path.write_text('\n'.join(lines[4:]) + '\n')
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['panels_created'], 1)
        self.assertEqual(result['peak_open_per_instance'], 1)
        self.assertEqual(result['open_at_observed_end'], 0)
        self.assertEqual(result['foreground_hours'], 1)
        self.assertEqual(result['observed_agent_hours'], 1)
        self.assertEqual(result['closed_lifetimes_minutes']['median'], 60)
        self.assertEqual(result['workspaces'][0]['name'], 'Test workspace')
        self.assertEqual(result['hang_rate_by_working_load'][0]['hangs_per_hour'], 1)
        self.assertEqual(result['hang_rate_by_open_load'][0]['hangs_per_hour'], 1)
        markdown = self.run_cli('report', '--instance', 'synthetic', '--format', 'md')
        self.assertIn('Test workspace', markdown)
        self.assertIn('Daily activity', markdown)

    def bootstrap_events(self, late_marker=False, analytics_off=False):
        rows = []
        def add(minute, event_type, workspace=None, panel=None, **payload):
            rows.append({'v': 2, 'instance': 'synthetic', 'seq': len(rows) + 1,
                'ts': '2026-01-02T%02d:%02d:00Z' % divmod(minute, 60),
                'type': event_type, 'workspace': workspace, 'panel': panel, 'payload': payload})
        add(0, 'log.opened', app_active=True, screen_locked=False, system_asleep=False)
        if analytics_off:
            add(0, 'log.policy', enabled=True, analytics_enabled=False)
        else:
            add(0, 'workspace.created', 'bootstrap', title='Transient graph', **({} if late_marker else {'transient': True}))
        add(0, 'panel.created', 'bootstrap', 'bootstrap-panel', kind='browser', **({} if late_marker else {'transient': True}))
        add(0, 'liveness.derived', 'bootstrap', 'bootstrap-panel', state='working', **({} if late_marker else {'transient': True}))
        add(0, 'workspace.selected', 'bootstrap', **({} if late_marker else {'transient': True}))
        add(0, 'workspace.created', 'installed', title='Installed graph')
        add(0, 'panel.created', 'installed', 'installed-panel', kind='terminal')
        add(0, 'liveness.derived', 'installed', 'installed-panel', state='working')
        add(0, 'workspace.selected', 'installed')
        for w, panel in [('bootstrap', 'bootstrap-panel'), ('installed', 'installed-panel')]:
            marker = {'transient': True} if w == 'bootstrap' and not late_marker else {}
            add(10, 'waiting.entered', w, panel, **marker)
            add(10, 'mailbox.accepted', w, **{'from': w}, **marker)
            add(10, 'mailbox.delivered', w, panel, **marker)
            add(10, 'flag.raised', w, panel, **marker)
        if late_marker:
            add(20, 'workspace.renamed', 'bootstrap', title='Transient graph', transient=True)
        add(30, 'hang.precursor', cause='main-thread', durations_ms=[10], count=1)
        add(60, 'panel.closed', 'installed', 'installed-panel')
        add(60, 'panel.closed', 'bootstrap', 'bootstrap-panel', transient=True)
        self.write(self.state / 'events/events-synthetic.ndjson', rows)
        return rows

    def test_report_bootstrap_graphs_are_visible_but_excluded_from_installed_summaries(self):
        rows = self.bootstrap_events()
        self.write(self.claude / 'session-a.jsonl', [self.claude_row()])
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['bootstrap_graphs_excluded'], 1)
        self.assertEqual(result['bootstrap_events_excluded'], 9)
        self.assertEqual(result['raw_events_observed'], len(rows))
        self.assertEqual(result['bootstrap_event_types_excluded']['mailbox.accepted'], 1)
        self.assertEqual(result['panels_created'], 1)
        self.assertEqual(result['peak_open_per_instance'], 1)
        self.assertEqual(result['peak_working_per_instance'], 1)
        self.assertEqual(result['kinds_created'], {'terminal': 1})
        self.assertEqual(result['observed_agent_hours'], 1)
        self.assertEqual(result['foreground_hours'], 1)
        self.assertEqual(result['closed_lifetimes_minutes']['count'], 1)
        self.assertEqual(result['mailbox_accepted'], 1)
        self.assertEqual(result['mailbox_delivered'], 1)
        self.assertEqual(result['flag_events'], {'flag.raised': 1})
        self.assertEqual(result['hang_precursors'], 1)
        self.assertEqual(result['host_usage']['totals']['calls'], 1)
        self.assertEqual([w['id'] for w in result['workspaces']], ['installed'])
        self.assertEqual(result['workspaces'][0]['selected_dwell_hours'], 1)
        self.assertEqual(result['workspaces'][0]['waiting_entered'], 1)
        self.assertEqual(sum(d['events'] for d in result['daily']), len(rows) - 9)
        self.assertNotIn('event_sequence_gap', result['coverage_gaps'])
        markdown = self.run_cli('report', '--instance', 'synthetic', '--format', 'md')
        self.assertIn('Bootstrap workspace graphs excluded: 1; events excluded: 9', markdown)
        self.assertNotIn('Transient graph', markdown)

    def test_report_late_transient_marker_classifies_earlier_events(self):
        self.bootstrap_events(late_marker=True)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['peak_open_per_instance'], 1)
        self.assertEqual(result['panels_created'], 1)
        self.assertEqual(result['bootstrap_events_excluded'], 10)
        self.assertEqual(result['kinds_created'], {'terminal': 1})

    def test_report_truncated_transient_panel_marker_preserves_unknown_load(self):
        self.write(self.state / 'events/events-synthetic.ndjson', [
            {'v': 2, 'instance': 'synthetic', 'seq': 10, 'ts': '2026-01-02T00:00:00Z', 'type': 'panel.created',
             'workspace': 'bootstrap', 'panel': 'bootstrap-panel', 'payload': {'kind': 'browser', 'transient': True}},
            {'v': 2, 'instance': 'synthetic', 'seq': 11, 'ts': '2026-01-02T00:00:00Z', 'type': 'panel.created',
             'workspace': 'installed', 'panel': 'installed-panel', 'payload': {'kind': 'terminal'}},
            {'v': 2, 'instance': 'synthetic', 'seq': 12, 'ts': '2026-01-02T01:00:00Z', 'type': 'hang.precursor'},
            {'v': 2, 'instance': 'synthetic', 'seq': 13, 'ts': '2026-01-02T02:00:00Z', 'type': 'panel.closed',
             'workspace': 'installed', 'panel': 'installed-panel'}])
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['bootstrap_graphs_excluded'], 1)
        self.assertEqual(result['bootstrap_events_excluded'], 1)
        self.assertEqual(result['observed_peak_open_per_instance'], 1)
        self.assertIsNone(result['peak_open_per_instance'])
        self.assertEqual(result['kinds_created'], {'terminal': 1})
        self.assertEqual(result['hangs_with_unknown_load'], 1)
        self.assertEqual(result['load_unknown_hours'], 2)

    def test_report_analytics_off_transient_panels_and_strict_boolean_marker(self):
        rows = self.bootstrap_events(analytics_off=True)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['bootstrap_graphs_excluded'], 1)
        self.assertEqual(result['panels_created'], 1)
        self.assertEqual(result['hang_precursors'], 1)
        self.assertIsNone(result['foreground_hours'])
        for row in rows:
            if row['payload'].get('transient') is True:
                row['payload']['transient'] = 1
        self.write(self.state / 'events/events-synthetic.ndjson', rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['bootstrap_graphs_excluded'], 0)
        self.assertEqual(result['panels_created'], 2)

    def test_report_bootstrap_conflicting_installed_context_preserves_graph(self):
        for conflict in ['workspace.selected', 'panel.created']:
            with self.subTest(conflict=conflict):
                rows = self.bootstrap_events()
                rows.insert(-3, {'v': 2, 'instance': 'synthetic', 'ts': '2026-01-02T00:20:00Z',
                    'type': conflict, 'workspace': 'bootstrap' if conflict == 'workspace.selected' else 'installed',
                    'panel': None if conflict == 'workspace.selected' else 'bootstrap-panel',
                    'payload': {'kind': 'browser'}})
                for seq, row in enumerate(rows, 1):
                    row['seq'] = seq
                self.write(self.state / 'events/events-synthetic.ndjson', rows)
                result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
                self.assertIn('bootstrap_classification_conflict', result['coverage_gaps'])
                self.assertEqual(result['bootstrap_graphs_excluded'], 0)
                self.assertEqual(result['bootstrap_events_excluded'], 0)
                self.assertEqual(result['peak_open_per_instance'], 2)
                self.assertEqual(result['mailbox_accepted'], 2)
                self.assertEqual({w['id'] for w in result['workspaces']}, {'bootstrap', 'installed'})

    def test_report_bootstrap_ids_do_not_exclude_process_evidence(self):
        rows = self.bootstrap_events()
        additions = [
            (20, 'app.deactivated', {}),
            (25, 'instance.sample', {'rss_mb': 64}),
            (30, 'hang.precursor', {'cause': 'main-thread', 'durations_ms': [20], 'count': 1}),
            (40, 'log.retention', {'state': 'degraded'}),
            (50, 'app.activated', {})]
        for minute, event_type, payload in additions:
            rows.append({'v': 2, 'instance': 'synthetic', 'ts': '2026-01-02T00:%02d:00Z' % minute,
                'type': event_type, 'workspace': 'bootstrap', 'panel': 'bootstrap-panel',
                'payload': dict(payload, transient=True)})
        rows.sort(key=lambda row: row['ts'])
        for seq, row in enumerate(rows, 1):
            row['seq'] = seq
        self.write(self.state / 'events/events-synthetic.ndjson', rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['bootstrap_events_excluded'], 9)
        self.assertEqual(result['hang_precursors'], 2)
        self.assertAlmostEqual(result['foreground_hours'], 0.5)
        self.assertIn('retention_reconciliation_degraded', result['coverage_gaps'])
        self.assertNotIn('bootstrap_classification_conflict', result['coverage_gaps'])
        self.assertEqual([w['id'] for w in result['workspaces']], ['installed'])
        self.assertEqual(sum(d['events'] for d in result['daily']), len(rows) - 9)
        # A process event's marker cannot enroll an otherwise installed graph.
        for row in rows:
            if row['type'] not in {'app.deactivated', 'app.activated', 'instance.sample', 'hang.precursor', 'log.retention'}:
                row['payload'].pop('transient', None)
        self.write(self.state / 'events/events-synthetic.ndjson', rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['bootstrap_graphs_excluded'], 0)
        self.assertEqual(result['bootstrap_events_excluded'], 0)
        self.assertEqual(result['peak_open_per_instance'], 2)

    def test_report_missing_presence_and_sequence_gap_are_unknown(self):
        self.events(gap=True, presence=False)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertIsNone(result['foreground_hours'])
        self.assertIn('event_sequence_gap', result['coverage_gaps'])
        self.assertGreater(result['presence_unknown_hours'], 0)

    def test_report_usage_is_bounded_by_observed_span(self):
        self.events()
        before = self.claude_row(msg='before')
        before['timestamp'] = '2026-01-01T23:00:00Z'
        after = self.claude_row(msg='after')
        after['timestamp'] = '2026-01-02T02:00:00Z'
        self.write(self.claude / 'session-a.jsonl', [before, self.claude_row(), after])
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['host_usage']['totals']['calls'], 1)

    def test_since_replays_baseline_before_the_first_in_range_close(self):
        self.events()
        result = self.run_cli('report', '--instance', 'synthetic', '--since',
                              '2026-01-02T00:45:00Z', '--format', 'json')
        self.assertEqual(result['panels_created'], 0)
        self.assertEqual(result['peak_open_per_instance'], 1)
        self.assertEqual(result['peak_working_per_instance'], 1)
        self.assertEqual(result['observed_agent_hours'], .25)
        self.assertEqual(result['foreground_hours'], .25)

    def test_policy_disabled_interval_is_not_foreground(self):
        self.events()
        path = self.state / 'events/events-synthetic.ndjson'
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        rows[4]['type'] = 'log.policy'
        rows[4]['payload'] = {'enabled': True, 'analytics_enabled': False}
        self.write(path, rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertIsNone(result['foreground_hours'])
        self.assertEqual(result['observed_foreground_hours'], .5)
        self.assertEqual(result['presence_unknown_hours'], .5)
        self.assertIn('analytics_disabled_span', result['coverage_gaps'])

    def test_v1_names_and_missing_logs(self):
        result = self.run_cli('report', '--instance', 'missing', '--format', 'json')
        self.assertIsNone(result['panels_created'])
        self.assertIsNone(result['foreground_hours'])
        self.events()
        path = self.state / 'events/events-synthetic.ndjson'
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        for row in rows:
            row['v'] = 1
            row['type'] = row['type'].replace('panel.', 'surface.')
            row['surface'] = row.pop('panel')
        self.write(path, rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['panels_created'], 1)
        self.assertEqual(result['open_at_observed_end'], 0)

    def test_copied_claude_history_deduplicates_across_sessions(self):
        self.write(self.claude / 'session-a.jsonl', [self.claude_row(session='session-a')])
        self.write(self.claude / 'session-b.jsonl', [self.claude_row(session='session-b')])
        self.link('panel-a', 'session-a', 'claude-code')
        self.link('panel-b', 'session-b', 'claude-code')
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['totals']['calls'], 1)
        self.assertEqual(result['totals']['total_tokens'], 110)
        self.assertEqual(result['unattributed']['total_tokens'], 110)
        self.assertEqual(result['groups'][0]['key'], 'unattributed')
        self.assertIn('ambiguous_session_attribution', result['coverage_gaps'])

    def test_native_defaults_and_whole_custom_price_override(self):
        row = self.claude_row(cache_read_input_tokens=200)
        row['message']['model'] = 'claude-sonnet-5-5'
        self.write(self.claude / 'session-a.jsonl', [row])
        result = self.run_cli('usage', '--json')
        self.assertAlmostEqual(result['groups'][0]['estimated_api_usd'], .00032)
        self.assertFalse((self.state / 'model-costs.json').exists())
        (self.state / 'model-costs.json').write_text(json.dumps({'claude-sonnet-5-5': {
            'in_usd': 1, 'out_usd': 1, 'cache_read_usd': 1}}))
        result = self.run_cli('usage', '--json')
        self.assertAlmostEqual(result['groups'][0]['estimated_api_usd'], .00031)
        # An operator entry without cache rates does not silently inherit rates from a different tier.
        (self.state / 'model-costs.json').write_text(json.dumps({'claude-sonnet-5-5': {
            'in_usd': 1, 'out_usd': 1}}))
        result = self.run_cli('usage', '--json')
        self.assertIsNone(result['groups'][0]['estimated_api_usd'])

    def test_quiet_intervals_crossing_midnight_have_daily_exposure(self):
        self.events()
        path = self.state / 'events/events-synthetic.ndjson'
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        rows = rows[:4] + rows[5:]
        for row in rows[4:]: row['ts'] = '2026-01-04T00:00:00Z'
        for index, row in enumerate(rows): row['seq'] = index + 1
        self.write(path, rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        quiet = next(day for day in result['daily'] if day['date'] == '2026-01-03')
        self.assertEqual(quiet['events'], 0)
        self.assertEqual(quiet['peak_open'], 1)
        self.assertEqual(quiet['peak_working'], 1)
        self.assertEqual(quiet['observed_hours'], 24)
        self.assertEqual(quiet['observed_agent_hours'], 24)
        self.assertEqual(result['hang_rate_by_open_load'][0]['observed_hours'], 48)

    def test_daily_load_remains_unknown_across_gap_and_quiet_days(self):
        self.events()
        path = self.state / 'events/events-synthetic.ndjson'
        rows = [json.loads(line) for line in path.read_text().splitlines()][:4]
        for seq, ts, kind, panel, payload in [
            (6, '2026-01-02T00:30:00Z', 'panel.created', 'panel-b', {'kind': 'terminal'}),
            (7, '2026-01-02T00:30:00Z', 'liveness.derived', 'panel-b', {'state': 'working'}),
            (8, '2026-01-04T00:00:00Z', 'hang.precursor', None, {}),
        ]:
            rows.append(dict(v=2, instance='synthetic', seq=seq, ts=ts,
                             type=kind, panel=panel, payload=payload))
        self.write(path, rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        days = {day['date']: day for day in result['daily']}
        for day in days.values():
            self.assertIsNone(day['peak_open'])
            self.assertIsNone(day['peak_working'])
        quiet = days['2026-01-03']
        self.assertEqual(quiet['events'], 0)
        self.assertEqual(quiet['load_unknown_hours'], 24)
        self.assertEqual(quiet['observed_peak_open'], 1)
        self.assertEqual(quiet['observed_peak_working'], 1)
        self.assertEqual(quiet['observed_agent_hours'], 24)
        self.assertEqual(sum(d['load_unknown_hours'] for d in days.values()), result['load_unknown_hours'])
        self.assertEqual(sum(d['observed_agent_hours'] for d in days.values()), result['observed_agent_hours'])
        self.assertEqual(result['hangs_with_unknown_load'], 1)
        markdown = self.run_cli('report', '--instance', 'synthetic', '--format', 'md')
        self.assertIn('2026-01-03 | 0 | 0 | unknown | unknown |', markdown)
        self.assertIn('Observed peak open', markdown)
        self.assertIn('Unknown load h', markdown)
        self.assertNotIn('<null>', markdown)

    def test_truncated_daily_load_is_unknown_with_observed_lower_bounds(self):
        self.events()
        path = self.state / 'events/events-synthetic.ndjson'
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        for row in rows: row['seq'] += 100
        self.write(path, rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        day = result['daily'][0]
        self.assertIsNone(day['peak_open'])
        self.assertIsNone(day['peak_working'])
        self.assertEqual(day['observed_peak_open'], 1)
        self.assertEqual(day['observed_peak_working'], 1)
        self.assertEqual(day['observed_agent_hours'], 1)
        self.assertEqual(day['load_unknown_hours'], 1)

    def test_aggregated_codex_delta_does_not_invent_long_context_premium(self):
        # Two small 150K requests were aggregated before the next token_count.
        # last_token_usage identifies only the latest request, not the other contexts.
        rows = [{'type': 'session_meta', 'payload': {'id': 'aggregate-session'}},
                {'type': 'turn_context', 'payload': {'model': 'gpt-6-sol'}},
                {'type': 'event_msg', 'timestamp': '2026-01-02T00:00:00Z', 'payload': {
                    'type': 'token_count', 'info': {
                        'total_token_usage': {'input_tokens': 300000, 'output_tokens': 0},
                        'last_token_usage': {'input_tokens': 150000, 'output_tokens': 0}}}}]
        self.write(self.codex / 'aggregate.jsonl', rows)
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['input_tokens'], 300000)
        self.assertIsNone(result['groups'][0]['estimated_api_usd'])
        self.assertIn('codex_per_request_context_unknown', result['coverage_gaps'])
        rows[-1]['payload']['info']['total_token_usage']['input_tokens'] = 150000
        self.write(self.codex / 'aggregate.jsonl', rows)
        result = self.run_cli('usage', '--json')
        self.assertIsNone(result['groups'][0]['estimated_api_usd'])
        self.assertAlmostEqual(result['groups'][0]['estimated_api_usd_lower_bound'], .3)
        self.assertAlmostEqual(result['groups'][0]['estimated_api_usd_upper_bound'], .375)

    def test_unreadable_subtree_is_a_visible_gap(self):
        blocked = self.claude / 'blocked-project'
        blocked.mkdir()
        self.write(blocked / 'session-a.jsonl', [self.claude_row()])
        blocked.chmod(0)
        self.addCleanup(blocked.chmod, 0o700)
        try:
            os.listdir(blocked)
        except PermissionError:
            pass
        else:
            self.skipTest('This process can bypass directory read permissions')
        result = self.run_cli('usage', '--json')
        self.assertIn('unreadable_jsonl_subtree', result['coverage_gaps'])

    def test_nonpositive_rotation_generations_are_ignored(self):
        self.events()
        extra = {'v': 2, 'instance': 'synthetic', 'seq': 8, 'ts': '2026-01-02T02:00:00Z',
                 'type': 'panel.created', 'panel': 'spurious-panel'}
        for suffix in ('0', '-1'):
            self.write(self.state / ('events/events-synthetic.ndjson.' + suffix), [extra])
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['panels_created'], 1)
        self.assertEqual(result['open_at_observed_end'], 0)

    def summary_events(self, gap=False, missing_duration=False):
        rows = []
        def add(minute, kind, payload=None, panel=None, workspace=None):
            rows.append({'v': 2, 'instance': 'synthetic', 'seq': len(rows) + 1,
                'ts': '2026-01-02T%02d:%02d:00Z' % divmod(minute, 60), 'type': kind,
                'payload': payload or {}, 'panel': panel, 'workspace': workspace})
        add(0, 'log.opened', {'app_active': True, 'screen_locked': False, 'system_asleep': False})
        add(0, 'workspace.created', {'title': 'Alpha test'}, workspace='workspace-a')
        add(0, 'workspace.selected', workspace='workspace-a')
        add(0, 'panel.created', {'kind': 'terminal'}, panel='panel-a', workspace='workspace-a')
        add(0, 'liveness.derived', {'state': 'working'}, panel='panel-a')
        add(15, 'panel.created', {'kind': 'markdown'}, panel='panel-b', workspace='workspace-b')
        add(15, 'workspace.selected', workspace='workspace-b')
        add(20, 'waiting.entered', panel='panel-b')
        add(22, 'waiting.entered')
        add(25, 'mailbox.accepted', {'from': 'synthetic-sender'})
        add(25, 'mailbox.delivered')
        add(30, 'flag.raised')
        add(30, 'flag.lowered')
        add(30, 'hang.precursor', {'cause': 'main-thread', 'durations_ms': [10, 20], 'count': 2})
        add(45, 'panel.closed', panel='panel-b')
        if missing_duration: add(50, 'hang.precursor')
        add(60, 'panel.closed', panel='panel-a')
        if gap:
            for row in rows[5:]: row['seq'] += 1
        self.write(self.state / 'events/events-synthetic.ndjson', rows)

    def test_report_workspace_coordination_hang_and_kind_summaries(self):
        self.summary_events()
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        workspaces = {w['id']: w for w in result['workspaces']}
        self.assertEqual(workspaces['workspace-a']['selected_dwell_hours'], .25)
        self.assertEqual(workspaces['workspace-b']['selected_dwell_hours'], .75)
        self.assertEqual(workspaces['workspace-a']['selections'], 1)
        self.assertEqual(workspaces['workspace-b']['waiting_entered'], 1)
        self.assertAlmostEqual(workspaces['workspace-a']['observed_agent_hours'], 1)
        self.assertEqual(result['waiting_entered_unattributed'], 1)
        self.assertEqual(result['workspace_selection_unknown_hours'], 0)
        self.assertEqual(result['kinds_created'], {'terminal': 1, 'markdown': 1})
        self.assertEqual(result['peak_open_kinds'], {'terminal': 1, 'markdown': 1})
        self.assertEqual(result['peak_open_by_kind'], {'terminal': 1, 'markdown': 1})
        self.assertEqual(result['mailbox_accepted'], 1)
        self.assertEqual(result['mailbox_delivered'], 1)
        self.assertEqual(result['mail_from'], {'synthetic-sender': 1})
        self.assertEqual(result['flag_events'], {'flag.raised': 1, 'flag.lowered': 1})
        self.assertEqual(result['hang_causes'], {'main-thread': 1})
        self.assertEqual(result['hang_durations_ms']['samples'], 2)
        self.assertEqual(result['hang_durations_ms']['total'], 30)
        self.assertEqual(result['hang_durations_ms']['max'], 20)

    def test_summary_gaps_keep_dwell_peaks_and_hang_duration_uncertain(self):
        self.summary_events(gap=True, missing_duration=True)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        workspaces = {w['id']: w for w in result['workspaces']}
        self.assertEqual(workspaces['workspace-a']['selected_dwell_hours'], 0)
        self.assertEqual(workspaces['workspace-b']['selected_dwell_hours'], .75)
        self.assertEqual(result['workspace_selection_unknown_hours'], .25)
        self.assertIsNone(result['peak_open_kinds'])
        self.assertIsNone(result['peak_open_by_kind'])
        self.assertIsNone(result['hang_durations_ms']['total'])
        self.assertEqual(result['hang_durations_ms']['observed_total'], 30)
        self.assertEqual(result['hang_durations_ms']['unknown_precursors'], 1)
        self.assertEqual(result['hang_causes']['unknown'], 1)
        self.assertIn('hang_durations_unknown', result['coverage_gaps'])

    def test_load_stays_unknown_after_gap_instead_of_becoming_zero(self):
        self.events()
        path = self.state / 'events/events-synthetic.ndjson'
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        # Lose one or more events before the 30-minute hang, then observe another
        # hang 90 minutes later. No census ever establishes the missing panels.
        rows[4]['seq'] += 1
        rows[5] = {'v': 2, 'instance': 'synthetic', 'seq': 7, 'ts': '2026-01-02T02:00:00Z',
                   'type': 'hang.precursor', 'payload': {'cause': 'synthetic'}}
        rows[6]['seq'] = 8
        rows[6]['ts'] = '2026-01-02T02:00:00Z'
        self.write(path, rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['hang_rate_by_open_load'][0]['observed_hours'], 0)
        self.assertEqual(result['load_unknown_hours'], 2)
        self.assertEqual(result['hangs_with_unknown_load'], 2)
        self.assertEqual(result['hang_rate_by_open_load'][0]['hangs'], 0)
        self.assertEqual(result['hang_rate_by_working_load'][0]['observed_hours'], 0)
        self.assertEqual(result['hang_rate_by_working_load'][0]['hangs'], 0)
        unknown = result['hang_rate_by_open_load'][-1]
        self.assertEqual(unknown['open_panels'], 'unknown')
        self.assertEqual(unknown['hangs'], 2)
        self.assertIsNone(unknown['hangs_per_hour'])

    def test_truncated_first_event_and_full_kill_never_restore_definite_load(self):
        self.events()
        path = self.state / 'events/events-synthetic.ndjson'
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        for row in rows: row['seq'] += 100
        self.write(path, rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['hang_rate_by_open_load'][0]['hangs'], 0)
        self.assertEqual(result['load_unknown_hours'], 1)
        self.assertEqual(result['hangs_with_unknown_load'], 1)
        self.events()
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        # A history restart plus presence snapshots is not a panel census.
        rows[3]['type'] = 'log.policy'; rows[3]['payload'] = {'enabled': False}
        rows[4]['type'] = 'log.policy'; rows[4]['payload'] = {'enabled': True}
        rows[5]['type'] = 'hang.precursor'
        self.write(path, rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['load_unknown_hours'], 1)
        self.assertEqual(result['hangs_with_unknown_load'], 1)
        self.assertEqual(result['hang_rate_by_open_load'][0]['hangs'], 0)

    def test_policy_at_sequence_one_is_not_an_instance_start_or_census(self):
        rows = [
            {'type': 'log.policy', 'payload': {'enabled': True, 'analytics_enabled': True}},
            {'type': 'app.activated', 'payload': {'snapshot': True}},
            {'type': 'screen.unlocked', 'payload': {'snapshot': True}},
            {'type': 'system.wake', 'payload': {'snapshot': True}},
            {'type': 'hang.precursor', 'payload': {'cause': 'synthetic'}},
        ]
        for index, row in enumerate(rows):
            row.update(v=2, instance='synthetic', seq=index + 1,
                       ts='2026-01-02T00:00:00Z' if index < 4 else '2026-01-02T01:00:00Z')
        self.write(self.state / 'events/events-synthetic.ndjson', rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertIsNone(result['peak_open_per_instance'])
        self.assertIsNone(result['peak_working_per_instance'])
        self.assertEqual(result['load_unknown_hours'], 1)
        self.assertEqual(result['hangs_with_unknown_load'], 1)
        self.assertEqual(result['hang_rate_by_open_load'][0]['observed_hours'], 0)
        self.assertEqual(result['hang_rate_by_open_load'][0]['hangs'], 0)
        self.assertIn('instance_start_missing', result['coverage_gaps'])

    def test_missing_instance_does_not_scan_or_claim_unbounded_host_usage(self):
        transcript = self.claude / 'session-a.jsonl'
        self.write(transcript, [self.claude_row()])
        with transcript.open('a') as stream: stream.write('malformed transcript line\n')
        result = self.run_cli('report', '--instance', 'absent-instance', '--format', 'json')
        self.assertIsNone(result['host_usage'])
        self.assertIn('usage_span_unavailable', result['coverage_gaps'])
        self.assertNotIn('malformed_jsonl', result['coverage_gaps'])
        self.assertNotIn('transcript_retention_and_unrecorded_usage_unknown', result['coverage_gaps'])
        self.assertIn('not scanned', result['usage_scope'])
        markdown = self.run_cli('report', '--instance', 'absent-instance', '--format', 'md')
        self.assertIn('not scanned', markdown)
        self.assertNotIn('test-model', markdown)

    def test_scanner_skips_counts_and_recovers_after_oversize_line(self):
        path = self.claude / 'session-a.jsonl'
        with path.open('w') as stream:
            stream.write('{"type":"user","content":"irrelevant"}\n')
            stream.write('{"usage":' + 'x' * (17 * 1024 * 1024) + '\n')
            stream.write('{"usage": malformed}\n{"usage": malformed again}\n')
            stream.write(json.dumps(self.claude_row()) + '\n')
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['total_tokens'], 110)
        self.assertEqual(result['skipped_counts']['oversize_jsonl_line'], 1)
        self.assertEqual(result['skipped_counts']['malformed_jsonl'], 2)
        self.assertEqual(result['skipped_counts']['filtered_lines'], 1)

    def test_claude_mtime_filter_is_counted_and_disclosed(self):
        path = self.claude / 'old.jsonl'
        self.write(path, [self.claude_row()])
        os.utime(path, (1, 1))
        result = self.run_cli('usage', '--since', '2026-01-02T00:00:00Z', '--json')
        self.assertEqual(result['totals']['calls'], 0)
        self.assertEqual(result['skipped_counts']['claude_files_before_since_skipped'], 1)
        self.assertIn('claude_file_mtime_filter_applied', result['coverage_gaps'])

    def test_equal_or_unknown_codex_times_preserve_file_line_order(self):
        for timestamp in ('2026-01-02T01:00:00Z', None):
            with self.subTest(timestamp=timestamp):
                rows = [{'type': 'session_meta', 'payload': {'id': 'codex-a'}}]
                for count in range(1, 5):
                    rows.append({'type': 'event_msg', 'timestamp': timestamp, 'payload': {
                        'type': 'token_count', 'info': {'total_token_usage': {
                            'input_tokens': count * 100, 'output_tokens': count * 10}}}})
                self.write(self.codex / 'rollout.jsonl', rows)
                result = self.run_cli('usage', '--json')
                self.assertEqual(result['totals']['input_tokens'], 400)
                self.assertEqual(result['totals']['output_tokens'], 40)
                self.assertFalse(any('counter_reset' in g for g in result['coverage_gaps']))

    def test_panel_move_preserves_panel_and_temporal_workspace_attribution(self):
        first = self.claude_row(msg='first'); first['timestamp'] = '2026-01-02T00:30:00Z'
        second = self.claude_row(msg='second'); second['timestamp'] = '2026-01-02T01:30:00Z'
        self.write(self.claude / 'session-a.jsonl', [first, second])
        self.link('panel-a', 'session-a', 'claude-code', 'workspace-a', 1767312000000)
        self.link('panel-a', 'session-a', 'claude-code', 'workspace-b', 1767315600000)
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['groups'][0]['key'], 'panel-a')
        self.assertEqual(result['unattributed']['total_tokens'], 0)
        result = self.run_cli('usage', '--by', 'workspace', '--json')
        self.assertEqual({g['key']: g['total_tokens'] for g in result['groups']},
                         {'workspace-a': 110, 'workspace-b': 110})

    def test_copied_history_uses_earliest_proven_origin_not_filename(self):
        # The copy sorts first on disk and has the same historical timestamp.
        self.write(self.claude / 'a-copy.jsonl', [self.claude_row(session='session-b')])
        self.write(self.claude / 'z-origin.jsonl', [self.claude_row(session='session-a')])
        self.link('panel-a', 'session-a', 'claude-code', 'workspace-a', 1767312000000)
        self.link('panel-b', 'session-b', 'claude-code', 'workspace-b', 1767315600000)
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['groups'][0]['key'], 'panel-a')
        self.assertEqual(result['totals']['calls'], 1)
        self.assertEqual(result['unattributed']['total_tokens'], 0)

    def test_same_panel_with_unknown_workspace_time_does_not_lose_panel(self):
        row = self.claude_row(); row.pop('timestamp')
        self.write(self.claude / 'session-a.jsonl', [row])
        self.link('panel-a', 'session-a', 'claude-code', 'workspace-a', 1)
        self.link('panel-a', 'session-a', 'claude-code', 'workspace-b', 2)
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['groups'][0]['key'], 'panel-a')
        result = self.run_cli('usage', '--by', 'workspace', '--json')
        self.assertEqual(result['groups'][0]['key'], 'unattributed')

    def test_unique_panel_survives_delayed_journal_registration(self):
        row = self.claude_row(); row['timestamp'] = '2026-01-02T00:30:00Z'
        self.write(self.claude / 'session-a.jsonl', [row])
        self.link('panel-a', 'session-a', 'claude-code', 'workspace-a', 1767315600000)
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['groups'][0]['key'], 'panel-a')
        self.assertEqual(result['unattributed']['total_tokens'], 0)
        result = self.run_cli('usage', '--by', 'workspace', '--json')
        self.assertEqual(result['groups'][0]['key'], 'unattributed')
        self.assertEqual(result['unattributed']['total_tokens'], 110)
        self.assertIn('usage_before_journal_attribution', result['coverage_gaps'])

    def test_real_snapshot_order_exposes_foreground_bounds(self):
        rows = [
            ('2026-01-02T00:00:00Z', 'log.opened', {'pid': 123}),
            ('2026-01-02T00:00:10Z', 'panel.created', {'kind': 'terminal'}),
            ('2026-01-02T00:00:20Z', 'app.activated', {'snapshot': True}),
            ('2026-01-02T00:00:20Z', 'screen.unlocked', {'snapshot': True}),
            ('2026-01-02T00:00:20Z', 'system.wake', {'snapshot': True}),
            ('2026-01-02T01:00:00Z', 'panel.closed', {}),
        ]
        self.write(self.state / 'events/events-synthetic.ndjson', [dict(
            v=2, instance='synthetic', seq=i+1, ts=ts, type=kind, payload=payload, panel='panel-a')
            for i, (ts, kind, payload) in enumerate(rows)])
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertIsNone(result['foreground_hours'])
        bounds = result['foreground_hours_range']
        self.assertAlmostEqual(bounds['minimum'], 3580 / 3600)
        self.assertEqual(bounds['maximum'], 1)
        self.assertAlmostEqual(result['presence_unknown_hours'], 20 / 3600)
        markdown = self.run_cli('report', '--instance', 'synthetic', '--format', 'md')
        self.assertIn('Foreground hours range:', markdown)

    def test_report_defaults_to_local_calendar_and_can_select_utc(self):
        self.events()
        self.zone = 'America/Los_Angeles'
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['timezone'], 'America/Los_Angeles')
        self.assertEqual(result['daily'][0]['date'], '2026-01-01')
        self.assertIn('16', result['hour_of_day_events'])
        result = self.run_cli('report', '--instance', 'synthetic', '--utc', '--format', 'json')
        self.assertEqual(result['daily'][0]['date'], '2026-01-02')
        self.assertIn('00', result['hour_of_day_events'])

    def test_report_excludes_tagged_instances_by_default(self):
        self.events()
        path = self.state / 'events/events-synthetic.ndjson'
        base = [json.loads(line) for line in path.read_text().splitlines()]
        path.unlink()
        for instance in ('com.stage11.c11-123', 'test-tag-456'):
            self.write(self.state / f'events/events-{instance}.ndjson',
                       [{**row, 'instance': instance} for row in base])
        result = self.run_cli('report', '--format', 'json')
        self.assertEqual(result['instances'], ['com.stage11.c11-123'])
        result = self.run_cli('report', '--since', '2026-01-01T00:00:00Z', '--format', 'json')
        self.assertEqual(result['panels_created'], 1)
        result = self.run_cli('report', '--all-instances', '--format', 'json')
        self.assertEqual(result['panels_created'], 2)

    def test_until_bounds_usage_and_replay_state(self):
        self.events()
        self.write(self.claude / 'session-a.jsonl', [self.claude_row()])
        result = self.run_cli('usage', '--until', '2026-01-02T00:30:00Z', '--json')
        self.assertEqual(result['totals']['calls'], 0)
        result = self.run_cli('report', '--instance', 'synthetic', '--until',
                              '2026-01-02T00:45:00Z', '--format', 'json')
        self.assertEqual(result['end'], '2026-01-02T00:45:00Z')
        self.assertEqual(result['open_at_observed_end'], 1)
        self.assertEqual(result['observed_agent_hours'], .75)
        self.run_cli('usage', '--since', '2026-01-03T00:00:00Z', '--until',
                     '2026-01-02T00:00:00Z', ok=False)

    def test_legacy_dated_aliases_and_missing_override_cache_gap(self):
        first = self.claude_row(msg='haiku', cache_read_input_tokens=200)
        first['message']['model'] = 'anthropic/claude-haiku-4-5-20251001'
        second = self.claude_row(msg='opus', cache_read_input_tokens=200)
        second['message']['model'] = 'claude-opus-4-8'
        self.write(self.claude / 'session-a.jsonl', [first, second])
        result = self.run_cli('usage', '--json')
        self.assertAlmostEqual(result['totals']['estimated_api_usd'], .00102)
        (self.state / 'model-costs.json').write_text(json.dumps({'claude-opus-4-8': {
            'in_usd': 5, 'out_usd': 25}}))
        result = self.run_cli('usage', '--json')
        self.assertIsNone(result['totals']['estimated_api_usd'])
        self.assertIn('model_cache_rate_unavailable', result['coverage_gaps'])
        self.assertEqual(result['totals']['unknown_cost_tokens'], 310)
        self.assertAlmostEqual(result['totals']['known_api_usd_subtotal'], .00017)

    def test_cost_totals_preserve_known_subtotal_and_unknown_volume(self):
        known = self.claude_row(msg='known'); known['message']['model'] = 'claude-sonnet-5-5'
        unknown = self.claude_row(msg='unknown')
        self.write(self.claude / 'session-a.jsonl', [known, unknown])
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertIsNone(result['totals']['estimated_api_usd'])
        self.assertAlmostEqual(result['totals']['known_api_usd_subtotal'], .0003)
        self.assertEqual(result['totals']['unknown_cost_tokens'], 110)
        self.assertEqual(result['totals']['unknown_cost_calls'], 1)
        self.assertAlmostEqual(result['groups'][0]['known_api_usd_subtotal'], .0003)

    def test_codex_single_request_premium_and_cache_write_bounds(self):
        total = {'input_tokens': 300000, 'cached_input_tokens': 100000,
                 'output_tokens': 100, 'reasoning_output_tokens': 50}
        rows = [{'type': 'session_meta', 'payload': {'id': 'single-request'}},
                {'type': 'turn_context', 'payload': {'model': 'gpt-6-sol'}},
                {'type': 'event_msg', 'timestamp': '2026-01-02T00:00:00Z', 'payload': {
                    'type': 'token_count', 'info': {'total_token_usage': total,
                                                  'last_token_usage': total}}}]
        self.write(self.codex / 'single.jsonl', rows)
        result = self.run_cli('usage', '--json')
        self.assertIsNone(result['totals']['estimated_api_usd'])
        self.assertAlmostEqual(result['totals']['estimated_api_usd_lower_bound'], .8415)
        self.assertAlmostEqual(result['totals']['estimated_api_usd_upper_bound'], 1.0415)
        self.assertIn('codex_cache_write_tokens_unknown', result['coverage_gaps'])
        self.assertNotIn('codex_per_request_context_unknown', result['coverage_gaps'])
        self.assertEqual(result['totals']['known_api_usd_subtotal'], 0)
        self.assertEqual(result['totals']['unknown_cost_tokens'], 300100)

    def test_journal_pruning_is_disclosed(self):
        with closing(sqlite3.connect(self.journal)) as db, db:
            db.execute('CREATE TABLE journal_meta(key TEXT PRIMARY KEY,value INTEGER)')
            db.execute("INSERT INTO journal_meta VALUES('coverage_low_water', 50)")
        self.write(self.claude / 'session-a.jsonl', [self.claude_row()])
        result = self.run_cli('usage', '--json')
        self.assertIn('journal_history_pruned', result['coverage_gaps'])

    def test_unrelated_pruned_journal_does_not_poison_complete_session_provenance(self):
        self.write(self.claude / 'session-a.jsonl', [self.claude_row()])
        self.link('panel-complete', 'session-a', 'claude', committed_at_ms=1767315660000)
        other = self.root / 'tagged.sqlite3'
        with closing(sqlite3.connect(other)) as db, db:
            db.execute('CREATE TABLE journal_meta(key TEXT PRIMARY KEY,value INTEGER)')
            db.execute("INSERT INTO journal_meta VALUES('coverage_low_water', 50)")
            db.execute('CREATE TABLE journal_events(tab_id TEXT,session_id TEXT,agent_kind TEXT,workspace_id TEXT,committed_at_ms INTEGER)')
            db.execute("INSERT INTO journal_events VALUES('other-panel','other-session','claude','other-workspace',0)")
        result = self.run_cli('usage', '--journal', str(self.journal), '--journal', str(other), '--by', 'panel', '--json')
        self.assertEqual(result['groups'][0]['key'], 'panel-complete')
        self.assertEqual(result['unattributed']['calls'], 0)
        self.assertIn('journal_history_pruned', result['coverage_gaps'])
        self.assertIn('usage_before_journal_attribution', result['coverage_gaps'])
        with closing(sqlite3.connect(self.journal)) as db, db:
            db.execute('CREATE TABLE journal_meta(key TEXT PRIMARY KEY,value INTEGER)')
            db.execute("INSERT INTO journal_meta VALUES('coverage_low_water', 50)")
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['groups'][0]['key'], 'unattributed')

    def test_unrelated_pruned_journal_does_not_hide_copied_origin_order(self):
        for name in ['parent', 'fork']:
            self.write(self.claude / (name + '.jsonl'), [self.claude_row(session=name)])
        self.link('panel-parent', 'parent', 'claude', committed_at_ms=0)
        self.link('panel-fork', 'fork', 'claude', committed_at_ms=1)
        other = self.root / 'pruned-empty.sqlite3'
        with closing(sqlite3.connect(other)) as db, db:
            db.execute('CREATE TABLE journal_meta(key TEXT PRIMARY KEY,value INTEGER)')
            db.execute("INSERT INTO journal_meta VALUES('coverage_low_water', 50)")
            db.execute('CREATE TABLE journal_events(tab_id TEXT,session_id TEXT,agent_kind TEXT,workspace_id TEXT,committed_at_ms INTEGER)')
        result = self.run_cli('usage', '--journal', str(self.journal), '--journal', str(other), '--by', 'panel', '--json')
        self.assertEqual(result['groups'][0]['key'], 'panel-parent')
        self.assertEqual(result['totals']['calls'], 1)

    def test_codex_mtime_skip_is_disclosed_and_new_file_retains_baseline(self):
        old = self.codex / 'old-import.jsonl'
        self.write(old, [{'type': 'session_meta', 'payload': {'id': 'old'}},
            self.codex_row('2026-01-02T00:00:01Z', 1000, 800, 100)])
        os.utime(old, (1, 1))
        self.write(self.codex / 'current.jsonl', [
            {'type': 'session_meta', 'payload': {'id': 'current'}},
            self.codex_row('2026-01-01T23:59:59Z', 100, 80, 10),
            self.codex_row('2026-01-02T00:00:01Z', 120, 90, 15,
                {'input_tokens': 20, 'cached_input_tokens': 10, 'output_tokens': 5})])
        result = self.run_cli('usage', '--since', '2026-01-02T00:00:00Z', '--json')
        self.assertEqual(result['totals']['calls'], 1)
        self.assertEqual(result['totals']['input_tokens'], 10)
        self.assertEqual(result['totals']['cache_read_tokens'], 10)
        self.assertEqual(result['skipped_counts']['codex_files_before_since_skipped'], 1)
        self.assertIn('codex_file_mtime_filter_applied', result['coverage_gaps'])

    def test_codex_first_cumulative_without_matching_last_is_quantified(self):
        self.write(self.codex / 'carry.jsonl', [
            {'type': 'session_meta', 'payload': {'id': 'carry'}},
            self.codex_row('2026-01-02T00:00:00Z', 1000, 800, 100,
                {'input_tokens': 10, 'cached_input_tokens': 5, 'output_tokens': 2}),
            self.codex_row('2026-01-02T00:00:01Z', 1010, 805, 102,
                {'input_tokens': 10, 'cached_input_tokens': 5, 'output_tokens': 2})])
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['input_tokens'], 205)
        self.assertEqual(result['totals']['output_tokens'], 102)
        self.assertEqual(result['analysis_counts']['codex_first_cumulative_without_matching_last_records'], 1)
        self.assertEqual(result['analysis_counts']['codex_first_cumulative_without_matching_last_tokens'], 1100)
        self.assertIn('codex_first_cumulative_baseline_unproven', result['coverage_gaps'])

    def test_codex_copied_unproven_first_sample_is_diagnosed_once(self):
        row = self.codex_row('2026-01-02T00:00:00Z', 1000, 800, 100,
            {'input_tokens': 10, 'cached_input_tokens': 5, 'output_tokens': 2})
        for name in ['parent', 'fork']:
            self.write(self.codex / (name + '.jsonl'), [
                {'type': 'session_meta', 'payload': {'id': name}}, row])
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['calls'], 1)
        self.assertEqual(result['analysis_counts']['codex_first_cumulative_without_matching_last_records'], 1)
        self.assertEqual(result['analysis_counts']['codex_first_cumulative_without_matching_last_tokens'], 1100)
        self.assertIn('codex_first_cumulative_baseline_unproven', result['coverage_gaps'])

    def test_report_compact_events_preserve_summaries_and_discard_irrelevant_text(self):
        self.summary_events(missing_duration=True)
        path = self.state / 'events/events-synthetic.ndjson'
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        for row in rows:
            row['payload']['body'] = 'ignored synthetic body' * 100
            row['payload']['text'] = 'ignored synthetic input' * 100
            row['payload']['unrelated'] = {'nested': ['ignored'] * 100}
        self.write(path, rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertEqual(result['panels_created'], 2)
        self.assertEqual(result['mail_from'], {'synthetic-sender': 1})
        self.assertEqual(result['hang_causes'], {'main-thread': 1, 'unknown': 1})
        self.assertEqual(result['hang_durations_ms']['observed_total'], 30)
        self.assertIsNone(result['hang_durations_ms']['total'])
        self.assertNotIn('ignored synthetic', json.dumps(result))

    def test_retention_coordination_gap_does_not_invalidate_replay(self):
        self.events()
        path = self.state / 'events/events-synthetic.ndjson'
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        rows[4]['type'] = 'log.retention'
        rows[4]['payload'] = {'state': 'degraded', 'reason': 'lock_busy'}
        self.write(path, rows)
        result = self.run_cli('report', '--instance', 'synthetic', '--format', 'json')
        self.assertIn('retention_reconciliation_degraded', result['coverage_gaps'])
        self.assertEqual(result['peak_open_per_instance'], 1)
        self.assertEqual(result['foreground_hours'], 1)
        self.assertEqual(result['load_unknown_hours'], 0)

    def codex_row(self, ts, input, cached, output, last=None):
        total = {'input_tokens': input, 'cached_input_tokens': cached,
                 'output_tokens': output, 'reasoning_output_tokens': 0,
                 'total_tokens': input + output}
        return {'type': 'event_msg', 'timestamp': ts, 'payload': {'type': 'token_count',
                'info': {'total_token_usage': total, 'last_token_usage': last or total}}}

    def test_codex_shared_header_never_interleaves_independent_rollout_counters(self):
        header = {'type': 'session_meta', 'payload': {'id': 'shared-header'}}
        self.write(self.codex / 'a.jsonl', [header,
            self.codex_row('2026-01-02T00:00:00Z', 100, 80, 10),
            self.codex_row('2026-01-02T00:00:02Z', 140, 110, 15,
                           {'input_tokens': 40, 'cached_input_tokens': 30, 'output_tokens': 5})])
        self.write(self.codex / 'b.jsonl', [header,
            self.codex_row('2026-01-02T00:00:01Z', 1000, 900, 100),
            self.codex_row('2026-01-02T00:00:03Z', 1100, 980, 130,
                           {'input_tokens': 100, 'cached_input_tokens': 80, 'output_tokens': 30})])
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['input_tokens'], 150)
        self.assertEqual(result['totals']['cache_read_tokens'], 1090)
        self.assertEqual(result['totals']['output_tokens'], 145)
        self.assertEqual(result['totals']['calls'], 4)
        self.assertNotIn('codex_counter_reset_last_usage_only', result['coverage_gaps'])

    def test_codex_fork_uses_first_own_metadata_for_journal_join(self):
        self.write(self.codex / 'fork.jsonl', [
            {'type': 'session_meta', 'payload': {'id': 'fork-own', 'forked_from_id': 'ancestor'}},
            {'type': 'session_meta', 'payload': {'id': 'ancestor'}},
            self.codex_row('2026-01-02T00:00:00Z', 100, 80, 10)])
        self.link('panel-fork', 'fork-own', 'codex')
        self.link('panel-ancestor', 'ancestor', 'codex')
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['groups'][0]['key'], 'panel-fork')
        self.assertEqual(result['analysis_counts']['codex_inherited_metadata_ignored'], 1)

    def test_codex_copied_fork_records_dedup_globally_and_keep_origin(self):
        first = self.codex_row('2026-01-02T00:00:00Z', 100, 80, 10)
        second = self.codex_row('2026-01-02T00:00:01Z', 150, 100, 20,
            {'input_tokens': 50, 'cached_input_tokens': 20, 'output_tokens': 10, 'total_tokens': 60})
        final = self.codex_row('2026-01-02T00:00:03Z', 180, 120, 30,
            {'input_tokens': 30, 'cached_input_tokens': 20, 'output_tokens': 10, 'total_tokens': 40})
        self.write(self.codex / 'z-parent.jsonl', [
            {'type': 'session_meta', 'payload': {'id': 'parent'}}, first, second])
        self.write(self.codex / 'a-fork.jsonl', [
            {'type': 'session_meta', 'payload': {'id': 'fork', 'forked_from_id': 'parent'}},
            {'type': 'session_meta', 'payload': {'id': 'parent'}}, first, second, final])
        self.link('panel-parent', 'parent', 'codex', committed_at_ms=0)
        self.link('panel-fork', 'fork', 'codex', committed_at_ms=1767312002000)
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['totals']['input_tokens'], 60)
        self.assertEqual(result['totals']['cache_read_tokens'], 120)
        self.assertEqual(result['totals']['output_tokens'], 30)
        self.assertEqual(result['totals']['calls'], 3)
        groups = {g['key']: g for g in result['groups']}
        self.assertEqual(groups['panel-parent']['calls'], 2)
        self.assertEqual(groups['panel-fork']['calls'], 1)
        self.assertEqual(result['analysis_counts']['codex_duplicate_candidate_records_removed'], 2)

    def test_codex_copied_origins_with_tied_journals_remain_unattributed(self):
        row = self.codex_row('2026-01-02T00:00:00Z', 100, 80, 10)
        for name in ['parent', 'fork']:
            payload = {'id': name}
            if name == 'fork':
                payload['forked_from_id'] = 'parent'
            self.write(self.codex / (name + '.jsonl'), [
                {'type': 'session_meta', 'payload': payload}, row])
            self.link('panel-' + name, name, 'codex', committed_at_ms=0)
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['totals']['calls'], 1)
        self.assertEqual(result['groups'][0]['key'], 'unattributed')
        self.assertEqual(result['unattributed']['cache_read_tokens'], 80)
        self.assertIn('ambiguous_session_attribution', result['coverage_gaps'])

    def test_codex_truncated_copy_prefers_observed_predecessor_delta(self):
        first = self.codex_row('2026-01-01T23:00:00Z', 100, 80, 10)
        second = self.codex_row('2026-01-02T00:00:01Z', 150, 100, 20,
            {'input_tokens': 50, 'cached_input_tokens': 20, 'output_tokens': 10, 'total_tokens': 60})
        final = self.codex_row('2026-01-02T00:00:03Z', 180, 120, 30,
            {'input_tokens': 30, 'cached_input_tokens': 20, 'output_tokens': 10, 'total_tokens': 40})
        self.write(self.codex / 'a-truncated.jsonl', [
            {'type': 'session_meta', 'payload': {'id': 'fork'}}, second, final])
        self.write(self.codex / 'z-original.jsonl', [
            {'type': 'session_meta', 'payload': {'id': 'parent'}}, first, second])
        result = self.run_cli('usage', '--since', '2026-01-02T00:00:00Z', '--json')
        self.assertEqual(result['totals']['input_tokens'], 40)
        self.assertEqual(result['totals']['cache_read_tokens'], 40)
        self.assertEqual(result['totals']['output_tokens'], 20)
        self.assertEqual(result['totals']['calls'], 2)
        self.assertEqual(result['analysis_counts']['codex_first_cumulative_without_matching_last_records'], 0)
        self.assertEqual(result['analysis_counts']['codex_first_cumulative_without_matching_last_tokens'], 0)
        self.assertNotIn('codex_first_cumulative_baseline_unproven', result['coverage_gaps'])

    def test_codex_global_copy_key_includes_full_last_usage_tuple(self):
        first = self.codex_row('2026-01-02T00:00:00Z', 100, 80, 10)
        other = json.loads(json.dumps(first))
        other['payload']['info']['last_token_usage']['total_tokens'] = 111
        for name, row in [('a', first), ('b', other)]:
            self.write(self.codex / (name + '.jsonl'), [
                {'type': 'session_meta', 'payload': {'id': name}}, row])
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['calls'], 2)
        self.assertEqual(result['totals']['cache_read_tokens'], 160)

    def test_codex_conflicting_copy_predecessors_preserve_unknown_interval(self):
        shared = self.codex_row('2026-01-02T00:00:01Z', 200, 150, 30,
            {'input_tokens': 10, 'cached_input_tokens': 5, 'output_tokens': 5})
        for name, baseline in [('a', 100), ('b', 120)]:
            self.write(self.codex / (name + '.jsonl'), [
                {'type': 'session_meta', 'payload': {'id': name}},
                {'type': 'turn_context', 'payload': {'model': 'gpt-6.1-sol'}},
                self.codex_row('2026-01-01T23:00:00Z', baseline, 80, 10), shared])
        result = self.run_cli('usage', '--since', '2026-01-02T00:00:00Z', '--json')
        self.assertEqual(result['totals']['calls'], 1)
        self.assertEqual(result['totals']['input_tokens'], 5)
        self.assertEqual(result['totals']['cache_read_tokens'], 5)
        self.assertEqual(result['totals']['output_tokens'], 5)
        self.assertIn('codex_duplicate_delta_ambiguous', result['coverage_gaps'])
        self.assertEqual(result['totals']['estimated_api_usd_lower_bound'], 0)
        self.assertIsNone(result['totals']['estimated_api_usd_upper_bound'])

    def test_codex_global_copy_key_preserves_full_total_tuple_and_native_timestamp(self):
        original = self.codex_row('2026-01-02T00:00:00Z', 100, 80, 10)
        for name, stamp, total in [('a', '2026-01-02T00:00:00Z', 110),
                                   ('b', '2026-01-02T00:00:00Z', 111),
                                   ('c', '2026-01-02T00:00:00.000Z', 110)]:
            row = json.loads(json.dumps(original))
            row['timestamp'] = stamp
            row['payload']['info']['total_token_usage']['total_tokens'] = total
            self.write(self.codex / (name + '.jsonl'), [
                {'type': 'session_meta', 'payload': {'id': name}}, row])
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['calls'], 3)
        self.assertEqual(result['totals']['cache_read_tokens'], 240)

    def test_claude_snapshot_upgrade_diagnostics_are_aggregate_only(self):
        self.write(self.claude / 'snapshots.jsonl', [self.claude_row(output=1),
            self.claude_row(output=10), self.claude_row(output=5)])
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['output_tokens'], 10)
        self.assertEqual(result['analysis_counts']['claude_output_upgrade_identities'], 1)
        self.assertEqual(result['analysis_counts']['claude_output_upgrade_tokens'], 9)
        self.assertEqual(result['analysis_counts']['claude_output_above_min_snapshot_tokens'], 9)

    def test_scanner_type_prefilter_tolerates_spacing_and_key_order(self):
        row = self.codex_row('2026-01-02T00:00:00Z', 100, 80, 10)
        shuffled = {'padding': 'x' * 1024, 'payload': row['payload'],
                    'timestamp': row['timestamp'], 'type': row['type']}
        (self.codex / 'ordered.jsonl').write_text(json.dumps(shuffled, separators=(' , ', ' : ')) + '\n')
        claude = self.claude_row()
        shuffled_claude = {'padding': 'x' * 1024, **{k: v for k, v in claude.items() if k != 'type'}, 'type': 'assistant'}
        self.write(self.claude / 'ordered.jsonl', [shuffled_claude])
        result = self.run_cli('usage', '--by', 'harness', '--json')
        self.assertEqual(result['totals']['calls'], 2)
        self.assertEqual(result['totals']['output_tokens'], 20)

    def test_utc_fraction_leap_day_and_offset_bounds(self):
        rows = []
        for name, stamp in [('before', '2024-02-29T23:59:59.999999Z'),
                            ('exact', '2024-03-01T00:00:00Z'),
                            ('offset', '2024-03-01T05:30:00+05:30'),
                            ('after', '2024-03-01T00:00:00.0009Z')]:
            row = self.claude_row(msg=name); row['timestamp'] = stamp; rows.append(row)
        self.write(self.claude / 'dates.jsonl', rows)
        result = self.run_cli('usage', '--since', '2024-03-01T00:00:00Z',
                              '--until', '2024-03-01T00:00:00.0005Z', '--json')
        self.assertEqual(result['totals']['calls'], 2)
        self.assertEqual(result['totals']['output_tokens'], 20)

    def test_codex_clock_regression_keeps_append_counter_chronology(self):
        rows = [{'type': 'session_meta', 'payload': {'id': 'clock-a'}}]
        for index, second in enumerate([0, 2, 1], 1):
            rows.append(self.codex_row(f'2026-01-02T00:00:0{second}Z', index * 100, index * 80, index * 10,
                {'input_tokens': 100, 'cached_input_tokens': 80, 'output_tokens': 10}))
        self.write(self.codex / 'clock.jsonl', rows)
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['input_tokens'], 60)
        self.assertEqual(result['totals']['cache_read_tokens'], 240)
        self.assertEqual(result['totals']['output_tokens'], 30)
        self.assertIn('codex_source_timestamp_regression', result['coverage_gaps'])

    def test_codex_missing_timestamps_do_not_invent_copy_identity(self):
        for name in ['a', 'b']:
            self.write(self.codex / (name + '.jsonl'), [
                {'type': 'session_meta', 'payload': {'id': name}},
                self.codex_row(None, 100, 80, 10)])
        result = self.run_cli('usage', '--json')
        self.assertEqual(result['totals']['calls'], 2)
        self.assertEqual(result['totals']['cache_read_tokens'], 160)
        self.assertIn('codex_copy_identity_timestamp_missing', result['coverage_gaps'])

    def test_codex_conflicting_nonfork_metadata_is_unattributed(self):
        self.write(self.codex / 'conflict.jsonl', [
            {'type': 'session_meta', 'payload': {'id': 'first'}},
            {'type': 'session_meta', 'payload': {'id': 'unproven-other'}},
            self.codex_row('2026-01-02T00:00:00Z', 100, 80, 10)])
        self.link('panel-first', 'first', 'codex')
        result = self.run_cli('usage', '--by', 'panel', '--json')
        self.assertEqual(result['groups'][0]['key'], 'unattributed')
        self.assertEqual(result['totals']['calls'], 1)
        self.assertIn('codex_session_metadata_conflict', result['coverage_gaps'])

    @unittest.skipUnless(os.environ.get('C11_ACTIVITY_MEMORY_PROBE') == '1',
                         'large-history RSS probe runs on CI or explicitly admitted Atlas job')
    def test_large_pre_window_history_has_bounded_resident_memory(self):
        if sys.platform != 'darwin':
            self.skipTest('macOS packaged CLI memory gate')
        with (self.codex / 'large-history.jsonl').open('w') as f:
            f.write(json.dumps({'type': 'session_meta', 'payload': {'id': 'memory-a'}}) + '\n')
            for index in range(1, 100001):
                f.write(json.dumps(self.codex_row('2026-01-01T00:00:00Z', index, 0, index)) + '\n')
            f.write(json.dumps(self.codex_row('2026-01-02T00:00:00Z', 100001, 0, 100001,
                {'input_tokens': 1, 'output_tokens': 1})) + '\n')
        proc = subprocess.run(['/usr/bin/time', '-l', self.cli, 'usage',
            '--state-root', str(self.state), '--claude-root', str(self.claude),
            '--codex-root', str(self.codex), '--journal', str(self.journal),
            '--since', '2026-01-02T00:00:00Z', '--json'], capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result['totals']['input_tokens'], 1)
        self.assertEqual(result['totals']['output_tokens'], 1)
        rss = int(re.search(r'(\d+)\s+maximum resident set size', proc.stderr).group(1))
        print(json.dumps({'synthetic_pre_window_records': 100000, 'maximum_rss_bytes': rss}))
        self.assertLess(rss, 128 * 1024 * 1024, 'historical samples must not remain resident')

    @unittest.skipUnless(os.environ.get('C11_ACTIVITY_MEMORY_PROBE') == '1',
                         'large report RSS probe runs on CI or explicitly admitted Atlas job')
    def test_report_large_history_retains_compact_events_only(self):
        if sys.platform != 'darwin':
            self.skipTest('macOS packaged CLI memory gate')
        path = self.state / 'events/events-synthetic.ndjson'
        with path.open('w') as f:
            for index in range(100000):
                row = {'v': 2, 'instance': 'synthetic', 'seq': index + 1,
                       'ts': '2026-01-02T00:00:00Z',
                       'type': 'log.opened' if index == 0 else 'metadata.changed',
                       'workspace': 'workspace-a', 'panel': 'panel-a',
                       'payload': {'key': 'description', 'value': 'x' * 512, 'source': 'explicit'}}
                f.write(json.dumps(row) + '\n')
        proc = subprocess.run(['/usr/bin/time', '-l', self.cli, 'report',
            '--instance', 'synthetic', '--state-root', str(self.state),
            '--claude-root', str(self.claude), '--codex-root', str(self.codex),
            '--journal', str(self.journal), '--format', 'json'],
            capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result['daily'][0]['events'], 100000)
        self.assertEqual(result['workspaces'][0]['topics'], [])
        rss = int(re.search(r'(\d+)\s+maximum resident set size', proc.stderr).group(1))
        print(json.dumps({'synthetic_report_records': 100000, 'maximum_rss_bytes': rss}))
        self.assertLess(rss, 128 * 1024 * 1024, 'report must retain typed events, not raw JSON payloads')

    def test_bad_input_is_rejected(self):
        self.run_cli('usage', '--by', 'account', ok=False)
        self.run_cli('usage', '--since', 'garbage', ok=False)
        self.run_cli('report', '--format', 'html', ok=False)
        self.run_cli('report', '--instance', 'synthetic', '--all-instances', ok=False)


if __name__ == '__main__':
    unittest.main()
