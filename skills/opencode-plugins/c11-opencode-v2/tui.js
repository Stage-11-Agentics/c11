import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createConnection } from 'node:net';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

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

async function claimTui(c11Bin, socketPath, panelID, agentPID) {
  const payload = {
    panel_id: panelID,
    kind: 'opencode',
    cwd: process.cwd(),
    placeholder_id: `wrapper-claim:${panelID}`,
    interactive_pid: agentPID,
    expires_at_epoch_ms: Date.now() + 120_000,
  };
  const expectedResumeID = process.env.C11_OPENCODE_EXPECTED_RESUME_ID;
  if (expectedResumeID) payload.expected_resume_id = expectedResumeID;
  for (const [environment, parameter] of [
    ['HOME', 'recovery_home'],
    ['XDG_DATA_HOME', 'recovery_xdg_data_home'],
    ['OPENCODE_DB', 'recovery_database_override'],
  ]) {
    if (Object.hasOwn(process.env, environment)) payload[parameter] = process.env[environment];
  }
  try {
    await execFileAsync(c11Bin, [
      '--socket', socketPath, 'rpc', 'conversation.claim', JSON.stringify(payload),
    ], { timeout: 1_000, maxBuffer: 64 * 1024 });
    return true;
  } catch { return false; }
}

function sessionList(value, id) {
  try {
    const result = typeof value === 'function' ? value(id) : value?.list?.(id);
    return Array.isArray(result) ? result : undefined;
  } catch { return undefined; }
}

function sessionConflict() {
  const error = new Error('session_conflict');
  error.code = 'session_conflict';
  return error;
}

function sessionNotReady() {
  const error = new Error('not_ready');
  error.code = 'not_ready';
  return error;
}

function sessionReadyForMailbox(context, id) {
  if (!id) return false;
  try {
    const status = context.data.session.status?.(id);
    const permissions = sessionList(context.data.session.permission, id);
    const pending = sessionList(context.data.session.pending, id);
    const forms = sessionList(context.data.session.form, id);
    if (!permissions || !pending || !forms) return false;
    return status !== 'running' && status !== 'busy' && status?.type !== 'running' && status?.type !== 'retry' &&
      !permissions.length && !pending.length && !forms.length;
  } catch { return false; }
}

function reportLifecycle(c11Bin, socketPath, activity) {
  if (!c11Bin || !socketPath) return Promise.resolve(false);
  return execFileAsync(c11Bin, ["--socket", socketPath, "agent-hook", activity], {
    timeout: 750,
    maxBuffer: 64 * 1024,
  }).then(() => true, () => false);
}

