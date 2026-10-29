import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { createConnection } from 'node:net';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const transportCandidates = [
  process.env.C11_AGENT_HOOK_CLI && path.join(path.dirname(process.env.C11_AGENT_HOOK_CLI), 'mailbox-native.mjs'),
  fileURLToPath(new URL('../../../Resources/bin/mailbox-native.mjs', import.meta.url)),
  fileURLToPath(new URL('../../../bin/mailbox-native.mjs', import.meta.url)),
].filter(Boolean);
const transportPath = transportCandidates.find(existsSync);
if (!transportPath) throw new Error('c11 native mailbox transport is unavailable');
const { subscribeNativeMailbox, doorbellText } = await import(pathToFileURL(transportPath).href);

const sessionIDPattern = /^ses_[0-9A-Za-z]{26}$/;

function currentRoute(context) {
  try {
    const value = context.ui?.router?.current?.();
    if (value?.type === 'session' && typeof value.sessionID === 'string') return value.sessionID;
    if (value?.name === 'session' && typeof value.params?.sessionID === 'string') return value.params.sessionID;
  } catch {}
  return undefined;
}

function loadedSession(context, id) {
  if (!id || !sessionIDPattern.test(id)) return undefined;
  try {
    const session = context.data?.session?.get?.(id);
    return session?.id === id ? session : undefined;
  } catch { return undefined; }
}

function c11(socketPath, method, params, timeout = 900) {
  if (!socketPath) return Promise.resolve(undefined);
  return new Promise(resolve => {
    const requestID = randomUUID();
    const socket = createConnection(socketPath);
    socket.unref();
    let buffered = '';
    let settled = false;
    const finish = value => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(value);
    };
    const timer = setTimeout(() => finish(undefined), timeout);
    socket.setTimeout(timeout, () => finish(undefined));
    socket.on('connect', () => socket.write(JSON.stringify({
      id: requestID, method, params,
    }) + '\n'));
    socket.on('data', chunk => {
      buffered += chunk.toString('utf8');
      if (buffered.length > 65536) return finish(undefined);
      const end = buffered.indexOf('\n');
      if (end < 0) return;
      try {
        const frame = JSON.parse(buffered.slice(0, end));
        finish(frame.id === requestID && frame.ok === true ? frame.result : undefined);
      } catch { finish(undefined); }
    });
    socket.on('error', () => finish(undefined));
    socket.on('close', () => finish(undefined));
  });
}

function sessionList(value, id) {
  try {
    if (typeof value === 'function') return value(id) ?? [];
    if (typeof value?.list === 'function') return value.list(id) ?? [];
  } catch {}
  return [];
}

function sessionConflict() {
  const error = new Error('session_conflict');
  error.code = 'session_conflict';
  return error;
}

