import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import { test } from 'node:test';
import { doorbellText } from '../Resources/bin/mailbox-native.mjs';

const rootA = 'ses_0fda89a49ffeLHwJXtrxnn4X6g';
const rootB = 'ses_0fd8a6fffffe6JzzcloHmtDV0R';
const child = 'ses_0fd8cb310ffe2of6OsP2qYz4Q5';
const send = (socket, frame) => socket.write(JSON.stringify(frame) + '\n');

async function until(predicate, timeout = 2000) {
  const end = Date.now() + timeout;
  while (!predicate()) { assert(Date.now() < end, 'timed out'); await delay(10); }
}

async function untilAsync(predicate, timeout = 2000) {
  const end = Date.now() + timeout;
  while (true) {
    const value = await predicate();
    if (value) return value;
    assert(Date.now() < end, 'timed out');
    await delay(10);
  }
}

async function fixture(t, {
  conflictID, loadRoot = true, hydrateAfterSync = Number.POSITIVE_INFINITY, syncFailureCount = 0,
  nativeMailDisabled = false, status = 'idle', unbindFailureCount = 0, claimPending = false,
  claimFailures = 0,
  hookFailOnce = [], hookDelayActivity = '', activeSessions, activeFailureCount = 0, holdActiveSnapshot = false,
  permissionHydrated = true, permissionSyncResult = [], formHydrated = true, formSyncResult = [],
  messageList = [],
  promptResult = input => ({ id: input.id, sessionID: input.sessionID, type: 'user', payload: { text: input.text } }),
} = {}) {
  const dir = await mkdtemp('/tmp/c11-oc-v2-');
  const socketPath = `${dir}/mail.sock`;
  const claimLog = `${dir}/claim.log`;
  const c11Binary = `${dir}/c11`;
  await writeFile(c11Binary, '#!/bin/sh\nprintf "%s\\n" "$*" >> "${C11_CLI_LOG:-$C11_CLAIM_LOG}"\nif [ "$3" = "rpc" ] && [ "$4" = "conversation.claim" ]; then\n  count_file="$C11_TEST_CLAIM_COUNT_FILE"\n  count=$(cat "$count_file" 2>/dev/null || printf 0)\n  count=$((count + 1))\n  printf "%s\\n" "$count" > "$count_file"\n  if [ "$count" -le "${C11_TEST_CLAIM_FAILURES:-0}" ]; then exit 1; fi\nfi\nif [ "$3" = "agent-hook" ]; then\n  case "${C11_TEST_HOOK_FAIL_ONCE:-}" in\n    *,"$4",*)\n      marker="${C11_TEST_HOOK_FAILURE_MARKER:-}.$4"\n      if [ -n "$marker" ] && [ ! -e "$marker" ]; then : > "$marker"; exit 1; fi\n      ;;\n  esac\n  if [ "$4" = "${C11_TEST_HOOK_DELAY_ACTIVITY:-}" ]; then sleep 0.2; fi\nfi\nexit 0\n');
  await chmod(c11Binary, 0o755);
  const envBefore = { ...process.env };
  for (const key of Object.keys(process.env)) if (/^(C11_|CMUX_)/.test(key)) delete process.env[key];
  Object.assign(process.env, {
    C11_SOCKET_PATH: socketPath, C11_PANEL_ID: 'panel-a',
    C11_AGENT_INTERACTIVE_PID: String(process.pid), C11_AGENT_HOOK_CLI: c11Binary, C11_CLI_LOG: claimLog,
    ...(hookFailOnce.length ? {
      C11_TEST_HOOK_FAIL_ONCE: `,${hookFailOnce.join(',')},`,
      C11_TEST_HOOK_FAILURE_MARKER: `${dir}/hook-failure`,
    } : {}),
    ...(hookDelayActivity ? { C11_TEST_HOOK_DELAY_ACTIVITY: hookDelayActivity } : {}),
    ...(claimPending
      ? { C11_OPENCODE_TUI_CLAIM_FAILED: '1', C11_OPENCODE_EXPECTED_RESUME_ID: rootA,
        C11_CLAIM_LOG: claimLog, C11_TEST_CLAIM_FAILURES: String(claimFailures),
        C11_TEST_CLAIM_COUNT_FILE: `${dir}/claim-attempts` }
      : { C11_OPENCODE_TUI_CLAIMED: '1' }),
  });
  if (nativeMailDisabled) process.env.C11_OPENCODE_NATIVE_MAIL_DISABLED = '1';

  const sessions = new Map([
    ...(loadRoot ? [[rootA, { id: rootA, location: { directory: '/same/cwd' } }]] : []),
    [rootB, { id: rootB, location: { directory: '/same/cwd' } }],
    [child, { id: child, parentID: rootA, location: { directory: '/same/cwd' } }],
  ]);
  const statusBySession = new Map([[rootA, status], [rootB, 'idle'], [child, 'idle']]);
  const state = { route: { type: 'session', sessionID: rootA }, sessions, callbacks: [], lifecycleHandlers: [],
    calls: [], syncCalls: 0, conflictID: conflictID ?? '', statusBySession, unbindCalls: 0, activeCalls: 0,
    activeSessions: activeSessions ?? (status === 'running' ? { [rootA]: 'running' } : {}),
    permissionList: permissionHydrated ? [] : undefined, permissionSyncCalls: 0,
    formList: formHydrated ? [] : undefined, formSyncCalls: 0, pendingList: [],
    messageList, messageSyncCalls: 0 };
  state.activeSnapshotGate = holdActiveSnapshot
    ? new Promise(resolve => { state.releaseActiveSnapshot = resolve; })
    : Promise.resolve();
  state.emit = (type, sessionID, extra = {}) => {
    const event = { type, data: { sessionID, ...extra } };
    for (const item of [...state.lifecycleHandlers]) if (item.type === type) item.handler(event);
  };
  const sockets = new Set();
  const subscriptions = [];
  const frames = [];
  const server = createServer(socket => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
    let input = '';
    socket.on('data', chunk => {
      input += chunk.toString('utf8');
      let end;
      while ((end = input.indexOf('\n')) >= 0) {
        const frame = JSON.parse(input.slice(0, end)); input = input.slice(end + 1); frames.push(frame);
        if (frame.method === 'mailbox.native.subscribe') {
          subscriptions.push({ socket, frame });
          send(socket, { ok: true, result: { subscription_id: 'registered' } });
        } else if (frame.method === 'conversation.push') {
          const id = frame.params.id;
          const isUnbind = Boolean(frame.params.displayed_route_state);
          if (isUnbind) state.unbindCalls++;
          if (isUnbind && state.unbindCalls <= unbindFailureCount) {
            send(socket, { id: frame.id, ok: false, error: { code: 'not_ready', message: 'restore in progress' } });
            continue;
          }
          const result = frame.params.displayed_route_state
            ? { outcome: 'unbound', id: `wrapper-claim:${frame.params.panel_id}:unbound-route` }
            : id === state.conflictID
            ? { outcome: 'identity_conflict', id, owner_surface_ids: ['other'] }
            : { outcome: 'accepted', id };
          send(socket, { id: frame.id, ok: true, result });
        }
      }
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
  let dispose;
  t.after(async () => {
    dispose?.(); sockets.forEach(socket => socket.destroy());
    await new Promise(resolve => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
    for (const key of Object.keys(process.env)) if (/^(C11_|CMUX_)/.test(key)) delete process.env[key];
    Object.assign(process.env, envBefore);
  });
  const context = {
    ui: { router: { current: () => state.route } },
    data: {
      session: {
        get: id => state.sessions.get(id), sync: async id => {
          state.syncCalls++;
          if (state.syncCalls <= syncFailureCount) throw new Error('session_sync_failed');
          if (state.syncCalls >= hydrateAfterSync) state.sessions.set(id, { id, location: { directory: '/same/cwd' } });
        }, status: id => state.statusBySession.get(id) ?? 'idle',
        permission: { list: () => state.permissionList, sync: async () => {
          state.permissionSyncCalls++;
          state.permissionList = permissionSyncResult;
        } },
        pending: { list: () => state.pendingList },
        form: { list: () => state.formList, sync: async () => {
          state.formSyncCalls++;
          state.formList = formSyncResult;
        } },
        message: { list: () => state.messageList, sync: async () => { state.messageSyncCalls++; } },
        question: { list: () => [] },
      },
      on: (type, handler) => {
        const item = { type, handler };
        state.lifecycleHandlers.push(item);
        return () => { state.lifecycleHandlers = state.lifecycleHandlers.filter(candidate => candidate !== item); };
      },
      listen: callback => { state.callbacks.push(callback); return () => { state.callbacks = state.callbacks.filter(item => item !== callback); }; },
    },
    client: { session: {
      active: async () => {
        state.activeCalls++;
        await state.activeSnapshotGate;
        if (state.activeCalls <= activeFailureCount) throw new Error('active_snapshot_failed');
        return { ...state.activeSessions };
      },
      prompt: input => { state.calls.push(input); return Promise.resolve(promptResult(input)); },
    } },
  };
  const plugin = (await import(pathToFileURL(new URL('../skills/opencode-plugins/c11-opencode-v2/tui.js', import.meta.url).pathname))).default;
  dispose = await plugin.setup(context);
  return { state, subscriptions, frames, sockets, claimLog };
}

test('v2 TUI owns exact displayed root capture and confirms native mail from its admitted inbox item', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  await until(() => f.subscriptions.length === 1);
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootA));
  await until(() => f.subscriptions.length === 2);
  const capture = f.frames.find(frame => frame.method === 'conversation.push' && frame.params.id === rootA);
  assert.equal(capture.params.displayed_root, true);
  assert.equal(capture.params.displayed_route_generation, 1);
  assert.equal(capture.params.panel_id, 'panel-a');
  assert.equal(f.subscriptions.at(-1).frame.params.session_id.startsWith(`${rootA}:`), true);

  send(f.subscriptions.at(-1).socket, { type: 'deliver', delivery_id: 'mail-a', text: doorbellText });
  await until(() => f.state.calls.length === 1);
  assert.equal(f.state.calls[0].sessionID, rootA);
  assert.match(f.state.calls[0].id, /^msg_[0-9a-f]{32}$/);
  assert.equal(f.state.calls[0].text, doorbellText);
  await until(() => f.frames.some(frame => frame.type === 'accepted' && frame.delivery_id === 'mail-a'));
});

test('v2 keeps resumed running roots closed until the authoritative active snapshot arrives', { timeout: 5000 }, async t => {
  const f = await fixture(t, { status: 'idle', activeSessions: { [rootA]: 'running' }, holdActiveSnapshot: true });
  await until(() => f.subscriptions.length >= 2 && f.state.activeCalls === 1);
  const stream = f.subscriptions.at(-1);

  send(stream.socket, { type: 'deliver', delivery_id: 'resume-before-snapshot', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'resume-before-snapshot'));
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'resume-before-snapshot').reason, 'not_ready');
  assert.equal(f.state.calls.length, 0, 'mail cannot reach a resumed root while its activity is unknown');
  assert.equal((await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook idle'), false,
    'an unseen local status must not emit an idle report');

  f.state.releaseActiveSnapshot();
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook working'));
  send(stream.socket, { type: 'deliver', delivery_id: 'resume-still-running', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'resume-still-running'));
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'resume-still-running').reason, 'not_ready');
  assert.equal(f.state.calls.length, 0, 'confirmed running roots remain closed to native mail');
});

