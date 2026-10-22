import { randomUUID } from 'node:crypto';

// OpenCode's TUI plugin API owns the displayed route. Server plugins see all
// sessions, including invisible ones, and cannot safely choose the recipient.
export default {
  id: 'com.stage11.c11.mailbox',
  async tui(api) {
    const socketPath = process.env.C11_SOCKET_PATH || process.env.CMUX_SOCKET_PATH;
    const panelID = process.env.C11_PANEL_ID || process.env.C11_TAB_ID || process.env.CMUX_SURFACE_ID;
    const agentPID = Number(process.env.C11_AGENT_INTERACTIVE_PID);
    if (!socketPath || !panelID || agentPID !== process.pid ||
        process.env.C11_OPENCODE_NATIVE_MAIL_DISABLED === '1' ||
        !api.route || !api.state?.session?.get || !api.state.session.status || !api.state.session.permission ||
        !api.state.session.question || !api.client?.session?.promptAsync ||
        !api.event?.on || !api.lifecycle?.onDispose) return;

    let transport;
    try { transport = await import(new URL('../../bin/mailbox-native.mjs', import.meta.url)); }
    catch { return; } // Older/incomplete bundles retain ordinary typed delivery.
    const { subscribeNativeMailbox, doorbellText } = transport;
    const pending = new Map();
    const users = new Map();
    let bound;
    let stop;
    let disposed = false;
    const currentSession = () => {
      const route = api.route.current;
      if (route?.name !== 'session' || typeof route.params?.sessionID !== 'string') return;
      const session = api.state.session.get(route.params.sessionID);
      // Child views have no composer. Until the displayed root is known, keep
      // the same typed fallback policy as Home instead of starting a child turn.
      return session && !session.parentID ? route.params.sessionID : undefined;
    };
    const retire = () => {
      stop?.();
      stop = undefined;
      bound = undefined;
      for (const item of pending.values()) clearTimeout(item.timer);
      pending.clear();
      users.clear();
    };
    const confirm = item => {
      if (item.messageID && users.get(item.messageID) === item.sessionID) {
        clearTimeout(item.timer);
        pending.delete(item.partID);
        item.resolve();
      }
    };
    const removers = [
      api.event.on('message.updated', event => {
        const info = event.properties?.info;
        if (info?.role !== 'user' || typeof info.id !== 'string') return;
        users.set(info.id, info.sessionID);
        if (users.size > 64) users.delete(users.keys().next().value);
        for (const item of pending.values()) confirm(item);
      }),
      api.event.on('message.part.updated', event => {
        const part = event.properties?.part;
        const item = pending.get(part?.id);
        if (!item || part.type !== 'text' || part.text !== doorbellText ||
            part.sessionID !== item.sessionID) return;
        item.messageID = part.messageID;
        confirm(item);
      }),
    ];
    const reconcile = () => {
      if (disposed) return;
      const sessionID = currentSession();
      if (sessionID === bound) return;
      retire();
      if (!sessionID) return;
      bound = sessionID;
      const generation = randomUUID();
      stop = subscribeNativeMailbox({ socketPath, panelID, agentPID,
        sessionID: generation, route: 'opencode_plugin', canQueue: false,
        deliver(text) {
          // Re-read the displayed route synchronously, including between the
          // route monitor's ticks. Every rejection precedes any SDK call.
          if (disposed || bound !== sessionID || currentSession() !== sessionID ||
              text !== doorbellText ||
              ['busy', 'retry'].includes(api.state.session.status(sessionID)?.type) ||
              api.state.session.permission(sessionID).length ||
              api.state.session.question(sessionID).length) throw new Error('not_ready');
          return new Promise(resolve => {
            const partID = 'prt_' + randomUUID().replaceAll('-', '');
            const item = { sessionID, partID, resolve };
            // No acknowledgement on ambiguity: c11 owns the two-second
            // fallback deadline. A later real event may still confirm receipt.
            item.timer = setTimeout(() => pending.delete(partID), 10000);
            item.timer.unref?.();
            pending.set(partID, item);
            // Let OpenCode allocate its ordered message ID. Only the text
            // part's ID is ours; the composer is never read or changed.
            try {
              Promise.resolve(api.client.session.promptAsync({ sessionID,
                parts: [{ id: partID, type: 'text', text }] })).catch(() => {});
            } catch { /* an invoked API is not a definite non-delivery */ }
          });
        },
      });
    };
    // The supported API has a live route getter but no navigation event.
    // Retirement is bounded here; the delivery callback checks it immediately.
    const monitor = setInterval(reconcile, 250);
    monitor.unref?.();
    api.lifecycle.onDispose(() => {
      disposed = true;
      clearInterval(monitor);
      retire();
      removers.forEach(remove => remove());
    });
    reconcile();
  },
};
