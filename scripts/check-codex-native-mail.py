#!/usr/bin/env python3
"""Codex native/typed mail acceptance in a running Codex-staged Atlas sandbox.
Usage: check-codex-native-mail.py RUN_ID [--out DIR]
Drives real Codex panels through the packaged wrapper with the opt-in setting:
native delivery with an operator draft, /new, a cold thread, a killed relay,
an exited TUI, an operator --no-daemon launch, and the setting turned off.
Uses the Codex credential staged by sandbox-agent.sh; never reads or exports it.
Never drives a Codex picker; the work directory is the staged trusted one.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

SCRIPTS = Path(__file__).resolve().parent
DOORBELL = 'You have mail: run c11 mailbox recv --ack when you want to receive it.'
WORK = '/Users/admin/c11-sandbox/work'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_id')
    parser.add_argument('--out', type=Path, default=Path('/tmp/c11-codex-native-proof'))
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    panels, targets, observations = [], [], {}
    nonce = uuid.uuid4().hex[:8]
    root = '/tmp/c11-codex-proof-' + nonce

    def command(script, *argv, timeout=60):
        result = subprocess.run(['/bin/bash', str(SCRIPTS / script), args.run_id, *map(str, argv)],
                                text=True, capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return result.stdout.strip()

    def c11(*argv):
        if '--json' in argv:
            argv = ('--json', '--id-format', 'both', *(arg for arg in argv if arg != '--json'))
        return command('sandbox-agent.sh', 'c11', *argv)

    def guest(code, *argv):
        return command('sandbox-exec.sh', '/usr/bin/python3', '-c', code, *argv)

    def wait(label, probe, seconds=60):
        deadline = min(time.monotonic() + seconds, started + 900)
        while time.monotonic() < deadline:
            value = probe()
            if value:
                return value
            time.sleep(.5)
        raise AssertionError('Timed out: ' + label)

    def note(label, value):
        observations[label] = value
        print(label + ':', json.dumps(value)[:300], flush=True)

    bundle_id = guest('''from pathlib import Path
import plistlib,sys
app=next((Path.home()/'c11-sandbox/apps'/sys.argv[1]).glob('*.app'))
print(plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleIdentifier'])''', args.run_id)

    def setting(on):
        guest('import subprocess,sys;subprocess.run(["/usr/bin/defaults","write",sys.argv[1],"codexNativeMailbox","-bool",sys.argv[2]],check=True)',
              bundle_id, 'true' if on else 'false')

    def tenant():
        return json.loads(guest('''from pathlib import Path
import hashlib,json
home=Path.home()/'.codex'
print(json.dumps({n:(hashlib.sha256((home/n).read_bytes()).hexdigest() if (home/n).exists() else None) for n in ['config.toml','hooks.json']}))'''))

    def processes():
        return json.loads(guest('''import json,subprocess
rows=[l.strip().split(None,1) for l in subprocess.check_output(['/bin/ps','-ax','-o','pid=,command=']).decode().splitlines()]
print(json.dumps([[int(r[0]),r[1]] for r in rows if len(r)==2 and ('codex' in r[1])]))'''))

    def proxy_log():
        return json.loads(guest('''from pathlib import Path
import json,os
rows=[]
for p in sorted(Path('/tmp/c11-%d'%os.getuid()).glob('codex-*.log')):
 for line in p.read_text().splitlines():
  try:
   r=json.loads(line);r['file']=p.name;rows.append(r)
  except ValueError:pass
print(json.dumps(rows))'''))

    def inspect(target):
        return json.loads(guest('''from pathlib import Path
import json,sys
mail=Path.home()/'Library/Application Support/c11/workspaces'/sys.argv[1].upper()/'mailboxes'
def rows(path):
 if not path.exists():return []
 out=[]
 for line in path.read_text().splitlines():
  try:out.append(json.loads(line))
  except ValueError:pass
 return out
inbox=mail/sys.argv[2].lower()
print(json.dumps(dict(dispatch=rows(mail/'_dispatch.log'),unread=[p.stem for p in inbox.glob('*.msg')],read=[p.stem for p in (inbox/'_read').glob('*.msg')])))''', workspace, target['panel']))

    def screen(target, lines=60):
        return c11('read-screen', '--workspace', workspace, '--panel', target['panel'], '--lines', str(lines))

    def instructions(tag):
        return ('For this isolated c11 mailbox test reply exactly ' + tag + ' and wait. '
                'If a message starts with "You have mail", reply exactly C11_AWAKE_' + nonce + ' and run no tools. '
                'Do not change any files or configuration.')

    def launch(label, prompt=True, shell_command=None):
        address = 'codex-proof-' + label + '-' + nonce
        ready = 'C11_READY_' + label.upper() + '_' + nonce
        if shell_command is None:
            options = ['launch-agent', '--type', 'codex', '--workspace', workspace, '--title', address, '--cwd', WORK, '--json']
            if prompt:
                options += ['--prompt', instructions(ready)]
            panel = json.loads(c11(*options))['panel_id']
        else:
            panel = json.loads(c11('new-panel', '--workspace', workspace, '--no-focus', '--json'))['panel_id']
            c11('send', '--workspace', workspace, '--panel', panel, 'cd ' + WORK + ' && ' + shell_command)
        panels.append(panel)
        target = dict(panel=panel, address=address, label=label)
        targets.append(target)
        for key, value in [('mailbox.address', address), ('mailbox.delivery', 'stdin')]:
            c11('set-metadata', '--workspace', workspace, '--panel', panel, '--key', key, '--value', value, '--type', 'string')
        if prompt and shell_command is None:
            wait('ready: ' + label, lambda: ('• ' + ready) in screen(target), 120)
        else:
            wait('composer: ' + label, lambda: 'for shortcuts' in screen(target) or 'context left' in screen(target), 90)
        time.sleep(1)
        return target

    def mail(target):
        result = root + '/send-' + uuid.uuid4().hex
        c11('send', '--workspace', workspace, '--panel', sender,
            'mkdir -p ' + root + ' && c11 mailbox send --to ' + shlex.quote(target['address']) +
            ' --body C11_ENVELOPE_' + nonce + ' > ' + shlex.quote(result))
        return wait('mail ID', lambda: guest('from pathlib import Path;import sys;p=Path(sys.argv[1]);print(p.read_text().strip() if p.exists() else "")', result))

    def rows(target, mail_id):
        return [r for r in inspect(target)['dispatch'] if r.get('id') == mail_id and r.get('event') == 'handler']

    def submitted(target, mail_id):
        found = [r for r in rows(target, mail_id) if r.get('outcome') == 'doorbell' and r.get('reason') == 'submitted']
        return found[-1] if found else None

    def remote_pids():
        return {pid for pid, cmd in processes() if '--remote unix:///tmp/c11-' in cmd}

    workspace = json.loads(c11('current-workspace', '--json'))['workspace_id']
    sender = json.loads(c11('new-panel', '--workspace', workspace, '--no-focus', '--json'))['panel_id']
    panels.append(sender)
    observations['tenant_before'] = tenant()
    guest('import subprocess;subprocess.run(["/usr/local/bin/codex","app-server","daemon","start"],timeout=30,capture_output=True)')
    try:
        setting(True)

        # A. Native delivery to a warm thread, with an operator draft in the composer.
        native = launch('native')
        note('native_remote_processes', sorted(remote_pids()))
        assert remote_pids(), 'setting on: no Codex launched with --remote'
        draft = 'UNSENT_CODEX_DRAFT_' + nonce
        c11('send', '--workspace', workspace, '--panel', native['panel'], '--raw', '--no-submit', draft)
        first = mail(native)
        row = wait('native doorbell', lambda: submitted(native, first))
        assert row.get('route') == 'codex_queue', row
        wait('doorbell turn visible', lambda: '› ' + DOORBELL in screen(native) and 'C11_AWAKE_' + nonce in screen(native), 60)
        assert draft in screen(native), 'draft lost'
        note('A_native_draft', dict(row=row, unread=inspect(native)['unread']))
        c11('send-key', '--workspace', workspace, '--panel', native['panel'], 'ctrl+c')
        time.sleep(1)

        # B. /new: the next native delivery targets the new thread only.
        before = {r.get('thread') for r in proxy_log() if r.get('outcome') == 'accepted'}
        c11('send', '--workspace', workspace, '--panel', native['panel'], '/new')
        time.sleep(3)
        c11('send', '--workspace', workspace, '--panel', native['panel'], instructions('C11_READY_NEW_' + nonce))
        wait('new thread ready', lambda: '• C11_READY_NEW_' + nonce in screen(native), 120)
        time.sleep(1)
        second = mail(native)
        row = wait('native after /new', lambda: submitted(native, second))
        assert row.get('route') == 'codex_queue', row
        accepted = [r.get('thread') for r in proxy_log() if r.get('outcome') == 'accepted']
        assert accepted and accepted[-1] not in before, ('ring did not move to the new thread', accepted, before)
        wait('doorbell on new thread', lambda: '› ' + DOORBELL in screen(native), 30)
        note('B_new_thread', dict(row=row, accepted_threads=accepted))

        # C. A thread with no completed turn: native refuses, typed delivers.
        cold = launch('cold', prompt=False)
        third = mail(cold)
        row = wait('cold typed fallback', lambda: submitted(cold, third))
        assert row.get('route') == 'typed' and row.get('native_route') == 'codex_queue' and row.get('native_failure'), row
        note('C_cold_typed', dict(row=row, proxy=[r for r in proxy_log() if r.get('event') == 'ring'][-1]))

        # D. Relay killed under a live TUI: c11 logs the lost route.
        killed_pid = max(pid for pid, cmd in processes() if 'codex-mailbox-proxy' in cmd)
        guest('import os,signal,sys;os.kill(int(sys.argv[1]),signal.SIGKILL)', killed_pid)
        lost = wait('native_route_lost logged', lambda: [r for r in inspect(cold)['dispatch'] if r.get('event') == 'native_route_lost'], 15)
        time.sleep(2)
        note('D_relay_killed', dict(pid=killed_pid, lost=lost, screens={t['label']: screen(t, 8) for t in (native, cold)}))

        # E. Exited TUI: nothing rings into the shell left behind.
        for target in (native, cold):
            c11('send-key', '--workspace', workspace, '--panel', target['panel'], 'ctrl+c')
            time.sleep(.5)
            c11('send-key', '--workspace', workspace, '--panel', target['panel'], 'ctrl+c')
        time.sleep(4)
        fourth = mail(native)
        time.sleep(10)
        assert submitted(native, fourth) is None, rows(native, fourth)
        note('E_exited', dict(rows=rows(native, fourth), screen=screen(native, 10)))

        # F. Operator chose --no-daemon: no relay, typed delivery.
        remote_before = remote_pids()
        nodaemon = launch('nodaemon', prompt=False, shell_command='codex --no-daemon')
        assert remote_pids() <= remote_before, 'no-daemon launch got --remote'
        fifth = mail(nodaemon)
        row = wait('no-daemon typed', lambda: submitted(nodaemon, fifth))
        assert row.get('route') == 'typed' and not row.get('native_route'), row
        note('F_no_daemon', row)

        # G. Setting off: the wrapper adds nothing; typed delivery.
        setting(False)
        remote_before = remote_pids()
        off = launch('off')
        assert remote_pids() <= remote_before, 'setting off: Codex launched with --remote'
        sixth = mail(off)
        row = wait('setting off typed', lambda: submitted(off, sixth))
        assert row.get('route') == 'typed' and not row.get('native_route'), row
        note('G_setting_off', row)

        observations['passed'] = True
        print('PASS: native+draft, /new retarget, cold typed fallback, relay death logged, exited TUI, --no-daemon typed, setting off typed')
    finally:
        setting(False)
        for target in targets:
            try:
                observations[target['address'] + '_screen'] = screen(target, 30)
                for _ in range(2):
                    c11('send-key', '--workspace', workspace, '--panel', target['panel'], 'ctrl+c')
                    time.sleep(.3)
            except Exception as error:
                observations[target['address'] + '_cleanup'] = str(error)
        observations['proxy_log'] = proxy_log()
        for panel in reversed(panels):
            try:
                c11('close-panel', '--workspace', workspace, '--panel', panel)
            except Exception as error:
                observations['close_' + panel] = str(error)
        observations['tenant_after'] = tenant()
        observations['tenant_unchanged'] = observations['tenant_before'] == observations['tenant_after']
        observations['seconds'] = round(time.monotonic() - started, 3)
        (args.out / 'proof.json').write_text(json.dumps(observations, indent=2) + '\n')
        assert observations['tenant_unchanged'], 'Codex tenant config changed during the proof'


if __name__ == '__main__':
    main()
