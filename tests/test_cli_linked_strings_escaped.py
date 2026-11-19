#!/usr/bin/env python3
"""C11H-359: the CLI's human output prints linked strings with their controls as text.

Panel and workspace titles, metadata values, sidebar status and log lines, flag
reasons and notifications can be set from another machine. Each command below
runs the real CLI against a fake socket twice: once with fixtures whose strings
carry OSC 2, OSC 7, OSC 9, BEL, CR, LF, C1 CSI and DEL, once with the same
fixtures holding plain words. The first run's stdout must hold no control byte
but tab and line feed, no C1 character, and as many lines as the second.

`mailbox recv` reads a synthetic inbox in an isolated home: with `--json` it
prints the stored envelope byte for byte (DEL and C1 raw, so it parses as JSON);
without, those controls print as text.

Reads the CLI from C11_CLI (or C11_CLI_BIN). Never contacts a running app.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()

import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

from fake_server_env import fake_server_env

WS = '88888888-2222-4333-8444-555555555555'
PANEL = '77777777-2222-4333-8444-555555555555'
BROWSER = '66666666-2222-4333-8444-555555555555'
AREA = '55555555-2222-4333-8444-555555555555'
GROUP = '44444444-2222-4333-8444-555555555555'
WINDOW = '33333333-2222-4333-8444-555555555555'

# One line of controls with no line feed: v1 replies keep their line feeds.
CONTROLS = '\x1b]2;owned\x07\x1b]7;file://rigel/tmp\x07\x1b]9;ping\x07\x07\r\x9b31m\x7f'
# JSON values also carry a line feed: no one-line renderer may start a line on it.
HOSTILE = CONTROLS + '\nz'


def v2_fixtures(h):
    def t(word):
        return word + h
    panels = [
        {'id': PANEL, 'ref': 'panel:1', 'type': 'terminal', 'title': t('Build'), 'selected': True,
         'focused': True, 'parent_panel_ref': 'panel:9', 'parent_panel_title': t('Lead')},
        {'id': BROWSER, 'ref': 'panel:2', 'type': 'browser', 'title': t('Docs'),
         'url': 'https://example.test/' + h},
    ]
    workspace = {
        'id': WS, 'ref': 'workspace:1', 'title': t('Studio'), 'root_directory': '/tmp/' + h,
        'selected': True, 'group_id': GROUP,
        'content_area': {'pixels': {'width': 1600, 'height': 900}},
        'areas': [{'id': AREA, 'ref': 'area:1', 'focused': True, 'panel_count': 2, 'panels': panels,
                   'layout': {'percent': {'H': [0, 1], 'V': [0, 1]},
                              'pixels': {'H': [0, 1600], 'V': [0, 900]}, 'split_path': []}}],
    }
    metadata = {'title': t('Build'), 'terminal_type': t('claude-code'), 'model': t('opus'),
                'status': t('working'), 'role': t('lead'), 'description': t('Ships the build'),
                'mailbox.address': t('lyra')}
    return {
        'system.tree': {'windows': [{
            'id': WINDOW, 'ref': 'window:1', 'name': t('Main'), 'current': True,
            'workspaces': [workspace],
            'workspace_groups': [{'id': GROUP, 'ref': 'workspace_group:1', 'name': t('Team'),
                                  'member_count': 1}],
        }]},
        'panel.get_metadata': {'metadata': metadata,
                               'metadata_sources': {k: {'source': t('explicit'), 'ts': 1.0} for k in metadata}},
        'workspace.list': {'workspaces': [{'id': WS, 'ref': 'workspace:1', 'title': t('Studio'),
                                           'selected': True,
                                           'remote': {'enabled': True, 'state': t('connected')}}]},
        'panel.list': {'panels': [{'id': PANEL, 'ref': 'panel:1', 'type': 'terminal', 'title': t('Build'),
                                   'focused': True,
                                   'flag': {'reason': t('Needs review'),
                                            'kind': {'emoji': '⚑', 'name': t('review')}}}]},
        'area.panels': {'panels': [{'id': PANEL, 'ref': 'panel:1', 'title': t('Build'), 'selected': True}]},
        'panel.family': {'nodes': [
            {'id': PANEL, 'ref': 'panel:1', 'type': t('terminal'), 'title': t('Lead'), 'state': t('running'),
             'workspace_ref': 'workspace:1', 'workspace_title': t('Studio'), 'origin': 'app',
             'origin_detail': t('relay')},
            {'id': BROWSER, 'ref': 'panel:2', 'parent_panel_id': PANEL, 'type': 'terminal', 'title': t('Builder'),
             'state': 'running', 'workspace_ref': 'workspace:1', 'workspace_title': t('Studio'), 'origin': 'panel'},
        ]},
        'workspace.get_metadata': {'metadata': {'captain': t('lyra'), 'notes': t('ship it')},
                                   'metadata_sources': {'captain': {'source': t('explicit')},
                                                        'notes': {'source': 'explicit'}}},
        'feed.list': {'rows': [{'kind': 'flag', 'state': t('open'), 'flag': {'reason': t('Needs review')},
                                'prompt_available': False, 'workspace_id': WS, 'panel_id': PANEL}],
                      'flag_lowered': {'panel_id': PANEL, 'by': t('rigel'), 'cause': t('evaporated'),
                                       'reason': t('Done'), 'lowered_at_ms': 0}},
        'system.fleet': {'schema_version': 1, 'scope': 'agents', 'panels': [{
            'panel_id': PANEL, 'workspace_title': t('Studio'), 'panel_title': t('Build'),
            'agent_type': t('codex'), 'model': t('gpt'), 'lifecycle': t('working'),
            'blocked': {'reason': t('approval')}, 'flag': False, 'mailbox_unread_count': 3}]},
    }


def v1_fixtures(h):
    return {
        'list_status': f'build=ready{h} icon=hammer\nreview=pending{h}',
        'list_log': f'[info] deploy{h}\n[lyra] [warning] retry{h}',
        'sidebar_state': f'tab={WS}\nstatus_count=1\n  build=ready{h}\nlog_count=1\n  [info] deploy{h}',
        'list_notifications': f'0:{PANEL}|{WS}|none|unread|Title{h}|Sub{h}|Body{h}',
    }


COMMANDS = [
    ['tree'],
    ['tree', '--report'],
    ['get-metadata', '--workspace', WS, '--panel', PANEL],
    ['get-metadata', '--workspace', WS, '--panel', PANEL, '--sources'],
    ['list-workspaces'],
    ['list-panels', '--workspace', WS],
    ['list-area-panels', '--workspace', WS],
    ['family', '--panel', PANEL],
    ['get-workspace-metadata', '--workspace', WS],
    ['get-workspace-metadata', '--workspace', WS, '--sources'],
    ['feed', 'list'],
    ['fleet'],
    ['list-status', '--workspace', WS],
    ['list-log', '--workspace', WS],
    ['sidebar-state', '--workspace', WS],
    ['list-notifications'],
]

FORBIDDEN_BYTES = set(range(0x00, 0x09)) | set(range(0x0B, 0x20)) | {0x7F}

# A mail body from a linked machine: JSON stores ESC and BEL escaped, DEL and C1 CSI raw.
MAIL_ID = '01K' + '1'.zfill(23)
MAIL = {'version': 1, 'id': MAIL_ID, 'from': 'lyra', 'to': 'rigel', 'ts': '2026-10-01T12:00:00Z',
        'body': 'text\x7f\x9bmore\x1b]2;owned\x07'}


def check_mailbox_recv(cli, socket_path):
    """Problems with `recv --peek` against a synthetic inbox, [] when none."""
    with tempfile.TemporaryDirectory(prefix='c11-linked-home-') as home:
        inbox = Path(home, 'Library', 'Application Support', 'c11', 'workspaces', WS.upper(), 'mailboxes',
                     PANEL.lower())
        inbox.mkdir(parents=True)
        stored = json.dumps(MAIL, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        assert b'\x7f' in stored and '\x9b'.encode() in stored, 'the stored envelope holds raw DEL and C1'
        (inbox / (MAIL_ID + '.msg')).write_bytes(stored)
        env = fake_server_env(socket_path)
        env.update(C11_QUIET_DISCOVERY='1', HOME=home, CFFIXED_USER_HOME=home, C11_WORKSPACE_ID=WS,
                   C11_PANEL_ID=PANEL, CMUX_CLI_SENTRY_DISABLED='1')
        problems = []
        for args in (['--json', 'mailbox', 'recv', '--peek'], ['mailbox', 'recv', '--peek']):
            result = subprocess.run([cli, '--socket', socket_path, *args], env=env, capture_output=True, timeout=20)
            if result.returncode != 0:
                problems.append(f'{" ".join(args)}: exit {result.returncode}: {result.stderr.decode(errors="replace")}')
                continue
            out = result.stdout
            if args[0] == '--json':
                if out != stored + b'\n':
                    problems.append(f'--json recv changed the stored envelope: {out!r}')
                try:
                    if json.loads(out) != MAIL:
                        problems.append(f'--json recv parsed to another envelope: {out!r}')
                except ValueError as error:
                    problems.append(f'--json recv is not JSON ({error}): {out!r}')
            else:
                text = out.decode('utf-8')
                bad = sorted({hex(b) for b in out if b in FORBIDDEN_BYTES})
                c1 = sorted({hex(ord(c)) for c in text if 0x80 <= ord(c) <= 0x9F})
                if bad or c1 or '\\x7F' not in text:
                    problems.append(f'recv printed controls raw (bytes {bad}, C1 {c1}): {text!r}')
        if not problems:
            print('ok: mailbox recv --peek (--json byte for byte, human as text)')
        return problems


def main():
    cli = os.environ.get('C11_CLI') or os.environ.get('C11_CLI_BIN')
    assert cli, 'set C11_CLI (or C11_CLI_BIN) to the built c11 CLI'
    fixtures = {
        'hostile': (v2_fixtures(HOSTILE), v1_fixtures(CONTROLS)),
        'plain': (v2_fixtures(' plain'), v1_fixtures(' plain')),
    }
    mode = {'name': 'plain'}
    with tempfile.TemporaryDirectory(prefix='c11-linked-') as directory:
        path = str(Path(directory) / 'fixture.sock')
        errors = []
        stopped = threading.Event()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(8)
        server.settimeout(.1)

        def serve():
            while not stopped.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                try:
                    with conn, conn.makefile('rwb') as stream:
                        v2, v1 = fixtures[mode['name']]
                        for line in stream:
                            if not line.startswith(b'{'):
                                command = line.decode().split(' ', 1)[0].strip().strip("'\"")
                                stream.write((v1.get(command, 'OK') + '\n').encode())
                                stream.flush()
                                continue
                            request = json.loads(line)
                            result = v2.get(request['method'], {})
                            response = {'id': request['id'], 'ok': True, 'result': result}
                            stream.write((json.dumps(response) + '\n').encode())
                            stream.flush()
                except Exception as error:
                    errors.append(repr(error))
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        env = fake_server_env(path)
        env.update(C11_QUIET_DISCOVERY='1')

        def run(name, args):
            mode['name'] = name
            result = subprocess.run([cli, '--socket', path, *args], env=env,
                                    capture_output=True, timeout=20)
            assert result.returncode == 0, (args, name, result.stderr.decode(errors='replace'))
            return result.stdout

        try:
            failures = []
            for args in COMMANDS:
                hostile = run('hostile', args)
                plain = run('plain', args)
                text = hostile.decode('utf-8')
                bad_bytes = sorted({b for b in hostile if b in FORBIDDEN_BYTES})
                c1 = sorted({hex(ord(c)) for c in text if 0x80 <= ord(c) <= 0x9F})
                problems = []
                if bad_bytes:
                    problems.append(f'control bytes {[hex(b) for b in bad_bytes]}')
                if c1:
                    problems.append(f'C1 characters {c1}')
                if '\\x1B' not in text:
                    problems.append('no escaped ESC (the linked string was not printed)')
                lines, plain_lines = hostile.count(b'\n'), plain.count(b'\n')
                if lines != plain_lines:
                    problems.append(f'{lines} lines, plain fixture has {plain_lines}')
                if problems:
                    failures.append(f'{" ".join(args)}: {"; ".join(problems)}\n{text!r}')
                else:
                    print(f'ok: {" ".join(args)}')
            mode['name'] = 'plain'
            failures += check_mailbox_recv(cli, path)
            assert not errors, errors
            assert not failures, '\n\n'.join(failures)
            print(f'PASS: {len(COMMANDS)} commands print linked strings with controls as \\xHH, '
                  'line structure intact; --json mailbox recv prints the stored envelope')
        finally:
            stopped.set(); worker.join(timeout=2); server.close()


if __name__ == '__main__':
    main()
