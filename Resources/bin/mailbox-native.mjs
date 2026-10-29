// Shared, event-driven native-doorbell transport. Never reads or writes config.
import { createConnection } from 'node:net';
import { randomUUID } from 'node:crypto';

export const doorbellText = 'c11 mail waiting: run c11 mailbox recv --ack';

export function subscribeNativeMailbox({ socketPath, panelID, agentPID, sessionID, route, canQueue = false, deliver,
  supportsAttemptReplay = false, onDeliveryPending, onDeliverySettled, onSettled }) {
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
    const pendingDeliveries = new Map();
    const scheduleReconnect = () => {
      // Only a replay-capable client can safely hold reconnect until an
      // outstanding prompt's durable result arrives. Legacy routes keep the
      // previous reconnect behavior while the two-second fallback runs.
      if (stopped || current !== socket || retry || (supportsAttemptReplay && pendingDeliveries.size > 0)) return;
      retry = setTimeout(() => {
        retry = undefined;
        connect();
      }, Math.min(10000, 250 * 2 ** Math.min(failures++, 6)));
      retry.unref();
    };
    const finishDelivery = (deliveryID, covered = false) => {
      const delivery = pendingDeliveries.get(deliveryID);
      if (!delivery) return;
      pendingDeliveries.delete(deliveryID);
      onDeliverySettled?.(deliveryID, { covered, attemptID: delivery.attemptID });
      if (pendingDeliveries.size === 0) {
        if (current.destroyed) scheduleReconnect();
        onSettled?.();
      }
    };
    current.setTimeout(2000, () => current.destroy());
    current.on('connect', () => current.write(JSON.stringify({id: randomUUID(), method: 'mailbox.native.subscribe', params: {
      panel_id: panelID, agent_pid: agentPID, session_id: sessionID, route, can_queue: canQueue,
      ...(supportsAttemptReplay ? { supports_attempt_replay: true } : {}),
    }}) + '\n'));
    const send = (frame, afterFlush, onUnavailable) => {
      if (!stopped && current === socket && !current.destroyed && current.readyState === 'open') {
        try {
          current.write(JSON.stringify(frame) + '\n', error => {
            if (error || current.destroyed || current.readyState !== 'open') onUnavailable?.();
            else afterFlush?.();
          });
        } catch {
          onUnavailable?.();
          return false;
        }
        return true;
      }
      onUnavailable?.();
      return false;
    };
    current.on('data', chunk => {
      buffered += chunk.toString('utf8');
      if (buffered.length > 65536) { current.destroy(); return; }
      let end;
      while ((end = buffered.indexOf('\n')) >= 0) {
        if (stopped) return;
        const line = buffered.slice(0, end); buffered = buffered.slice(end + 1);
        let frame;
        try { frame = JSON.parse(line); } catch { current.destroy(); return; }
        if (!registered) {
          // Session restore's not_ready is transient. Other explicit refusals
          // require a new session/configuration instead of a reconnect loop.
          if (frame.ok === false && frame.error?.code !== 'not_ready') { stop(); return; }
          if (!frame.ok || !frame.result?.subscription_id) { current.destroy(); return; }
          registered = true; failures = 0; current.setTimeout(0);
          continue;
        }
        if (frame.type === 'replaced') { stop(); return; }
        if (frame.type === 'settled' && typeof frame.delivery_id === 'string') {
          finishDelivery(frame.delivery_id, true);
          continue;
        }
        if (frame.type !== 'deliver' || typeof frame.delivery_id !== 'string' || frame.text !== doorbellText) continue;
        pendingDeliveries.set(frame.delivery_id, { attemptID: frame.attempt_id, promptSettled: false });
        onDeliveryPending?.(frame.delivery_id);
        // A positive result means observed harness acceptance, never merely
        // invoking a void API. Rejections must precede any possible side effect.
        Promise.resolve().then(() => {
          if (stopped || current !== socket || current.destroyed) throw new Error('session_closed');
          return deliver(frame.text, frame.attempt_id);
        }).then(
          result => {
            const delivery = pendingDeliveries.get(frame.delivery_id);
            if (delivery) delivery.promptSettled = true;
            send({type: 'accepted', delivery_id: frame.delivery_id,
              ...(result?.alreadyAdmitted ? { disposition: 'already_admitted' } : {})}, undefined,
              () => finishDelivery(frame.delivery_id, false));
          },
          error => {
            const delivery = pendingDeliveries.get(frame.delivery_id);
            if (delivery) delivery.promptSettled = true;
            const reason = ['session_conflict', 'not_ready'].includes(error?.code) ? error.code : undefined;
            send({type: 'rejected', delivery_id: frame.delivery_id, ...(reason ? {reason} : {})},
              () => finishDelivery(frame.delivery_id, false), () => finishDelivery(frame.delivery_id, false));
          },
        );
      }
    });
    current.on('error', () => {});
    current.on('close', () => {
      if (stopped || current !== socket) return;
      // Wait for submitted prompts to resolve before opening another stream.
      // Their stable attempt IDs make the later registration idempotent.
      for (const [deliveryID, delivery] of pendingDeliveries) {
        if (delivery.promptSettled) finishDelivery(deliveryID, false);
      }
      scheduleReconnect();
    });
  };
  connect();
  return stop;
}