test('v2 treats an assistant retry scheduled in the hydrated transcript as busy', { timeout: 5000 }, async t => {
  const f = await fixture(t, {
    activeSessions: {},
    messageList: [{ type: 'assistant', retry: { attempt: 1, at: Date.now() + 1000 } }],
  });
  await until(() => f.subscriptions.length >= 2 && f.state.messageSyncCalls > 0);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook working'));
  send(f.subscriptions.at(-1).socket, { type: 'deliver', delivery_id: 'scheduled-retry', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'scheduled-retry'));
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'scheduled-retry').reason, 'not_ready');
  assert.equal(f.state.calls.length, 0, 'an idle active map cannot open a scheduled retry');
});

test('v2 keeps retries closed between schedule and terminal lifecycle events', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  await until(() => f.subscriptions.length >= 2 && f.state.messageSyncCalls > 0);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook idle'));

  f.state.emit('session.retry.scheduled', rootA);
  send(f.subscriptions.at(-1).socket, { type: 'deliver', delivery_id: 'retry-scheduled', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'retry-scheduled'));
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'retry-scheduled').reason, 'not_ready');
  assert.equal(f.state.calls.length, 0);

  f.state.emit('session.step.started', rootA);
  send(f.subscriptions.at(-1).socket, { type: 'deliver', delivery_id: 'retry-running', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'retry-running'));
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'retry-running').reason, 'not_ready');
  assert.equal(f.state.calls.length, 0);

  f.state.emit('session.execution.failed', rootA);
  await until(() => f.subscriptions.length >= 3);
  send(f.subscriptions.at(-1).socket, { type: 'deliver', delivery_id: 'retry-terminal', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'accepted' && frame.delivery_id === 'retry-terminal'));
  assert.equal(f.state.calls.length, 1, 'terminal completion clears retry state and reopens native mail');
});

