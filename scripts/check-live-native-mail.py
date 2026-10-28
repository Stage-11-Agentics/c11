#!/usr/bin/env python3
"""One real-model native-mail smoke in an already running sandbox (Pi or omp).
Usage: check-live-native-mail.py RUN_ID --kind pi|omp [--out DIR]
Stage first with the OpenRouter key in the caller's environment, never in an argument:
  C11_SANDBOX_OPENROUTER_KEY=... sandbox-agent.sh RUN_ID stage pi-live   (or omp-live)
The model is OpenRouter's openai/gpt-4o-mini. Asserts the native route delivered the
doorbell into a real session without touching an unsent draft, and records whether the
model then claimed the mail. Only sandbox-* commands address the guest.
"""
import argparse
import json
import pathlib
import shlex
import subprocess
import time
import uuid

DOORBELL = 'c11 mail waiting: run c11 mailbox recv --ack'
SCRIPTS = pathlib.Path(__file__).resolve().parent
ROUTES = {'pi': 'pi_extension', 'omp': 'omp_extension'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_id')
    parser.add_argument('--kind', choices=sorted(ROUTES), required=True)
    parser.add_argument('--out', type=pathlib.Path)
    args = parser.parse_args()
    out = args.out or pathlib.Path('/tmp/c11-' + args.kind + '-live-proof')
    out.mkdir(parents=True, exist_ok=True)
    route = ROUTES[args.kind]
    started = time.monotonic()
    observations = {'kind': args.kind, 'provider': 'openrouter', 'model': 'openai/gpt-4o-mini'}
    panels = []

    def command(script, *argv):
        result = subprocess.run([str(SCRIPTS / script), args.run_id, *map(str, argv)],
                                text=True, capture_output=True, timeout=60)
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
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = probe()
            if value:
                return value
            time.sleep(1)
        raise AssertionError('Timed out: ' + label)

    workspace = json.loads(c11('current-workspace', '--json'))['workspace_id']
    nonce = uuid.uuid4().hex[:8]
    sender = json.loads(c11('new-panel', '--workspace', workspace, '--no-focus', '--json'))['panel_id']
    panels.append(sender)
    address = args.kind + '-live-' + nonce

    def flat(text):
        # The terminal wraps lines and boxes them; compare letters and digits only.
        return ''.join(ch for ch in text if ch.isalnum())

    def screen(panel):
        return c11('read-screen', '--workspace', workspace, '--panel', panel, '--lines', '80')

    def inspect(panel):
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
print(json.dumps(dict(dispatch=lines(root/'_dispatch.log'),unread=[p.stem for p in inbox.glob('*.msg')],read=[p.stem for p in (inbox/'_read').glob('*.msg')])))'''
        return json.loads(guest(code, workspace, panel))

    try:
        panel = json.loads(c11('launch-agent', '--type', args.kind, '--workspace', workspace, '--title', address,
                               '--prompt', 'Reply with only the word READY.', '--json'))['panel_id']
        panels.append(panel)
        for key, value in [('mailbox.address', address), ('mailbox.delivery', 'stdin')]:
            c11('set-metadata', '--workspace', workspace, '--panel', panel, '--key', key, '--value', value, '--type', 'string')
        wait('real model answered the first prompt', lambda: 'READY' in screen(panel).split('Reply with only the word READY.')[-1], 120)
        time.sleep(3)
        draft = 'UNSENT-LIVE-DRAFT-' + nonce
        c11('send', '--workspace', workspace, '--panel', panel, '--raw', '--no-submit', draft)
        result = '/tmp/live-send-' + nonce
        c11('send', '--workspace', workspace, '--panel', sender,
            'c11 mailbox send --to ' + shlex.quote(address) + ' --body PROOF > ' + shlex.quote(result))
        mail_id = wait('sibling mail ID', lambda: guest('import pathlib,sys;p=pathlib.Path(sys.argv[1]);print(p.read_text().strip() if p.exists() else "")', result))
        data = wait('native route delivered', lambda: (lambda d: d if any(
            e.get('id') == mail_id and e.get('outcome') == 'doorbell' and e.get('reason') == 'submitted' for e in d['dispatch']) else None)(inspect(panel)), 30)
        rows = [e for e in data['dispatch'] if e.get('id') == mail_id and e.get('outcome') == 'doorbell' and e.get('reason') == 'submitted']
        assert len(rows) == 1 and rows[0]['route'] == route, rows
        observations['dispatch'] = rows
        c11('focus-panel', '--workspace', workspace, '--panel', panel)
        guest('import pathlib,subprocess,sys;app=next((pathlib.Path.home()/"c11-sandbox/apps"/sys.argv[1]).glob("*.app"));subprocess.run(["/usr/bin/osascript","-e","tell application " + chr(34) + str(app) + chr(34) + " to activate"],check=True)', args.run_id)
        shown = wait('doorbell visible in the session', lambda: (lambda s: s if flat(DOORBELL) in flat(s) else None)(screen(panel)), 20)
        assert flat(draft) in flat(shown), 'the unsent draft must still be in the composer'
        observations['screen_after_doorbell'] = shown
        command('sandbox-shot.sh', out / 'live-doorbell.png')
        # Whether a real model acts on the invitation: it should claim the envelope.
        try:
            wait('model claimed the mail', lambda: mail_id in inspect(panel)['read'], 90)
            observations['model_claimed_mail'] = True
        except AssertionError:
            observations['model_claimed_mail'] = False
        observations['screen_final'] = screen(panel)
        observations['inbox'] = inspect(panel)
        command('sandbox-shot.sh', out / 'live-final.png')
        assert observations['model_claimed_mail'], 'the model did not claim the mail after the doorbell'
        observations['passed'] = True
        print('PASS: %s native route delivered with a real model (%s); draft intact; model_claimed_mail=%s' % (
            args.kind, observations['model'], observations['model_claimed_mail']))
    finally:
        observations['seconds'] = round(time.monotonic() - started, 3)
        (out / 'proof.json').write_text(json.dumps(observations, indent=2) + '\n')
        for panel in reversed(panels):
            try:
                c11('close-panel', '--workspace', workspace, '--panel', panel)
            except Exception as error:
                print('Panel cleanup:', error)


if __name__ == '__main__':
    main()
