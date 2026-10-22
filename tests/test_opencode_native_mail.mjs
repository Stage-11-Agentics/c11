import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, mkdir, copyFile, rm } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import { test } from 'node:test';
import { doorbellText } from '../Resources/bin/mailbox-native.mjs';

const send = (socket, frame) => socket.write(JSON.stringify(frame) + '\n');
async function until(probe) {
  const end = Date.now() + 2000;
  while (!probe()) { assert(Date.now() < end, 'native event timed out'); await delay(10); }
}

// Real bundled plugin and Unix transport, with a controlled OpenCode TUI API.
// The real-TUI acceptance script separately validates the upstream boundary.
async function fixture(t, options = {}) {
  const root = await mkdtemp('/tmp/c11-oc-');
  await mkdir(root + '/skills/opencode-plugins', { recursive: true });
  await mkdir(root + '/bin');
  await copyFile(new URL('../skills/opencode-plugins/c11-mailbox.mjs', import.meta.url), root + '/skills/opencode-plugins/c11-mailbox.mjs');
  await copyFile(new URL('../Resources/bin/mailbox-native.mjs', import.meta.url), root + '/bin/mailbox-native.mjs');
  const env = { ...process.env };
  for (const key of Object.keys(process.env)) if (/^(C11_|CMUX_)/.test(key)) delete process.env[key];
  Object.assign(process.env, { C11_SOCKET_PATH: root + '/mail.sock', C11_PANEL_ID: 'fixture-panel',
    C11_AGENT_INTERACTIVE_PID: String(process.pid), ...options.env });
  const sockets = new Set(), subscriptions = [], frames = [], calls = [], disposers = [], handlers = new Map();
  const state = { route: { name: 'session', params: { sessionID: 'session-a' } }, status: 'idle', permission: [], question: [] };
  const server = createServer(socket => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
    let input = '';
    socket.on('data', chunk => {
      input += chunk;
      let end;
      while ((end = input.indexOf('\n')) >= 0) {
        const frame = JSON.parse(input.slice(0, end)); input = input.slice(end + 1);
        frames.push(frame);
        if (frame.method === 'mailbox.native.subscribe') {
          subscriptions.push({ socket, frame });
          send(socket, { ok: true, result: { subscription_id: 'fixture' } });
        }
      }
    });
  });
  await new Promise(resolve => server.listen(root + '/mail.sock', resolve));
  t.after(async () => {
    disposers.forEach(fn => fn());
    sockets.forEach(socket => socket.destroy());
    await new Promise(resolve => server.close(resolve));
    await rm(root, { recursive: true, force: true });
    for (const key of Object.keys(process.env)) if (/^(C11_|CMUX_)/.test(key)) delete process.env[key];
    Object.assign(process.env, env);
  });
  const api = {
    route: { get current() { return state.route; } },
    state: { session: { status: () => ({ type: state.status }), permission: () => state.permission, question: () => state.question } },
    get ui() { assert.fail('mail must never read or edit the composer'); },
    client: { session: { promptAsync(input) { calls.push(input); return options.prompt?.(input) ?? Promise.resolve({ response: { status: 204 } }); } } },
    event: { on(type, fn) { handlers.set(type, fn); return () => handlers.delete(type); } },
    lifecycle: { onDispose(fn) { disposers.push(fn); } },
  };
  const plugin = (await import(pathToFileURL(root + '/skills/opencode-plugins/c11-mailbox.mjs'))).default;
  await plugin.tui(api);
  const emit = (type, properties) => handlers.get(type)?.({ type, properties });
  const part = (call, messageID = 'accepted-message') => ({ ...call.parts[0], sessionID: call.sessionID, messageID });
  const user = (call, messageID = 'accepted-message') => ({ id: messageID, sessionID: call.sessionID, role: 'user' });
  const accept = call => {
    emit('message.updated', { info: user(call) });
    emit('message.part.updated', { part: part(call) });
  };
  const deliver = id => send(subscriptions.at(-1).socket, { type: 'deliver', delivery_id: id, text: doorbellText });
  const reply = id => frames.find(frame => frame.delivery_id === id);
  return { subscriptions, frames, sockets, calls, state, emit, part, user, accept, deliver, reply, dispose: () => disposers.forEach(fn => fn()) };
}