test('v2 retries a failed active snapshot while holding mail and lifecycle idle closed', { timeout: 5000 }, async t => {
  const f = await fixture(t, { activeFailureCount: 1, activeSessions: {} });
  await until(() => f.subscriptions.length >= 2 && f.state.activeCalls === 1);
  const stream = f.subscriptions.at(-1);
  send(stream.socket, { type: 'deliver', delivery_id: 'snapshot-failed', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'snapshot-failed'));
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'snapshot-failed').reason, 'not_ready');
  assert.equal((await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook idle'), false,
    'a failed snapshot cannot be treated as proof of idle');

  await until(() => f.state.activeCalls >= 2, 2500);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook idle'));
  await until(() => f.subscriptions.length >= 3);
  send(f.subscriptions.at(-1).socket, { type: 'deliver', delivery_id: 'snapshot-recovered', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'accepted' && frame.delivery_id === 'snapshot-recovered'));
  assert.equal(f.state.calls.length, 1, 'mail resumes only after a successful snapshot confirms idle');
});

test('v2 synchronizes unhydrated permission and form state before admitting native mail', { timeout: 5000 }, async t => {
  const f = await fixture(t, {
    permissionHydrated: false, permissionSyncResult: [{ id: 'permission-a' }],
    formHydrated: false, formSyncResult: [{ id: 'form-a' }],
  });
  await until(() => f.subscriptions.length >= 2 && f.state.permissionSyncCalls > 0 && f.state.formSyncCalls > 0);
  const stream = f.subscriptions.at(-1);
  send(stream.socket, { type: 'deliver', delivery_id: 'unhydrated-readiness', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'unhydrated-readiness'));
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'unhydrated-readiness').reason, 'not_ready');
  assert.equal(f.state.calls.length, 0, 'pending permission or form state cannot admit the prompt');

  f.state.permissionList = [];
  f.state.formList = [];
  await until(() => f.subscriptions.length >= 3);
  send(f.subscriptions.at(-1).socket, { type: 'deliver', delivery_id: 'hydrated-readiness', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'accepted' && frame.delivery_id === 'hydrated-readiness'));
  assert.equal(f.state.calls.length, 1, 'mail resumes after both readiness lists are hydrated and clear');
});

