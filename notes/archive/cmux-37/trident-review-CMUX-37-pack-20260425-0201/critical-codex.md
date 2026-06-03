## Critical Code Review
- **Date:** 2026-04-25T06:34:10Z
- **Model:** Codex (GPT-5)
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8b153
- **Linear Story:** CMUX-37
- **Review Type:** Critical/Adversarial
---

## The Ugly Truth

This branch is close in shape, but it is not production-ready. The biggest problem is that Phase 5 ships restart commands without proving they are valid for the actual CLIs. That is exactly the kind of "best-effort" code that turns resume into a broken automation loop. There are also feature-completeness holes in the new blueprint picker and a documentation/schema mismatch that will cause users to author plans that silently do not do what the docs say.

I did not run local tests because `CLAUDE.md` says tests run via CI/VM only. I also did not `git pull` because this was explicitly a read-only review and pulling would mutate the worktree. Current local status is dirty from pre-existing `.lattice/*` and `notes/*` files; I ignored those and reviewed `origin/main...HEAD`.

## What Will Break

- Restored Codex terminals will not resume. The registry sends `codex --last`, but the installed Codex CLI rejects `--last` at top level; `--last` belongs under `codex resume`.
- `c11 workspace new` will not show repo-local blueprints from `.cmux/blueprints/`, even though the store and feature description say repo blueprints are a priority source.
- Users following `docs/workspace-apply-plan-schema.md` will write snake_case keys such as `working_directory`, `file_path`, and `pane_metadata`; the implementation decodes camelCase keys, so those values are ignored or nil.
- `c11 snapshot --all` can report success while individual workspace writes failed, because the socket returns per-item `"error"` entries inside an OK envelope and the CLI ignores them.

## What's Missing

- No test proves the restart commands are accepted by the installed agent CLIs, or at least matches documented command syntax.
- No CLI/socket test covers `workspace new` discovering repo-local blueprints from the caller's current directory.
- No test exercises `snapshot --all` partial write failure behavior.
- No artifact-level validation catches the docs/schema mismatch for the newly added schema doc.

## The Nits

- `c11 snapshot --help` still omits `--all`, so the new flag is discoverable only from code or release notes.
- `WorkspaceBlueprintIndex.Source.user` still comments `~/.c11-blueprints/`, while the implementation uses `~/.config/cmux/blueprints/`.
- The docs claim "all fields use snake_case" but the same doc also shows `surfaceIds` and `dividerPosition`; the contract is internally inconsistent.

## Findings

1. **Blocker - Codex restart command is invalid.** ✅ Confirmed

   `Sources/AgentRestartRegistry.swift:123` returns `"codex --last\n"` for every Codex surface. On this machine, `codex --last --help` exits with `error: unexpected argument '--last' found`, while `codex resume --help` documents `resume --last` as the supported form. This means any restored Codex surface using `C11_SESSION_RESUME=1` will type a command that fails immediately instead of resuming. The new test at `c11Tests/AgentRestartRegistryTests.swift:249` only locks in the wrong string, so CI can pass while the product behavior is broken.

2. **Important - Interactive blueprint picker never passes `cwd`, so repo blueprints are invisible.** ✅ Confirmed

   `Sources/WorkspaceBlueprintStore.swift:122` only includes per-repo blueprints when `merged(cwd:)` receives a non-nil cwd, and `Sources/TerminalController.swift:4472` only builds that cwd from the optional socket param. But `CLI/c11.swift:2793` calls `workspace.list_blueprints` with `params: [:]`. Result: `c11 workspace new` omits `.cmux/blueprints/` entirely and shows only user plus built-in blueprints. That breaks the advertised priority order for the most project-specific blueprint source.

3. **Important - The new schema doc tells users to write keys the decoder does not read.** ✅ Confirmed

   `docs/workspace-apply-plan-schema.md:5` says all fields use snake_case, with examples like `custom_color` and `working_directory` at `docs/workspace-apply-plan-schema.md:30`, `file_path` at `docs/workspace-apply-plan-schema.md:79`, and `pane_metadata` at `docs/workspace-apply-plan-schema.md:81`. The Codable types in `Sources/WorkspaceApplyPlan.swift:25` and `Sources/WorkspaceApplyPlan.swift:56` do not define snake_case coding keys, so the actual wire names are `customColor`, `workingDirectory`, `filePath`, and `paneMetadata`. JSONDecoder ignores unknown keys, so a doc-authored plan can apply while silently dropping cwd, markdown paths, pane metadata, and color.

4. **Important - `snapshot --all` hides per-workspace write failures behind OK output.** ✅ Confirmed

   In `Sources/TerminalController.swift:4597`, a failed write appends an entry containing `"error"` and still returns `.ok(["snapshots": results])` at `Sources/TerminalController.swift:4605`. The CLI loop in `CLI/c11.swift:2947` never checks for `"error"`; it prints `OK snapshot=? surfaces=0 workspace=... path=?`. A disk-full or permission failure can therefore look successful to scripts and operators.

5. **Potential - `snapshot --all` is implemented but absent from command-specific help.** ✅ Confirmed

   `CLI/c11.swift:2929` parses `--all`, but `CLI/c11.swift:8453` still documents `Usage: c11 snapshot [--workspace <ref>] [--out <path>] [--json]`, and the flag list at `CLI/c11.swift:8459` omits `--all`. This is not an incident by itself, but it makes the new Phase 3b behavior unnecessarily hidden.

6. **Potential - Opencode restart syntax is unverified and diverges from the supplied plan.** ❓ Likely but hard to verify

   `Sources/AgentRestartRegistry.swift:128` emits `opencode --continue\n`, while the review context says the plan expected `opencode -c` with a fresh `opencode` fallback. I could not verify opencode help because the installed command attempts to create `/Users/atin/.cache/opencode/bin` and the sandbox blocks it with EPERM. This should still be treated as suspicious: Phase 5 is typing agent commands into terminals, and at least the Codex row is already confirmed wrong.

## Validation Pass

- Re-read `AgentRestartRegistry.phase1` and ran local CLI help checks. Codex failure is real: top-level `--last` is rejected; `resume --last` is documented.
- Re-read the blueprint list flow from CLI to socket to store. There is no cwd param from the picker path, so repo discovery cannot run.
- Re-read `WorkspaceApplyPlan` Codable definitions and the schema doc. The doc's snake_case fields are not decoded by the current model types.
- Re-read socket and CLI `snapshot --all` handling. Per-snapshot write errors are returned in a success payload and ignored by the CLI printer.

## Production Call

No, I would not mass deploy this to 100k users. Fix the Codex restart command first, pass cwd through the blueprint picker, align the schema doc with the actual Codable wire format or add explicit snake_case decoding, and make `snapshot --all` fail visibly on any per-workspace write error.