test('accepts only a correlated text part and user message, in either event order', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  await until(() => f.subscriptions.length === 1);
  assert.equal(f.subscriptions[0].frame.params.route, 'opencode_plugin');
  assert.equal(f.subscriptions[0].frame.params.can_queue, false);
  f.deliver('first');
  await until(() => f.calls.length === 1);
  const call = f.calls[0];
  assert.equal(call.messageID, undefined, 'OpenCode allocates ordered message IDs');
  assert.equal(call.parts[0].text, doorbellText);
  await delay(40);
  assert.equal(f.reply('first'), undefined, '204 is not acceptance');
  f.emit('message.part.updated', { part: { ...f.part(call), sessionID: 'wrong-session' } });
  f.emit('message.updated', { info: f.user(call) });
  await delay(40);
  assert.equal(f.reply('first'), undefined, 'other-session part is not acceptance');
  f.emit('message.part.updated', { part: f.part(call) });
  await until(() => f.reply('first'));
  assert.equal(f.reply('first').type, 'accepted');

  f.deliver('reverse');
  await until(() => f.calls.length === 2);
  const second = f.calls[1];
  f.emit('message.part.updated', { part: f.part(second, 'message-two') });
  f.emit('message.updated', { info: { ...f.user(second, 'message-two'), role: 'assistant' } });
  await delay(40);
  assert.equal(f.reply('reverse'), undefined, 'assistant event is not acceptance');
  f.emit('message.updated', { info: f.user(second, 'message-two') });
  await until(() => f.reply('reverse'));
  assert.equal(f.reply('reverse').type, 'accepted');
});

test('busy, retry, permission and question states reject before invoking OpenCode', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  await until(() => f.subscriptions.length === 1);
  for (const guard of [{ status: 'busy' }, { status: 'retry' }, { permission: [{}] }, { question: [{}] }]) {
    Object.assign(f.state, { status: 'idle', permission: [], question: [] }, guard);
    const id = JSON.stringify(guard);
    f.deliver(id);
    await until(() => f.reply(id));
    assert.equal(f.reply(id).type, 'rejected');
    assert.equal(f.calls.length, 0);
  }
});

test('home retires, new and resumed sessions rebind, and exit stops reconnects', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  await until(() => f.subscriptions.length === 1);
  const first = f.subscriptions[0];
  f.state.route = { name: 'home' };
  f.deliver('stale-before-monitor');
  await until(() => f.reply('stale-before-monitor') || f.sockets.size === 0);
  assert.equal(f.calls.length, 0, 'live route check must win between monitor ticks');
  await until(() => f.sockets.size === 0);
  f.state.route = { name: 'session', params: { sessionID: 'session-b' } };
  await until(() => f.subscriptions.length === 2);
  assert.notEqual(first.frame.params.session_id, f.subscriptions[1].frame.params.session_id);
  f.deliver('new');
  await until(() => f.calls.length === 1);
  assert.equal(f.calls[0].sessionID, 'session-b');
  f.accept(f.calls[0]);
  await until(() => f.reply('new'));
  f.state.route = { name: 'session', params: { sessionID: 'session-a' } };
  await until(() => f.subscriptions.length === 3);
  assert.notEqual(first.frame.params.session_id, f.subscriptions[2].frame.params.session_id);
  f.deliver('resume');
  await until(() => f.calls.length === 2);
  assert.equal(f.calls[1].sessionID, 'session-a');
  f.accept(f.calls[1]);
  await until(() => f.reply('resume'));
  f.dispose();
  await until(() => f.sockets.size === 0);
  await delay(600);
  assert.equal(f.subscriptions.length, 3);
});

test('an API error after invocation leaves acknowledgement to real events or timeout', { timeout: 5000 }, async t => {
  const f = await fixture(t, { prompt: () => Promise.reject(new Error('uncertain response')) });
  await until(() => f.subscriptions.length === 1);
  f.deliver('ambiguous');
  await until(() => f.calls.length === 1);
  await delay(100);
  assert.equal(f.reply('ambiguous'), undefined, 'must not assert definite non-delivery');
  f.accept(f.calls[0]);
  await until(() => f.reply('ambiguous'));
  assert.equal(f.reply('ambiguous').type, 'accepted');
});

test('native opt-out and inherited interactive PID never register', { timeout: 5000 }, async t => {
  for (const env of [{ C11_OPENCODE_NATIVE_MAIL_DISABLED: '1' }, { C11_AGENT_INTERACTIVE_PID: '1' }]) {
    await t.test(JSON.stringify(env), async t => {
      const f = await fixture(t, { env });
      await delay(300);
      assert.equal(f.subscriptions.length, 0);
    });
  }
});
