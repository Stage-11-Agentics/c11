# C11-104: Skill install/update UX: state-aware update flow with 'Update all' default

# Skill install/update UX: state-aware update flow with "Update all" default

## Why now

The c11 skill catalog (skills/c11/, skills/c11-browser/, skills/c11-markdown/, skills/c11-debug-windows/, skills/release/, skills/c11-hotload/) is the agent's steering wheel. Per `CLAUDE.md`: "every change to the CLI, socket protocol, metadata schema, or surface model is incomplete until the skill is updated to match." That means **skill files change with effectively every c11 release** — and operators need to pick up those changes without thinking about it.

Today's failure mode (observed during v0.49.0 release):
- Operator installs c11 v0.47.0 → onboarding sheet fires → clicks "Install" → `cmuxAgentSkillsOnboardingShown` UserDefault permanently set at `Sources/AgentSkillsView.swift:881`.
- c11 v0.49.0 ships with revised skill content.
- Operator updates c11. Launch. `shouldPresent` (`Sources/AgentSkillsView.swift:1204`) short-circuits on the persistent flag BEFORE the content-status check runs. Sheet never fires. Installed skills stay at v0.47.0 content forever.

The hash-based content drift check at `Sources/SkillInstaller.swift:438-461` already knows about drift; it's just unreachable behind the dismissal flag.

## What we want — three states per (skill × target)

For each detected agent target (`.claude`, `.codex`, `.kimi`, `.opencode`) × each bundled skill package:

1. **Not installed** — no skill dir at `~/.{target}/skills/<name>/`.
2. **Installed and current** — content hash matches the bundled hash.
3. **Installed but outdated** — content hash drifted from the bundled hash. Either:
   - bundled changed (new c11 release)
   - destination changed (operator edited the local copy)

Both drift sub-cases want the same UX: prompt to refresh.

## What we want — UX

**Brain-dead default: "Update all."** The primary action button updates every detected outdated/uninstalled skill across every detected target in one click. Confirmation is per-target only if any target has been explicitly opted-out previously (see "per-target dismissed-against-hash memory" below).

The dialog must communicate each row's state clearly:
- ✓ Up to date (`.installedCurrent`) — no action
- ⚠ Update available (`.installedOutdated` with bundled drift) — checked by default, headline state
- ⚠ Local edits will be overwritten (`.installedOutdated` with destination drift, bundled matches) — checked by default, but warn explicitly
- ◯ Not installed (`.notInstalled` or `.installedNoManifest`) — checked by default for any detected target

Secondary actions: "Update selected" (legacy per-target picker), "Maybe later" (`_dismissedThisLaunch`), "Don't ask again" (permanent silence).

## Per-target dismissed-against-hash memory

Replace the single `cmuxAgentSkillsOnboardingShown: Bool` with a per-(target, skill) dismissed-against-hash store. New UserDefaults key shape:

```
c11SkillDismissals: {
  "claude.c11": "<bundled hash at dismissal time>",
  "claude.c11-browser": "<hash>",
  ...
}
```

`shouldPresent` logic: for each detected target × bundled skill, compute the bundled hash. If the dismissal store has an entry and the entry matches the current bundled hash, skip that row. If the bundled hash has changed since dismissal (or there is no entry), include the row. If any row would be included, present.

On dismissal-without-install ("Maybe later" or close): record the current bundled hash for every row the operator left in its un-actioned state.

On successful install: clear that target × skill's dismissal entry (no longer relevant).

On "Don't ask again": set a global never-show flag separate from the dismissal store — operator's explicit opt-out, honored regardless of content drift. Add a Help-menu re-enable: "Help → Re-enable agent skills install prompts."

## Acceptance criteria

- After operator installs skills at c11 v0.47.0, then updates to c11 v0.49.0 (which has revised skill content), launching v0.49.0 fires the sheet showing the changed rows as "Update available."
- After operator clicks "Update all" at v0.49.0, no further prompt until c11 v0.50.0 (or whenever content next changes).
- After operator clicks "Maybe later" at v0.49.0, sheet re-fires next launch (in-memory dismissal only).
- After operator clicks "Don't ask again," sheet does NOT re-fire even when content changes. Help menu has a re-enable action.
- After operator installs Claude only and declines Codex, Codex row's dismissal is recorded against the current bundled hash; sheet only re-fires for Codex when Codex's bundled content changes.
- Skill drift caused by operator hand-editing a local skill file is detected and offered for refresh with an explicit "local edits will be overwritten" warning on the row.
- `c11 doctor` (or a new `c11 skills status` subcommand) reports the same state model the dialog renders.

## Touch points

- `Sources/AgentSkillsView.swift` (the onboarding sheet view + `AgentSkillsOnboarding.shouldPresent` logic)
- `Sources/SkillInstaller.swift` (status + install actions; the hash machinery is already correct, but install() must clear dismissal entries)
- New: per-skill dismissal store (UserDefaults key + read/write helpers)
- New: Help menu "Re-enable agent skills install prompts" action
- Maybe: `c11 skills status` CLI subcommand for parity

## Out of scope

- Auto-install without confirmation. The skill files affect every TUI's agent behavior; install action must remain explicit per operator click.
- Migrating existing dismissals. Operators on the legacy `cmuxAgentSkillsOnboardingShown=true` flag re-see the sheet once after this lands (acceptable; one-time noise per operator).
- Skill-level granularity beyond per-skill-package (no per-file diff UI; package-level update is the unit).

## References

- v0.49.0 release retrospective conversation surfaced this. The hash-based drift detection in `SkillInstaller.status()` is correct; the gap is `shouldPresent` short-circuiting before reaching it.
- `Resources/bin/claude` wrapper precedent: c11 reaches into ~/.{target}/ only via narrow, well-defined paths. The skill install flow is that same kind of edge — keep it explicit, keep it consent-based, keep it idempotent.