test('v2 reconnect reconciles a shutdown root before reopening native mail', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  await until(() => f.subscriptions.length >= 2 && f.state.activeCalls === 1);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook idle'));
  f.state.emit('session.execution.interrupted', rootA, { reason: 'shutdown' });
  const shutdownStream = f.subscriptions.at(-1);
  send(shutdownStream.socket, { type: 'deliver', delivery_id: 'shutdown-not-ready', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'shutdown-not-ready'));
  assert.equal(f.state.calls.length, 0);

  f.state.emit('server.connected');
  await until(() => f.state.activeCalls >= 2);
  await until(() => f.subscriptions.length >= 3);
  send(f.subscriptions.at(-1).socket, { type: 'deliver', delivery_id: 'reconnected-idle', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'accepted' && frame.delivery_id === 'reconnected-idle'));
  assert.equal(f.state.calls.length, 1, 'a fresh idle snapshot clears shutdown suppression and reopens mail');
});

test('v2 reports only the bound displayed root execution lifecycle', { timeout: 5000 }, async t => {
  const f = await fixture(t, { status: 'unknown' });
  await until(() => f.subscriptions.length >= 2 && f.frames.some(frame =>
    frame.method === 'conversation.push' && frame.params.id === rootA && frame.params.displayed_root));
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook idle'));
  const initialLifecycleLog = await readFile(f.claimLog, 'utf8');

  f.state.emit('session.execution.started', rootB);
  await delay(30);
  assert.equal(await readFile(f.claimLog, 'utf8'), initialLifecycleLog,
    'another root in the shared server cannot change this panel lifecycle');

  f.state.statusBySession.set(rootA, 'running');
  f.state.emit('session.execution.started', rootA);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook working'));

  f.state.emit('session.execution.succeeded', rootB);
  await delay(30);
  assert.equal((await readFile(f.claimLog, 'utf8')).match(/agent-hook idle/g)?.length, 1,
    'a sibling session completion cannot release this panel');

  f.state.statusBySession.set(rootA, 'idle');
  f.state.emit('session.execution.failed', rootA);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook idle'));
  f.state.statusBySession.set(rootA, 'running');
  f.state.emit('session.execution.started', rootA);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).match(/agent-hook working/g)?.length >= 2);
  f.state.statusBySession.set(rootA, 'idle');
  f.state.emit('session.execution.interrupted', rootA, { reason: 'user_abort' });
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).match(/agent-hook idle/g)?.length >= 2);

  f.state.statusBySession.set(rootA, 'running');
  f.state.emit('session.execution.started', rootA);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).match(/agent-hook working/g)?.length >= 3);
  f.state.statusBySession.set(rootA, 'idle');
  f.state.emit('session.execution.interrupted', rootA, { reason: 'shutdown' });
  await delay(250);
  assert.equal((await readFile(f.claimLog, 'utf8')).match(/agent-hook idle/g)?.length, 3,
    'shutdown keeps the idle status monitor from emitting a prompt-ready edge');
  f.state.emit('session.execution.succeeded', rootA);
  await delay(250);
  assert.equal((await readFile(f.claimLog, 'utf8')).match(/agent-hook idle/g)?.length, 3,
    'a terminal event following shutdown remains suppressed for this route');
  const calls = (await readFile(f.claimLog, 'utf8')).trim().split('\n');
  assert.equal(calls.some(line => line.includes('--native-event')), false,
    'OpenCode lifecycle uses the panel-scoped activity bridge, not the Pi journal event');
});

