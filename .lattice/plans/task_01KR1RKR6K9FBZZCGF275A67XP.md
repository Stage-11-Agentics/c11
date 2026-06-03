# C11-34: Debug-bundle isolation: legacy-prefs migration masks TCCPrimer + welcome on dev builds

## Problem

`AppDelegate.migrateLegacyPreferencesIfNeeded` (Sources/AppDelegate.swift:2314) copies all keys from legacy bundle ids (`ai.manaflow.cmuxterm`, `com.cmuxterm.app`) into the current bundle's UserDefaults on first launch. On a dev machine with cmuxterm history, this carries `cmuxWelcomeShown=1` into the c11 debug bundle (`com.stage11.c11.debug`).

Then `TCCPrimer.migrateExistingUserIfNeeded` (Sources/TCCPrimerView.swift:227) sees `cmuxWelcomeShown=true` + `cmuxTCCPrimerShown=nil` and sets `cmuxTCCPrimerShown=true` — suppressing the primer on the assumption the user has already navigated TCC dialogs the old way. That assumption is wrong for the test/dev environment.

Net effect: the TCC primer never appears on tagged-build / DEV launches if cmux history exists on the machine. Same masking applies to any first-run UX gated on `cmuxWelcomeShown` (the welcome workspace itself, etc.).

Discovered by C11-16 Codex Validate (Test 1 FAIL: 'TCC primer did not appear after pre-validation reset and tagged launch'). C11-16 PR #138 documents the chain in its body.

## Fix

Gate `migrateLegacyPreferencesIfNeeded` to skip when bundle id is a debug variant (`com.stage11.c11.debug` and any future `com.stage11.c11.debug.<suffix>` pattern). Add `CMUX_DISABLE_LEGACY_MIGRATION=1` env var as an escape hatch for either direction.

Real users run Release (`com.stage11.c11`); they still get the legacy migration. Dev/test runs start with a clean profile.

## Acceptance

- DEV launches do NOT inherit legacy bundle keys; primer presents normally on a machine with cmuxterm history.
- Release launch behavior unchanged.
- Unit test for the gate-decision matrix.
- Build green.

## Out of scope

- Refactor of TCCPrimer.migrateExistingUserIfNeeded itself (the heuristic is correct for its actual inputs).
