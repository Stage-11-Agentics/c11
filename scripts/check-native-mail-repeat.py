#!/usr/bin/env python3
"""Two mails in a row to one idle native seat ring natively twice (C11-476).
Runs in an existing Atlas sandbox guest started with `--agents pi`.
OpenCode uses the credential-free synthetic provider; Pi uses its fixture.
Each seat gets mail A, `recv --ack`, then more mails with no typed turn between.
Each must log `submitted` on the seat's native route, never `once_per_idle`.
A fast invitation turn's working edge can lose to its idle snapshot; `--load`
makes that race likely. The caller owns sandbox-up/down.
Usage: check-native-mail-repeat.py RUN_ID [--out DIR] [--rounds N] [--load N]
"""
import argparse
import json
import pathlib
import shlex
import subprocess
import time
import uuid

SCRIPTS = pathlib.Path(__file__).resolve().parent
ROUTES = {'opencode': 'opencode_plugin', 'pi': 'pi_extension'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_id')
    parser.add_argument('--out', type=pathlib.Path, default=pathlib.Path('/tmp/c11-native-mail-repeat'))
    parser.add_argument('--seats', default='opencode,pi')
    parser.add_argument('--rounds', type=int, default=4, help='mails after the first, each at a fresh idle')
    parser.add_argument('--load', type=int, default=0,
                        help='busy processes in the guest; the lost working edge is a scheduling race')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    root = '/tmp/c11-opencode-proof-' + args.run_id
    nonce = uuid.uuid4().hex[:8]
    panels, results = [], {}

    def command(script, *argv, timeout=60):
        result = subprocess.run([str(SCRIPTS / script), args.run_id, *map(str, argv)],
                                text=True, capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return result.stdout.strip()

    def c11(*argv):
        if '--json' in argv:
            argv = ('--json', '--id-format', 'both', *(x for x in argv if x != '--json'))
        return command('sandbox-agent.sh', 'c11', *argv)

    def guest(code, *argv):
        return command('sandbox-exec.sh', '/usr/bin/python3', '-c', code, *argv)

    def wait(label, probe, seconds=45):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            result = probe()
            if result:
                return result
            time.sleep(.5)
        raise AssertionError('Timed out: ' + label)

    def read_file(path):
        return guest('import pathlib,sys;p=pathlib.Path(sys.argv[1]);print(p.read_text().strip() if p.exists() else "")', path)

    workspace = json.loads(c11('current-workspace', '--json'))['workspace_id']
    sender = json.loads(c11('new-panel', '--workspace', workspace, '--no-focus', '--json'))['panel_id']
    panels.append(sender)

    def inspect(panel):
        return json.loads(guest('''import json,pathlib,sys
r=pathlib.Path.home()/'Library/Application Support/c11/workspaces'/sys.argv[1].upper()/'mailboxes'
def rows(p):
 if not p.exists(): return []
 return [json.loads(x) for x in p.read_text().splitlines() if x]
inbox=r/sys.argv[2].lower()
print(json.dumps(dict(dispatch=rows(r/'_dispatch.log'),unread=[p.stem for p in inbox.glob('*.msg')],
 read=[p.stem for p in (inbox/'_read').glob('*.msg')])))''', workspace, panel))

    def meta(panel, address):
        for key, value in [('mailbox.address', address), ('mailbox.delivery', 'stdin')]:
            c11('set-metadata', '--workspace', workspace, '--panel', panel, '--key', key, '--value', value, '--type', 'string')

    def launch_opencode():
        command('stage-opencode-mail-proof.sh', timeout=120)
        guest(r'''import pathlib,json,sys,shlex,time
r=pathlib.Path(sys.argv[1]);app=next((pathlib.Path.home()/'c11-sandbox/apps'/sys.argv[2]).glob('*.app'))
for _ in range(50):
  if (r/'provider-port').exists(): break
  time.sleep(.2)
port=(r/'provider-port').read_text()
config={'model':'fixture/fixture','small_model':'fixture/fixture','autoupdate':False,
 'plugin':['file://'+str(r/'observer.mjs')],
 'provider':{'fixture':{'npm':'@ai-sdk/openai-compatible','name':'Fixture',
  'options':{'baseURL':'http://127.0.0.1:'+port+'/v1','apiKey':'fixture-nonsecret'},
  'models':{'fixture':{'name':'Fixture','limit':{'context':32768,'output':1024}}}}}}
s='#!/bin/bash\nset -eu\nROOT='+shlex.quote(str(r))+'\n'
s+='LABEL="$1"\nshift 1\n'
s+='export HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/home/config" XDG_DATA_HOME="$ROOT/home/data" XDG_CACHE_HOME="$ROOT/home/cache" XDG_STATE_HOME="$ROOT/home/state"\n'
s+='export OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_PROJECT_CONFIG=1\nunset OPENCODE_CONFIG OPENCODE_TUI_CONFIG\n'
s+='export OPENCODE_CONFIG_CONTENT='+shlex.quote(json.dumps(config))+'\n'
s+='export C11_OPENCODE_PROOF_LOG="$ROOT/$LABEL.jsonl"\necho $$ > "$ROOT/$LABEL.pid"\n'
s+='export PATH='+shlex.quote(str(app/'Contents/Resources/bin'))+':"$ROOT/real-bin":/opt/homebrew/bin:/usr/bin:/bin\n'
s+='cd "$ROOT/project"\nexec opencode "$@"\n'
p=r/'launch.sh';p.write_text(s);p.chmod(0o755)''', root, args.run_id)
        address = 'repeat-opencode-' + nonce
        panel = json.loads(c11('new-panel', '--workspace', workspace, '--no-focus', '--json'))['panel_id']
        panels.append(panel)
        meta(panel, address)
        c11('send', '--workspace', workspace, '--panel', panel, root + '/launch.sh repeat')
        screen = lambda: c11('read-screen', '--workspace', workspace, '--panel', panel, '--lines', '60')
        wait('OpenCode composer', lambda: 'Fixture Fixture' in screen(), 90)
        c11('send', '--workspace', workspace, '--panel', panel, 'READY-opencode')
        wait('OpenCode reply', lambda: 'FIXTURE_ACK' in screen(), 60)
        time.sleep(2)
        return dict(panel=panel, address=address)

    def launch_pi():
        address = 'repeat-pi-' + nonce
        proof_log = '/tmp/' + address + '.jsonl'
        panel = json.loads(c11('launch-agent', '--type', 'pi', '--workspace', workspace, '--title', address,
                               '--prompt', 'READY-' + address, '--env', 'C11_PI_PROOF_LOG=' + proof_log, '--json'))['panel_id']
        panels.append(panel)
        meta(panel, address)
        wait('Pi ready', lambda: 'agent_settled' in read_file(proof_log), 90)
        time.sleep(2)
        return dict(panel=panel, address=address)

    def mail(target, body):
        result = root + '-send-' + uuid.uuid4().hex
        text = shlex.join(['c11', 'mailbox', 'send', '--to', target['address'], '--body', body]) + ' > ' + shlex.quote(result)
        c11('send', '--workspace', workspace, '--panel', sender, text)
        return wait('mail ID', lambda: read_file(result))

    def rows(data, mail_id):
        return [r for r in data['dispatch'] if r.get('id') == mail_id or mail_id in (r.get('ids') or [])]

    def rang(target, mail_id, route):
        data = inspect(target['panel'])
        mine = rows(data, mail_id)
        submitted = [r for r in mine if r.get('outcome') == 'doorbell' and r.get('reason') == 'submitted']
        if not submitted:
            return None
        assert len(submitted) == 1 and submitted[0].get('route') == route, mine
        assert mail_id in data['unread'], 'rang mail must stay unread until recv --ack'
        return mine

    def ack(target, mail_id):
        c11('send', '--workspace', workspace, '--panel', sender,
            shlex.join(['c11', 'mailbox', 'recv', '--panel', target['panel'], '--ack']) + ' > /dev/null')
        wait('recv --ack claims mail', lambda: mail_id in inspect(target['panel'])['read'])

    try:
        for seat in args.seats.split(','):
            target = launch_opencode() if seat == 'opencode' else launch_pi()
            route = ROUTES[seat]
            if args.load:
                guest('''import subprocess,sys
for _ in range(int(sys.argv[1])):
  subprocess.Popen(['/usr/bin/yes'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)''', args.load)
            previous = mail(target, 'REPEAT-0-' + nonce)
            rounds = [dict(id=previous, rows=wait(seat + ' first ring', lambda: rang(target, previous, route)))]
            ok = True
            for n in range(1, args.rounds + 1):
                ack(target, previous)
                time.sleep(4)  # The invitation turn settles; nothing typed in between.
                previous = mail(target, 'REPEAT-%d-%s' % (n, nonce))
                try:
                    found = wait('%s ring %d' % (seat, n), lambda: rang(target, previous, route), 20)
                except AssertionError:
                    found = None
                mine = found or rows(inspect(target['panel']), previous)
                round_ok = bool(found) and not [r for r in mine if r.get('reason') == 'once_per_idle']
                rounds.append(dict(id=previous, passed=round_ok, rows=mine))
                print(('PASS ' if round_ok else 'FAIL ') + '%s mail %d ' % (seat, n) +
                      ('rang on ' + route if round_ok else 'did not ring: ' + json.dumps(
                          [(r.get('ts'), r.get('outcome'), r.get('reason')) for r in mine])[:500]), flush=True)
                ok = ok and round_ok
                if not round_ok:
                    break
            if args.load:
                guest('import subprocess;subprocess.run(["/usr/bin/pkill","-x","yes"])')
            results[seat] = dict(passed=ok, route=route, rounds=rounds)
    finally:
        results['seconds'] = round(time.monotonic() - started, 1)
        results['passed'] = all(v['passed'] for k, v in results.items() if isinstance(v, dict)) and \
            len([v for v in results.values() if isinstance(v, dict)]) == len(args.seats.split(','))
        (args.out / 'repeat.json').write_text(json.dumps(results, indent=2) + '\n')
        for panel in reversed(panels):
            try:
                c11('close-panel', '--workspace', workspace, '--panel', panel)
            except Exception as error:
                print('Panel cleanup:', error)
        if args.load:
            guest('import subprocess;subprocess.run(["/usr/bin/pkill","-x","yes"])')
        guest('''import pathlib,os,signal,sys,shutil
r=pathlib.Path(sys.argv[1]);p=r/'provider.pid'
if p.exists():
 try: os.kill(int(p.read_text()),signal.SIGTERM)
 except ProcessLookupError: pass
if r.name.startswith('c11-opencode-proof-') and r.parent==pathlib.Path('/tmp'): shutil.rmtree(r,ignore_errors=True)''', root)
        print('RESULT ' + ('PASS' if results['passed'] else 'FAIL'), flush=True)
    raise SystemExit(0 if results['passed'] else 1)


if __name__ == '__main__':
    main()