export default {
  id: 'com.stage11.c11.opencode-v2',
  async setup(context) {
    const panelID = process.env.C11_PANEL_ID || process.env.C11_TAB_ID || process.env.CMUX_SURFACE_ID;
    const agentPID = Number(process.env.C11_AGENT_INTERACTIVE_PID);
    const socketPath = process.env.C11_SOCKET_PATH || process.env.CMUX_SOCKET_PATH;
    const c11Bin = process.env.C11_AGENT_HOOK_CLI;
    const nativeMailDisabled = process.env.C11_OPENCODE_NATIVE_MAIL_DISABLED === '1';
    if (!panelID || !socketPath || !c11Bin || agentPID !== process.pid ||
        !context.ui?.router?.current || !context.data?.session?.get) return;

    let disposed = false;
    let tuiClaimed = process.env.C11_OPENCODE_TUI_CLAIMED === '1';
    let claimAttempts = 0;
    let nextClaimAt = 0;
    let claimWarningLogged = false;
    let generation = 0;
    let visibleID;
    let boundID;
    let conflict = false;
    let captureState = 'no-route';
    let retryCaptureAt = 0;
    let pendingUnbind;
    let mailboxHandoff;
    let retryUnbindAt = 0;
    let hasObservedRoute = false;
    let stopMailbox;
    let mailboxRevision = 0;
    let nativeNotReady = false;
    let reportedLifecycle;
    let desiredLifecycle;
    let lifecycleInFlight = false;
    let lifecycleRetryAt = 0;
    let shutdownSessionID;
    let boundStatusConfirmed = false;
    let boundStatus;
    let retryScheduled = false;
    let statusCheckInFlight = false;
    let statusCheckRetryAt = 0;
    let lifecycleSignalRevision = 0;
    let readinessSyncInFlight = false;
    let readinessSyncRetryAt = 0;
    const pending = new Map();
    const unsettledMailboxDeliveries = new Set();
    const admittedMailboxAttempts = new Map();

    const refreshBoundSessionStatus = async (sessionID, routeGeneration) => {
      if (disposed || !sessionID || sessionID !== boundID || sessionID !== visibleID ||
          currentRoute(context) !== sessionID || conflict || captureState !== 'bound' ||
          sessionID === shutdownSessionID || boundStatusConfirmed || statusCheckInFlight ||
          Date.now() < statusCheckRetryAt) return;
      const signalRevision = lifecycleSignalRevision;
      statusCheckInFlight = true;
      try {
        const messageSource = context.data.session.message;
        if (typeof messageSource?.sync !== 'function') throw new Error('session_messages_unavailable');
        const [active] = await Promise.all([
          context.client.session.active(),
          messageSource.sync(sessionID),
        ]);
        if (!active || typeof active !== 'object' || Array.isArray(active)) throw new Error('invalid_active_sessions');
        const messages = sessionList(messageSource, sessionID);
        if (!messages) throw new Error('invalid_session_messages');
        if (disposed || generation !== routeGeneration || lifecycleSignalRevision !== signalRevision ||
            boundID !== sessionID || visibleID !== sessionID || currentRoute(context) !== sessionID ||
            conflict || captureState !== 'bound' || sessionID === shutdownSessionID) return;
        retryScheduled = messages.some(message => message?.type === 'assistant' && Boolean(message.retry));
        boundStatusConfirmed = true;
        statusCheckRetryAt = 0;
        boundStatus = retryScheduled || Object.hasOwn(active, sessionID) ? 'running' : 'idle';
        reportRootLifecycle(sessionID, boundStatus === 'running' ? 'working' : 'idle');
      } catch {
        if (!disposed && generation === routeGeneration && boundID === sessionID &&
            visibleID === sessionID && currentRoute(context) === sessionID && !boundStatusConfirmed) {
          // `data.session.status()` defaults unseen IDs to idle while its active
          // map hydrates. Keep mail and idle reports closed until a real snapshot
          // arrives; retry transient client/API failures from the route monitor.
          statusCheckRetryAt = Date.now() + 500;
        }
      } finally {
        statusCheckInFlight = false;
      }
    };

    const refreshSessionReadiness = async (sessionID, routeGeneration) => {
      if (disposed || !sessionID || sessionID !== boundID || sessionID !== visibleID ||
          currentRoute(context) !== sessionID || conflict || captureState !== 'bound' ||
          !boundStatusConfirmed || boundStatus !== 'idle' || sessionID === shutdownSessionID ||
          readinessSyncInFlight || Date.now() < readinessSyncRetryAt) return;
      const sources = [context.data.session.permission, context.data.session.pending, context.data.session.form];
      const unhydrated = sources.filter(source => !sessionList(source, sessionID));
      if (!unhydrated.length) return;
      readinessSyncInFlight = true;
      try {
        const results = await Promise.allSettled(unhydrated.map(source => Promise.resolve().then(() => {
          if (typeof source?.sync !== 'function') throw new Error('session_readiness_sync_unavailable');
          return source.sync(sessionID);
        })));
        if (disposed || generation !== routeGeneration || boundID !== sessionID ||
            visibleID !== sessionID || currentRoute(context) !== sessionID) return;
        const stillUnhydrated = sources.some(source => !sessionList(source, sessionID));
        readinessSyncRetryAt = results.some(result => result.status === 'rejected') || stillUnhydrated
          ? Date.now() + 500
          : 0;
      } finally {
        readinessSyncInFlight = false;
      }
    };

    const flushRootLifecycle = () => {
      const sessionID = boundID;
      const activity = desiredLifecycle;
      const routeGeneration = generation;
      if (disposed || !sessionID || sessionID !== visibleID || currentRoute(context) !== sessionID ||
          conflict || captureState !== 'bound' || !activity || activity === reportedLifecycle ||
          !boundStatusConfirmed ||
          (sessionID === shutdownSessionID && activity === 'idle') ||
          lifecycleInFlight || Date.now() < lifecycleRetryAt) return;
      lifecycleInFlight = true;
      void reportLifecycle(c11Bin, socketPath, activity).then(succeeded => {
        lifecycleInFlight = false;
        if (disposed) return;
        if (succeeded && generation === routeGeneration && boundID === sessionID &&
            visibleID === sessionID && currentRoute(context) === sessionID && captureState === 'bound' &&
            !(sessionID === shutdownSessionID && activity === 'idle')) {
          reportedLifecycle = activity;
          lifecycleRetryAt = 0;
        } else if (!succeeded && generation === routeGeneration && boundID === sessionID &&
            visibleID === sessionID && currentRoute(context) === sessionID && captureState === 'bound') {
          // Keep the desired edge unacknowledged. The route monitor retries it
          // after a short backoff instead of latching a failed best-effort call.
          lifecycleRetryAt = Date.now() + 500;
        }
        if (generation !== routeGeneration || desiredLifecycle !== reportedLifecycle) flushRootLifecycle();
      });
    };

    const reportRootLifecycle = (sessionID, activity) => {
      if (disposed || !sessionID || sessionID !== boundID || sessionID !== visibleID ||
          currentRoute(context) !== sessionID || conflict || captureState !== 'bound' ||
          !boundStatusConfirmed ||
          (sessionID === shutdownSessionID && activity === 'idle')) return;
      desiredLifecycle = activity;
      flushRootLifecycle();
    };

    const stopLifecycle = [];
    const onSessionEvent = (type, handler) => {
      const stop = context.data.on?.(type, handler);
      if (typeof stop === 'function') stopLifecycle.push(stop);
    };
    onSessionEvent('session.execution.started', event => {
      if (event?.data?.sessionID === boundID) {
        shutdownSessionID = undefined;
        retryScheduled = false;
        boundStatusConfirmed = true;
        boundStatus = 'running';
        statusCheckRetryAt = 0;
        lifecycleSignalRevision++;
      }
      reportRootLifecycle(event?.data?.sessionID, 'working');
    });
    onSessionEvent('session.retry.scheduled', event => {
      if (event?.data?.sessionID !== boundID) return;
      retryScheduled = true;
      boundStatusConfirmed = true;
      boundStatus = 'running';
      statusCheckRetryAt = 0;
      lifecycleSignalRevision++;
      reportRootLifecycle(event.data.sessionID, 'working');
    });
    onSessionEvent('session.step.started', event => {
      if (event?.data?.sessionID !== boundID) return;
      retryScheduled = false;
      boundStatusConfirmed = true;
      boundStatus = 'running';
      statusCheckRetryAt = 0;
      lifecycleSignalRevision++;
      reportRootLifecycle(event.data.sessionID, 'working');
    });
    for (const type of ['session.execution.succeeded', 'session.execution.failed', 'session.execution.interrupted']) {
      onSessionEvent(type, event => {
        if (type === 'session.execution.interrupted' && event?.data?.reason === 'shutdown') {
          if (event?.data?.sessionID === boundID) {
            shutdownSessionID = boundID;
            retryScheduled = false;
            boundStatusConfirmed = false;
            boundStatus = undefined;
            statusCheckRetryAt = 0;
            lifecycleSignalRevision++;
          }
          return;
        }
        if (event?.data?.sessionID === boundID) {
          if (shutdownSessionID === boundID) return;
          retryScheduled = false;
          boundStatusConfirmed = true;
          boundStatus = 'idle';
          statusCheckRetryAt = 0;
          readinessSyncRetryAt = 0;
          lifecycleSignalRevision++;
        }
        reportRootLifecycle(event?.data?.sessionID, 'idle');
      });
    }
    onSessionEvent('server.connected', () => {
      if (!boundID || boundID !== visibleID) return;
      shutdownSessionID = undefined;
      retryScheduled = false;
      boundStatusConfirmed = false;
      boundStatus = undefined;
      statusCheckRetryAt = 0;
      readinessSyncRetryAt = 0;
      lifecycleSignalRevision++;
      nativeNotReady = true;
    });

    const closeMailboxStream = () => {
      stopMailbox?.();
      stopMailbox = undefined;
    };

    const clearPending = () => {
      closeMailboxStream();
      for (const item of pending.values()) {
        item.finish?.(new Error('route_changed'));
      }
      pending.clear();
      mailboxHandoff = undefined;
    };

    const finishMailboxHandoff = () => {
      // The prompt result can precede c11's durable coverage acknowledgement.
      // Keep the old stream until both the prompt and every delivery settle.
      if (!mailboxHandoff || pending.size || unsettledMailboxDeliveries.size || pendingUnbind) return;
      const next = mailboxHandoff;
      if (next.generation !== generation || next.sessionID !== visibleID) return;
      mailboxHandoff = undefined;
      closeMailboxStream();
      if (next.sessionID) register(next.sessionID, next.generation);
    };

    const replaceMailboxStream = (sessionID, routeGeneration) => {
      mailboxHandoff = { sessionID, generation: routeGeneration };
      finishMailboxHandoff();
    };

    const rejectPending = error => {
      for (const item of [...pending.values()]) {
        // Once session.prompt has been issued it cannot be cancelled. Let its
        // exact durable result settle this original delivery so c11 does not
        // retry the same envelope into a later displayed route.
        if (item.submitted) continue;
        item.finish?.(error);
      }
    };

    const register = (sessionID, routeGeneration) => {
      if (!sessionID || disposed || nativeMailDisabled) return;
      const streamID = `${sessionID}:${routeGeneration}:${++mailboxRevision}`.slice(0, 256);
      stopMailbox = subscribeNativeMailbox({
        socketPath, panelID, agentPID, sessionID: streamID, route: 'opencode_plugin', canQueue: false,
        onDeliveryPending: deliveryID => unsettledMailboxDeliveries.add(deliveryID),
        onDeliverySettled: (deliveryID, settlement) => {
          unsettledMailboxDeliveries.delete(deliveryID);
          if (settlement?.covered && typeof settlement.attemptID === 'string')
            admittedMailboxAttempts.delete(settlement.attemptID);
        },
        onSettled: finishMailboxHandoff,
        async deliver(message, attemptID) {
          if (message !== doorbellText) throw sessionConflict();
          // c11 may have lost the acknowledgement after OpenCode durably
          // admitted the prompt. Replay confirms that same attempt without
          // checking the now-current route or submitting another prompt.
          if (typeof attemptID === 'string' && admittedMailboxAttempts.has(attemptID))
            return { alreadyAdmitted: true };
          if (disposed || generation !== routeGeneration || currentRoute(context) !== visibleID ||
              conflict || !boundID || boundID !== visibleID) throw sessionConflict();
          if (!boundStatusConfirmed || boundStatus !== 'idle' || retryScheduled || boundID === shutdownSessionID ||
              !sessionReadyForMailbox(context, boundID)) {
            nativeNotReady = true;
            void refreshSessionReadiness(boundID, routeGeneration);
            throw sessionNotReady();
          }
          return new Promise((resolve, reject) => {
            const messageID = `msg_${randomUUID().replaceAll('-', '')}`;
            const item = { sessionID: boundID, messageID, resolve, reject, submitted: false, finish: undefined };
            const finish = error => {
              if (pending.get(messageID) !== item) return;
              pending.delete(messageID);
              if (error) reject(error);
              else resolve();
            };
            item.finish = finish;
            pending.set(messageID, item);
            try {
              item.submitted = true;
              Promise.resolve(context.client.session.prompt({
                sessionID: boundID,
                id: messageID,
                text: message,
              })).then(result => {
                // OpenCode 2 returns the durable inbox item admitted for this
                // session. Invocation alone is not delivery confirmation.
                if (result?.id !== messageID || result?.sessionID !== item.sessionID ||
                    result?.type !== 'user' || result?.payload?.text !== doorbellText) {
                  finish(new Error('unconfirmed'));
                  return;
                }
                if (typeof attemptID === 'string') {
                  admittedMailboxAttempts.set(attemptID, { messageID, sessionID: item.sessionID });
                }
                finish();
              }, finish);
            } catch (error) { finish(error); }
          });
        },
      });
    };

    const performCapture = async () => {
      if (disposed) return;
      if (!tuiClaimed) {
        if (Date.now() < nextClaimAt) return;
        claimAttempts++;
        tuiClaimed = await claimTui(c11Bin, socketPath, panelID, agentPID);
        if (!tuiClaimed) {
          if (claimAttempts >= 10 && !claimWarningLogged) {
            claimWarningLogged = true;
            console.warn('c11 OpenCode route capture still waiting: authenticated panel claim was not acknowledged');
          }
          // Keep retrying at the capped interval for this TUI's lifetime; c11
          // restore or its socket can recover after the initial backoff.
          nextClaimAt = Date.now() + Math.min(1_000 * (2 ** (claimAttempts - 1)), 5_000);
          return;
        }
      }
      const candidateID = currentRoute(context);
      if (candidateID !== visibleID) {
        const nextGeneration = ++generation;
        const previousID = visibleID;
        const shouldUnbind = hasObservedRoute && Boolean(candidateID || previousID);
        visibleID = candidateID;
        boundID = undefined;
        conflict = Boolean(candidateID);
        reportedLifecycle = undefined;
        desiredLifecycle = undefined;
        lifecycleRetryAt = 0;
        shutdownSessionID = undefined;
        retryScheduled = false;
        boundStatusConfirmed = false;
        boundStatus = undefined;
        statusCheckRetryAt = 0;
        readinessSyncRetryAt = 0;
        lifecycleSignalRevision++;
        nativeNotReady = false;
        captureState = candidateID ? 'waiting' : 'no-route';
        retryCaptureAt = 0;
        if (shouldUnbind) {
          pendingUnbind = {
            generation: nextGeneration,
            id: candidateID || previousID,
            state: candidateID ? 'pending' : 'no-route',
          };
          retryUnbindAt = 0;
        } else {
          pendingUnbind = undefined;
        }
        // Keep the old stream alive until c11 acknowledges the unbind. Its
        // captured generation now rejects deliveries as a session conflict,
        // keeping typed fallback closed while c11 still shows the old root.
        rejectPending(sessionConflict());
        if (candidateID) hasObservedRoute = true;
        if (candidateID && !pendingUnbind) {
          // The initial route has no old root to unbind. Establish an unsafe
          // provisional stream before waiting for hydration or ownership.
          register(candidateID, nextGeneration);
        }
      }
      if (pendingUnbind) {
        if (Date.now() < retryUnbindAt) return;
        const unbind = pendingUnbind;
        const result = await c11(socketPath, 'conversation.push', {
          panel_id: panelID,
          kind: 'opencode',
          id: unbind.id,
          source: 'hook',
          displayed_route_state: unbind.state,
          displayed_route_generation: unbind.generation,
        });
        if (disposed || generation !== unbind.generation || currentRoute(context) !== candidateID || pendingUnbind !== unbind) return;
        if (result?.outcome !== 'unbound') {
          // Retry the unbind while the provisional stream rejects delivery;
          // no new root is captured until c11 acknowledges this route change.
          retryUnbindAt = Date.now() + 250;
          return;
        }
        pendingUnbind = undefined;
        retryUnbindAt = 0;
        // The old binding is now unbound, so typed fallback remains closed
        // even while its native stream is replaced by the provisional route.
        replaceMailboxStream(candidateID, unbind.generation);
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
        const result = await c11(socketPath, 'conversation.push', {
          panel_id: panelID,
          kind: 'opencode',
          id: candidateID,
          source: 'hook',
          displayed_route_state: 'child',
          displayed_route_generation: routeGeneration,
          cwd: session.location?.directory || session.directory,
        });
        if (disposed || generation !== routeGeneration || currentRoute(context) !== candidateID) return;
        if (result?.outcome === 'unbound') {
          captureState = 'child'; // Child views have no root composer or identity.
          conflict = true;
          retryCaptureAt = 0;
        } else {
          captureState = 'waiting';
          retryCaptureAt = Date.now() + 500;
        }
        return;
      }

      const cwd = session.location?.directory || session.directory;
      const result = await c11(socketPath, 'conversation.push', {
        panel_id: panelID,
        kind: 'opencode',
        id: candidateID,
        source: 'hook',
        displayed_root: true,
        displayed_route_generation: routeGeneration,
        ...(cwd ? { cwd } : {}),
      });
      if (disposed || generation !== routeGeneration || currentRoute(context) !== candidateID) return;
      if (result?.outcome === 'accepted' && result.id === candidateID) {
        boundID = candidateID;
        conflict = false;
        nativeNotReady = false;
        captureState = 'bound';
        void refreshBoundSessionStatus(candidateID, routeGeneration);
        if (!nativeMailDisabled) {
          // Replace the provisional stream so a prior session_conflict
          // fallback ledger clears after this route becomes authoritative.
          replaceMailboxStream(candidateID, routeGeneration);
        }
      } else if (result?.outcome === 'identity_conflict') {
        conflict = true;
        captureState = 'identity-conflict';
        retryCaptureAt = Date.now() + 500;
      } else {
        captureState = 'waiting';
        retryCaptureAt = Date.now() + 500;
      }
    };

    let captureInFlight;
    const capture = () => {
      if (disposed) return Promise.resolve();
      if (captureInFlight) return captureInFlight;
      captureInFlight = performCapture().finally(() => { captureInFlight = undefined; });
      return captureInFlight;
    };

    const monitor = setInterval(() => {
      void capture().then(() => {
        if (boundID && visibleID === boundID && currentRoute(context) === boundID && boundID !== shutdownSessionID)
          void refreshBoundSessionStatus(boundID, generation);
        flushRootLifecycle();
        if (boundID && boundID === visibleID && boundStatusConfirmed && boundStatus === 'idle' &&
            !sessionReadyForMailbox(context, boundID)) void refreshSessionReadiness(boundID, generation);
        if (!nativeNotReady || !boundID || boundID !== visibleID || conflict ||
            !boundStatusConfirmed || boundStatus !== 'idle' || retryScheduled || boundID === shutdownSessionID ||
            !sessionReadyForMailbox(context, boundID)) return;
        nativeNotReady = false;
        // Readiness recovery also replaces a stream. Route it through the
        // same prompt and durable-coverage gate as a displayed-root handoff.
        replaceMailboxStream(boundID, generation);
      });
    }, 100);
    monitor.unref?.();
    await capture();
    return () => {
      disposed = true;
      generation++;
      clearInterval(monitor);
      clearPending();
      stopLifecycle.forEach(stop => stop());
    };
  },
};
