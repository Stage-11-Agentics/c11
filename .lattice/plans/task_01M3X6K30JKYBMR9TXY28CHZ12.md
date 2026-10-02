# C11-309: Tell agents that tab numbers do not survive a restart

## Incident
Agents store `tab:292` and reuse it after a restart. The number now belongs to a different tab, so a send or a close hits the wrong agent. Backlog B058. Ruling D15 keeps the numbers resetting (`upstream-triage/c11-1.0/README.md:52`, and D15 is in the Out list at `:37`). The fix is the skill. Base `0ff8887e5e`.

## What is already true
Ordinals are process-local. `v2NextHandleOrdinal` starts at 1 for window, workspace, area, and tab (`TerminalController.swift:283-288`). `v2RefByUUID` and `v2UUIDByRef` start empty (`:289-300`). `v2EnsureHandleRef` (`:2504-2517`) reuses a UUID already seen in this process, or assigns `kind:next` and increments. Nothing writes those maps to the session snapshot. A restart starts them at 1 again. A `tab:N` ref has no generation.

Stable UUIDs already exist. `c11 tree` prints them. `C11_TAB_ID` and `C11_WORKSPACE_ID` are those UUIDs. The skill tells agents to target `tab:N` (`skills/c11/SKILL.md:17`) and does not say the number dies with the process.

The ticket's cite `:2504-2516` matches this SHA. Ledger B058 cites `:279`, `:2496`, and `:2512`. The counter comment is now `:274-275`. The allocator is `:2504-2517`. The behavior is the same.

`skills/lattice-orchestrator/references/intake.md:115-116` already says refs renumber after a restart and the UUID does not. Leave that file alone.

## Change
No Swift. No change to `v2EnsureHandleRef`, the maps, or session persistence.

One short paragraph beside `skills/c11/SKILL.md:17`, after the existing ordinal sentence. Keep `tab:N` as the way to target a live tab. Say that `tab:N`, `area:N`, `workspace:N`, and `window:N` are assigned in memory and start over at launch. After a restart, store the UUID from `c11 tree` or from the environment (`C11_TAB_ID`, `C11_WORKSPACE_ID`), not the ordinal. A number from before the restart is a different tab.

The same one-sentence caveat, not a rewrite, in:

- `skills/c11/references/api.md:31` (operator-spoken numbers). Add a clause on the `C11_TAB_NUM` row at `:55` so the table does not read as a durable id.
- `skills/c11-browser/SKILL.md:43-45` (short refs, and "keep using one `tab:N` per task").
- `skills/c11-browser/references/commands.md:97` (prefer short handles).

Do not sprinkle the caveat into every example. Do not change command samples that use `tab:N` for a live process.

Voice: operator guidance. An agent that must find the same tab after a restart stores the UUID. Do not write it as a warning about hitting another agent.

## Files
- `skills/c11/SKILL.md`
- `skills/c11/references/api.md` — the ordinal paragraph only. C11-308 owns the send-key vocabulary at `:288-294`. Either PR can land first.
- `skills/c11-browser/SKILL.md`
- `skills/c11-browser/references/commands.md`

Both skills are installable (`skills/MANIFEST.json`: `c11`, `c11-browser`). `lattice-orchestrator` is installable and is not edited, so it is not synced.

## Sync
Editing the repo file does nothing to an already-installed copy. The app copies skills once and stamps `.c11-skill.json`. After the source edit, on the landing machine:

```bash
scripts/sync-installed-skills.sh c11
scripts/sync-installed-skills.sh c11-browser
```

The script mirrors `skills/<name>/` onto `~/.claude/skills/<name>/` and keeps the marker. Planning mode does not run it. Build mode runs it before the acceptance read. Do not write tenant config by hand. The sync script is the only install step.

## Acceptance
1. A reader of the repo `skills/c11/SKILL.md` and of `~/.claude/skills/c11/SKILL.md` can answer: a `tab:N` from before the restart is not the same tab, and the UUID is. The installed file matches the repo. `.c11-skill.json` is still in `~/.claude/skills/c11/`.
2. The skill still shows `tab:N` for a live tab. Ordinals still work inside one process. `git diff --name-only` against the branch base contains no `.swift` file and does not touch `TerminalController.swift`.
3. The same sentence is in the three peer spots above. `~/.claude/skills/c11-browser/SKILL.md` matches after its sync, and its `.c11-skill.json` is still there. `intake.md` is unchanged.

## Validation
The reviewer reads the files. No unit test that greps the skill. No build. No soak. The diff is the doctrine check: skill text only, no tenant config, numbers keep resetting.

## Strings
None. Skill prose is English source. No `Localizable.xcstrings` key.

## Cut
No stable numbers, no generation stamped onto an ordinal, no persisted ordinals. D15 forbids that fix. Do not land it beside the paragraph. No duplicate-id restore work (B024). No fail-closed stale refs (B066). No rewrite of the skill.

## Dependencies
None. D15 is the ruling, not a ticket. Shared file `skills/c11/references/api.md` with C11-308: disjoint paragraphs (`:31` here, `:288` there).

## Branch
Build mode, from `origin/main`: `c11-1.0/C11-309-tab-ref-restart`.

## Decisions
None. Skill text is the ruling.


## Build-mode validation and installed-copy concurrency
Codex started the ticket from fetched origin/main 9b1380e08fc09eeede96a6fa5d491648ee8cfe86 after Orchestrator NEXT C11-309, with C11-279 parked until C11-284 lands. Four source files only, one documentation commit. No build or source-grep regression test. The wording says a saved ordinal *can* name a different object, rather than claiming it always does. The UUID lookup example requests both refs and UUIDs explicitly.

Both required sync scripts run after commit, followed by byte comparison of all four edited installed files and marker-content comparison. Concurrent installed copies already contain pending C11-284 guide, workspace-folder and browser-crash-probe additions; restore only those named blocks after sync so this lane does not erase peer guidance. Verify every new restart sentence still exactly matches source, and both installation markers remain unchanged. Record the exact-copy match at sync time separately from the final combined installed state; final c11 and browser commands documents additionally retain those peer sections. Landing sync must use the combined merged source.

## Reset 2026-10-02 by agent:codex-cli
