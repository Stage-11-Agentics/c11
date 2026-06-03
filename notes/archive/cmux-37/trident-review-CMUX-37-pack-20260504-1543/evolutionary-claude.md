## Evolutionary Code Review
- **Date:** 2026-05-04T15:45:00Z
- **Model:** Claude (claude-opus-4-7)
- **Branch:** cmux-37/final-push
- **Latest Commit:** aea6eaa8 (HEAD), merge-base 3a3908110afacf7c2296ef3e3df592c4a5062616
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory
---

## What's Really Being Built

The stated feature is "close five smoke-test gaps." That's the surface read. What's actually being built across the nine commits is something more interesting and not yet named in the codebase: **a hand-authorable, agent-authorable, lossless-via-JSON description language for c11 workspaces, paired with a polymorphic envelope graph for restoring them.**

Three concrete pieces of evidence:

1. **`WorkspaceBlueprintMarkdown.swift` is not a serialisation format. It is a DSL.** The doc comment says the quiet part out loud: "The markdown form is meant for hand-authoring and legible exports — not lossless capture." The format has a deliberate split — JSON is the lossless wire and the round-trip rail; Markdown is the *legible interface* humans and agents author against. That dual rail is rare and powerful: most projects pick one and lose either fidelity or readability. c11 just bought both, scoped cleanly.

2. **Snapshot sets are an envelope-of-envelopes.** `WorkspaceSnapshotSetFile` (in `Sources/WorkspaceSnapshotSet.swift:34-127`) is a *pointer* file — it carries no plan data of its own, just references to inner snapshots that stay independently restorable. Aea6eaa8's commit message frames this as a "manifest." It is more than that: it is the first compositional object in c11's persistence layer. Inner snapshots remain leaves; the set is the first node. The next node type — a "session," a "moment," a "checkpoint chain" — slots in next to it without breaking anyone.

3. **Polymorphic restore by id (`CLI/c11.swift:3416-3440`, `isLocalSnapshotSetId`) is a typeless dispatch table.** `c11 restore <id>` now probes `~/.c11-snapshots/sets/<id>.json` first, falls through to single-snapshot. Both share the ULID grammar so the dispatch is *behavioural*, not syntactic. This is a small but important architectural move: ids in c11 are starting to be polymorphic over the artifact graph, not 1:1 with a single artifact kind.

What this enables that wasn't possible before: **operators (and agents) can hand-edit a workspace layout, commit it to a repo, and instantiate it as a fresh workspace with a single command.** That's a very different proposition than "we have JSON snapshots." It's the difference between a backup format and a *configuration-as-code* substrate.

---

## Emerging Patterns

**1. Capture-side fix + classifier as belt-and-suspenders.**
Workstream 3 fixed `metadata_override` warnings two ways: (a) capture-side, by stripping redundant canonical fields when they match (`WorkspacePlanCapture.swift:152-169`), and (b) CLI-side, by classifying the diagnostic as `info` rather than `failure` (`CLI/c11.swift:2882-2889`). This is a deliberate redundancy. It's also a pattern worth naming: **executor invariants are enforced at the producer (capture) and tolerated at the consumer (CLI render).** Should be formalized — it's the right shape for any "expected-but-noisy" diagnostic that flows through the executor.

**2. CLI-as-trusted-kernel for paths, socket-as-sandbox.**
Three sites now reflect the same rule: the socket refuses caller-supplied `path` (`v2SnapshotCreate`, `v2SnapshotRestore`, `v2SnapshotRestoreSet` all have the same guard at the top), and the CLI handles file I/O against the user's real FS permissions before submitting by id. The doc comments explicitly cite the threat model: "an agent with only socket access … overwriting `~/.claude/settings.json` etc." This is a clean factoring — the CLI is the trusted boundary, the socket is the untrusted one — and worth promoting to a documented invariant in CLAUDE.md's "Socket focus policy" section. Right now it's discoverable only by reading three handlers in a row.

**3. Two-level help dispatch (`CLI/c11.swift:9187-9273`) is the seed of subcommand grammar.**
`c11 workspace <sub> --help` gets per-subcommand help text, and the dispatcher prefixes the printed header with `c11 workspace <sub>` so operators see *which* help block they got. This is the first place in c11.swift where the CLI grammar is genuinely two-level instead of flat-with-hyphens. With ~12 commands already shaped like `<noun>-<verb>` (`new-workspace`, `close-workspace`, `select-workspace`, …), the pattern is asking to be normalized. Workspace-as-noun + apply/new/export-blueprint as verbs is the v2 shape; the legacy hyphenated forms can remain as compat aliases (and already do — `workspace-apply` is preserved).

