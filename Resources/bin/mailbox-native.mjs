// Shared, event-driven native-doorbell transport. Never reads or writes config.
import { createConnection } from 'node:net';
import { randomUUID } from 'node:crypto';

export const doorbellText = 'You have mail: run c11 mailbox recv --ack when you want to receive it.';

export function subscribeNativeMailbox({ socketPath, panelID, agentPID, sessionID, route, canQueue = false, deliver }) {
  let stopped = false;
  let socket;
  let retry;
  let failures = 0;
  const stop = () => { stopped = true; clearTimeout(retry); socket?.destroy(); };
  const connect = () => {
    if (stopped) return;
    const current = createConnection(socketPath);
    socket = current;
    current.unref();
    let buffered = '';
    let registered = false;
    current.setTimeout(2000, () => current.destroy());
    current.on('connect', () => current.write(JSON.stringify({id: randomUUID(), method: 'mailbox.native.subscribe', params: {
      panel_id: panelID, agent_pid: agentPID, session_id: sessionID, route, can_queue: canQueue,
    }}) + '\n'));
    const send = frame => {
      if (!stopped && current === socket && !current.destroyed) current.write(JSON.stringify(frame) + '\n');
    };
    current.on('data', chunk => {
      buffered += chunk.toString('utf8');
      if (buffered.length > 65536) { current.destroy(); return; }
      let end;
      while ((end = buffered.indexOf('\n')) >= 0) {
        const line = buffered.slice(0, end); buffered = buffered.slice(end + 1);
        let frame;
        try { frame = JSON.parse(line); } catch { current.destroy(); return; }
        if (!registered) {
          // An explicit refusal requires a new session/configuration, not a
          // reconnect loop for the lifetime of this harness.
          if (frame.ok === false) { stop(); return; }
          if (!frame.ok || !frame.result?.subscription_id) { current.destroy(); return; }
          registered = true; failures = 0; current.setTimeout(0);
          continue;
        }
        if (frame.type === 'replaced') { stop(); return; }
        if (frame.type !== 'deliver' || typeof frame.delivery_id !== 'string' || frame.text !== doorbellText) continue;
        // A positive result means observed harness acceptance, never merely
        // invoking a void API. Rejections must precede any possible side effect.
        Promise.resolve().then(() => {
          if (stopped || current !== socket || current.destroyed) throw new Error('session_closed');
          return deliver(frame.text);
        }).then(
          () => send({type: 'accepted', delivery_id: frame.delivery_id}),
          () => send({type: 'rejected', delivery_id: frame.delivery_id}),
        );
      }
    });
    current.on('error', () => {});
    current.on('close', () => {
      if (stopped || current !== socket) return;
      // Only failed connections retry. An established idle stream has no timer.
      retry = setTimeout(connect, Math.min(10000, 250 * 2 ** Math.min(failures++, 6)));
      retry.unref();
    });
  };
  connect();
  return stop;
}
