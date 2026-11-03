#!/usr/bin/env python3
"""Every agent kind sends c11 mail to every other, in a running sandbox guest.
Usage: check-mail-matrix.py RUN_ID [--kinds claude,codex,grok,pi-live,opencode-live] [--out DIR]
Stage the kinds first (sandbox-up.sh --agents ..., with C11_SANDBOX_OPENROUTER_KEY in the
environment for the -live kinds). Each agent runs one shell command that sends one envelope
to each peer from its own tool process, so the sender is that harness's own panel. Passes
when every envelope reads delivered and read by its own recipient (`c11 mailbox status`).
Claude Code reads its mail inline; the others answer their doorbell with `recv --ack`.
Only sandbox-* commands address the guest. The caller owns sandbox-down.sh.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

SCRIPTS = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_id')
    parser.add_argument('--kinds', default='claude,codex,grok,pi-live,opencode-live')
    parser.add_argument('--out', type=Path, default=Path('/tmp/c11-mail-matrix'))
    parser.add_argument('--timeout', type=int, default=480)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    kinds = args.kinds.split(',')
    nonce = uuid.uuid4().hex[:8]
    root = '/Users/admin/c11-sandbox/matrix-' + nonce
    started = time.monotonic()
    observations = {'nonce': nonce, 'kinds': kinds}

    def command(script, *argv, timeout=240):
        result = subprocess.run([str(SCRIPTS / script), args.run_id, *map(str, argv)],
                                text=True, capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(script + ' ' + ' '.join(map(str, argv[:2])) + ': ' + result.stderr + result.stdout)
        return result.stdout.strip()

    def c11(*argv):
        return command('sandbox-agent.sh', 'c11', *argv, timeout=60)

    def guest(code, *argv):
        return command('sandbox-exec.sh', '/usr/bin/python3', '-c', code, *argv, timeout=60)

    def address(kind):
        return 'matrix-' + kind.replace('-live', '') + '-' + nonce

    peers = {kind: [k for k in kinds if k != kind] for kind in kinds}
    guest('''from pathlib import Path
import sys, json
root = Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
for kind, rows in json.loads(sys.argv[2]).items():
    lines = ["#!/bin/sh", "set -e"]
    for peer, addr in rows:
        body = "MATRIX %s from %s to %s" % (sys.argv[3], kind, peer)
        lines.append('id=$(c11 mailbox send --to %s --topic matrix --body "%s")' % (addr, body))
        lines.append('echo "%s $id" >> %s/ids-%s.txt' % (peer, root, kind))
    lines.append("echo MATRIX_SCRIPT_DONE")
    (root / ("send-%s.sh" % kind)).write_text("\\n".join(lines) + "\\n")
''', root, json.dumps({k: [[p, address(p)] for p in peers[k]] for k in kinds}), nonce)

    brief = ('This is an isolated c11 mailbox test (run %s). Reply briefly and wait for '
             'instructions. Later, when a line says "c11 mail waiting", run exactly `c11 mailbox recv --ack` '
             'once, then reply MATRIX_GOT. When other c11 mail reaches you, reply MATRIX_GOT. '
             'Never edit files or change configuration.') % nonce
    targets = {}
    with tempfile.NamedTemporaryFile('w', suffix='.md', delete=False) as handle:
        handle.write(brief + '\n')
        brief_path = handle.name
    for kind in kinds:
        out = command('sandbox-agent.sh', 'launch', kind, brief_path, '--title', address(kind),
                      '--address', address(kind), timeout=300)
        fields = dict(line.split('=', 1) for line in out.splitlines() if '=' in line)
        assert fields.get('ready'), out
        targets[kind] = fields
        observations['launch_' + kind] = fields
    workspace = targets[kinds[0]]['workspace']

    def screen(kind, lines=60):
        return c11('read-screen', '--workspace', targets[kind]['workspace'], '--panel', targets[kind]['tab'],
                   '--lines', str(lines))

    def wait(label, probe, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = probe()
            if value:
                return value
            time.sleep(2)
        raise AssertionError('Timed out: ' + label)

    for kind in kinds:
        c11('send', '--workspace', targets[kind]['workspace'], '--panel', targets[kind]['tab'],
            'Run exactly this one shell command, then reply MATRIX_SENT: sh %s/send-%s.sh' % (root, kind))

    def sent():
        rows = json.loads(guest('''from pathlib import Path
import sys, json
out = {}
for path in Path(sys.argv[1]).glob("ids-*.txt"):
    out[path.stem[4:]] = [line.split() for line in path.read_text().splitlines() if line.strip()]
print(json.dumps(out))''', root))
        return rows if sum(len(v) for v in rows.values()) == len(kinds) * (len(kinds) - 1) else None

    ids = wait('every agent sent its envelopes', sent, 240)
    observations['sent'] = ids

    def status(mail_id):
        return json.loads(c11('mailbox', 'status', mail_id, '--json'))

    def settled():
        rows = {}
        for sender, sent_rows in ids.items():
            for recipient, mail_id in sent_rows:
                report = status(mail_id)
                person = report['recipients'][0] if report.get('recipients') else {}
                rows[(sender, recipient)] = dict(id=mail_id, delivery=person.get('delivery'),
                                                 route=person.get('delivery_route'), read=person.get('read'),
                                                 read_state=person.get('read_state'))
        observations['matrix'] = {'%s->%s' % k: v for k, v in rows.items()}
        return rows if all(v['read'] for v in rows.values()) else None

    try:
        rows = wait('every envelope read by its recipient', settled, args.timeout)
    finally:
        for kind in kinds:
            try:
                observations['screen_' + kind] = screen(kind, 120)
            except Exception as error:
                observations['screen_' + kind] = str(error)
        observations['seconds'] = round(time.monotonic() - started, 1)
        (args.out / 'matrix.json').write_text(json.dumps(observations, indent=2, default=str) + '\n')
        for kind in kinds:
            try:
                c11('close-panel', '--workspace', targets[kind]['workspace'], '--panel', targets[kind]['tab'])
            except Exception:
                pass

    # A ring uses the recipient's own route, never the typed fallback where a
    # native route exists. No route means the recipient claimed the mail without
    # a ring (a Stop drain, or a recv already running).
    expected = {'claude': 'claude_inbox', 'grok': 'grok_leader', 'pi-live': 'pi_extension',
                'opencode-live': 'opencode_plugin', 'omp-live': 'omp_extension', 'codex': 'typed'}
    wrong = {k: v['route'] for k, v in rows.items() if v['route'] not in (None, expected.get(k[1]))}
    assert not wrong, 'unexpected delivery routes: %s' % wrong
    print('%-15s %-15s %-10s %-17s %s' % ('from', 'to', 'delivery', 'route', 'read'))
    for (sender, recipient), row in sorted(rows.items()):
        print('%-15s %-15s %-10s %-17s %s' % (sender, recipient, row['delivery'], row['route'], row['read_state']))
    print('PASS: %d of %d envelopes delivered and read by their recipients in %.0f s'
          % (len(rows), len(rows), time.monotonic() - started))


if __name__ == '__main__':
    main()
