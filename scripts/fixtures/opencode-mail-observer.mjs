import { appendFileSync } from 'node:fs';

// Test-only observer. The guest has an isolated HOME and synthetic prompts.
export const C11MailProof = async () => ({
  event: async ({ event }) => {
    const path = process.env.C11_OPENCODE_PROOF_LOG;
    if (!path) return;
    const p = event.properties || {};
    let row;
    if (event.type === 'message.updated') {
      const m = p.info;
      if (m) row = { event: event.type, session: m.sessionID, message: m.id,
        role: m.role, completed: m.time?.completed, parent: m.parentID };
    } else if (event.type === 'message.part.updated' && p.part?.type === 'text') {
      row = { event: event.type, session: p.part.sessionID, message: p.part.messageID, text: p.part.text };
    } else if (event.type === 'session.status') {
      row = { event: event.type, session: p.sessionID, status: p.status?.type };
    }
    if (row) appendFileSync(path, JSON.stringify({ at: Date.now(), ...row }) + '\n');
  },
});
