#!/usr/bin/env python3
"""C11-273 packaged append/projection checks, through sandbox-tests-v2.sh only.

Synthetic structural inputs exercise the actual CLI, socket, conversation
owner, SQLite and UI projection. They are not native provider captures.
Restart/computer-use proof is a separate scenario on the same tagged artifact.
"""
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import tempfile
import time
import uuid

from cmux import cmux
from test_claude_attention_batch import eventually, legacy


def main():
    path, cli = os.environ['C11_SOCKET_PATH'], os.environ['C11_CLI']
    assert 'sandbox' in path or 'c11-sb-' in path, 'Use sandbox-tests-v2.sh'
    with cmux(path) as client, tempfile.TemporaryDirectory(prefix='c11-journal-') as temporary:
        workspace = client.new_workspace()
        tab = client.list_surfaces(workspace)[0][1]
        sibling = client._call('tab.create', {'workspace_id': workspace, 'type': 'terminal'})['tab_id']
        env = {k: v for k, v in os.environ.items() if not k.startswith(('C11_', 'CMUX_'))}
        env.update(CMUX_WORKSPACE_ID=workspace, CMUX_SURFACE_ID=tab,
                   CMUX_CLAUDE_HOOK_STATE_PATH=str(Path(temporary) / 'sessions.json'))
        app = next(p for p in Path(cli).resolve().parents if p.suffix == '.app')
        bundle = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
        env['CMUX_BUNDLE_ID'] = bundle
        journal_dir = Path.home() / 'Library/Application Support/c11/journal' / bundle
        session = str(uuid.uuid4())

        def hook(event, fields=None):
            payload = {'session_id': session, **(fields or {})}
            result = subprocess.run([cli, '--socket', path, 'claude-hook', event],
                                    input=json.dumps(payload), text=True, capture_output=True, env=env, timeout=10)
            assert result.returncode == 0, result.stderr

        def state(target=tab):
            return client._call('tab.get_metadata', {'tab_id': target})['metadata']['journal']

        def phase(expected, target=tab):
            eventually(lambda: state(target)['phase'] == expected, f'{target}: {expected}; got {state(target)}')

        def draft(kind, **fields):
            return {'schema_version': 1, 'event_id': str(uuid.uuid4()), 'kind': kind,
                    'emitted_at_ms': int(time.time() * 1000), 'tab_id': tab,
                    'workspace_id': workspace, 'session_id': session, 'agent_kind': 'claude-code',
                    'source': 'hook', 'adapter': 'claude_hook', 'native_event': 'PreToolUse', **fields}

        try:
            hook('session-start')
            hook('prompt-submit')
            phase('working')
            hook('pre-tool-use', {'tool_name': 'AskUserQuestion', 'permission_mode': 'bypassPermissions',
                                 'tool_use_id': 'synthetic-ask', 'tool_input': {'questions': [{'question': 'PRIVATE-SENTINEL-C11-273'}]}})
            phase('blocked')
            before = state()
            legacy(path, f'clear_notifications --tab={workspace} --panel={tab}')
            legacy(path, f'report_agent_activity working --tab={workspace} --panel={tab}')
            legacy(path, f'report_agent_activity idle --tab={workspace} --panel={sibling}')
            hook('pre-tool-use', {'tool_name': 'Bash'})
            hook('stop')
            phase('blocked')
            assert state()['sequence'] == before['sequence'], 'seen, sibling, legacy or Stop changed blocked projection'
            assert state()['reason'] == 'question'
            print('PASS seen/sibling/legacy/late tool/Stop preserve blocked request')

            hook('prompt-submit')
            phase('working')
            hook('stop')
            phase('idle')
            before = state()
            hook('pre-tool-use', {'tool_name': 'Bash'})
            assert state()['phase'] == 'idle' and state()['sequence'] == before['sequence']
            print('PASS delayed PreToolUse cannot reopen terminal barrier')

            hook('prompt-submit')
            phase('working')
            capture = json.loads((Path(__file__).parent / 'fixtures' / 'c11-263-native-exit-plan-before.json').read_text())
            native_plan = next(row for row in capture['hooks']
                               if row.get('hook_event_name') == 'PreToolUse' and row.get('tool_name') == 'ExitPlanMode')
            hook('pre-tool-use', {'tool_name': native_plan['tool_name'],
                                 'permission_mode': native_plan['permission_mode']})
            phase('blocked')
            assert state()['reason'] == 'plan_review'
            print('PASS recorded ExitPlanMode hook shape reaches plan-review journal projection')
            hook('prompt-submit')
            phase('working')
            event = draft('agent.plan_review.requested', tool_class='exit_plan_mode', request_id='synthetic-plan')
            # Lost reply after actual write: retry must return the original committed receipt.
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.connect(path)
                connection.sendall((json.dumps({'id': 'lost-ack', 'method': 'agent.event.append', 'params': {'event': event}}) + '\n').encode())
                time.sleep(.1)
            phase('blocked')
            receipt = client._call('agent.event.append', {'event': event})
            assert receipt['replayed'] is True
            assert client._call('agent.event.append', {'event': event})['sequence'] == receipt['sequence']
            try:
                client._call('agent.event.append', {'event': {**event, 'kind': 'agent.question.requested'}})
            except Exception as error:
                assert 'idempotency_conflict' in str(error), error
            else:
                raise AssertionError('changed retry accepted')
            print('PASS lost acknowledgement dedupes and changed draft conflicts')

            child = draft('agent.turn.completed', native_event='Stop', is_child=True, parent_session_id=session)
            assert client._call('agent.event.append', {'event': child})['projection_effect'] == 'child'
            stale = draft('agent.turn.started', native_event='UserPromptSubmit', session_id='old-session')
            assert client._call('agent.event.append', {'event': stale})['projection_effect'] == 'unattributed'
            phase('blocked')
            print('PASS child and stale session cannot change current owner')

            # Public append rejects bodies before any storage; the hook extracts only structure.
            invalid = {**event, 'event_id': str(uuid.uuid4()), 'body': 'PRIVATE-SENTINEL-C11-273'}
            result = subprocess.run([cli, '--socket', path, 'agent-event', 'append', '--stdin'],
                                    input=json.dumps(invalid), text=True, capture_output=True, env=env, timeout=2)
            assert result.returncode != 0
            offline = draft('agent.question.requested', request_id='offline-ask')
            start = time.monotonic()
            result = subprocess.run([cli, '--socket', str(Path(temporary) / 'absent.sock'), 'agent-event', 'append', '--stdin'],
                                    input=json.dumps(offline), text=True, capture_output=True, env=env, timeout=2)
            assert result.returncode == 0 and json.loads(result.stdout)['spooled'], (result.stdout, result.stderr)
            elapsed = time.monotonic() - start
            ready = list((journal_dir / 'spool').glob('*.ready'))
            assert any(json.loads(p.read_text())['event_id'].lower() == offline['event_id'] for p in ready)
            for p in journal_dir.rglob('*'):
                if p.is_file():
                    assert b'PRIVATE-SENTINEL-C11-273' not in p.read_bytes(), str(p)
            print(f'PASS offline spool preserves event identity and structural privacy ({elapsed * 1000:.1f} ms)')
        finally:
            client.close_workspace(workspace)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
