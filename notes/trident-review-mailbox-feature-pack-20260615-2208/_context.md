# Trident Review Context — c11 Mailbox Feature (as it stands today)

You are one of **nine reviewers** (three lenses × three models) reviewing the c11 **mailbox** — an inter-agent messaging primitive in a native macOS terminal multiplexer (Swift/AppKit). This is **not** a narrow diff review. Review the **feature as a whole**, as it stands today on `main`, with the forward-looking intent of deciding whether and how it should *mutate*.

## What the mailbox is

c11 hosts many terminal "surfaces" (agents) across panes, workspaces, and windows. The mailbox lets one surface send a structured message to another by **surface name**. A per-workspace, in-process `MailboxDispatcher` watches a filesystem `_outbox/`, validates a JSON envelope (schema v1), resolves the recipient by its `title` metadata, copies the envelope into the recipient's inbox, and — for `mailbox.delivery=stdin` recipients — types a framed `<c11-msg>…</c11-msg>` block into the recipient's PTY. Everything is filesystem-backed (atomic writes, dot-tmp rename) with an append-only NDJSON `_dispatch.log`.

It just gained **cross-workspace routing** + **non-silent rejection** (PR #251, merged). Before that, a send to a recipient in another workspace resolved to zero recipients and was silently discarded.

## The feature surface — read these real files

Core (`Sources/Mailbox/`, ~2200 LOC):
- `MailboxDispatcher.swift` — the pipeline: outbox→processing→validate→resolve→copy→handlers→cleaned, plus GC sweep, dedupe, quarantine, and the new reject-on-zero path.
- `MailboxSurfaceResolver.swift` — per-workspace name→surface resolution **and** the new pure `MailboxGlobalResolver` (cross-workspace, local-first precedence + ambiguity rule).
- `MailboxEnvelope.swift` — schema-v1 build + validate (single source of truth).
- `MailboxLayout.swift` — per-workspace dir layout + surface-name validation + state-dir migration.
- `MailboxDispatchLog.swift` — NDJSON event log.
- `MailboxOutboxWatcher.swift` — fsevents watcher.
- `MailboxIO.swift` — atomic write.
- `MailboxHandler.swift` / `StdinMailboxHandler.swift` — delivery handlers (stdin = PTY paste+submit; silent = no-op).
- `MailboxULID.swift` — id generation.

Wiring:
- `Sources/Workspace.swift` — `startMailboxDispatcher()` constructs one dispatcher per workspace, registers `silent` + `stdin` handlers.
- `Sources/AppDelegate.swift` — `mailboxAddressableSurfaces()` enumerates all live surfaces across all windows/workspaces (global registry).
- `Sources/TerminalController.swift` — `mailbox.resolve` socket method (`v2MailboxResolve`).
- `CLI/c11.swift` — `c11 mailbox send/recv/trace/tail/...`, the new `resolveMailboxTargetWorkspace`, `--to-workspace`.

Docs/spec:
- `docs/c11-mailbox-guide.md` — full guide (layout, sequence diagrams, patterns, Stage 2 limits).
- `docs/c11-messaging-primitive-design.md` — design rationale.
- `spec/mailbox-envelope.v1.schema.json` — envelope schema.
- `skills/c11/SKILL.md` (Inter-agent messaging section) — agent-facing contract.

The diff of the just-merged cross-workspace change is at `notes/.tmp/trident-mailbox-feature/merged-change.txt`.

## How it routes now (post #251)

`c11 mailbox send --to <name>` calls the `mailbox.resolve` socket method, which scans every live surface and resolves **local-first**: a match in the sender's own workspace wins; else the single workspace that has the name receives it; a name in >1 *other* workspace is **ambiguous** (non-zero error, `--to-workspace <ref>` disambiguates); no match anywhere is **unresolved** (non-zero, message not written). The CLI then writes the envelope into the **recipient's** workspace outbox, and that workspace's own dispatcher delivers it. Same-workspace behavior is unchanged. The dispatcher also now quarantines a `to`-bearing envelope that resolves to nobody (`_rejected/<id>.msg` + `.err` + `rejected` event) — the backstop for raw-bash writers and races.

## Live validation already performed (tagged build, 3 workspaces)

T1 cross-workspace deliver ✓ (framed block reached recipient in another workspace; WS2 dispatch log shows full sequence). T2 local-first ✓ (name in 2 workspaces, sender's wins). T3 collision → ambiguous non-zero ✓. T4 `--to-workspace` qualifier ✓. T5 unknown → non-zero "Message not sent" ✓. T6 raw unresolvable write → `_rejected/` + `.err` + `rejected` event, no `cleaned` ✓. Unit tests (c11LogicTests) green.

## Known Stage-2 limits (already documented — not "findings", but fair game for evolution)

No topic fan-out (topic-only rejected; `mailbox.subscribe` globs are Stage 3). No `_processing/` crash-recovery sweep (at-least-once is steady-state only). No per-surface inbox cap. No `body_ref` read-through. Delivery handlers are only `{stdin, silent}`. `stdin` delivery pastes into a PTY and dispatches Return — undefined for cooked-mode shells, designed for agent TUIs.

## Architectural context worth weighing

- The dispatcher is **per-workspace and in-process**; cross-workspace routing is achieved by the CLI writing into the *recipient* workspace's outbox (not by a global dispatcher). Resolution is synchronous at the CLI via a socket call; delivery is async via the recipient workspace's fsevents watcher.
- Recipient identity == the surface `title` metadata. Titles are user/agent-mutable and non-unique.
- Everything is local-filesystem under `~/Library/Application Support/c11/workspaces/<uuid>/mailboxes/`. Single-host, single-process.
- This is dogfooded: c11's own agent-orchestration workflows (lattice-orchestrator, overwatch) are the primary consumers — operator running 8–30 agents in parallel who need them to coordinate.

## Your charter

Review the feature as it stands, then think one step ahead. Your specific lens instructions follow this context document.
