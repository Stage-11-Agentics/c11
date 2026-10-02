#!/usr/bin/env python3
"""Atlas tagged UI proof for C11-231 submit attribution (synthetic data only).

Run inside the ticket's isolated Tart guest after sandbox-up. UI events target
the exact tagged PID; socket calls only build/query the fixture. The active
phase is capped at five minutes and cleanup dismisses copy mode/TextBox state.
"""
import json
import argparse
import hashlib
import os
from pathlib import Path
import signal
import sqlite3
import threading
import time
import uuid

import attention_menu_bar_probe as base


ACTIVE_SECONDS = 300
PICKER_ASKS = ('picker',)
HARD_SECONDS = 330
EXTRA_JXA = r'''
    if (operation === 'target-key') {
        var code = Number(args[2]), flags = Number(args[3] || 0), repeat = Number(args[4] || 0);
        var down = $.CGEventCreateKeyboardEvent(null, code, true);
        var up = $.CGEventCreateKeyboardEvent(null, code, false);
        $.CGEventSetFlags(down, flags); $.CGEventSetFlags(up, flags);
        if (repeat) $.CGEventSetIntegerValueField(down, 8, 1); // kCGKeyboardEventAutorepeat
        $.CGEventPostToPid(pid, down); $.CGEventPostToPid(pid, up);
        return '{}';
    }
    if (operation === 'target-type') {
        se.keystroke(String(args[2]));
        return '{}';
    }
    function descendants() { return process.windows()[0].entireContents(); }
    function ax(element, name) {
        try { return String(element.attributes.byName(name).value()); } catch (_) { return ''; }
    }
    if (operation === 'dismiss-notification-prompt') {
        var pressed = 0;
        process.windows().forEach(function(window) {
            window.entireContents().forEach(function(item) {
                if (item.role() === 'AXButton' && item.name() === 'Not Now') {
                    item.actions.byName('AXPress').perform();
                    pressed += 1;
                }
            });
        });
        return JSON.stringify({pressed: pressed});
    }
    if (operation === 'copy-mode-state') {
        var hits = [];
        descendants().forEach(function(item) {
            ['AXValue', 'AXDescription', 'AXHelp', 'AXTitle'].forEach(function(name) {
                var value = ax(item, name);
                if (value.toLowerCase() === 'vim' || value.toLowerCase() === 'copy mode')
                    hits.push({role: item.role(), attribute: name, value: value});
            });
        });
        return JSON.stringify(hits);
    }
    if (operation === 'textbox-inventory') {
        return JSON.stringify(descendants().map(function(item) {
            return {role: item.role(), name: item.name() || '', description: ax(item, 'AXDescription'),
                help: ax(item, 'AXHelp'), value: ax(item, 'AXValue')};
        }).filter(function(item) {
            return item.role === 'AXTextArea' || item.role === 'AXTextField' ||
                item.role === 'AXButton' || item.help === 'Send' || item.description === 'Send';
        }));
    }
    if (operation === 'focus-textbox') {
        var fields = descendants().filter(function(item) {
            return item.role() === 'AXTextArea' && ax(item, 'AXHelp') !== 'Terminal content area';
        });
        if (fields.length !== 1) throw new Error('Expected exactly one TextBox AXTextArea, found ' + fields.length);
        fields[0].click();
        return '{}';
    }
    if (operation === 'press-textbox-send') {
        var buttons = descendants().filter(function(item) {
            return item.role() === 'AXButton' &&
                (item.name() === 'Send' || ax(item, 'AXDescription') === 'Send' || ax(item, 'AXHelp') === 'Send');
        });
        if (buttons.length !== 1 || !buttons[0].enabled())
            throw new Error('Expected exactly one enabled TextBox Send button, found ' + buttons.length);
        buttons[0].actions.byName('AXPress').perform();
        return '{}';
    }
'''
base.JXA = base.JXA.replace('    var bars = process.menuBars()', EXTRA_JXA + '\n    var bars = process.menuBars()')


