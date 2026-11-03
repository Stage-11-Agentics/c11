#!/usr/bin/env python3
"""Claude inbox/typed acceptance in a running Claude-staged Atlas sandbox.
Covers inline mail (the turn holds the message, no recv tool call, status reads
read), batching, body_ref, a session resumed from another folder, and Claude-to-Claude.
Usage: check-claude-native-mail.py RUN_ID [--out DIR] [--disable-native-control]
The control removes the native hook; the native-with-draft assertion must fail.
Uses real Claude credentials staged by sandbox-agent.sh; never reads or exports them.
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
DOORBELL = 'c11 mail waiting: run c11 mailbox recv --ack'
PEER = 'Another Claude session sent a message:\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_id')
    parser.add_argument('--out', type=Path, default=Path('/tmp/c11-claude-native-proof'))
    parser.add_argument('--disable-native-control', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    panels, targets = [], []
    observations = {}
    nonce = uuid.uuid4().hex[:8]
    root = '/tmp/c11-claude-proof-' + nonce

    def command(script, *argv):
        result = subprocess.run(['/bin/bash', str(SCRIPTS / script), args.run_id, *map(str, argv)],
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
        deadline = min(time.monotonic() + seconds, started + 300)
        while time.monotonic() < deadline:
            value = probe()
            if value:
                return value
            time.sleep(.4)
        raise AssertionError('Timed out: ' + label)

    def tenant_listing():
        return json.loads(guest('''from pathlib import Path
import json
home=Path.home(); roots=[home/'.claude',home/'.claude.json']; rows={}
for root in roots:
 for p in ([root]+list(root.rglob('*')) if root.is_dir() else [root]):
  if p.exists(): rows[str(p.relative_to(home))]=[p.stat().st_mtime_ns,p.stat().st_size]
print(json.dumps(rows))'''))

    workspace = json.loads(c11('current-workspace', '--json'))['workspace_id']
    sender = json.loads(c11('new-panel', '--workspace', workspace, '--no-focus', '--json'))['panel_id']
    panels.append(sender)
    observations['tenant_before'] = tenant_listing()

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
messages=[];tools=[]
for path in (Path(sys.argv[3])/'projects').rglob('*.jsonl'):
 for row in rows(path):
  if row.get('type') not in ['user','assistant']:continue
  content=row.get('message',{}).get('content','')
  if isinstance(content,list):
   tools+=[json.dumps(b.get('input')) for b in content if b.get('type')=='tool_use']
   content='\\n'.join(b.get('text','') for b in content if b.get('type')=='text')
  if content:messages.append(dict(role=row['type'],session=row.get('sessionId'),text=content,at=row.get('timestamp')))
inbox=mail/sys.argv[2].lower()
print(json.dumps(dict(dispatch=rows(mail/'_dispatch.log'),messages=messages,tools=tools,unread=[p.stem for p in inbox.glob('*.msg')],read=[p.stem for p in (inbox/'_read').glob('*.msg')])))''', workspace, target['panel'], target['state']))

    def launch(label, disabled=False, refuse=False):
        address = 'claude-proof-' + label + '-' + nonce
        state = root + '/' + label
        guest('''from pathlib import Path
import json,sys
state=Path(sys.argv[1]);state.mkdir(parents=True,exist_ok=True)
work=Path.home()/'c11-sandbox/work';work.mkdir(parents=True,exist_ok=True)
elsewhere=work.parent/'elsewhere';elsewhere.mkdir(parents=True,exist_ok=True)
(state/'.claude.json').write_text(json.dumps({'hasCompletedOnboarding':True,'projects':{str(p):{'hasTrustDialogAccepted':True} for p in (work,elsewhere)}}))
settings={'skipDangerousModePermissionPrompt':True}
if sys.argv[2]=='1':settings['crossSessionInbound']='refuse'
(state/'settings.json').write_text(json.dumps(settings))''', state, '1' if refuse else '0')
        prompt = ('For this isolated c11 mailbox test reply exactly C11_READY_' + nonce +
                  ' and wait. On a mailbox invitation reply C11_AWAKE without tools. '
                  'On a c11 mail envelope reply C11_MAIL_SEEN without tools. Do not change any files or configuration, '
                  'and never run c11 yourself unless a message from the operator gives the exact command.')
        options = ['launch-agent', '--type', 'claude-code', '--workspace', workspace, '--title', address,
                   '--cwd', '/Users/admin/c11-sandbox/work', '--prompt', prompt,
                   '--env', 'CLAUDE_CONFIG_DIR=' + state, '--env', 'DISABLE_AUTOUPDATER=1', '--json']
        if disabled:
            options += ['--env', 'C11_CLAUDE_NATIVE_MAIL_DISABLED=1']
        panel = json.loads(c11(*options))['panel_id']
        panels.append(panel)
        target = dict(panel=panel, address=address, state=state)
        targets.append(target)
        for key, value in [('mailbox.address', address), ('mailbox.delivery', 'stdin')]:
            c11('set-metadata', '--workspace', workspace, '--panel', panel, '--key', key, '--value', value, '--type', 'string')
        wait('ready: ' + label, lambda: any(m['role'] == 'assistant' and 'C11_READY_' + nonce in m['text'] for m in inspect(target)['messages']))
        return target

    def mail(target, *options, body=None):
        result = root + '/send-' + uuid.uuid4().hex
        text = ('c11 mailbox send --to ' + shlex.quote(target['address']) + ' ' + ' '.join(options) +
                ' --body ' + shlex.quote(body if body is not None else 'C11_ENVELOPE_' + nonce) + ' > ' + shlex.quote(result))
        c11('send', '--workspace', workspace, '--panel', sender, text)
        return wait('mail ID', lambda: guest('from pathlib import Path;import sys;p=Path(sys.argv[1]);print(p.read_text().strip() if p.exists() else "")', result))

    def delivered(target, mail_id, route, native_failure=None):
        data = inspect(target)
        rows = [r for r in data['dispatch'] if r.get('id') == mail_id and r.get('outcome') == 'doorbell' and r.get('reason') == 'submitted']
        if not rows:
            return None
        assert rows[-1].get('route') == route, rows
        if native_failure:
            # The failed native attempt and the typed row that follows it both
            # name the bridge's reason, not a bare timeout.
            failed = [r for r in data['dispatch'] if r.get('id') == mail_id and r.get('outcome') == 'doorbell_failed']
            assert failed and failed[-1].get('route') == 'claude_inbox' and failed[-1].get('reason') == native_failure, data['dispatch']
            assert rows[-1].get('native_route') == 'claude_inbox' and rows[-1].get('native_failure') == native_failure, rows
        return data

    def inline(target, mail_id, *needles):
        """The transcript shows the message as its turn, with no recv, and status says read."""
        data = wait('inline delivery of ' + mail_id, lambda: delivered(target, mail_id, 'claude_inbox'))
        wait('inline claim of ' + mail_id, lambda: mail_id in inspect(target)['read'])
        data = inspect(target)
        assert any(m['role'] == 'user' and m['text'].startswith(PEER + 'c11 mailbox:') and mail_id in m['text']
                   and all(needle in m['text'] for needle in needles) for m in data['messages']), data['messages']
        assert not any('mailbox recv' in tool for tool in data['tools']), data['tools']
        claimed = [r for r in data['dispatch'] if r.get('event') == 'claimed' and r.get('id') == mail_id]
        assert [r.get('via') for r in claimed] == ['native'], claimed
        status = json.loads(c11('mailbox', 'status', mail_id, '--json'))
        assert status['recipients'][0]['read'] is True and status['recipients'][0]['delivery'] == 'delivered', status
        observations['status_' + mail_id] = status
        return data

    def screenshot(label, target):
        c11('focus-panel', '--workspace', workspace, '--panel', target['panel'])
        pid = int(guest('''from pathlib import Path
import subprocess,sys
app=next((Path.home()/'c11-sandbox/apps'/sys.argv[1]).glob('*.app'))
exe=str(app/'Contents/MacOS/c11')
rows=[line.split(None,1) for line in subprocess.check_output(['/bin/ps','-ax','-o','pid=,command=']).decode().splitlines()]
pids=[int(row[0]) for row in rows if len(row)==2 and row[1]==exe]
assert len(pids)==1,pids
print(pids[0])''', args.run_id))
        code = ('ObjC.import("CoreGraphics"); ObjC.bindFunction("CGWindowListCopyWindowInfo", ["id", ["uint32", "uint32"]]); '
                'JSON.stringify(ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(0,0)).filter(w => w.kCGWindowOwnerPID === ' + str(pid) +
                ' && w.kCGWindowLayer === 0 && w.kCGWindowBounds.Width > 500 && w.kCGWindowBounds.Height > 300))')
        windows = json.loads(command('sandbox-exec.sh', '/usr/bin/osascript', '-l', 'JavaScript', '-e', code))
        assert windows, 'No tagged guest window'
        window = max(windows, key=lambda w: w['kCGWindowBounds']['Width'] * w['kCGWindowBounds']['Height'])
        observations[label + '_window'] = window
        observations[label + '_screen'] = c11('read-screen', '--workspace', workspace, '--panel', target['panel'], '--lines', '90')
        command('sandbox-shot.sh', args.out / (label + '.png'), '-l' + str(window['kCGWindowNumber']), '-o')

    try:
        native = launch('native', args.disable_native_control)
        draft = 'UNSENT_CLAUDE_DRAFT_' + nonce
        c11('send', '--workspace', workspace, '--panel', native['panel'], '--raw', '--no-submit', draft)
        first_id = mail(native)
        data = inline(native, first_id, 'C11_ENVELOPE_' + nonce)
        screen = c11('read-screen', '--workspace', workspace, '--panel', native['panel'], '--lines', '90')
        assert draft in screen, screen
        assert all(draft not in m['text'] for m in data['messages']), 'Draft entered the conversation'
        observations['native_draft'] = data
        screenshot('native-draft', native)

        # Repeated native wake, still with the operator draft present.
        repeat_id = mail(native)
        observations['native_repeat'] = inline(native, repeat_id)
        c11('set-metadata', '--workspace', workspace, '--panel', native['panel'], '--key', 'mailbox.doorbell', '--value', 'off', '--type', 'string')
        report = root + '/report.txt'
        guest('from pathlib import Path;import sys;Path(sys.argv[1]).write_text("C11_REPORT_HEAD_' + nonce + '"+"x"*5000)', report)
        batch = [mail(native, '--topic', 'c11-proof-topic', body='C11_FIRST_' + nonce),
                 mail(native, body='a' * 4000 + '<tag> & C11_LARGE_' + nonce),
                 mail(native, '--body-ref', report, body='')]
        c11('set-metadata', '--workspace', workspace, '--panel', native['panel'], '--key', 'mailbox.doorbell', '--value', 'on', '--type', 'string')
        last = mail(native, body='C11_LAST_' + nonce)
        data = inline(native, last, 'C11_LAST_' + nonce, 'C11_FIRST_' + nonce, 'topic="c11-proof-topic"',
                      'C11_REPORT_HEAD_' + nonce, 'rest is at ' + report, '&lt;tag&gt; &amp; C11_LARGE_' + nonce, *batch)
        turn = next(m['text'] for m in data['messages'] if m['role'] == 'user' and last in m['text'])
        assert turn.count('<c11-msg ') == 4, turn
        assert [turn.index(i) for i in batch + [last]] == sorted(turn.index(i) for i in batch + [last]), turn
        observations['batch'] = data
        # Past the budget: nothing is lost or reordered, and every id is read once.
        c11('set-metadata', '--workspace', workspace, '--panel', native['panel'], '--key', 'mailbox.doorbell', '--value', 'off', '--type', 'string')
        large = [mail(native, body=str(n) + '-C11_OVER_' + nonce + '-' + 'b' * 4000) for n in range(11)]
        c11('set-metadata', '--workspace', workspace, '--panel', native['panel'], '--key', 'mailbox.doorbell', '--value', 'on', '--type', 'string')
        large.append(mail(native, body='11-C11_OVER_' + nonce))
        wait('over-budget mail all read', lambda: set(large) <= set(inspect(native)['read']), seconds=90)
        data = inspect(native)
        seen = [i for m in data['messages'] if m['role'] == 'user' for i in large if 'id="' + i + '"' in m['text']]
        hooks = [r for r in data['dispatch'] if r.get('event') == 'claimed' and r.get('id') in large]
        assert len(hooks) == len(large), hooks
        first = next(m['text'] for m in data['messages'] if m['role'] == 'user' and large[0] in m['text'])
        assert first.count('<c11-msg ') < len(large), 'The budget did not split this batch'
        observations['over_budget'] = dict(inline_ids=seen, claimed=[(r.get('id'), r.get('via')) for r in hooks])
        c11('send-key', '--workspace', workspace, '--panel', native['panel'], 'ctrl+u')
        before = {m['session'] for m in inspect(native)['messages']}
        c11('send', '--workspace', workspace, '--panel', native['panel'], '/clear')
        wait('clear command completed', lambda: any(m['session'] not in before for m in inspect(native)['messages']))
        c11('send', '--workspace', workspace, '--panel', native['panel'], 'Reply C11_CLEAR_READY without tools and wait.')
        wait('new session after clear', lambda: any(m['session'] not in before and m['role'] == 'assistant' and 'C11_CLEAR_READY' in m['text'] for m in inspect(native)['messages']))
        clear_id = mail(native)
        data = inline(native, clear_id)
        observations['clear'] = data
        session = next(m['session'] for m in data['messages'] if m['session'] not in before)
        c11('send', '--workspace', workspace, '--panel', native['panel'], '/exit')
        wait('Claude exited', lambda: 'Resume this session' in c11('read-screen', '--workspace', workspace, '--panel', native['panel'], '--lines', '12'))
        # From another folder: the hook then names a transcript that does not exist.
        resume = ('cd /Users/admin/c11-sandbox/elsewhere && env CLAUDE_CONFIG_DIR=' +
                  shlex.quote(native['state']) + ' DISABLE_AUTOUPDATER=1 claude --resume ' + shlex.quote(session))
        c11('send', '--workspace', workspace, '--panel', native['panel'], resume)
        wait('resume composer', lambda: 'shift+tab' in c11('read-screen', '--workspace', workspace, '--panel', native['panel'], '--lines', '8'))
        c11('send', '--workspace', workspace, '--panel', native['panel'], 'Reply C11_RESUME_READY without tools and wait.')
        wait('resume ready', lambda: any(m['role'] == 'assistant' and 'C11_RESUME_READY' in m['text'] for m in inspect(native)['messages']))
        resume_id = mail(native)
        observations['resume'] = inline(native, resume_id)
        assert not [r for r in inspect(native)['dispatch'] if r.get('id') == resume_id and r.get('reason') == 'native_unconfirmed']

        # Claude to Claude: a live agent sends, a live agent reads.
        sender_agent = launch('sender')
        receiver = launch('receiver')
        peer_body = 'C11_PEER_' + nonce
        sent = root + '/peer-id'
        c11('send', '--workspace', workspace, '--panel', sender_agent['panel'],
            'Run exactly this one shell command, then reply C11_SENT: c11 mailbox send --to ' + receiver['address'] +
            ' --topic peer-proof --body ' + peer_body + ' > ' + sent)
        peer_id = wait('peer sent', lambda: guest('from pathlib import Path;import sys;p=Path(sys.argv[1]);print(p.read_text().strip() if p.exists() else "")', sent))
        observations['peer'] = inline(receiver, peer_id, peer_body, 'topic="peer-proof"')
        wait('peer reacted', lambda: any(m['role'] == 'assistant' and 'C11_MAIL_SEEN' in m['text'] for m in inspect(receiver)['messages']))
        screenshot('peer-inline', receiver)

        typed = launch('typed', disabled=True)
        typed_id = mail(typed)
        observations['typed'] = wait('typed fallback', lambda: delivered(typed, typed_id, 'typed'))
        wait('typed acceptance', lambda: any(m['role'] == 'user' and m['text'] == DOORBELL for m in inspect(typed)['messages']))
        screenshot('typed-fallback', typed)

        refused = launch('refused', refuse=True)
        refused_id = mail(refused)
        observations['refused'] = wait('policy refusal typed fallback', lambda: delivered(refused, refused_id, 'typed', native_failure='native_unconfirmed'))
        assert not any(m['role'] == 'user' and m['text'].startswith(PEER) for m in inspect(refused)['messages'])
        wait('refused mail stays claimable', lambda: refused_id in inspect(refused)['read'] or refused_id in inspect(refused)['unread'])
        observations['passed'] = True
        print('PASS: inline draft/repeat/batch/body_ref, /clear, --resume elsewhere, Claude to Claude, hook-absent typed fallback, policy refusal')
    finally:
        for target in targets:
            try:
                observations[target['address']] = inspect(target)
                if not observations.get('passed'):
                    screenshot('failed-' + target['address'], target)
                c11('send-key', '--workspace', workspace, '--panel', target['panel'], 'ctrl+u')
                c11('send', '--workspace', workspace, '--panel', target['panel'], '/exit')
            except Exception as error:
                observations[target['address'] + '_cleanup'] = str(error)
        for panel in reversed(panels):
            try:
                c11('close-panel', '--workspace', workspace, '--panel', panel)
            except Exception as error:
                observations['close_' + panel] = str(error)
        observations['tenant_after'] = tenant_listing()
        observations['tenant_unchanged'] = observations['tenant_before'] == observations['tenant_after']
        observations['seconds'] = round(time.monotonic() - started, 3)
        (args.out / 'proof.json').write_text(json.dumps(observations, indent=2) + '\n')
        assert observations['tenant_unchanged'], 'Default tenant state changed during isolated proof'


if __name__ == '__main__':
    main()
