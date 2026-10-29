import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
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

async function fixture(t, {
  conflictID, loadRoot = true, hydrateAfterSync = Number.POSITIVE_INFINITY, syncFailureCount = 0,
  nativeMailDisabled = false, status = 'idle', unbindFailureCount = 0,
} = {}) {
  const dir = await mkdtemp('/tmp/c11-oc-v2-');
  const socketPath = `${dir}/mail.sock`;
  const c11Binary = process.execPath;
  const envBefore = { ...process.env };
  for (const key of Object.keys(process.env)) if (/^(C11_|CMUX_)/.test(key)) delete process.env[key];
  Object.assign(process.env, {
    C11_SOCKET_PATH: socketPath, C11_PANEL_ID: 'panel-a',
    C11_AGENT_INTERACTIVE_PID: String(process.pid), C11_AGENT_HOOK_CLI: c11Binary,
    C11_OPENCODE_TUI_CLAIMED: '1',
  });
  if (nativeMailDisabled) process.env.C11_OPENCODE_NATIVE_MAIL_DISABLED = '1';

  const sessions = new Map([
    ...(loadRoot ? [[rootA, { id: rootA, location: { directory: '/same/cwd' } }]] : []),
    [rootB, { id: rootB, location: { directory: '/same/cwd' } }],
    [child, { id: child, parentID: rootA, location: { directory: '/same/cwd' } }],
  ]);
  const state = { route: { type: 'session', sessionID: rootA }, sessions, callbacks: [], calls: [], syncCalls: 0,
    conflictID: conflictID ?? '', status, unbindCalls: 0 };
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
        }, status: () => state.status,
        permission: { list: () => [] }, question: { list: () => [] },
      },
      listen: callback => { state.callbacks.push(callback); return () => { state.callbacks = state.callbacks.filter(item => item !== callback); }; },
    },
    client: { session: { promptAsync: input => { state.calls.push(input); return Promise.resolve({}); } } },
  };
  const plugin = (await import(pathToFileURL(new URL('../skills/opencode-plugins/c11-opencode-v2/tui.js', import.meta.url).pathname))).default;
  dispose = await plugin.setup(context);
  return { state, subscriptions, frames, sockets };
}

test('v2 TUI owns exact displayed root capture and confirmed native mail', { timeout: 5000 }, async t => {
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
  const part = f.state.calls[0].parts[0];
  f.state.callbacks.forEach(callback => callback({ details: { type: 'message.part.updated', data: { part: { ...part, type: 'text', text: doorbellText, sessionID: rootA, messageID: 'msg-a' } } } }));
  f.state.callbacks.forEach(callback => callback({ details: { type: 'message.updated', data: { info: { id: 'msg-a', sessionID: rootA, role: 'user' } } } }));
  await until(() => f.frames.some(frame => frame.type === 'accepted' && frame.delivery_id === 'mail-a'));
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
  assert.equal(f.state.calls.length, 0, 'a colliding panel ID never reaches OpenCode promptAsync');
  const rejection = f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'conflict-mail');
  assert.equal(rejection.reason, 'session_conflict');
});

test('v2 busy route rejects with not_ready and re-registers after the session becomes idle', { timeout: 5000 }, async t => {
  const f = await fixture(t, { status: 'running' });
  await until(() => f.subscriptions.length >= 2);
  const busyStream = f.subscriptions.at(-1);
  send(busyStream.socket, { type: 'deliver', delivery_id: 'busy-mail', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'rejected' && frame.delivery_id === 'busy-mail'));
  assert.equal(f.state.calls.length, 0, 'busy mail cannot invoke promptAsync');
  assert.equal(f.frames.find(frame => frame.type === 'rejected' && frame.delivery_id === 'busy-mail').reason, 'not_ready');

  f.state.status = 'idle';
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
  assert.equal(f.state.calls.length, 0, 'pending route mail cannot invoke promptAsync');
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