export default {
  id: 'com.stage11.c11.opencode-v2',
  async setup(context) {
    const panelID = process.env.C11_PANEL_ID || process.env.C11_TAB_ID || process.env.CMUX_SURFACE_ID;
    const agentPID = Number(process.env.C11_AGENT_INTERACTIVE_PID);
    const socketPath = process.env.C11_SOCKET_PATH || process.env.CMUX_SOCKET_PATH;
    const c11Bin = process.env.C11_AGENT_HOOK_CLI;
    if (!panelID || !socketPath || !c11Bin || agentPID !== process.pid ||
        process.env.C11_OPENCODE_NATIVE_MAIL_DISABLED === '1' ||
        process.env.C11_OPENCODE_TUI_CLAIMED !== '1' ||
        process.env.C11_OPENCODE_TUI_CLAIM_FAILED === '1' ||
        process.env.C11_OPENCODE_RESUME_RESERVATION_FAILED === '1' ||
        !context.ui?.router?.current || !context.data?.session?.get || !context.data?.listen) return;

    let disposed = false;
    let generation = 0;
    let visibleID;
    let boundID;
    let conflict = false;
    let captureState = 'no-route';
    let retryCaptureAt = 0;
    let stopMailbox;
    const pending = new Map();
    const userMessages = new Map();

    const clearPending = () => {
      stopMailbox?.();
      stopMailbox = undefined;
      for (const item of pending.values()) {
        clearTimeout(item.timer);
        item.reject?.(new Error('route_changed'));
      }
      pending.clear();
      userMessages.clear();
    };

    const register = (sessionID, routeGeneration) => {
      if (!sessionID || disposed) return;
      const streamID = `${sessionID}:${routeGeneration}`.slice(0, 256);
      stopMailbox = subscribeNativeMailbox({
        socketPath, panelID, agentPID, sessionID: streamID, route: 'opencode_plugin', canQueue: false,
        deliver(message) {
          if (disposed || generation !== routeGeneration || currentRoute(context) !== visibleID ||
              message !== doorbellText || conflict || !boundID || boundID !== visibleID) throw sessionConflict();
          const status = context.data.session.status?.(boundID);
          if (status === 'running' || status === 'busy' || status?.type === 'running' || status?.type === 'retry' ||
              sessionList(context.data.session.permission, boundID).length ||
              sessionList(context.data.session.pending, boundID).length ||
              sessionList(context.data.session.form, boundID).length) throw new Error('not_ready');
          return new Promise((resolve, reject) => {
            const partID = `prt_${randomUUID().replaceAll('-', '')}`;
            const item = { sessionID: boundID, partID, resolve, reject };
            item.timer = setTimeout(() => { pending.delete(partID); reject(new Error('unconfirmed')); }, 10000);
            item.timer.unref?.();
            pending.set(partID, item);
            try {
              Promise.resolve(context.client.session.promptAsync({
                sessionID: boundID,
                parts: [{ id: partID, type: 'text', text: message }],
              })).catch(() => {});
            } catch { /* an invocation is not delivery confirmation */ }
          });
        },
      });
    };

    const capture = async () => {
      if (disposed) return;
      const candidateID = currentRoute(context);
      if (candidateID !== visibleID) {
        const nextGeneration = ++generation;
        clearPending();
        visibleID = candidateID;
        boundID = undefined;
        conflict = Boolean(candidateID);
        captureState = candidateID ? 'waiting' : 'no-route';
        retryCaptureAt = 0;
        if (candidateID) {
          // Establish an unsafe provisional native route before waiting for TUI
          // hydration or the c11 ownership check. It rejects with a named
          // conflict so mail is held until this displayed route is verified.
          register(candidateID, nextGeneration);
        }
      }
      if (!candidateID || captureState === 'bound' ||
          captureState === 'child' || captureState === 'capturing' || Date.now() < retryCaptureAt) return;
      const routeGeneration = generation;
      captureState = 'capturing';

      let session = loadedSession(context, candidateID);
      if (!session) {
        try { await context.data.session.sync?.(candidateID); } catch {}
        session = loadedSession(context, candidateID);
      }
      if (disposed || generation !== routeGeneration || currentRoute(context) !== candidateID) return;
      if (!session) {
        captureState = 'waiting';
        retryCaptureAt = Date.now() + 500;
        return;
      }
      if (session.parentID) {
        captureState = 'child'; // Child views have no root composer or identity.
        conflict = true;
        return;
      }

      const cwd = session.location?.directory || session.directory;
      const result = await c11(socketPath, 'conversation.push', {
        panel_id: panelID,
        kind: 'opencode',
        id: candidateID,
        source: 'hook',
        displayed_root: true,
        ...(cwd ? { cwd } : {}),
      });
      if (disposed || generation !== routeGeneration || currentRoute(context) !== candidateID) return;
      if (result?.outcome === 'accepted' && result.id === candidateID) {
        boundID = candidateID;
        conflict = false;
        captureState = 'bound';
      } else if (result?.outcome === 'identity_conflict') {
        conflict = true;
        captureState = 'identity-conflict';
        retryCaptureAt = Date.now() + 500;
      } else {
        captureState = 'waiting';
        retryCaptureAt = Date.now() + 500;
      }
    };

    const confirm = event => {
      const detail = event?.details ?? event;
      const properties = detail?.properties ?? detail?.data ?? detail ?? {};
      if (detail?.type === 'message.updated' || detail?.type === 'message.created') {
        const info = properties.info ?? properties.message ?? properties;
        if (info?.role === 'user' && typeof info.id === 'string') {
          userMessages.set(info.id, info.sessionID);
          if (userMessages.size > 64) userMessages.delete(userMessages.keys().next().value);
          for (const [id, item] of pending) if (item.messageID && userMessages.get(item.messageID) === item.sessionID) {
            clearTimeout(item.timer); pending.delete(id); item.resolve();
          }
        }
      }
      if (detail?.type === 'message.part.updated' || detail?.type === 'message.part.created') {
        const part = properties.part ?? properties;
        const item = pending.get(part?.id);
        if (!item || part.type !== 'text' || part.text !== doorbellText || part.sessionID !== item.sessionID) return;
        item.messageID = part.messageID;
        if (userMessages.get(item.messageID) === item.sessionID) {
          clearTimeout(item.timer); pending.delete(item.partID); item.resolve();
        }
      }
    };
    let removeEvent;
    try { removeEvent = context.data.listen(confirm); } catch { return; }

    const monitor = setInterval(() => { void capture(); }, 100);
    monitor.unref?.();
    await capture();
    return () => {
      disposed = true;
      generation++;
      clearInterval(monitor);
      clearPending();
      try { removeEvent?.(); } catch {}
    };
  },
};
