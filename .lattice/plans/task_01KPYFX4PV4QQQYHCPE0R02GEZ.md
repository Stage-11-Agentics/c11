# C11-13: Inter-agent messaging primitive: mailbox + pluggable delivery handlers

Design and ship a minimal inter-surface messaging primitive for c11. Filesystem-contract-first mailbox at $C11_STATE/mailboxes/ with a shared _outbox/, per-surface inboxes, and pluggable delivery handlers (stdin, silent, watch, potentially exec). XML-tag wire format for PTY injection. Topic discovery via hybrid advertised+emergent registry. CLI is a thin convenience wrapper; direct file writes are equivalent. See design doc at docs/c11-messaging-primitive-design.md.
