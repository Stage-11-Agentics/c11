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
        tabs += [client._call('tab.create', {'workspace_id': workspace, 'type': 'terminal'})['tab_id'] for _ in range(2)]
        owners = [str(uuid.uuid4()) for _ in tabs]
        for tab, owner in zip(tabs, owners):
            client._call('conversation.push', {'tab_id': tab, 'kind': 'claude-code', 'id': owner, 'source': 'hook'})

        def event(index, kind, **fields):
            return dict(schema_version=1, event_id=str(uuid.uuid4()), kind=kind,
                        emitted_at_ms=int(time.time() * 1000), tab_id=tabs[index], workspace_id=workspace,
                        session_id=owners[index], agent_kind='claude-code', source='hook', adapter='claude_hook',
                        native_event='UserPromptSubmit' if kind == 'agent.turn.started' else 'PreToolUse', **fields)

        def append(draft):
            return client._call('agent.event.append', {'event': draft})

        for index in range(3):
            append(event(index, 'agent.turn.started'))
        append(event(0, 'agent.question.requested', request_id='synthetic-open-ask'))
        client._call('session.save', {'include_scrollback': False})
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

        def restart():
            pid = int(subprocess.check_output(['/usr/sbin/lsof', '-t', '-a', '-U', address], text=True).strip())
            command = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'command='], text=True).strip()
            assert command == str(executable), 'Refusing to kill anything except this guest bundle'
            client.close()
            os.kill(pid, signal.SIGKILL)
            time.sleep(.3)
            Path(address).unlink(missing_ok=True)
            launch_env = {k: os.environ[k] for k in ('HOME', 'USER', 'LOGNAME', 'PATH', 'TMPDIR') if k in os.environ}
            launch_env.update(C11_SOCKET_MODE='automation', C11_ALLOW_SOCKET_OVERRIDE='1',
                              C11_SOCKET=address, C11_SOCKET_PATH=address, C11_QA_LAUNCH='resume',
                              C11_DEBUG_LOG='/tmp/c11-sandbox-journal-restart.log',
                              CMUXD_UNIX_PATH='/tmp/c11-sandbox-journal-restart-daemon.sock')
            with open('/tmp/c11-sandbox-journal-restart.stdout', 'wb') as output:
                subprocess.Popen([str(executable)], env=launch_env, stdout=output, stderr=output, start_new_session=True)
            eventually(lambda: Path(address).is_socket(), 'resume socket', timeout=30)
            client.connect()
            wait_for_session_ready(client)

        def state(index):
            return client._call('tab.get_metadata', {'tab_id': tabs[index]})['metadata']['journal']

        restart()
        eventually(lambda: state(0)['phase'] == 'blocked', 'restored open ask', timeout=15)
        eventually(lambda: state(2)['phase'] == 'blocked', 'offline ask drained', timeout=15)
        for index in (0, 2):
            assert state(index)['confirmation'] == 'unconfirmed'
            assert state(index)['connection'] == 'disconnected'
        assert state(1)['confirmation'] == 'unconfirmed'
        old_running = client._call('tab.get_metadata', {'tab_id': tabs[1]})['metadata']
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