test('v2 ignores lifecycle events from child and former displayed routes', { timeout: 5000 }, async t => {
  const f = await fixture(t, { status: 'unknown' });
  await until(() => f.subscriptions.length >= 2 && f.frames.some(frame =>
    frame.method === 'conversation.push' && frame.params.id === rootA && frame.params.displayed_root));
  f.state.route = { type: 'session', sessionID: rootB };
  await until(() => f.subscriptions.length >= 4 && f.frames.some(frame =>
    frame.method === 'conversation.push' && frame.params.id === rootB && frame.params.displayed_root));
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).match(/agent-hook idle/g)?.length >= 2);
  const boundRootLifecycleLog = await readFile(f.claimLog, 'utf8');

  f.state.emit('session.execution.succeeded', rootA);
  f.state.emit('session.execution.started', child);
  await delay(30);
  assert.equal(await readFile(f.claimLog, 'utf8'), boundRootLifecycleLog,
    'neither a former root nor a child session owns this panel lifecycle');

  f.state.statusBySession.set(rootB, 'running');
  f.state.emit('session.execution.started', rootB);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook working'));
});

test('v2 reports the newly bound root state and retries failed lifecycle reports in order', { timeout: 5000 }, async t => {
  const f = await fixture(t, { status: 'running', hookFailOnce: ['working', 'idle'], hookDelayActivity: 'working' });
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootA && frame.params.displayed_root));
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).match(/agent-hook working/g)?.length >= 2);

  f.state.statusBySession.set(rootA, 'idle');
  f.state.emit('session.execution.succeeded', rootA);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).match(/agent-hook idle/g)?.length >= 2);

  f.state.statusBySession.set(rootB, 'idle');
  f.state.route = { type: 'session', sessionID: rootB };
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' &&
    frame.params.id === rootB && frame.params.displayed_root));
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).match(/agent-hook idle/g)?.length >= 3);

  const activity = (await readFile(f.claimLog, 'utf8')).split('\n')
    .filter(line => line.includes('agent-hook ')).map(line => line.split('agent-hook ')[1].trim());
  assert.equal(activity.at(-1), 'idle', 'serialized retries leave c11 on the current bound root state');
});

test('v2 native mail is not acknowledged when session.prompt returns a different inbox item', { timeout: 5000 }, async t => {
  const f = await fixture(t, { promptResult: input => ({
    id: input.id, sessionID: rootB, type: 'user', payload: { text: input.text },
  }) });
  await until(() => f.subscriptions.length >= 2);
  const stream = f.subscriptions.at(-1);
  send(stream.socket, { type: 'deliver', delivery_id: 'wrong-session-mail', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'wrong-session-mail'));
  assert.equal(f.frames.some(frame => frame.type === 'accepted' && frame.delivery_id === 'wrong-session-mail'), false);
});

