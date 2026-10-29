#!/usr/bin/env python3
"""C11-514: run only via sandbox-tests-v2.sh; drive CLI in real caller shells."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

from cmux import cmux, find_cli_binary


def wait(check, label, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        time.sleep(.15)
    raise AssertionError('Timed out: ' + label)


def main():
    cli = find_cli_binary()
    socket = os.environ['C11_SOCKET_PATH']
    scratch = Path(tempfile.mkdtemp(prefix='c11-514-'))
    page = scratch / 'page.html'
    page.write_text('<!doctype html><title>Caller placement proof</title><h1>Browser placement loaded</h1>')
    url = page.as_uri()
    base = [cli, '--socket', socket, '--id-format', 'both']

    def command(*args, raw=False):
        result = subprocess.run(base + ([] if raw else ['--json']) + list(args), capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return result.stdout if raw else json.loads(result.stdout)

    def tree(ws):
        return command('tree', '--workspace', ws)['windows'][0]['workspaces'][0]

    def area_for(ws, panel):
        return next(a for a in tree(ws)['areas'] if any(p['id'] == panel for p in a['panels']))

    def panel_id(result):
        return result['panel_id']

    with cmux(socket) as c:
        window = c._call('window.create')['window_id']
        ws = c._call('workspace.list', {'window_id': window})['workspaces'][0]['id']
        initial = c.list_surfaces(ws)
        a = initial[0][1]
        # New windows can inherit the operator's starter layout (e.g. a quad).
        for _, panel, _ in initial[1:]:
            c._call('panel.close', {'panel_id': panel})
        print('DISPLAY', command('resize-window', '--window', window, '1900', '1040'), flush=True)
        b = panel_id(command('new-split', 'right', '--workspace', ws, '--panel', a))
        cc = panel_id(command('new-split', 'down', '--workspace', ws, '--panel', a))
        d = panel_id(command('new-split', 'down', '--workspace', ws, '--panel', b))
        for p in (a, b, cc, d):
            wait(lambda: next((r.get('tty') for r in c._call('panel.list', {'workspace_id': ws})['panels'] if r['id'] == p), None), 'terminal tty')
        c._call('panel.focus', {'panel_id': d})
        time.sleep(.4)
        original = area_for(ws, d)
        print('BEFORE\n' + command('tree', '--workspace', ws, '--no-layout', raw=True), flush=True)
        sequence = 0

        def from_panel(panel, args):
            nonlocal sequence
            sequence += 1
            out = scratch / f'call-{sequence}.json'
            done = scratch / f'call-{sequence}.done'
            line = shlex.join([cli, '--json', '--id-format', 'both', *args]) + f' > {shlex.quote(str(out))} 2>&1; echo $? > {shlex.quote(str(done))}\n'
            c.send_surface(panel, line)
            wait(done.exists, 'caller CLI receipt')
            assert done.read_text().strip() == '0', out.read_text()
            payload = json.loads(out.read_text())
            print('CALL', panel, args, payload, flush=True)
            return payload

        def loaded(result):
            pid = panel_id(result)
            wait(lambda: command('browser', pid, 'get', 'url').get('url') == url, 'browser URL')
            wait(lambda: 'Browser placement loaded' in command('browser', pid, 'get', 'text', 'body').get('value', ''), 'rendered page')

        opened = []
        for caller in (a, b, cc, a, b):
            result = from_panel(caller, ['browser', 'open', url])
            assert result['source_panel_id'] == caller, result
            loaded(result)
            opened.append(result)
        assert opened[0]['area_id'] == opened[3]['area_id'], opened
        assert opened[1]['area_id'] == opened[4]['area_id'], opened
        after = area_for(ws, d)
        assert after['layout'] == original['layout'], (original, after)
        assert [p['id'] for p in after['panels']] == [d], after
        assert after['focused'], after
        for area in tree(ws)['areas']:
            h = area['layout']['percent']['H']
            assert h[1] - h[0] >= .24, area
        print('AFTER\n' + command('tree', '--workspace', ws, '--no-layout', raw=True), flush=True)
        other = c._call('workspace.create', {'window_id': window})['workspace_id']
        other_initial = c.list_surfaces(other)
        for _, panel, _ in other_initial[1:]:
            c._call('panel.close', {'panel_id': panel})
        for verb in ('open', 'open-split', 'new'):
            result = from_panel(a, ['browser', verb, url, '--workspace', other])
            assert result['workspace_id'] == other and not result['created_split'], result
            loaded(result)
        assert len(tree(other)['areas']) == 1
        # Aliases use the same caller anchor and reuse, rather than focused d.
        for verb in ('open-split', 'new'):
            result = from_panel(a, ['browser', verb, url])
            assert result['source_panel_id'] == a and result['area_id'] == opened[0]['area_id'], result
            loaded(result)
        result = from_panel(a, ['browser', 'open', url, '--panel', b])
        assert result['source_panel_id'] == b and result['area_id'] == opened[1]['area_id'], result
        loaded(result)
        before_count = len(c.list_surfaces(ws))
        result = from_panel(a, ['browser', 'open', url, '--panel', opened[0]['panel_ref']])
        assert result['panel_id'] == opened[0]['panel_id'] and len(c.list_surfaces(ws)) == before_count, result
        loaded(result)
        # Hidden aliases still navigate. Invalid explicit targets must never create.
        for alias in ('surface:', 'tab:'):
            result = from_panel(a, ['browser', 'open', url, '--panel', opened[0]['panel_ref'].replace('panel:', alias)])
            assert result['panel_id'] == opened[0]['panel_id']
        for args in (['--panel', 'panel:999999'], ['--panel', ''], ['--area', ''], ['--area', 'area:999999']):
            result = subprocess.run(base + ['browser', 'open', url] + args, capture_output=True, text=True, timeout=20)
            assert result.returncode != 0, (args, result.stdout)
        assert len(c.list_surfaces(ws)) == before_count
        other_area = tree(other)['areas'][0]['id']
        result = from_panel(a, ['browser', 'open', url, '--area', other_area])
        assert result['workspace_id'] == other and result['area_id'] == other_area and not result['created_split'], result
        loaded(result)
        print('CROSS WORKSPACE\n' + command('tree', '--workspace', other, '--no-layout', raw=True), flush=True)
        print('PASS: three callers/five opens; focus and geometry unchanged; aliases, cross-workspace, explicit panel/area and browser navigation; all pages loaded.', flush=True)
        print('Evidence scratch:', scratch, flush=True)


if __name__ == '__main__':
    main()