**4. Substring-keyed classification (anti-pattern to catch early).**
`failureSeverity` (`CLI/c11.swift:2882-2889`) detects the seed-cwd case via `message.contains("seed terminal reuse")`. The code itself flags this as fragile — there's a CAUTION block pointing at the executor line that has to keep emitting that exact string. **This is a wire-protocol violation in disguise.** The producer (executor) and consumer (CLI) are coupled through prose. If the operator localizes the executor message tomorrow, the classifier silently breaks. See "Concrete Suggestions #1" — promote it to a structured field.

**5. Mirror-everything env var policy (`CLI/c11.swift:39-50`, `mirrorC11CmuxEnv`).**
The cmux→c11 rename is being absorbed at a single point: any `CMUX_*` is mirrored to `C11_*` and vice versa. The fact that this works at all is good ergonomics (and the right call given existing operators), but the cost is real — `defaultSocketPath` now reads three keys (`C11_SOCKET`, `CMUX_SOCKET_PATH`, `CMUX_SOCKET`), the env-resolution shape is different in `Self.envSocketPath` vs `run()`, and the keys look at slightly different combinations in different sites. The pattern works for now but is creeping toward a maintainability cliff. Worth pulling into a single `EnvResolver.preferred(_:)` that owns the precedence.

---

## How This Could Evolve

**The Markdown blueprint format is the leverage point.** Today it's a layout description. With small, additive moves it becomes:

1. **An agent-authoring surface.** Right now an agent has to construct a `WorkspaceApplyPlan` JSON tree to compose a workspace. The Markdown form is *easier* for an LLM to author than JSON — it's text with whitespace, it has a fenced YAML for the structural parts, and the parser tolerates incidental prose between sections. Telling Claude "write me a blueprint" lands much better than "write me a workspace plan envelope." There's a reason a parser that ignores free-form prose is in the public path.

2. **A skill-portable artifact.** Drop `agent-room.md` in `~/.config/c11/blueprints/`, share it with the operator, version it in a repo's `.c11/blueprints/`. The store already supports all three (`WorkspaceBlueprintStore.swift:64-129`). The next move is documenting blueprints-as-skill-deliverable so a skill that wants a particular working environment (research room, code-review trident layout, mailbox triage room) ships its blueprint alongside its instructions.

3. **A diff target.** Two markdown blueprints can be visually diffed by Git/Obsidian. Two JSON snapshot envelopes cannot. This is a sneaky big deal — it means "what changed between yesterday's room and today's" is human-readable for the first time.

**Snapshot sets should evolve into a proper artifact graph.** The current envelope is a flat manifest pointing at leaves. Two natural mutations:

1. **Add named sets.** A user-supplied label (`--label "before-trident-review"`) writes to `sets/<set_id>.json` *and* a symlink `sets/<label>.json -> <set_id>.json`. `c11 restore before-trident-review` becomes muscle memory. Implementation cost: trivial — `writeSet` already controls the destination filename.

2. **Add set-of-sets (sessions).** A "session" is a curated chain of sets — capture-restore-capture-restore — with provenance (which set was the parent). Schema is the same envelope shape one level up. Dialog: "rewind to before I broke the build" becomes a one-liner against the session graph.

**Failure classification should evolve from substring-matching to structured.** See Suggestion #1. The wire shape needs a new field; the executor needs to set it; the CLI reads it. After that, the classifier disappears and the executor owns its own opinion about severity. Phosphor-grade move: the dataset becomes the API.

**The `c11 workspace <sub>` namespace wants to absorb peer commands.** `snapshot`, `restore`, `list-snapshots` are workspace operations conceptually; right now they're top-level. As the grammar settles, they could become `c11 workspace snapshot`, `c11 workspace restore`. Keep the top-level forms as aliases. The two-level help dispatch is already the right machinery.

---

## Mutations and Wild Ideas

**1. Markdown blueprints as the c11 *surface description protocol.* (Strategic mutation.)** Stop thinking of `.md` blueprints as a workspace export format. Start thinking of them as the universal substrate any c11 surface can be described in. A markdown surface in c11 is already a first-class citizen. A blueprint is markdown. So: **a blueprint can describe a workspace whose first markdown surface is the blueprint itself.** Self-hosting, documentation-as-environment, the room ships with its own usage notes baked in. An agent receiving a "fix this build" task gets a blueprint that opens the right terminals, browser, and a markdown panel with the bug report — all from one file.