test('v2 retries a failed wrapper claim before capturing its displayed root', { timeout: 5000 }, async t => {
  const f = await fixture(t, { claimPending: true });
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.displayed_root));
  const lines = (await readFile(f.claimLog, 'utf8')).trim().split('\n');
  assert.equal(lines.length, 1, lines.join('\n'));
  assert.match(lines[0], /rpc conversation\.claim/);
  const payload = JSON.parse(lines[0].split('rpc conversation.claim ', 2)[1]);
  assert.equal(payload.panel_id, 'panel-a');
  assert.equal(payload.interactive_pid, process.pid);
  assert.equal(payload.expected_resume_id, rootA);
  const capture = f.frames.find(frame => frame.method === 'conversation.push' && frame.params.displayed_root);
  assert.equal(capture.params.id, rootA);
});

test('v2 keeps retrying the panel claim after its backoff reaches the cap', { timeout: 60000 }, async t => {
  const f = await fixture(t, { claimPending: true, claimFailures: 10 });
  await untilAsync(async () => {
    const lines = (await readFile(f.claimLog, 'utf8').catch(() => '')).split('\n');
    return lines.filter(line => line.includes('rpc conversation.claim')).length >= 10;
  }, 45000);
  assert.equal(f.frames.some(frame => frame.method === 'conversation.push' && frame.params.displayed_root), false,
    'no route capture is attempted while the authenticated TUI claim is failing');
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.displayed_root), 10000);
  const lines = (await readFile(f.claimLog, 'utf8')).trim().split('\n');
  assert.equal(lines.filter(line => line.includes('rpc conversation.claim')).length, 11, lines.join('\n'));
  const capture = f.frames.find(frame => frame.method === 'conversation.push' && frame.params.displayed_root);
  assert.equal(capture.params.id, rootA);
});

test('v2 route retries capture after session-sync failure and delayed hydration while holding mailbox mail', { timeout: 5000 }, async t => {
  const f = await fixture(t, { loadRoot: false, hydrateAfterSync: 2, syncFailureCount: 1 });
  await until(() => f.subscriptions.length === 1);
  send(f.subscriptions[0].socket, { type: 'deliver', delivery_id: 'early-mail', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'early-mail'));
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'early-mail').reason, 'session_conflict');
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootA));
  assert(f.state.syncCalls >= 2, `expected retry after hydration, got ${f.state.syncCalls} sync call(s)`);
  assert.equal(f.frames.filter(frame => frame.method === 'conversation.push' && frame.params.id === rootA && frame.params.displayed_root).length, 1);
});

test('v2 route ownership conflict rejects before prompting and names safe hold', { timeout: 5000 }, async t => {
  const f = await fixture(t, { conflictID: rootB });
  await until(() => f.subscriptions.length === 1);
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootA && frame.params.displayed_root));
  await until(() => f.subscriptions.length === 2);
  f.state.route = { type: 'session', sessionID: rootB };
  await until(() => f.subscriptions.length === 3);
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootB && frame.params.displayed_root));
  const latest = f.subscriptions.at(-1);
  send(latest.socket, { type: 'deliver', delivery_id: 'conflict-mail', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'conflict-mail'));
  assert.equal(f.state.calls.length, 0, 'a colliding panel ID never reaches OpenCode session.prompt');
  const rejection = f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'conflict-mail');
  assert.equal(rejection.reason, 'session_conflict');
});

test('v2 busy route rejects with not_ready and re-registers after the session becomes idle', { timeout: 5000 }, async t => {
  const f = await fixture(t, { status: 'running' });
  await until(() => f.subscriptions.length >= 2);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook working'));
  const busyStream = f.subscriptions.at(-1);
  send(busyStream.socket, { type: 'deliver', delivery_id: 'busy-mail', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'busy-mail'));
  assert.equal(f.state.calls.length, 0, 'busy mail cannot invoke OpenCode session.prompt');
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'busy-mail').reason, 'not_ready');

  f.state.statusBySession.set(rootA, 'idle');
  f.state.emit('session.execution.succeeded', rootA);
  await untilAsync(async () => (await readFile(f.claimLog, 'utf8').catch(() => '')).includes('agent-hook idle'));
  await until(() => f.subscriptions.length >= 3);
  const readyStream = f.subscriptions.at(-1);
  assert.notEqual(readyStream.frame.params.session_id, busyStream.frame.params.session_id,
    'ready transition creates a new registration to clear c11 fallback state');
  send(readyStream.socket, { type: 'deliver', delivery_id: 'ready-mail', text: doorbellText });
  await until(() => f.state.calls.length === 1);
  assert.equal(f.state.calls[0].sessionID, rootA);
});

