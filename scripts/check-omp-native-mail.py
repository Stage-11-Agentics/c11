#!/usr/bin/env python3
"""Real omp TUI native-route proof in an already running, omp-staged sandbox.
Usage: check-omp-native-mail.py RUN_ID [--out DIR] [--disable-native-control]
Stage first: sandbox-agent.sh RUN_ID stage omp (controlled provider fixture).
The control deliberately disables native delivery; the native assertions must fail.
No provider credentials are used. Only sandbox-* commands address the guest.
"""
import argparse
import json
import pathlib
import shlex
import subprocess
import time
import uuid

DOORBELL = 'You have mail: run c11 mailbox recv --ack when you want to receive it.'
SCRIPTS = pathlib.Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_id')
    parser.add_argument('--out', type=pathlib.Path, default=pathlib.Path('/tmp/c11-omp-native-proof'))
    parser.add_argument('--disable-native-control', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    panels = []
    targets = []
    observations = {}

    def command(script, *argv):
        result = subprocess.run([str(SCRIPTS / script), args.run_id, *map(str, argv)],
                                text=True, capture_output=True, timeout=45)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return result.stdout.strip()

    def c11(*argv):
        if '--json' in argv:
            argv = ('--json', '--id-format', 'both', *(arg for arg in argv if arg != '--json'))
        return command('sandbox-agent.sh', 'c11', *argv)

    def guest(code, *argv):
        return command('sandbox-exec.sh', '/usr/bin/python3', '-c', code, *argv)

    def wait(label, probe, seconds=35):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = probe()
            if value:
                return value
            time.sleep(0.5)
        raise AssertionError('Timed out: ' + label)

    workspace = json.loads(c11('current-workspace', '--json'))['workspace_id']
    nonce = uuid.uuid4().hex[:8]
    sender = json.loads(c11('new-panel', '--workspace', workspace, '--no-focus', '--json'))['panel_id']
    panels.append(sender)

    def send_command(text):
        c11('send', '--workspace', workspace, '--panel', sender, text)

    def launch(label, disabled=False):
        address = 'omp-proof-' + label + '-' + nonce
        proof_log = '/tmp/' + address + '.jsonl'
        options = ['launch-agent', '--type', 'omp', '--workspace', workspace, '--title', address,
                   '--prompt', 'READY-' + address, '--env', 'C11_OMP_PROOF_LOG=' + proof_log, '--json']
        if disabled:
            options += ['--env', 'C11_OMP_NATIVE_MAIL_DISABLED=1']
        panel = json.loads(c11(*options))['panel_id']
        panels.append(panel)
        for key, value in [('mailbox.address', address), ('mailbox.delivery', 'stdin')]:
            c11('set-metadata', '--workspace', workspace, '--panel', panel, '--key', key, '--value', value, '--type', 'string')
        target = dict(panel=panel, address=address, proof_log=proof_log)
        targets.append(target)
        wait('omp ready: ' + label, lambda: any(e.get('event') == 'session_start' for e in inspect(target)['events']), 90)
        return target

    def inspect(target):
        code = '''import json,pathlib,sys
root=pathlib.Path.home()/'Library/Application Support/c11/workspaces'/sys.argv[1].upper()/'mailboxes'
def lines(path):
 if not path.exists(): return []
 out=[]
 for line in path.read_text().splitlines():
  try: out.append(json.loads(line))
  except ValueError: pass
 return out
inbox=root/sys.argv[2].lower()
print(json.dumps(dict(events=lines(pathlib.Path(sys.argv[3])),dispatch=lines(root/'_dispatch.log'),unread=[p.stem for p in inbox.glob('*.msg')],read=[p.stem for p in (inbox/'_read').glob('*.msg')])))'''
        return json.loads(guest(code, workspace, target['panel'], target['proof_log']))

    def mail(target):
        result = '/tmp/omp-send-' + uuid.uuid4().hex
        send_command('c11 mailbox send --to ' + shlex.quote(target['address']) + ' --body PROOF > ' + shlex.quote(result))
        code = 'import pathlib,sys;p=pathlib.Path(sys.argv[1]);print(p.read_text().strip() if p.exists() else "")'
        return wait('sibling mail ID', lambda: guest(code, result))

    def submitted(target, mail_id, route):
        data = inspect(target)
        rows = [e for e in data['dispatch'] if e.get('id') == mail_id and e.get('outcome') == 'doorbell' and e.get('reason') == 'submitted']
        if not rows:
            return None
        assert len(rows) == 1, rows
        assert rows[0]['route'] == route, rows
        return data

    def doorbells(data, event):
        return [e for e in data['events'] if e.get('role') == 'custom' and e.get('event') == event and e.get('text') == DOORBELL]

    try:
        native = launch('native', args.disable_native_control)
        draft = 'UNSENT-OMP-DRAFT-' + nonce
        c11('send', '--workspace', workspace, '--panel', native['panel'], '--raw', '--no-submit', draft)
        native_id = mail(native)
        data = wait('native accepted with draft', lambda: submitted(native, native_id, 'omp_extension'))
        # omp's own message_start, exact text, composer untouched before and after the turn it started.
        starts = doorbells(data, 'message_start')
        assert len(starts) == 1 and starts[0]['editor'] == draft, starts
        data = wait('doorbell turn finished', lambda: (lambda d: d if any(e.get('event') == 'agent_end' and e['at'] >= starts[0]['at'] for e in d['events']) else None)(inspect(native)))
        assert [e['editor'] for e in data['events'] if e.get('event') == 'agent_end' and e['at'] >= starts[0]['at']] == [draft], data['events']
        assert native_id in data['unread'] and native_id not in data['read'], data
        observations['native_draft'] = data
        c11('focus-panel', '--workspace', workspace, '--panel', native['panel'])
        guest('import pathlib,subprocess,sys;app=next((pathlib.Path.home()/"c11-sandbox/apps"/sys.argv[1]).glob("*.app"));subprocess.run(["/usr/bin/osascript","-e","tell application " + chr(34) + str(app) + chr(34) + " to activate"],check=True)', args.run_id)
        observations['native_screen'] = c11('read-screen', '--workspace', workspace, '--panel', native['panel'], '--lines', '80')
        command('sandbox-shot.sh', args.out / 'native-draft.png')
        send_command('c11 mailbox recv --panel ' + shlex.quote(native['panel']) + ' --ack > /tmp/omp-ack-' + nonce)
        wait('explicit recv claims envelope', lambda: native_id in inspect(native)['read'])

        # Real TUI turn lasts eight seconds. Mail arrives while that turn runs,
        # and the operator types a new draft during it.
        c11('send-key', '--workspace', workspace, '--panel', native['panel'], 'ctrl+u')
        c11('send', '--workspace', workspace, '--panel', native['panel'], 'BUSY-' + nonce)
        wait('busy turn started', lambda: any(e.get('text') == 'BUSY-' + nonce and e.get('event') == 'message_start' for e in inspect(native)['events']))
        mid_draft = 'MID-TURN-DRAFT-' + nonce
        c11('send', '--workspace', workspace, '--panel', native['panel'], '--raw', '--no-submit', mid_draft)
        busy_id = mail(native)
        data = wait('idle-edge native accepted', lambda: submitted(native, busy_id, 'omp_extension'))
        busy_end = next(e['at'] for e in data['events'] if e.get('text') == 'COMPLETED: BUSY-' + nonce and e.get('event') == 'message_end')
        invitations = [e for e in doorbells(data, 'message_start')]
        assert len(invitations) == 2 and invitations[-1]['at'] >= busy_end, (busy_end, invitations)
        assert invitations[-1]['editor'] == mid_draft, invitations
        assert busy_id in data['unread'], data
        observations['busy_idle_edge'] = data

        send_command('c11 mailbox recv --panel ' + shlex.quote(native['panel']) + ' --ack > /tmp/omp-busy-ack-' + nonce)
        wait('busy envelope claimed', lambda: busy_id in inspect(native)['read'])
        switches = sum(e.get('event') == 'session_switch' for e in data['events'])
        c11('send-key', '--workspace', workspace, '--panel', native['panel'], 'ctrl+u')
        c11('send', '--workspace', workspace, '--panel', native['panel'], '/new')
        wait('new omp session', lambda: sum(e.get('event') == 'session_switch' for e in inspect(native)['events']) > switches)
        new_id = mail(native)
        observations['new_session'] = wait('native rebound after /new', lambda: submitted(native, new_id, 'omp_extension'))

        # Control: native disabled. omp has no typed composer reader, so the
        # invitation is not typed: the mail waits unread and no turn starts.
        typed = launch('typed', True)
        typed_id = mail(typed)
        time.sleep(12)
        data = inspect(typed)
        assert not doorbells(data, 'message_start'), data['events']
        assert typed_id in data['unread'], data
        assert not [e for e in data['dispatch'] if e.get('id') == typed_id and e.get('outcome') == 'doorbell' and e.get('reason') == 'submitted'], data['dispatch']
        observations['typed_fallback'] = data
        observations['typed_screen'] = c11('read-screen', '--workspace', workspace, '--panel', typed['panel'], '--lines', '80')
        # Nothing was written under the guest's own ~/.omp; omp kept its state in a private HOME.
        listing = guest('import json,os,pathlib;h=pathlib.Path.home();o=h/".omp";p=h/"c11-sandbox/agents/omp-home/.omp";print(json.dumps(dict(guest_dot_omp_exists=o.exists(),private_files=sorted(str(f.relative_to(p)) for f in p.rglob("*") if f.is_file())[:50])))')
        observations['omp_state'] = json.loads(listing)
        assert observations['omp_state']['guest_dot_omp_exists'] is False, listing
        observations['passed'] = True
        print('PASS: native draft, mid-turn draft, idle edge, /new session, typed control waits, nothing under ~/.omp')
    finally:
        for target in targets:
            try:
                observations[target['address']] = inspect(target)
                observations[target['address'] + '_screen'] = c11('read-screen', '--workspace', workspace, '--panel', target['panel'], '--lines', '80')
            except Exception as error:
                observations[target['address'] + '_error'] = str(error)
        observations['seconds'] = round(time.monotonic() - started, 3)
        (args.out / 'proof.json').write_text(json.dumps(observations, indent=2) + '\n')
        # The guest remains owned by the caller, but no proof panel is left running.
        for panel in reversed(panels):
            try:
                c11('close-panel', '--workspace', workspace, '--panel', panel)
            except Exception as error:
                print('Panel cleanup:', error)


if __name__ == '__main__':
    main()