**2. Markdown blueprints with executable seed scripts.** The current `command:` field on a surface is a one-liner. A small extension: an extra fenced codeblock under `## Seed`:

```markdown
## Seed

```bash
# Runs once on first creation; ignored on restore.
brew install hyperfine
git -C ~/work/c11 fetch
```
```

This is a one-edit operation on the parser (recognise a second fenced section), and it makes blueprints **bootable**. Combined with restart-registry session resume, the workspace stops being "a layout" and becomes "a working environment."

**3. Manifest as content-addressable graph.** Today each set entry has `snapshot_id`, `workspace_ref`, `order`, `selected`. Add an optional `parent_set_id` and a `created_from`: `"manual" | "auto-restart" | "branch:<commit>"`. Now your snapshot history forms a DAG. `c11 list-snapshots --sets --history` walks it. `c11 restore <id> --branch` clones a set into a new lineage. This is git semantics applied to workspaces, and the ULID grammar already gives you content-addressing for free.

**4. Failure classification owned by the executor, queryable by the CLI.** Promote `severity: info|warning|failure` to a typed enum on `ApplyFailure`. Default emit-site sets the right value. Then `failureSeverity()` becomes `failure.severity` and the substring matcher dies. The risk-reward is excellent because the wire shape additions are additive (older clients ignoring an unknown field still get the old behavior).

**5. `c11 workspace export-blueprint --format md` becomes the c11 equivalent of "Save As..."** Today it captures and writes. With `--watch` it captures, writes, and re-emits on every workspace mutation. Suddenly `~/.config/c11/blueprints/current.md` is a live mirror of the room — open it in Obsidian, watch it update. That's a debugging superpower for skill authors and a documentation superpower for everyone else.

**6. Polymorphic IDs unify the artifact namespace.** `restore <id>` already disambiguates set vs single. The same dispatch can extend: `apply <id>` → blueprint by name; `inspect <id>` → whatever artifact the id resolves to. ULIDs become the c11 noun primitive. The `isLocalSnapshotSetId` predicate is the seed of a registry.

**7. Skill-driven "room recipes."** A skill can ship `recipes/*.md` blueprints alongside `SKILL.md`. When the skill is invoked, it prompts the operator: "I work best in this layout. Apply it?" Yes → `c11 workspace new --blueprint <skill-path>/recipes/default.md`. The skill brings the room with it. This is where the markdown format pays off most: it's portable, readable, signable, and reviewable without c11 running.

---

## Leverage Points

**1. The blueprint Markdown parser is the highest-leverage surface in this PR.** Anything that becomes part of the `## Layout` schema becomes accessible to (a) every blueprint author, (b) every snapshot-via-blueprint round-trip, and (c) every agent that learns the format. Adding one optional field to the surface schema (e.g., `seed_command:`) is a few-line change with whole-system impact.

**2. The polymorphic `restore <id>` dispatch is a cheap registry waiting to be born.** Add a third probe (`blueprints/<id>.md`) and `c11 restore <my-blueprint-name>` works. Add a fourth (`sessions/<id>.json`) and rewinds work. Keep the dispatcher dumb but the registry extensible.

**3. `failureSeverity` as a single function in `CLI/c11.swift` is the right place to refactor.** Every consumer of the executor's `failures` payload routes through `partitionFailures`. Replace the function body with a wire-field read and the entire UI surface improves at once.

**4. `WorkspaceBlueprintStore.merged(cwd:)` is the discovery surface.** Today it walks repo → user → built-in. Adding "skill" as a fourth source (skills declare a blueprints dir) is a 15-line change and turns blueprints into a skill artifact class.

**5. The `info:` line is a UI primitive, not just a smoke-test fix.** The CLI now distinguishes `failures:` from `info:` in render. The same machinery extends to `warnings:` (already exists), `notices:`, `suggestions:`. This is a tiny amount of code that opens up nuanced human output.

---

## The Flywheel

**The blueprint format flywheel.** As more operators and agents author blueprints, the format gets stress-tested → parser improves → format gains expressivity → blueprints become more useful → more get authored. The c11 tree already plants the seed at three sources (repo, user, built-in) — built-in blueprints are the authoring tutorial. **One concrete move to set it spinning: ship 3-5 starter blueprints in the app bundle's `Blueprints/` directory** (research-room.md, code-review-trident.md, mailbox-triage.md, debug-session.md, agent-room.md). They become the on-ramp and the documentation simultaneously.

