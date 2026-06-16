# C11-145: Mailbox: liveness/presence (minimal, existing signals only)

Claude's co-#1 from the Trident review (notes/trident-review-mailbox-feature-pack-20260615-2208/synthesis-evolutionary.md). The mailbox can deliver to an actor that never processes its inbox, and nothing tells the sender — invisible deadlocks in unattended runs (the '7am deadlock' prediction).

Deliverable (reuse what already exists — no new hooks):
- 'c11 mailbox who' and a send '--check' that report a recipient live/dead + workspace, reusing AppDelegate.mailboxAddressableSurfaces() (already computed on every resolve).
- Emit a 'recipient_closed' (or reuse 'rejected') dispatch-log event when a send resolves to a now-closed surface, so dead-recipient is observable.

Scope guard: DEFER the heavy Erlang-style 'DOWN' monitor / outstanding-correlation tracking. Presence (PTY exists) is not responsiveness (will process) — document that honestly; don't oversell. Start with presence + the log event.

Acceptance: 'mailbox who <name>' returns live/dead+workspace; a send to a just-closed surface produces a visible log event and non-zero/​warned result.
