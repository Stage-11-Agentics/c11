#!/usr/bin/env python3
"""Dwell/navigation/JSON checks in the isolated tagged-build guest only.

Run via scripts/sandbox-tests-v2.sh RUN tests_v2/test_focus_history.py.
This activates apps and changes focus in that guest; never run on the operator's Mac.
"""
import json
import os
from pathlib import Path
import subprocess
import time

from cmux import cmux, cmuxError


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def main():
    # The golden guest contains this marker; require it before any focus action.
    require(Path.home().joinpath('c11-sandbox').is_dir(), 'Run only in the c11 sandbox guest')
    socket = os.environ['C11_SOCKET']
    cli = os.environ['C11_CLI']
    with cmux(socket) as client:
        workspace = client.new_workspace()
        client.select_workspace(workspace)
        targets = [client.new_surface() for _ in range(4)]
        a, b, c, d = targets
        client.activate_app()

        def focus(tab, dwell):
            client._call('panel.focus', {'workspace_id': workspace, 'panel_id': tab})
            rows = client._call('panel.list', {'workspace_id': workspace})['panels']
            require(any(row['id'] == tab and row['being_seen'] for row in rows),
                    f'Target {tab} is not actually being seen')
            time.sleep(dwell)

        def history(limit=200):
            return client._call('history.list', {'limit': limit})

        focus(a, 1.2)
        focus(b, 0.1)
        focus(c, 1.2)
        focus(d, 0.1)
        payload = history()
        visits = [row['panel_id'] for row in payload['entries'] if row['panel_id'] in targets]
        require(visits == [a, c], ('dwell qualification', payload))
        require(payload['cap'] == 200 and payload['threshold_seconds'] == 1, payload)
        tail = history(2)
        require(tail['entries'] == payload['entries'][-2:], ('tail order', tail, payload))
        for row in tail['entries']:
            require(set(row) == {'workspace_id', 'workspace_ref', 'workspace_title', 'panel_id',
                                'panel_ref', 'tab_id', 'tab_ref', 'title', 'type', 'seen_at',
                                'dwell_seconds', 'current'}, row)
            require(row['tab_id'] == row['panel_id'], row)
            require(row['panel_ref'].startswith('panel:') and row['tab_ref'] == 'tab:' + row['panel_ref'].split(':', 1)[1], row)

        for value in [None, True, 0, -1, 201, 1.5, '2']:
            try:
                client._call('history.list', {'limit': value})
            except cmuxError as error:
                require('limit must be an integer from 1 to 200' in str(error), str(error))
            else:
                raise AssertionError(f'Accepted invalid limit {value!r}')

        # An unrelated explicit --window must be ignored by the app-wide read.
        other_window = client.new_window()
        focus(d, 0.1)
        before = client._call('system.identify')
        require(before['focused']['window_id'] != other_window, 'Focus must start in the original window')
        seen_before = client._call('panel.list', {'workspace_id': workspace})['panels']
        result = subprocess.run([cli, '--socket', socket, '--window', other_window,
                                 'history', '--json', '--limit', '2'], capture_output=True, text=True)
        require(result.returncode == 0, result.stderr)
        require(json.loads(result.stdout) == history(2), result.stdout)
        require(client._call('system.identify') == before, 'Listing changed current focus')
        seen_after = client._call('panel.list', {'workspace_id': workspace})['panels']
        require([(r['id'], r['being_seen']) for r in seen_before] ==
                [(r['id'], r['being_seen']) for r in seen_after], 'Listing changed being_seen')
        client.close_window(other_window)

        # Complete B and C visits so the traversal scenario has A/B/C.
        focus(b, 1.2)
        focus(c, 1.2)
        focus(d, 0.1)
        require(client._call('history.back')['panel_id'] == b, history())
        time.sleep(1.2)
        require(client._call('history.forward')['panel_id'] == c, history())
        time.sleep(1.2)
        require(client._call('history.back')['panel_id'] == b, history())
        focus(d, 1.2)
        focus(a, 0.1)
        require(history()['entries'][-1]['panel_id'] == d, history())
        require(history()['forward_count'] == 0, 'New qualified visit did not truncate forward')
        client.close_surface(b)
        require(all(row['panel_id'] != b for row in history()['entries']), 'Closed target retained')

        # Background navigation changes in-app selection but must leave Finder frontmost.
        subprocess.run(['osascript', '-e', 'tell application "Finder" to activate'], check=True)
        time.sleep(0.2)
        selection_before = client._call('system.identify')['focused']['panel_id']
        destination = client._call('history.back')['panel_id']
        require(destination != b, 'Navigated to closed tab')
        require(destination != selection_before, 'Background scenario requires a different destination')
        require(client._call('system.identify')['focused']['panel_id'] == destination,
                'Navigation returned a destination without selecting it')
        time.sleep(0.2)
        front = subprocess.check_output(['osascript', '-e',
            'tell application "System Events" to get name of first process whose frontmost is true'], text=True).strip()
        require(front == 'Finder', ('Navigation activated c11', front))
        stable = history()
        client._call('panel.focus', {'workspace_id': workspace, 'panel_id': c})
        time.sleep(1.2)
        client._call('panel.focus', {'workspace_id': workspace, 'panel_id': a})
        require(history() == stable, 'Background focus added unseen visits')
        client.close_workspace(workspace)
    print('PASS: focus history dwell, tail/JSON, nonfocus reads, traversal, close and background focus')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
