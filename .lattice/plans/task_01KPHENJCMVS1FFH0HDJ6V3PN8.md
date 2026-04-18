# CMUX-11: Nameable panes: metadata layer & :: lineage mechanism

Add a first-class metadata layer to panes whose initial consumer is a user/agent-assigned title carrying lineage (Parent :: Child :: Grandchild) through the task graph as operators and agents move through their work. Mechanism layer only — no UI chrome (see separate Ticket 2 for pane title bar rendering).

PHILOSOPHICAL SHIFT (load-bearing): it's text. Trust the LLM. No structured breadcrumb type, no merge rules, no close-time snapshotting — a single string field that agents compose, mutate, and occasionally reset. The :: separator is a convention, not a system delimiter.

KEY DECISIONS (from scoping conversation):

1. Create-time seeding passes lineage for free. pane.create and split commands take an optional --title argument. The spawning agent composes the title (typically: read own title → append :: child-role). c11mux does not auto-copy — intelligence lives at the LLM layer per the unopinionated-host principle.

2. Rename is read-then-write by convention. pane.set_metadata RPC response includes the prior value so agents have it in-hand after a write. Skill documents the read-before-write norm so agents default to mutation over replacement. Agents can always replace wholesale when the new task is unrelated.

3. Breadcrumb survives ancestor closure. Plain text; closure has no effect on descendants. The string is frozen narrative.

4. Full PaneMetadataStore parity with SurfaceMetadataStore — JSON value fidelity, source attribution, 64 KiB cap, monotonic revision counter. Title is just text today, but the store is the foundation for future pane-level metadata (status/role/progress) without a second migration. Satisfies TODO.md:38 parity goal.

5. Windows out of scope (they don't split — simpler case, defer until panes prove the pattern).

6. /clear cue lives in the skill. When an agent runs /clear (or equivalent context-reset), the skill instructs it to ask the operator whether to rename the pane. c11mux installs no hooks — guidance only.

7. Skill :: convention is single source of truth. Title Bar Fidelity (in-flight sibling work) is landing the :: lineage convention in skills/cmux/SKILL.md for surface titles. This ticket's skill addition is a short cross-reference ('same rules apply to panes'), not a re-documentation.

PHASES (each a PR):

Phase 1 — PaneMetadataStore (in-memory). Scaffolding; ships a store nobody uses yet.
Phase 2 — Socket RPCs (pane.set_metadata / .get / .clear) + CLI (--pane on set-metadata family, --title on new-pane/new-split). Prior-value-in-response substrate for the read-then-write convention.
Phase 3 — Persistence via SessionPaneSnapshot extension (rides Tier 1 Phase 2 rails; additive-optional decoding, schema stays at v1).
Phase 4 — Skill guidance addition (cross-reference to Title Bar Fidelity's :: convention + pane-layer specifics).

NO UI in this ticket. Visibility is via cmux tree, cmux list-panes, and RPC responses. Pane title bar chrome is Ticket 2.

PLAN DOC: docs/c11mux-pane-naming-plan.md
