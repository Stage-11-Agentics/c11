#!/usr/bin/env python3
"""C11-273 crash/replay proof. Run only through sandbox-tests-v2.sh.

Uses structural synthetic events through the packaged CLI, a normal session
save, SIGKILL of the exact guest bundle process, and QA resume. No store seeding.
"""
import json
import os
from pathlib import Path
import plistlib
import signal
import sqlite3
import subprocess
import time
import uuid
from datetime import datetime, timezone

from cmux import cmux, cmuxError
from test_claude_attention_batch import eventually


def wait_for_session_ready(client):
    # The listener is available before C11-297 finishes restoring tabs.
    # Retry only its explicit readiness response, not journal failures.
    def session_ready():
        try:
            client._call('workspace.list', timeout_s=2)
        except cmuxError as error:
            if str(error).startswith('not_ready:'):
                return False
            raise
        return True
    eventually(session_ready, 'session restoration readiness', timeout=30)


def main():
    address, cli = os.environ['C11_SOCKET_PATH'], os.environ['C11_CLI']
    app = next(p for p in Path(cli).resolve().parents if p.suffix == '.app')
    assert address.startswith('/tmp/c11-sandbox-') and app.parent.parent.name == 'apps'
    assert Path('/Volumes/My Shared Files/out').is_dir()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    bundle = info['CFBundleIdentifier']
    assert bundle.startswith('com.stage11.c11.debug.')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    root = Path.home() / 'Library/Application Support/c11/journal' / bundle
    env = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
    env['CMUX_BUNDLE_ID'] = bundle
    with cmux(address) as client:
        wait_for_session_ready(client)
        workspace = client.new_workspace()
        tabs = [client.list_surfaces(workspace)[0][1]]
        tabs += [client._call('panel.create', {'workspace_id': workspace, 'type': 'terminal'})['panel_id'] for _ in range(2)]
        owners = [str(uuid.uuid4()) for _ in tabs]
        for tab, owner in zip(tabs, owners):
            client._call('conversation.push', {'tab_id': tab, 'kind': 'claude-code', 'id': owner, 'source': 'hook'})

        def event(index, kind, **fields):
            return dict(schema_version=1, event_id=str(uuid.uuid4()), kind=kind,
                        emitted_at_ms=int(time.time() * 1000), tab_id=tabs[index], workspace_id=workspace,
                        session_id=owners[index], agent_kind='claude-code', source='hook', adapter='claude_hook',
                        native_event=('SessionStart' if kind == 'agent.session.started' else
                                      'UserPromptSubmit' if kind == 'agent.turn.started' else 'PreToolUse'), **fields)

        def append(draft):
            return client._call('agent.event.append', {'event': draft})

        for index in range(3):
            append(event(index, 'agent.session.started'))
            append(event(index, 'agent.turn.started', turn_id=f'synthetic-turn-{index}'))
        append(event(0, 'agent.question.requested', request_id='synthetic-open-ask', turn_id='synthetic-turn-0'))
        append(event(1, 'agent.question.requested', request_id='synthetic-delayed-owner-ask', turn_id='synthetic-turn-1'))
        # Keep this baseline durable but make its exact owner arrive only after
        # the next process has completed its startup cache pass.
        client._call('conversation.clear', {'tab_id': tabs[1]})
        client._call('session.save', {'include_scrollback': False})
        with sqlite3.connect(root / 'lifecycle.sqlite3') as database:
            attached_event_count = database.execute(
                'SELECT count(*) FROM journal_events WHERE tab_id=?', (tabs[1],)).fetchone()[0]
            attached_turn = next(json.loads(row[0]) for row in database.execute(
                'SELECT event FROM journal_events WHERE tab_id=? ORDER BY sequence DESC', (tabs[1],))
                if json.loads(row[0])['draft']['kind'] == 'agent.turn.started')
        # Durable offline ask, a retry of an already committed event, one stale
        # owner, and a truncated tail all traverse the real startup drainer.
        committed = event(0, 'agent.state.changed', signal='tool_activity')
        receipt = append(committed)
        offline = event(2, 'agent.plan_review.requested', request_id='synthetic-offline-plan')
        stale = event(2, 'agent.question.requested', request_id='stale-ask')
        stale['session_id'] = str(uuid.uuid4())
        for draft in (committed, offline, stale):
            result = subprocess.run([cli, '--socket', '/tmp/c11-sandbox-journal-absent.sock',
                                     'agent-event', 'append', '--stdin'], input=json.dumps(draft),
                                    text=True, capture_output=True, env=env, timeout=2)
            assert result.returncode == 0 and json.loads(result.stdout)['spooled']
        ready = next((root / 'spool').glob('*.ready'))
        with ready.open('ab') as output:
            output.write(b'{"truncated":')

        def close_without_relaunch():
            pid = int(subprocess.check_output(['/usr/sbin/lsof', '-t', '-a', '-U', address], text=True).strip())
            command = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'command='], text=True).strip()
            assert command == str(executable), 'Refusing to kill anything except this guest bundle'
            client.close()
            os.kill(pid, signal.SIGKILL)
            time.sleep(.3)
            Path(address).unlink(missing_ok=True)

        def launch_after_crash():
            launch_env = {k: os.environ[k] for k in ('HOME', 'USER', 'LOGNAME', 'PATH', 'TMPDIR') if k in os.environ}
            launch_env.update(C11_SOCKET_MODE='automation', C11_ALLOW_SOCKET_OVERRIDE='1',
                              C11_SOCKET=address, C11_SOCKET_PATH=address, C11_QA_LAUNCH='resume',
                              C11_DEBUG_LOG='/tmp/c11-sandbox-journal-restart.log',
                              CMUXD_UNIX_PATH='/tmp/c11-sandbox-journal-restart-daemon.sock')
            with open('/tmp/c11-sandbox-journal-restart.stdout', 'wb') as output:
                subprocess.Popen([str(executable)], env=launch_env, stdout=output, stderr=output, start_new_session=True)
            eventually(lambda: Path(address).is_socket(), 'resume socket', timeout=30)

        def restart():
            close_without_relaunch()
            launch_after_crash()
            client.connect()
            wait_for_session_ready(client)

        def state(index):
            return client._call('panel.get_metadata', {'panel_id': tabs[index]})['metadata']['journal']

        # Query while the app is actually down. The confirmed working baseline
        # must be projected through replay policy as a candidate without writing
        # a synthetic connection_lost event to make it appear historical.
        close_without_relaunch()
        offline = subprocess.run(
            [cli, '--socket', '/tmp/c11-sandbox-offline-roster-absent.sock',
             'agents', '--json', '--bundle-id', bundle],
            text=True, capture_output=True, env=env, timeout=5)
        assert offline.returncode == 0, offline.stderr
        offline_document = json.loads(offline.stdout)
        candidates = offline_document['restore_candidates']
        crash_live = next(row for row in candidates if row['panel_id'] == tabs[1])
        assert crash_live['label'] == 'historical_candidate', crash_live
        assert crash_live['confirmation'] == 'unconfirmed'
        with sqlite3.connect(root / 'lifecycle.sqlite3') as database:
            stored = database.execute('SELECT state FROM journal_current WHERE owner LIKE ?', (f'%{owners[1]}%',)).fetchone()
            stored_state = json.loads(stored[0]) if stored is not None else None
            assert stored_state is not None and stored_state['confirmation'] == 'confirmed'
            assert stored_state['connection'] == 'live', stored_state
            rows = database.execute('SELECT event FROM journal_events WHERE tab_id=?', (tabs[1],)).fetchall()
        assert not any(json.loads(row[0])['draft'].get('signal') == 'connection_lost' for row in rows)
        print('PASS offline crash-live candidate comes from a confirmed baseline with no connection_lost event')

        launch_after_crash()
        client.connect()
        wait_for_session_ready(client)
        eventually(lambda: state(0)['phase'] == 'blocked', 'restored open ask', timeout=15)
        eventually(lambda: state(2)['phase'] == 'blocked', 'offline ask drained', timeout=15)
        for index in (0, 2):
            assert state(index)['confirmation'] == 'unconfirmed'
            assert state(index)['connection'] == 'disconnected'
        expected_turn_start = datetime.fromtimestamp(
            attached_turn['committed_at_ms'] / 1000, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        attached = {}
        pre_attach = client._call('agents.list', {})
        pre_attach_row = next(row for row in pre_attach['panels'] if row['panel_id'] == tabs[1])
        assert pre_attach_row['session_id'] is None and pre_attach_row['turn_started_at'] is None, \
            'fixture owner and its turn cache must be absent after startup cache pass'
        client._call('conversation.push', {
            'tab_id': tabs[1], 'kind': 'claude-code', 'id': owners[1], 'source': 'hook'
        })

        def restored_caches_attached():
            document = client._call('agents.list', {})
            row = next(row for row in document['panels'] if row['panel_id'] == tabs[1])
            if row['state'] == 'blocked' and row['turn_started_at'] == expected_turn_start:
                attached.update(document=document, row=row)
                return True
            return False

        eventually(restored_caches_attached, 'late owner registration hydrates ask and turn caches', timeout=15)
        live_roster, restored_deferred = attached['document'], attached['row']
        eventually(lambda: state(1)['phase'] == 'blocked'
                   and state(1)['confirmation'] == 'unconfirmed'
                   and state(1)['connection'] == 'disconnected',
                   'late owner attaches the offline baseline', timeout=15)
        live_candidate = next(row for row in live_roster['restore_candidates'] if row['panel_id'] == tabs[1])
        assert live_candidate['label'] == 'historical_candidate', live_candidate
        assert restored_deferred['state'] == 'blocked', restored_deferred
        assert restored_deferred['turn_started_at'] == expected_turn_start, restored_deferred
        assert restored_deferred['confirmation'] == 'unconfirmed'
        with sqlite3.connect(root / 'lifecycle.sqlite3') as database:
            assert database.execute(
                'SELECT count(*) FROM journal_events WHERE tab_id=?', (tabs[1],)).fetchone()[0] == attached_event_count
        old_running = client._call('panel.get_metadata', {'panel_id': tabs[1]})['metadata']
        assert old_running.get('activity') != 'working', 'old running must not paint present liveness'
        assert append(committed)['sequence'] == receipt['sequence']
        assert not list((root / 'spool').glob('*.ready'))
        print('PASS force-kill/resume restores asks unconfirmed; old running is not live')
        print('PASS startup spool drains once, dedupes committed retry, rejects stale owner and truncated tail')
        with sqlite3.connect(root / 'lifecycle.sqlite3') as database:
            before = database.execute('SELECT count(*) FROM journal_events').fetchone()[0]
        client._call('session.save', {'include_scrollback': False})
        restart()
        eventually(lambda: state(0)['phase'] == 'blocked', 'second replay', timeout=15)
        with sqlite3.connect(root / 'lifecycle.sqlite3') as database:
            assert database.execute('SELECT count(*) FROM journal_events').fetchone()[0] == before
        append(event(0, 'agent.turn.started'))
        eventually(lambda: state(0)['phase'] == 'working' and state(0)['confirmation'] == 'confirmed', 'fresh reconciliation')
        print('PASS repeated restart adds no events; fresh native submission reconciles prior ask')
        client.close_workspace(workspace)


if __name__ == '__main__':
    main()
