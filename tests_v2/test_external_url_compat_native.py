#!/usr/bin/env python3
"""Measure ordinary URL, folder and Dock-reopen behavior in a verified guest.

Run against the approved main baseline and candidate with sandbox-tests-v2.sh;
compare semantic outcomes and native window deltas, not process-local IDs.
"""
import json
from pathlib import Path
import time
import traceback

import test_external_panel_links_native as outside

OUT = Path('/Volumes/My Shared Files/out/external-url-compat')
outside.OUT = outside.native.OUT = OUT

DOCK_ITEM = r'''
function run(args) {
    var expected = args[0];
    var dock = Application('System Events').processes.byName('Dock');
    function attr(e, name) { try { return e.attributes.byName(name).value(); } catch (_) { return null; } }
    var items = dock.lists()[0].uiElements().map(function(e) {
        return {title: attr(e, 'AXTitle'), url: String(attr(e, 'AXURL') || ''),
                position: attr(e, 'AXPosition'), size: attr(e, 'AXSize')};
    });
    var matches = items.filter(function(e) { return decodeURI(e.url).indexOf(expected) >= 0; });
    if (matches.length !== 1) throw Error('Exact guest app Dock item missing or ambiguous: '+JSON.stringify(items));
    return JSON.stringify(matches[0]);
}
'''


class Compatibility(outside.Proof):
    def snapshot(self):
        ids = self.native_main_window_ids()
        workspaces = self.call('workspace.list', window_id=self.window)['workspaces']
        return dict(native_window_count=len(ids), native_window_ids=ids,
                    workspace_count=len(workspaces), selected=self.selection(), workspaces=workspaces)

    def settle(self):
        previous = None
        stable = 0
        deadline = time.monotonic()+8
        while time.monotonic() < deadline:
            state = self.snapshot()
            signature = (state['native_window_ids'], state['workspace_count'], state['selected'])
            stable = stable+1 if signature == previous else 0
            if stable >= 2:
                return state
            previous = signature
            time.sleep(.2)
        raise AssertionError('External event did not settle within eight seconds')

    def execute(self):
        self.precondition()
        self.ui('activate')
        windows = self.call('window.list')['windows']
        assert len(windows) == 1 and windows[0]['key'], windows
        self.window = windows[0]['id']
        self.report['observations'] = []
        initial = self.snapshot()
        assert initial['native_window_count'] == 1, initial
        folder = self.fixture/'ordinary-folder'
        folder.mkdir(exist_ok=True)
        for label, url in [('folder', folder.as_uri()), ('http', 'http://127.0.0.1:9/c11-552-compat'),
                           ('https', 'https://127.0.0.1:9/c11-552-compat')]:
            before = self.snapshot()
            self.safari_foreground()
            self.console_open('-a', str(self.app), url)
            after = self.settle()
            if label == 'folder':
                assert after['workspace_count'] == before['workspace_count']+1, after
                selected = self.call('system.identify', window_id=self.window)['focused']
                assert Path(selected['root_directory']) == folder, selected
            observation = dict(label=label, before=before, after=after,
                               native_window_delta=after['native_window_count']-before['native_window_count'],
                               workspace_delta=after['workspace_count']-before['workspace_count'])
            self.report['observations'].append(observation)
            self.capture(label)

        self.ui('activate')
        before = self.settle()
        self.key(4, 'command down')
        self.wait(lambda: self.ui('foreground') != self.pid, 'native Cmd+H hides c11')
        self.safari_foreground()
        item = json.loads(self.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', DOCK_ITEM, str(self.app)], text=True).stdout)
        x,y = item['position']; w,h = item['size']
        self.confirmation_mouse(int(x+w/2), int(y+h/2))
        self.wait(lambda: self.ui('foreground') == self.pid, 'real Dock click reopens exact app')
        after = self.settle()
        self.report['observations'].append(dict(label='dock_reopen', before=before, after=after, dock_item=item,
            native_window_delta=after['native_window_count']-before['native_window_count'],
            workspace_delta=after['workspace_count']-before['workspace_count']))
        self.capture('dock-reopen')
        self.report['status'] = 'measured'


if __name__ == '__main__':
    proof = Compatibility()
    try:
        proof.execute()
        print('MEASURED ordinary folder/http/https/Dock behavior; compare with approved main baseline', flush=True)
    except BaseException as error:
        proof.report.update(status='failed', error=repr(error), traceback=traceback.format_exc())
        try:
            proof.capture('failure')
        except Exception:
            pass
        raise
    finally:
        proof.cleanup()