test('v2 retries a route conflict until the displayed root becomes unowned', { timeout: 5000 }, async t => {
  const f = await fixture(t, { conflictID: rootB });
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootA && frame.params.displayed_root));
  await until(() => f.subscriptions.length === 2);
  f.state.route = { type: 'session', sessionID: rootB };
  await until(() => f.subscriptions.length === 3);
  await until(() => f.frames.filter(frame => frame.method === 'conversation.push' && frame.params.id === rootB && frame.params.displayed_root).length === 1);
  f.state.conflictID = '';
  await until(() => f.frames.filter(frame => frame.method === 'conversation.push' && frame.params.id === rootB && frame.params.displayed_root).length >= 2);
  await until(() => f.subscriptions.length === 4);
  const stream = f.subscriptions.at(-1);
  send(stream.socket, { type: 'deliver', delivery_id: 'after-release', text: doorbellText });
  await until(() => f.state.calls.length === 1);
  assert.equal(f.state.calls[0].sessionID, rootB);
});

test('v2 retries failed route unbinds and rejects mail until the new root binds', { timeout: 5000 }, async t => {
  const f = await fixture(t, { unbindFailureCount: 2 });
  await until(() => f.subscriptions.length >= 2);
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootA && frame.params.displayed_root));

  f.state.route = { type: 'session', sessionID: rootB };
  await until(() => f.subscriptions.length >= 3);
  const provisional = f.subscriptions.at(-1);
  send(provisional.socket, { type: 'deliver', delivery_id: 'route-pending-mail', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'route-pending-mail'));
  assert.equal(f.state.calls.length, 0, 'pending route mail cannot invoke OpenCode session.prompt');
  await until(() => f.state.unbindCalls >= 3);
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootB && frame.params.displayed_root));

  const attempts = f.frames.filter(frame => frame.method === 'conversation.push' && frame.params.displayed_route_state === 'pending');
  assert.equal(attempts.length, 3, 'failed unbind writes are retried until c11 acknowledges the route change');
  assert(attempts.every(frame => frame.params.displayed_route_generation === 2), 'retries retain the same route generation');
  const nextCapture = f.frames.find(frame => frame.method === 'conversation.push' && frame.params.id === rootB && frame.params.displayed_root);
  assert.equal(nextCapture.params.displayed_route_generation, 2, 'unbind and root capture share one generation');
  assert(f.frames.indexOf(attempts.at(-1)) < f.frames.findIndex(frame => frame.method === 'conversation.push' && frame.params.id === rootB && frame.params.displayed_root));
});

test('child session is never captured or opened as a mailbox recipient', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  await until(() => f.subscriptions.length === 1);
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootA && frame.params.displayed_root));
  await until(() => f.subscriptions.length === 2);
  f.state.route = { type: 'session', sessionID: child };
  await until(() => f.subscriptions.length === 3);
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === child &&
    frame.params.displayed_route_state === 'child'));
  assert(!f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === child && frame.params.displayed_root));
  const stream = f.subscriptions.at(-1);
  send(stream.socket, { type: 'deliver', delivery_id: 'child-mail', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'child-mail'));
  assert.equal(f.state.calls.length, 0);
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'child-mail').reason, 'session_conflict');
});

test('native mail disabled still captures the exact root and marks child routes unbound', { timeout: 5000 }, async t => {
  const f = await fixture(t, { nativeMailDisabled: true });
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootA && frame.params.displayed_root));
  assert.equal(f.subscriptions.length, 0);
  f.state.route = undefined;
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === rootA &&
    frame.params.displayed_route_state === 'no-route'));
  f.state.route = { type: 'session', sessionID: child };
  await until(() => f.frames.some(frame => frame.method === 'conversation.push' && frame.params.id === child &&
    frame.params.displayed_route_state === 'child'));
  assert.equal(f.subscriptions.length, 0);
  assert.equal(f.state.calls.length, 0);
});
