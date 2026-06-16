# C11-143: Mailbox: stable addressing (mailbox.address/role, decouple from mutable title)

FOUNDATION — the unanimous #1 mutation from the nine-instance Trident review of the mailbox feature (notes/trident-review-mailbox-feature-pack-20260615-2208/synthesis-evolutionary.md).

Problem: a mailbox recipient is addressed by its 'title' metadata, which is user/agent-mutable and non-unique. The global CLAUDE.md MANDATES agents rename their tab as their first action — so the bus silently re-partitions the moment an agent renames itself. Every reliability mutation sits on top of this.

Deliverable:
- New 'mailbox.address' / 'mailbox.role' metadata key; resolver (MailboxSurfaceResolver + MailboxGlobalResolver) prefers it, FALLS BACK to title (back-compat, no envelope schema change — 'to' is already opaque).
- New qualifier forms 'surface:<ulid>' and 'role:<name>' alongside existing 'workspace:*' in the send path / mailbox.resolve.
- Update the c11 skill so agents declare a stable address once at orientation; sync installed skill.

Scope guard: keep local-first/ambiguity routing as-is (stable addressing dissolves the collision worry that made it feel 'too clever'). Identity, not a routing rewrite.

Acceptance: send to a stable address survives a recipient tab-rename; unit tests for resolver precedence (address > role > title) and the new qualifiers; same/cross-workspace behavior unchanged when only titles are set.