**The skill ↔ blueprint flywheel.** Skills want to teach behavior; blueprints want to teach environments. A skill that ships `recipes/*.md` is a skill that teaches *both*. Once one skill does this and it works, others copy. The `c11` skill itself should ship a recipe for the c11 dev pane layout — eat your own dog food.

**The snapshot-as-time-machine flywheel.** Once `--all` produces sets routinely (and it does, by default — that's the whole point of the W2 fix), operators get used to *captures-being-restorable-in-bulk*. They start running `c11 snapshot --all` more often (low cost, high optionality). The set archive grows. `list-snapshots --sets` becomes a navigation surface. Then named sets, then session graphs, then time-travel UX. The flywheel is already turning; the question is whether to lubricate it (suggestion #2 above) or let it spin freely.

**The diagnostic-classification flywheel.** Once `info:` is an accepted output channel, operators stop training themselves to ignore noisy "failures." Trust in the executor's failure list goes up → real failures get attention → bugs get found earlier. The structured-severity refactor (suggestion #1) is the multiplier here.

---

## Concrete Suggestions

### High Value

**1. Promote failure severity from substring matching to a typed wire field.**
*File:* `Sources/WorkspaceApplyPlan.swift` (the `ApplyFailure` definition), `Sources/WorkspaceLayoutExecutor.swift` (every `reportWorkingDirectoryNotApplicable`/`reportMetadataOverride` emission site), `CLI/c11.swift:2882-2889` (delete the substring matcher, replace with `failure.severity` read).

Add `severity: FailureSeverity` (case `info | warning | failure`, encoded as a string field for forward-compat) to the `ApplyFailure` value. Default emission sites in the executor pick the right value at the source. The CLI's classifier becomes a one-liner field read. The `metadata_override` and `seed terminal reuse` cases are tagged at emission and travel as data, not prose.

*Why high-value:* Eliminates the prose-coupled coupling between executor and CLI flagged in the existing code's CAUTION block. Adds zero net runtime cost. Is additive on the wire (older readers ignore the unknown key and fall back to current behavior). Phosphor-grade: dataset-as-API.

*Risks:* Touching every emission site is a meaningful diff. Test impact: any test asserting on the failure list shape needs a `severity:` field added. Mitigation: pick a sensible default (`.failure`) so unset sites don't change behavior.

✅ Confirmed — verified `failureSeverity` lives in one place and `partitionFailures` is the only consumer (`CLI/c11.swift:2893-2907`). The replacement is mechanical.

**2. Ship 3–5 starter blueprints in `Resources/Blueprints/`.**
*File:* New directory `Resources/Blueprints/` with `agent-room.md`, `code-review-trident.md`, `mailbox-triage.md`, `debug-session.md`, `research-room.md`. `WorkspaceBlueprintStore.builtInBlueprintURLs()` (`Sources/WorkspaceBlueprintStore.swift:115-129`) already walks `Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Blueprints")` for both `json` and `md` — so adding `.md` files there shows up automatically in the picker.

*Why high-value:* This is the on-ramp for the entire format. Without seeded examples, operators don't know to author blueprints; with them, the picker becomes a tutorial. Free tutorial, free dogfooding, free documentation, all in one move.

*Risks:* Bundle size (negligible — markdown is tiny). Maintenance: keep the bundled examples valid as the schema evolves. Mitigation: add a CI test that round-trips every `Resources/Blueprints/*.md` file through the parser.

✅ Confirmed — verified the store reads bundle resources via `Bundle.main.urls(forResourcesWithExtension:subdirectory:)`. Adding files to the resource path works without code changes.

**3. Document the trusted-kernel CLI / sandboxed-socket invariant in CLAUDE.md.**
*File:* `CLAUDE.md` (worktree root), section "Socket focus policy" or a new sibling section "Trusted CLI vs sandboxed socket."

The pattern is already enforced in three places (`v2SnapshotCreate`, `v2SnapshotRestore`, `v2SnapshotRestoreSet` all reject caller-supplied paths) but a future contributor adding a fourth socket method that takes a file argument has no documented rule to follow. A two-paragraph addition in CLAUDE.md prevents a privilege-escalation regression.

*Why high-value:* Codifies a security-relevant invariant. Costs nothing at runtime. Aligns with existing CLAUDE.md culture (security/style rules live there).

*Risks:* None.

✅ Confirmed — verified the same `path`-rejection guard appears at `Sources/TerminalController.swift:4724-4732`, `4867-4875`, `5037-5045`. Three sites is enough to formalize.

**4. Add named-set aliases via `--label`.**
*File:* `CLI/c11.swift` (`runSnapshotCreate`, around the `--all` branch at `3281-3318`), `Sources/WorkspaceSnapshotStore.swift` (a small helper for symlinking).

`c11 snapshot --all --label "pre-trident-review"` writes the manifest to `sets/<set_id>.json` (current behaviour) *and* a symlink `sets/pre-trident-review.json -> <set_id>.json`. Then `c11 restore pre-trident-review` Just Works through the existing polymorphic dispatch (the label resolves through `setManifestExists(id:)`).

*Why high-value:* Drastically improves snapshot ergonomics. Memorable names beat ULIDs every time. Implementation cost is small — symlinks are filesystem-native.

*Risks:* Label collisions, label safety (need the same `isSafeSnapshotId` regex). The symlink is a soft pointer — if the underlying ULID file is deleted, the alias breaks. Acceptable: matches `git tag` semantics.

❓ Needs exploration — verified the polymorphic dispatch in `CLI/c11.swift:3434-3439` and `isLocalSnapshotSetId` predicate at `3544-3555`. Symlink resolution under the existing `assertPathUnderSnapshotRoots` (`WorkspaceSnapshotStore.swift:420-436`) does the right thing because it normalizes via `resolvingSymlinksInPath`. So the security boundary holds. The actual implementation is straightforward; the "needs exploration" is around UX (what if a label and a set_id collide?).

### Strategic

**5. Add a `## Seed` section to the Markdown blueprint schema.**
*File:* `Sources/WorkspaceBlueprintMarkdown.swift` (parser + writer).

Optional second fenced codeblock under a `## Seed` heading containing shell snippets to run once on first creation (not on restore). The parser already walks headings looking for `## Layout`; an analogous walk for `## Seed` is mechanical. The seed runs through `command:` synthesis in the executor — keep the per-surface `command:` field as the surface-level analog; the `## Seed` block is workspace-level.

*Why strategic:* Turns blueprints from "layouts" into "bootable working environments." Skills can ship recipes that just *work*, not "this is the layout, now `npm install` yourself."

*Risks:* Security — running shell snippets from a blueprint is exactly the kind of thing an attacker would want. Mitigations: (a) only run on `workspace new`, never on `restore`; (b) prompt the operator the first time a blueprint with a `## Seed` block is applied; (c) per-blueprint allowlist stored under `~/.config/c11/blueprint-trust/`.

❓ Needs exploration — the security envelope is non-trivial. Worth prototyping behind a feature flag.

**6. Promote `c11 workspace snapshot` and `c11 workspace restore` as the canonical forms.**
*File:* `CLI/c11.swift` (the `case "workspace":` block at `1908-1939`).

The two-level dispatch is already in place; add `snapshot` and `restore` as subcommands that delegate to the existing `runSnapshotCreate` / `runSnapshotRestore`. Keep the top-level `c11 snapshot` and `c11 restore` as aliases (existing behavior), document the canonical forms in `--help`. Same model as `apply` / `workspace-apply`.

*Why strategic:* As CMUX-37's blueprint+snapshot story matures, the noun-first grammar pays back compounding interest. New operators learn one prefix; agents learn one dispatcher. Old operators don't break because the aliases stay.

*Risks:* Help-text sprawl. Mitigation: the `subcommandUsage` function already groups by command — extend it cleanly.

✅ Confirmed — verified the two-level dispatch at `CLI/c11.swift:9187-9273` and the per-subcommand routing at `1908-1939`. The seam is in place; this is just adding more spokes.

**7. Add `parent_set_id` and `lineage` fields to the snapshot-set envelope.**
*File:* `Sources/WorkspaceSnapshotSet.swift` (envelope schema), `Sources/TerminalController.swift:4796-4818` (the manifest-write site populates `parent_set_id` from a new optional `params["parent_set_id"]`).

Two additive optional fields:
- `parent_set_id: String?` — when this manifest was created by a restore-from-set followed by a re-capture, points at the set restored from.
- `lineage: String?` — free-form label (`"main"`, `"experiment-a"`).

A `c11 snapshot --all` after `c11 restore <set-id>` automatically threads `parent_set_id` (the CLI knows which set it just restored). Now the manifest history is a DAG.

*Why strategic:* Sets up the time-travel UX. `c11 list-snapshots --sets --tree` becomes a real thing. Branch/clone semantics fall out of the data model.

*Risks:* Schema bloat if not used. Mitigation: optional fields, default null, never emitted unless populated.

❓ Needs exploration — the data model addition is trivial; the CLI plumbing for "remember the last restored set" is moderately fiddly. Probably wants a session-lifecycle store under `~/.c11-snapshots/.session/`.

### Experimental

**8. `c11 workspace export-blueprint --watch` for live blueprint mirrors.**
Re-emit on every workspace mutation (subscribing to existing TabManager / Bonsplit change events). Dump destination is the named blueprint file. Consumers: Obsidian renderers, file-system watchers, debug skills. Cost: moderate — needs a debouncer and a teardown when the workspace closes. Payoff: massive for skill authors who want live introspection.

**9. Polymorphic-id registry interface.**
Promote `isLocalSnapshotSetId`, `setManifestExists`, and any future `blueprintExists(name:)` into a `c11ID` registry that classifies any string into `{snapshot, set, blueprint, session, unknown}`. `c11 inspect <id>` becomes the catch-all. Cost: a 50-line file. Payoff: every new noun in the persistence layer slots into one place.

**10. Bundled `c11 blueprint lint` command.**
Read a `.md`, parse it, validate, print warnings (e.g., "split has uneven children counts," "absolute path doesn't expand under home"). Becomes the agent's debugging tool when authoring blueprints by hand. Builds on the existing `WorkspaceBlueprintMarkdown.parse` error surface — the errors are already typed; a CLI subcommand around them is a few hours of work.

**11. Markdown blueprint as `c11 send` payload.**
The mailbox / `c11 send` story already moves messages between agents. Letting one agent send another a blueprint to apply ("here, work in this room") composes mailbox + workspace persistence in a way that's basically free given everything CMUX-37 just shipped.

**12. Round-trip property test for the parser.**
`c11Tests/WorkspaceBlueprintMarkdownTests.swift` has good example-driven coverage. Add one property-style test: generate random `WorkspaceBlueprintFile` values within the supported subset (no metadata, no descriptions), serialize → parse → assert equality. Catches drift in `quoteIfNeeded` rules and YAML emission edge cases the example tests miss. Cost: trivial. Payoff: meaningful confidence boost in the parser/writer pair.

---

## Validation Pass Summary

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Promote severity to typed field | ✅ Confirmed | Single classifier site, three executor emission sites. Mechanical. |
| 2 | Ship starter blueprints in `Resources/Blueprints/` | ✅ Confirmed | `builtInBlueprintURLs()` reads both .json and .md from bundle. No code changes needed. |
| 3 | Document trusted-CLI / sandboxed-socket in CLAUDE.md | ✅ Confirmed | Three socket sites already enforce; a doc-only addition. |
| 4 | `--label` for snapshot sets | ❓ Needs exploration | Symlink security holds via `resolvingSymlinksInPath`; UX collision question. |
| 5 | `## Seed` section in Markdown blueprints | ❓ Needs exploration | Security envelope non-trivial; worth feature-flagged prototype. |
| 6 | `c11 workspace snapshot` / `restore` canonical forms | ✅ Confirmed | Two-level dispatch is already in place. |
| 7 | `parent_set_id` / `lineage` fields | ❓ Needs exploration | Schema is easy; CLI lifecycle plumbing is the real work. |

---

## The Most Exciting Opportunities

If I had to pick three for the operator to put on the radar:

- **The Markdown blueprint format becoming an agent-authoring substrate.** The infrastructure is there; what's missing is documentation, starter examples, and the `## Seed` extension. Each is small. Together they make c11 the only multiplexer where a skill can ship its room.
- **Polymorphic IDs as the unification layer.** Right now restore-by-id quietly disambiguates set vs single. The same mechanism extends to blueprints, sessions, and any future noun. It costs nearly nothing to formalize and pays off every time a new artifact type ships.
- **Structured failure severity replacing substring matching.** This is the cleanest small refactor in the PR's blast radius. It eliminates a documented fragility, frees the executor to localize messages, and turns `info:` from a smoke-test patch into a first-class output channel.

The PR closes five smoke-test gaps cleanly. The latent shape underneath is more interesting than the gap-fix framing suggests — c11 is quietly building a configuration-as-code substrate that points somewhere worth pointing.
