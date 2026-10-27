#!/usr/bin/env python3
"""Five-minute real OpenCode proof in an existing Atlas sandbox guest.
Stages only the host executable and a credential-free synthetic provider.
The caller owns sandbox-up/down. --disable-native-control must fail the native
assertion while leaving the guarded operator draft untouched.
"""
import argparse
import json
import pathlib
import shlex
import subprocess
import time
import uuid

SCRIPTS = pathlib.Path(__file__).resolve().parent
DOORBELL = 'c11 mailbox: you have mail. Run c11 mailbox recv --ack when you want to receive it.'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_id')
    parser.add_argument('--out', type=pathlib.Path, default=pathlib.Path('/tmp/c11-opencode-proof'))
    parser.add_argument('--disable-native-control', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    root = '/tmp/c11-opencode-proof-' + args.run_id
    panels, targets, observations = [], [], {}

    def command(script, *argv, timeout=45):
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
            time.sleep(.25)
        raise AssertionError('Timed out: ' + label)

    workspace = json.loads(c11('current-workspace', '--json'))['workspace_id']
    nonce = uuid.uuid4().hex[:8]
    sender = json.loads(c11('new-panel', '--workspace', workspace, '--no-focus', '--json'))['panel_id']
    panels.append(sender)

    def inspect(target):
        return json.loads(guest('''import json,pathlib,sys
r=pathlib.Path.home()/'Library/Application Support/c11/workspaces'/sys.argv[1].upper()/'mailboxes'
def rows(p):
 if not p.exists(): return []
 return [json.loads(x) for x in p.read_text().splitlines() if x]
inbox=r/sys.argv[2].lower()
print(json.dumps(dict(events=rows(pathlib.Path(sys.argv[3])),dispatch=rows(r/'_dispatch.log'),
 unread=[p.stem for p in inbox.glob('*.msg')],read=[p.stem for p in (inbox/'_read').glob('*.msg')],
 tenant_config=(pathlib.Path.home()/'.config/opencode').exists())))''', workspace, target['panel'], target['log']))

    def messages(data, text):
        roles = {e['message']: e['role'] for e in data['events'] if e['event'] == 'message.updated'}
        return {e['message']: e for e in data['events'] if e.get('text') == text and roles.get(e['message']) == 'user'}

    def settled(target, text):
        data = inspect(target)
        ids = messages(data, text)
        latest = max(ids.values(), key=lambda e: e['at'])['message'] if ids else None
        return data if latest and any(e.get('completed') and e.get('parent') == latest for e in data['events']) else None

    def launch(label, disabled=False, target=None, session=None):
        panel = target['panel'] if target else json.loads(c11('new-panel', '--workspace', workspace, '--no-focus', '--json'))['panel_id']
        if not target:
            panels.append(panel)
        target = dict(panel=panel, address='oc-proof-' + label + '-' + nonce, log=root + '/' + label + '.jsonl', label=label)
        targets.append(target)
        for key, value in [('mailbox.address', target['address']), ('mailbox.delivery', 'stdin')]:
            c11('set-metadata', '--workspace', workspace, '--panel', panel, '--key', key, '--value', value, '--type', 'string')
        launch_command = shlex.join([root + '/launch.sh', label, '1' if disabled else '0', *(['--session', session] if session else [])])
        c11('send', '--workspace', workspace, '--panel', panel, launch_command)
        wait('OpenCode composer', lambda: 'Fixture Fixture' in c11('read-screen', '--workspace', workspace, '--panel', panel, '--lines', '35'))
        c11('send', '--workspace', workspace, '--panel', panel, 'READY-' + label)
        wait('initial response', lambda: settled(target, 'READY-' + label))
        return target

    def mail(target):
        result = root + '/send-' + uuid.uuid4().hex
        text = shlex.join(['c11', 'mailbox', 'send', '--to', target['address'], '--body', 'SYNTHETIC-PROOF']) + ' > ' + shlex.quote(result)
        c11('send', '--workspace', workspace, '--panel', sender, text)
        return wait('mail ID', lambda: guest('import pathlib,sys;p=pathlib.Path(sys.argv[1]);print(p.read_text().strip() if p.exists() else "")', result))

    def submitted(target, mail_id, route):
        data = inspect(target)
        rows = [e for e in data['dispatch'] if e.get('id') == mail_id and e.get('outcome') == 'doorbell' and e.get('reason') == 'submitted']
        if not rows:
            return None
        assert len(rows) == 1 and rows[0]['route'] == route, rows
        assert mail_id in data['unread'] and mail_id not in data['read'], data
        return data

    def ack(target, mail_id):
        c11('send', '--workspace', workspace, '--panel', sender,
            shlex.join(['c11', 'mailbox', 'recv', '--panel', target['panel'], '--ack']) + ' > /dev/null')
        wait('explicit recv claims mail', lambda: mail_id in inspect(target)['read'])

    def exit_tui(target):
        c11('send-key', '--workspace', workspace, '--panel', target['panel'], 'ctrl+c')
        wait('OpenCode exits', lambda: guest('''import os,pathlib,sys
p=int(pathlib.Path(sys.argv[1]).read_text())
try: os.kill(p,0); print('')
except ProcessLookupError: print('gone')''', root + '/' + target['label'] + '.pid'))

    def capture_native(target):
        c11('focus-panel', '--workspace', workspace, '--panel', target['panel'])
        window = json.loads(guest(r'''import pathlib,subprocess,json,sys
app=next((pathlib.Path.home()/'c11-sandbox/apps'/sys.argv[1]).glob('*.app'))
binary=str(app/'Contents/MacOS/c11')
processes=[line.strip().split(None,1) for line in subprocess.check_output(['/bin/ps','-axo','pid=,command='],text=True).splitlines()]
pid=next(int(p) for p,cmd in processes if cmd==binary or cmd.startswith(binary+' '))
js="ObjC.import('CoreGraphics'); ObjC.bindFunction('CGWindowListCopyWindowInfo',['id',['uint32','uint32']]); var w=ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(0,0)).filter(x=>x.kCGWindowOwnerPID==="+str(pid)+" && x.kCGWindowLayer===0 && x.kCGWindowBounds.Width>500); w.sort((a,b)=>b.kCGWindowBounds.Width*b.kCGWindowBounds.Height-a.kCGWindowBounds.Width*a.kCGWindowBounds.Height); console.log(JSON.stringify({pid:"+str(pid)+",window:w[0].kCGWindowNumber}));"
print(subprocess.check_output(['/usr/bin/osascript','-l','JavaScript','-e',js],stderr=subprocess.STDOUT,text=True).strip())''', args.run_id))
        command('sandbox-shot.sh', args.out / 'native-draft.png', '-x', '-l', window['window'], '-o')
        observations['native_window'] = window

    try:
        command('stage-opencode-mail-proof.sh', timeout=90)
        guest(r'''import pathlib,json,sys,shlex
r=pathlib.Path(sys.argv[1]);app=next((pathlib.Path.home()/'c11-sandbox/apps'/sys.argv[2]).glob('*.app'))
port=(r/'provider-port').read_text()
config={'model':'fixture/fixture','small_model':'fixture/fixture','autoupdate':False,
 'plugin':['file://'+str(r/'observer.mjs')],
 'provider':{'fixture':{'npm':'@ai-sdk/openai-compatible','name':'Fixture',
  'options':{'baseURL':'http://127.0.0.1:'+port+'/v1','apiKey':'fixture-nonsecret'},
  'models':{'fixture':{'name':'Fixture','limit':{'context':32768,'output':1024}}}}}}
s='#!/bin/bash\nset -eu\nROOT='+shlex.quote(str(r))+'\n'
s+='LABEL="$1"\nexport C11_OPENCODE_NATIVE_MAIL_DISABLED="$2"\nshift 2\n'
s+='export HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/home/config" XDG_DATA_HOME="$ROOT/home/data" XDG_CACHE_HOME="$ROOT/home/cache" XDG_STATE_HOME="$ROOT/home/state"\n'
s+='export OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_PROJECT_CONFIG=1\nunset OPENCODE_CONFIG OPENCODE_TUI_CONFIG\n'
s+='export OPENCODE_CONFIG_CONTENT='+shlex.quote(json.dumps(config))+'\n'
s+='export C11_OPENCODE_PROOF_LOG="$ROOT/$LABEL.jsonl"\necho $$ > "$ROOT/$LABEL.pid"\n'
s+='export PATH='+shlex.quote(str(app/'Contents/Resources/bin'))+':"$ROOT/real-bin":/opt/homebrew/bin:/usr/bin:/bin\n'
s+='cd "$ROOT/project"\nexec opencode "$@"\n'
p=r/'launch.sh';p.write_text(s);p.chmod(0o755)''', root, args.run_id)
        native = launch('native', args.disable_native_control)
        first_session = next(iter(messages(inspect(native), 'READY-native').values()))['session']
        draft = 'UNSENT-OPENCODE-DRAFT-' + nonce
        c11('send', '--workspace', workspace, '--panel', native['panel'], '--raw', '--no-submit', draft)
        mail_id = mail(native)
        data = wait('native delivery with draft', lambda: submitted(native, mail_id, 'opencode_plugin'), seconds=15)
        assert len(messages(data, DOORBELL)) == 1, data
        screen = c11('read-screen', '--workspace', workspace, '--panel', native['panel'], '--lines', '70')
        assert draft in screen, screen
        observations['native_draft'] = {'data': data, 'screen': screen}
        capture_native(native)
        ack(native, mail_id)
        c11('send-key', '--workspace', workspace, '--panel', native['panel'], 'ctrl+u')
        c11('send', '--workspace', workspace, '--panel', native['panel'], 'BUSY-476')
        wait('busy turn accepted', lambda: messages(inspect(native), 'BUSY-476'))
        busy_id = mail(native)
        data = wait('idle-edge native delivery', lambda: submitted(native, busy_id, 'opencode_plugin'))
        busy_message = next(iter(messages(data, 'BUSY-476')))
        completed = min(e['at'] for e in data['events'] if e.get('completed') and e.get('parent') == busy_message)
        assert len(messages(data, DOORBELL)) == 2
        assert max(e['at'] for e in messages(data, DOORBELL).values()) >= completed
        observations['busy_idle_edge'] = data
        ack(native, busy_id)
        wait('invitation response complete', lambda: settled(native, DOORBELL))
        c11('send', '--workspace', workspace, '--panel', native['panel'], '/new')
        wait('new-session home', lambda: 'Ask anything' in c11('read-screen', '--workspace', workspace, '--panel', native['panel'], '--lines', '35'))
        c11('send', '--workspace', workspace, '--panel', native['panel'], 'NEW-476')
        data = wait('new session', lambda: settled(native, 'NEW-476'))
        new_session = next(iter(messages(data, 'NEW-476').values()))['session']
        assert new_session != first_session
        new_id = mail(native)
        data = wait('native rebind after new', lambda: submitted(native, new_id, 'opencode_plugin'))
        assert any(e['session'] == new_session for e in messages(data, DOORBELL).values())
        observations['new_session'] = data
        ack(native, new_id)
        wait('new invitation completes', lambda: settled(native, DOORBELL))
        exit_tui(native)
        resumed = launch('resumed', target=native, session=first_session)
        resumed_id = mail(resumed)
        data = wait('resume rebind', lambda: submitted(resumed, resumed_id, 'opencode_plugin'))
        assert all(e['session'] == first_session for e in messages(data, DOORBELL).values())
        observations['resumed_session'] = data
        ack(resumed, resumed_id)
        typed = launch('typed', disabled=True)
        typed_id = mail(typed)
        data = wait('typed fallback', lambda: submitted(typed, typed_id, 'typed'))
        wait('typed user message', lambda: messages(inspect(typed), DOORBELL))
        observations['typed_fallback'] = data
        assert not data['tenant_config'], 'tenant OpenCode config was created'
        observations['result'] = 'PASS'
        print('PASS: native draft, busy idle edge, new, resume, typed fallback, unread until ack')
    finally:
        for target in targets:
            try:
                observations[target['label'] + '_final'] = inspect(target)
                observations[target['label'] + '_metadata'] = c11('get-metadata', '--workspace', workspace, '--panel', target['panel'], '--json')
                observations[target['label'] + '_screen'] = c11('read-screen', '--workspace', workspace, '--panel', target['panel'], '--lines', '70')
            except Exception as error:
                observations[target['label'] + '_error'] = str(error)
        observations['runtime_logs'] = guest('''import pathlib,json,sys
r=pathlib.Path(sys.argv[1]);logs=r/'home/data/opencode/log'
print(json.dumps({p.name:p.read_text()[-16000:] for p in logs.glob('*.log')}))''', root)
        observations['seconds'] = round(time.monotonic() - started, 3)
        (args.out / 'proof.json').write_text(json.dumps(observations, indent=2) + '\n')
        for panel in reversed(panels):
            try:
                c11('close-panel', '--workspace', workspace, '--panel', panel)
            except Exception as error:
                print('Panel cleanup:', error)
        guest('''import pathlib,os,signal,sys,shutil
r=pathlib.Path(sys.argv[1]);p=r/'provider.pid'
if p.exists():
 try: os.kill(int(p.read_text()),signal.SIGTERM)
 except ProcessLookupError: pass
if r.name.startswith('c11-opencode-proof-') and r.parent==pathlib.Path('/tmp'): shutil.rmtree(r,ignore_errors=True)''', root)


if __name__ == '__main__':
    main()
