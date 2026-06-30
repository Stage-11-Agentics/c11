# Bug B — Agent Skills onboarding sheet re-fires on every launch

## Symptom
On a non-dev **Release** build (v0.55.0 staging, `com.stage11.c11.staging.rel.v0.55.0`),
the **c11 Agent Skills** onboarding sheet appears on **every** launch. The header is the
celebratory *"Your agent is current with c11. / Every detected agent has the latest c11
skill set,"* most rows read **"Already current,"** but exactly one row reads **"Will update
the installed skill."** The primary button is **"Done."** Clicking **Done** and relaunching
shows the identical sheet again — it never stops, even though nothing on disk changed.

## Root cause — a predicate mismatch between the auto-show gate and the sheet

Two predicates disagree about whether a skill row in state `.installedNoManifest` or
`.schemaMismatch` is "something to act on":

1. **The auto-show gate** — `AgentSkillsOnboarding.shouldPresent()` (the
   `applicationDidBecomeActive` trigger) iterates each detected target's package statuses and
   calls `shouldRowOffer(status)`, which returns **true** for
   `.notInstalled`, `.installedOutdated`, `.installedNoManifest`, **and** `.schemaMismatch`.
   For any such row with no matching hash-pinned dismissal, `shouldPresent` returns `true`
   and the sheet auto-pops.

2. **The sheet's "actionable" predicate** — the view's `hasActionNeeded` is driven by
   `TargetRow.needsInstallOrUpdate`, which only counted `.notInstalled` and `.installedOutdated`
   (and excluded shared destinations). It did **not** count `.installedNoManifest` or
   `.schemaMismatch`.

So a detected target whose only non-current package is `.installedNoManifest` or
`.schemaMismatch` lands in a contradictory state:

- The gate **offers** it (`shouldPresent == true`) → the sheet auto-shows.
- The sheet thinks nothing needs action (`hasActionNeeded == false`) → it renders its
  **celebratory** branch: header "…is current with c11", primary button **"Done"**, and the
  row's checkbox is **disabled** (`.disabled(!row.detected || !row.needsInstallOrUpdate)`).
  The row still shows **"Will update the installed skill"** because the label uses
  `row.hasOutdated`, which *does* include `.installedNoManifest`/`.schemaMismatch`.

Clicking **Done** runs `activatePrimaryAction()` → celebratory branch → `onDismiss()` **only**.
It does not install, does not call `recordDismissalsForUncheckedRows` (the hash-pinned
persistence the "Later" and "Update selected" paths use), and does not even set the in-memory
`markDismissedThisLaunch()` flag. Nothing is persisted.

Next launch, `shouldPresent` sees the same offerable row with no stored dismissal → returns
`true` → the sheet re-fires. Forever. The operator has no way out: the checkbox is disabled,
and the only button is a "Done" that fixes nothing. This is exactly "hit Done, relaunch, same
sheet, nothing changed."

### Why it surfaced in v0.55 staging but is pre-existing
The bug is latent until an operator has a skill on disk in `.installedNoManifest`
(directory present but no `.c11-skill.json` marker, or an undecodable / package-name-mismatched
marker) or `.schemaMismatch` (marker present but an older `schema` version). That happens
naturally after upgrading across a marker-schema bump, or when a skill folder was hand-copied.
The v0.54 "stops over-firing" work added hash-pinned dismissal persistence to the **Later** and
**Update selected** paths, but the **celebratory Done** path was never wired to persist
anything — and the row-class mismatch is what funnels these rows into that path. It predates
v0.55.

## Fix
Make the sheet's actionable predicate share the gate's offer predicate as a single source of
truth, so they can never disagree:

```swift
var needsInstallOrUpdate: Bool {
    // Single source of truth with the auto-show gate: a row is actionable iff
    // the gate (AgentSkillsOnboarding.shouldRowOffer / shouldPresent) would offer
    // any of its packages. Keeps shared destinations non-actionable.
    !isSharedDestination && packages.contains { AgentSkillsOnboarding.shouldRowOffer($0) }
}
```

Effect on the repro: a `.installedNoManifest` / `.schemaMismatch` row now makes
`hasActionNeeded == true`, so the sheet renders its **non-celebratory** branch — header "Your
agent already knows c11," an **enabled** checkbox, and an **"Update all" / "Update selected"**
button. Clicking it calls `model.install(force: true)`, which replaces the directory and writes
a fresh schema-current manifest → `.installedCurrent`; the install result lists it under
`refreshed`, which calls `clearDismissal`. Next launch the gate sees `.installedCurrent`
(`shouldRowOffer == false`) → no re-fire. If the operator instead clicks **Later** or **Don't
ask again**, those paths already persist a hash-pinned dismissal / global opt-out, so they
suppress re-fire too.

Because owner/shared rows that point at the same directory share the same on-disk state, any
offerable shared row always has a non-shared owner row in the same state — so unifying the
predicate also guarantees the celebratory branch is only ever reached when there is genuinely
nothing offerable (all `.installedCurrent`), where "Done" doing nothing is correct.

## Regression test
`AgentSkillsOnboardingDefaultOptInTests` (c11LogicTests target):
- A detected, non-shared row whose only package is `.installedNoManifest` (and again
  `.schemaMismatch`) must report `needsInstallOrUpdate == true` and make
  `AgentSkillsOnboarding.shouldOffer(for: rows) == true`.
- Structural invariant: for **every** `SkillInstallerState` the gate would offer
  (`shouldRowOffer == true`), a detected non-shared single-package row in that state must be
  `needsInstallOrUpdate == true`. This pins the two predicates together so they cannot drift
  apart again.
