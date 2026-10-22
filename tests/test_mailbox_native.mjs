import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { test } from 'node:test';
import { subscribeNativeMailbox, doorbellText } from '../Resources/bin/mailbox-native.mjs';

// Real Unix-socket traffic and reconnect timers, with no harness or credentials.
async function fixture(t, receive) {
  const root = await mkdtemp('/tmp/c11-native-test-');
  const socketPath = root + '/mail.sock';
  const sockets = new Set();
  const subscriptions = [];
  const frames = [];
  const stops = [];
  const server = createServer(socket => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
    let input = '';
    socket.on('data', chunk => {
      input += chunk.toString('utf8');
      let end;
      while ((end = input.indexOf('\n')) >= 0) {
        const frame = JSON.parse(input.slice(0, end));
        input = input.slice(end + 1);
        frames.push(frame);
        if (frame.method === 'mailbox.native.subscribe') subscriptions.push({ socket, frame });
        receive(socket, frame, subscriptions);
      }
    });
  });
  t.after(async () => {
    stops.forEach(stop => stop());
    sockets.forEach(socket => socket.destroy());
    await new Promise(resolve => server.close(resolve));
    await rm(root, { recursive: true, force: true });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
  const subscribe = (sessionID, deliver = () => {}) => {
    const stop = subscribeNativeMailbox({ socketPath, panelID: 'same-panel', agentPID: process.pid,
      sessionID, route: 'pi_extension', deliver });
    stops.push(stop);
    return stop;
  };
  return { subscribe, subscriptions, frames };
}

const send = (socket, frame) => socket.write(JSON.stringify(frame) + '\n');
const accept = socket => send(socket, { ok: true, result: { subscription_id: 'subscription' } });
async function until(predicate) {
  const deadline = Date.now() + 2000;
  while (!predicate()) {
    assert(Date.now() < deadline, 'socket event timed out');
    await delay(10);
  }
}

test('explicit subscribe rejection stops reconnecting', { timeout: 5000 }, async t => {
  const f = await fixture(t, (socket, frame) => {
    if (frame.method === 'mailbox.native.subscribe') {
      socket.end(JSON.stringify({ ok: false, error: { code: 'invalid_params' } }) + '\n');
    }
  });
  f.subscribe('rejected', () => assert.fail('rejected listener delivered'));
  await until(() => f.subscriptions.length === 1);
  await delay(800); // Cross the first and second reconnect deadlines.
  assert.equal(f.subscriptions.length, 1);
});

test('not_ready retries after session restore and later delivers', { timeout: 5000 }, async t => {
  const delivered = [];
  const f = await fixture(t, (socket, frame, subscriptions) => {
    if (frame.method !== 'mailbox.native.subscribe') return;
    if (subscriptions.length === 1) {
      send(socket, { ok: false, error: { code: 'not_ready' } });
      return;
    }
    accept(socket);
    send(socket, { type: 'deliver', delivery_id: 'after-restore', text: doorbellText });
  });
  f.subscribe('restoring', text => delivered.push(text));
  await until(() => f.frames.some(frame => frame.type === 'accepted' && frame.delivery_id === 'after-restore'));
  assert.equal(f.subscriptions.length, 2);
  assert.deepEqual(delivered, [doorbellText]);
});

test('replacement retires the old consumer without a reconnect contest', { timeout: 5000 }, async t => {
  let active;
  let oldDeliveries = 0;
  const delivered = [];
  const f = await fixture(t, (socket, frame) => {
    if (frame.method !== 'mailbox.native.subscribe') return;
    if (active) {
      // Include queued work after retirement in the same read batch.
      active.end(JSON.stringify({ type: 'replaced' }) + '\n' +
        JSON.stringify({ type: 'deliver', delivery_id: 'stale', text: doorbellText }) + '\n');
    }
    active = socket;
    accept(socket);
  });
  f.subscribe('old', () => { oldDeliveries++; });
  await until(() => f.subscriptions.length === 1);
  f.subscribe('new', text => delivered.push(text));
  await until(() => f.subscriptions.length === 2);
  await delay(800);
  assert.equal(f.subscriptions.length, 2, 'retired listener must not evict its replacement');
  assert.equal(oldDeliveries, 0);
  send(active, { type: 'deliver', delivery_id: 'current', text: doorbellText });
  await until(() => f.frames.some(frame => frame.type === 'accepted' && frame.delivery_id === 'current'));
  assert.deepEqual(delivered, [doorbellText]);
});

test('unexpected close still reconnects and delivers', { timeout: 5000 }, async t => {
  const delivered = [];
  const f = await fixture(t, (socket, frame, subscriptions) => {
    if (frame.method !== 'mailbox.native.subscribe') return;
    accept(socket);
    if (subscriptions.length === 1) socket.end();
    else send(socket, { type: 'deliver', delivery_id: 'after-close', text: doorbellText });
  });
  const stop = f.subscribe('reconnecting', text => delivered.push(text));
  await until(() => f.frames.some(frame => frame.type === 'accepted'));
  assert.equal(f.subscriptions.length, 2);
  assert.deepEqual(delivered, [doorbellText]);
  stop();
  await delay(350);
  assert.equal(f.subscriptions.length, 2);
});