class SubmitProbe(base.Probe):
    def __init__(self, args):
        super().__init__(args)
        self.deadline = self.started + ACTIVE_SECONDS
        self.tabs = {}
        self.owners = {}
        self.requests = {}
        self.journal_db = None
        self.textbox_visible = False
        self.copy_mode = False
        self.completion_suppressed = False
        self.completion_notification_created = False

    def timeout(self):
        limit = self.started + (HARD_SECONDS if self.cleanup_mode else ACTIVE_SECONDS)
        remaining = limit - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('C11-231 UI probe deadline reached')
        # Accessibility tree walks of the whole window exceed 3 s in the guest.
        return min(30, remaining)

    def journal_path(self):
        with (Path(self.args.app) / 'Contents/Info.plist').open('rb') as source:
            import plistlib
            bundle = plistlib.load(source)['CFBundleIdentifier']
        return Path.home() / 'Library/Application Support/c11/journal' / bundle / 'lifecycle.sqlite3'

    def events(self, tab):
        with sqlite3.connect(self.journal_db) as database:
            rows = database.execute(
                'SELECT event FROM journal_events WHERE tab_id=? ORDER BY sequence', (tab,)).fetchall()
        return [json.loads(row[0]) for row in rows]

    def responses(self, tab, request):
        return [event for event in self.events(tab)
                if event['draft'].get('signal') == 'operator_response'
                and event['draft'].get('request_id') == request]

    def send_key(self, tab, key):
        result = self.run([self.args.cli, '--socket', self.args.socket, 'send-key',
                           '--workspace', self.workspace, '--tab', tab, key])
        self.check(result.returncode == 0, 'Synthetic c11 send-key delivered without a response observation')

    def launch_pinned_picker(self):
        wrapper = Path(self.args.app) / 'Contents/Resources/bin/claude'
        version = self.run([str(wrapper), '--version'], check=False)
        version_text = (version.stdout + version.stderr).strip()
        if version.returncode != 0 or not version_text.startswith('2.1.287'):
            raise AssertionError('Pinned Claude Code 2.1.287 is unavailable in this guest')
        self.report['picker_fixture'] = {
            'case': 'claude-bypass-ask', 'provider_version': '2.1.287 (Claude Code)'
        }

        before = {tab['id'] for tab in self.rpc('tab.list', {'workspace_id': self.workspace})['tabs']}
        prompt = ('Use AskUserQuestion exactly once. Ask one single-choice question with two options: '
                  '"Synthetic option A" and "Synthetic option B". Do not call any other tool. '
                  'Wait after asking for my answer.')
        launch = self.run([
            self.args.cli, '--socket', self.args.socket, 'launch-agent', '--type', 'claude-code',
            '--model', 'haiku', '--effort', 'low', '--workspace', self.workspace,
            '--cwd', '/tmp', '--title', 'Pinned AskUserQuestion fixture', '--prompt', prompt, '--json'
        ])
        try:
            payload = json.loads(launch.stdout)
        except json.JSONDecodeError as error:
            raise AssertionError('Tagged launch-agent did not return machine-readable refs') from error
        tab = payload.get('tab_id') or payload.get('surface_id')
        if not tab:
            after = self.rpc('tab.list', {'workspace_id': self.workspace})['tabs']
            created = [item['id'] for item in after if item['id'] not in before]
            if len(created) != 1:
                raise AssertionError('Could not uniquely identify the pinned fixture tab')
            tab = created[0]
        self.tabs['picker'] = tab

        def ask_event():
            asks = [event for event in self.events(tab)
                    if event['draft'].get('native_event') == 'PreToolUse'
                    and event['draft'].get('tool_class') == 'ask_user_question']
            return asks[0] if len(asks) == 1 and asks[0].get('projection_effect') == 'applied' else None

        ask = self.eventually(ask_event, 'Pinned Claude fixture emitted one committed AskUserQuestion hook', seconds=90)
        request = ask['draft'].get('request_id')
        if not request:
            raise AssertionError('Pinned ask hook did not carry its correlation id')
        self.requests['picker'] = request
        self.eventually(lambda: self.rpc('tab.get_metadata', {'tab_id': tab})
                        ['metadata']['journal']['phase'] == 'blocked', 'Pinned ask is visibly blocked')
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': tab})
        self.ui('activate')
        def picker_screen():
            value = self.run([self.args.cli, '--socket', self.args.socket, 'read-screen',
                              '--workspace', self.workspace, '--tab', tab, '--lines', '50']).stdout
            return value if 'Synthetic option A' in value and 'Synthetic option B' in value else None

        screen = self.eventually(picker_screen, 'Pinned AskUserQuestion choices reached the terminal screen', seconds=30)
        (self.output / 'pinned-ask-screen.txt').write_text(screen)
        self.report['picker_screen_sha256'] = hashlib.sha256(screen.encode()).hexdigest()
        self.screenshot('07-pinned-ask-before-input')
        self.check(True, 'Named C11-271 Claude Code 2.1.287 bypass AskUserQuestion fixture is on screen')
        return tab, request, screen

    def append(self, tab, owner, kind, **fields):
        native = {'agent.session.started': 'SessionStart', 'agent.turn.started': 'UserPromptSubmit',
                  'agent.question.requested': 'PreToolUse', 'agent.plan_review.requested': 'PreToolUse',
                  'agent.turn.completed': 'Stop'}[kind]
        event = dict(schema_version=1, event_id=str(uuid.uuid4()), kind=kind,
                     emitted_at_ms=int(time.time() * 1000), tab_id=tab, workspace_id=self.workspace,
                     session_id=owner, agent_kind='claude-code', source='hook', adapter='claude_hook',
                     native_event=native, **fields)
        result = self.rpc('agent.event.append', {'event': event})
        return result

    def open_ask(self, name):
        tab = self.tabs[name]
        owner, request = str(uuid.uuid4()), 'synthetic-' + name + '-request'
        self.owners[name], self.requests[name] = owner, request
        self.rpc('conversation.push', {'tab_id': tab, 'kind': 'claude-code', 'id': owner, 'source': 'hook'})
        self.append(tab, owner, 'agent.session.started')
        self.append(tab, owner, 'agent.turn.started', turn_id='synthetic-' + name + '-turn')
        # Plain terminal asks (plan review) are answered by a terminal submit. The
        # AskUserQuestion picker needs its own committed key, which stays unknown.
        if name in PICKER_ASKS:
            self.append(tab, owner, 'agent.question.requested', request_id=request,
                        turn_id='synthetic-' + name + '-turn', tool_class='ask_user_question')
        else:
            self.append(tab, owner, 'agent.plan_review.requested', request_id=request,
                        turn_id='synthetic-' + name + '-turn', tool_class='exit_plan_mode')
        self.eventually(lambda: self.rpc('tab.get_metadata', {'tab_id': tab})
                        ['metadata']['journal']['phase'] == 'blocked', name + ' synthetic ask blocked')
        self.check(not self.responses(tab, request), name + ' ask starts without operator-response evidence')

    def exercise_completion_unread(self):
        tab = self.tabs['completion']
        owner, turn = str(uuid.uuid4()), 'synthetic-completed-turn'
        self.rpc('conversation.push', {'tab_id': tab, 'kind': 'claude-code', 'id': owner, 'source': 'hook'})
        self.append(tab, owner, 'agent.session.started')
        self.append(tab, owner, 'agent.turn.started', turn_id=turn)
        self.eventually(lambda: self.rpc('tab.get_metadata', {'tab_id': tab})
                        ['metadata']['journal']['phase'] == 'working', 'Synthetic completion turn starts')
        self.append(tab, owner, 'agent.turn.completed', turn_id=turn)

        def completed_state():
            journal = self.rpc('tab.get_metadata', {'tab_id': tab})['metadata']['journal']
            return journal if journal['phase'] == 'idle' and journal['turn_outcome'] == 'completed' else None

        completed = self.eventually(completed_state, 'Committed journal completion is idle', seconds=10)
        self.rpc('notification.create_for_tab', {
            'workspace_id': self.workspace, 'surface_id': tab,
            'title': 'Synthetic completion', 'subtitle': 'Agent finished', 'body': 'Synthetic fixture'
        })
        self.completion_notification_created = True
        # The first notification in a fresh app can raise c11's own authorization prompt.
        # Dismiss exactly that prompt (PID-scoped) so it cannot cover the window.
        prompt = self.ui('dismiss-notification-prompt')
        self.report['notification_prompt_dismissed'] = prompt.get('pressed', 0)

        def unread_completion():
            rows = self.rpc('notification.list')['notifications']
            return next((row for row in rows if row['surface_id'] == tab
                         and row['title'] == 'Synthetic completion' and not row['is_read']), None)

        unread = self.eventually(unread_completion, 'Unopened completed turn remains unread', seconds=10)
        self.check(completed['turn_outcome'] == 'completed' and completed['phase'] == 'idle',
                   'Unread completion is distinct from the journal idle phase')
        self.check(unread is not None, 'Synthetic completion notification is unread before opening its tab')
        self.screenshot('05-unread-completion')

        journal_event_count = len(self.events(tab))
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': tab})
        self.ui('activate')

        def read_completion():
            rows = self.rpc('notification.list')['notifications']
            return next((row for row in rows if row['surface_id'] == tab
                         and row['title'] == 'Synthetic completion' and row['is_read']), None)

        read = self.eventually(read_completion, 'Opening the completed tab clears only its unread mark', seconds=10)
        opened = self.rpc('tab.get_metadata', {'tab_id': tab})['metadata']['journal']
        self.check(read is not None, 'Opening the completed tab marks its existing notification read')
        self.check(opened['phase'] == 'idle' and opened['turn_outcome'] == 'completed'
                   and opened['sequence'] == completed['sequence'],
                   'Opening an unread completion does not alter journal lifecycle evidence')
        self.check(len(self.events(tab)) == journal_event_count,
                   'Opening a completed tab changes last-seen/unread state without appending journal evidence')
        self.screenshot('06-read-completion')
        self.rpc('notification.clear')
        self.completion_notification_created = False

    def exercise_unread_clear_preserves_ask(self):
        tab, request = self.tabs['copy'], self.requests['copy']
        params = {'workspace_id': self.workspace, 'tab_id': tab, 'by': 'operator'}
        self.rpc('flag.suppress', params)
        self.rpc('notification.create_for_tab', {
            'workspace_id': self.workspace, 'surface_id': tab,
            'title': 'Synthetic legacy unread', 'subtitle': 'Compatibility edge', 'body': 'Synthetic fixture'
        })
        try:
            unread = self.eventually(lambda: next((row for row in self.rpc('notification.list')['notifications']
                                                   if row['surface_id'] == tab and not row['is_read']), None),
                                     'Legacy unread appears beside the blocked journal ask')
            before = self.rpc('tab.get_metadata', {'tab_id': tab})['metadata']['journal']
            event_count = len(self.events(tab))
            response_count = len(self.responses(tab, request))
            self.check(before['phase'] == 'blocked' and unread is not None,
                       'Unread compatibility attention remains distinct from blocked journal state')
            self.rpc('notification.clear')
            after = self.rpc('tab.get_metadata', {'tab_id': tab})['metadata']['journal']
            self.check(after['phase'] == 'blocked' and after['sequence'] == before['sequence'],
                       'Clearing unread does not resolve or rewrite the blocked ask')
            self.check(not any(not row['is_read'] for row in self.rpc('notification.list')['notifications']),
                       'Clearing unread removes only notification attention')
            self.check(len(self.events(tab)) == event_count and len(self.responses(tab, request)) == response_count,
                       'Unread clear appends neither journal nor operator-response evidence')
        finally:
            self.rpc('flag.unsuppress', params)

    def execute(self):
        self.preflight()
        self.journal_db = self.journal_path()
        self.workspace = self.rpc('workspace.create', {'working_directory': '/tmp',
            'initial_command': "/usr/bin/env PS1='$ ' /bin/zsh -f"})['workspace_id']
        self.rpc('workspace.rename', {'workspace_id': self.workspace, 'title': 'C11-231 submit proof'})
        for workspace in self.rpc('workspace.list')['workspaces']:
            if workspace['id'] != self.workspace:
                self.rpc('workspace.close', {'workspace_id': workspace['id']})
        self.tabs['copy'] = self.rpc('tab.list', {'workspace_id': self.workspace})['tabs'][0]['id']
        for name in ('input', 'picker', 'textbox', 'completion'):
            self.tabs[name] = self.rpc('tab.create', {'workspace_id': self.workspace, 'type': 'terminal'})['tab_id']
        for name, tab in self.tabs.items():
            self.rpc('tab.set_metadata', {'tab_id': tab, 'metadata': {'title': 'Synthetic ' + name}})
            self.rpc('tab.send_text', {'tab_id': tab, 'text': 'exec /bin/cat >/dev/null\n'})
        topology = self.run([self.args.cli, '--socket', self.args.socket, 'tree', '--no-layout']).stdout
        self.check(all('Synthetic ' + name in topology for name in self.tabs),
                   'All synthetic validation tabs remain named and visible in workspace topology')
        self.rpc('workspace.select', {'workspace_id': self.workspace})
        for name in ('copy', 'input', 'picker', 'textbox'):
            self.open_ask(name)

        # Negative inputs run on an ordinary plan-review ask that a real Return answers,
        # so each check can only pass because the guard rejected the key. Draft typing,
        # autorepeat Return, c11 send-key and an IME/dead-key composition commit all come
        # before the one real Return on this same still-open ask.
        tab, request = self.tabs['input'], self.requests['input']
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': tab})
        self.ui('activate')
        self.ui('target-type', 'synthetic draft')
        self.check(not self.responses(tab, request), 'Typing a draft produces no response')
        self.ui('target-key', '36', '0', '1')
        time.sleep(.5)
        self.check(not self.responses(tab, request), 'Autorepeat Return produces no response')
        self.send_key(tab, 'enter')
        time.sleep(.5)
        self.check(not self.responses(tab, request), 'Generated c11 send-key enter produces no response')
        # Option-E starts a dead-key composition (marked text); Return then commits it.
        self.ui('target-key', '14', str(1 << 19))
        self.screenshot('00-ime-composition-active')
        self.ui('target-key', '36', '0')
        time.sleep(.5)
        self.check(not self.responses(tab, request), 'Return that commits an IME composition produces no response')
        self.check(self.rpc('tab.get_metadata', {'tab_id': tab})['metadata']['journal']['phase'] == 'blocked',
                   'Negative inputs leave the plan-review ask blocked')
        self.ui('target-key', '36', '0')
        self.eventually(lambda: len(self.responses(tab, request)) == 1,
                        'One real Return records exactly one response on the same ask')
        time.sleep(.5)
        self.check(len(self.responses(tab, request)) == 1, 'No further response rows follow the single real Return')
        self.check(self.rpc('tab.get_metadata', {'tab_id': tab})['metadata']['journal']['phase'] == 'blocked',
                   'Real Return leaves the ask blocked')

        # An AskUserQuestion picker has no known commit key, so Return records nothing.
        tab, request = self.tabs['picker'], self.requests['picker']
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': tab})
        self.ui('activate')
        self.ui('target-key', '36', '0')
        time.sleep(.5)
        self.check(not self.responses(tab, request),
                   'Return on an AskUserQuestion picker ask stays unobserved while no commit key is named')

        # Copy-mode Return is consumed locally; Escape exits; a real Return then
        # records exactly once while the journal phase remains blocked.
        tab, request = self.tabs['copy'], self.requests['copy']
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': tab})
        self.ui('activate')
        self.ui('target-key', '46', str((1 << 20) | (1 << 17)))  # Command-Shift-M
        self.copy_mode = True
        self.check(bool(self.ui('copy-mode-state')), 'Keyboard copy mode is visibly active before Return')
        self.screenshot('01-keyboard-copy-mode')
        self.ui('target-key', '36', '0')
        self.check(not self.responses(tab, request), 'Copy-mode Return produces no operator-response event')
        self.ui('target-key', '53', '0')
        self.copy_mode = False
        self.check(not self.ui('copy-mode-state'), 'Synthesized Escape exits keyboard copy mode')
        self.ui('target-key', '36', '0')
        self.eventually(lambda: len(self.responses(tab, request)) == 1, 'real Return records one correlated response')
        self.ui('target-key', '36', '0')
        self.check(len(self.responses(tab, request)) == 1, 'Repeated real submit remains once per ask event')
        self.check(self.rpc('tab.get_metadata', {'tab_id': tab})['metadata']['journal']['phase'] == 'blocked',
                   'Operator response leaves the committed ask blocked')
        self.screenshot('02-return-response-stays-blocked')

        # TextBox editing is not a submit; clicking its actual Send button is.
        tab, request = self.tabs['textbox'], self.requests['textbox']
        self.rpc('tab.focus', {'workspace_id': self.workspace, 'tab_id': tab})
        self.ui('activate')
        self.ui('target-key', '11', str((1 << 20) | (1 << 19)))  # Command-Option-B
        self.textbox_visible = True
        self.ui('focus-textbox')
        self.ui('target-type', 'synthetic text-box draft')
        self.check(not self.responses(tab, request), 'TextBox draft editing produces no response event')
        self.screenshot('03-textbox-editing-no-submit')
        self.ui('press-textbox-send')
        self.eventually(lambda: len(self.responses(tab, request)) == 1, 'TextBox Send records one correlated response')
        self.check(self.rpc('tab.get_metadata', {'tab_id': tab})['metadata']['journal']['phase'] == 'blocked',
                   'TextBox response leaves the committed ask blocked')
        self.screenshot('04-textbox-send-response')
        self.ui('target-key', '11', str((1 << 20) | (1 << 19)))
        self.textbox_visible = False

        self.exercise_completion_unread()
        self.exercise_unread_clear_preserves_ask()

        if self.args.skip_picker:
            self.report['picker_fixture'] = {
                'case': 'claude-bypass-ask', 'provider_version': '2.1.287 (Claude Code)',
                'status': 'not_run', 'reason': 'pinned provider unavailable in this guest'
            }
            return

        tab, request, screen = self.launch_pinned_picker()
        navigation_hint = any(token in screen.lower() for token in ('arrow', '↑', '↓', 'up/down'))
        self.check(navigation_hint, 'Pinned picker explicitly names arrow-key navigation')
        navigation_key = self.args.picker_navigation_key_code or 125
        self.ui('target-key', str(navigation_key), '0')
        time.sleep(.25)
        self.check(not self.responses(tab, request), 'Pinned picker navigation key produces no response event')
        self.check(self.rpc('tab.get_metadata', {'tab_id': tab})['metadata']['journal']['phase'] == 'blocked',
                   'Navigating the pinned picker leaves its committed ask blocked')
        self.screenshot('08-pinned-picker-navigation')

        if self.args.discover_picker_only:
            self.report['picker_observation'] = {
                'navigation_key_code': navigation_key,
                'commit_key_code': None,
                'status': 'awaiting explicit on-screen commit-key observation'
            }
            return

        commit_key = self.args.picker_commit_key_code
        if commit_key is None:
            raise AssertionError('No picker commit key supplied; refusing to guess')
        commit_hint = {36: ('enter', 'return'), 76: ('enter', 'return'), 49: ('space',)}.get(commit_key)
        if not commit_hint or not any(token in screen.lower() for token in commit_hint):
            raise AssertionError('The pinned picker screen does not name the supplied commitment key')
        self.ui('target-key', str(commit_key), '0')
        provider_ack = self.eventually(lambda: next((event for event in self.events(tab)
                                    if event['draft'].get('native_event') == 'PostToolUse'
                                    and event['draft'].get('tool_class') == 'ask_user_question'), None),
                        'Pinned provider acknowledges the committed picker choice', seconds=60)
        response_count = len(self.responses(tab, request))
        self.report['picker_observation'] = {
            'navigation_key_code': navigation_key,
            'commit_key_code': commit_key,
            'provider_ack_event_id': provider_ack['draft'].get('event_id'),
            'response_event_count': response_count,
            'status': 'provider_committed'
        }
        try:
            correlated = self.eventually(
                lambda: self.responses(tab, request) if len(self.responses(tab, request)) == 1 else None,
                'One correlated response is recorded by actual picker keyDown', seconds=10)
        except Exception:
            self.report['picker_observation']['response_event_count'] = len(self.responses(tab, request))
            raise
        response_count = len(self.responses(tab, request))
        self.check(correlated[0]['draft'].get('source') == 'c11'
                   and correlated[0]['draft'].get('signal') == 'operator_response',
                   'Picker keyDown emits one c11 operator-response event for the applied ask')
        self.report['picker_observation'] = {
            'navigation_key_code': navigation_key,
            'commit_key_code': commit_key,
            'provider_ack_event_id': provider_ack['draft'].get('event_id'),
            'response_event_count': response_count,
            'status': 'committed'
        }
        self.screenshot('09-pinned-picker-committed')

    def cleanup(self):
        if self.safe and self.completion_suppressed:
            try:
                self.rpc('flag.unsuppress', {
                    'workspace_id': self.workspace, 'tab_id': self.tabs['completion'], 'by': 'operator'
                })
                self.completion_suppressed = False
            except Exception as error:
                self.report.setdefault('cleanup_errors', []).append(str(error))
        if self.safe and self.completion_notification_created:
            try:
                self.rpc('notification.clear')
                self.completion_notification_created = False
            except Exception as error:
                self.report.setdefault('cleanup_errors', []).append(str(error))
        if self.safe:
            try:
                if self.copy_mode:
                    self.ui('target-key', '53', '0')
                    self.copy_mode = False
                if self.textbox_visible:
                    self.ui('target-key', '11', str((1 << 20) | (1 << 19)))
                    self.textbox_visible = False
            except Exception:
                pass
        super().cleanup()
        safe = {key: self.report[key] for key in (
            'result', 'checks', 'screenshots', 'elapsed_seconds', 'dismissals', 'guest_model',
            'picker_fixture', 'picker_observation', 'picker_screen_sha256', 'notification_prompt_dismissed'
        ) if key in self.report}
        safe['cleanup_ok'] = not self.report.get('cleanup_errors')
        if self.output:
            (self.output / 'report.json').write_text(json.dumps(safe, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('run-id', 'app', 'cli', 'socket'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--output-name', default='c11-231-submit-ui')
    parser.add_argument('--discover-picker-only', action='store_true')
    parser.add_argument('--skip-picker', action='store_true',
                        help='Record the pinned picker fixture as not run (provider unavailable in the guest)')
    parser.add_argument('--picker-navigation-key-code', type=int)
    parser.add_argument('--picker-commit-key-code', type=int)
    args = parser.parse_args()
    args.inspect_dialogs_only = False
    probe = SubmitProbe(args)

    def expire(_signal, _frame):
        raise TimeoutError('C11-231 UI proof exceeded its five-minute active limit')

    signal.signal(signal.SIGALRM, expire)
    signal.alarm(ACTIVE_SECONDS)
    watchdog = threading.Timer(HARD_SECONDS, lambda: os._exit(124))
    watchdog.daemon = True
    watchdog.start()
    try:
        probe.execute()
        probe.report['result'] = ('DISCOVERY_ONLY' if args.discover_picker_only
                                  else 'PASS_PICKER_NOT_RUN' if args.skip_picker else 'PASS')
    except Exception as error:
        probe.report.update(result='FAIL', error=str(error))
    finally:
        signal.alarm(0)
        probe.cleanup()
        watchdog.cancel()
    print(json.dumps(probe.report, indent=2))
    return 0 if probe.report.get('result') in ('PASS', 'PASS_PICKER_NOT_RUN', 'DISCOVERY_ONLY') else 1


if __name__ == '__main__':
    raise SystemExit(main())
