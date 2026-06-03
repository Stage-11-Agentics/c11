# C11-33: Legacy-migration masks TCC primer on dev machines with cmux history

Discovered while validating C11-16 (Runtime-detect FDA grant and auto-continue the TCC primer).

## Root cause

\`migrateLegacyPreferencesIfNeeded\` in \`Sources/AppDelegate.swift:2354\` copies all 60 keys from legacy \`com.cmuxterm.app\` (and \`ai.manaflow.cmuxterm\`) into the current bundle id on every fresh launch where the v1 migration flag isn't set yet. This includes \`cmuxWelcomeShown=1\` on any developer who has used cmux before.

\`TCCPrimer.migrateExistingUserIfNeeded\` (Sources/TCCPrimerView.swift:271) then sees \`cmuxWelcomeShown=1\` and \`cmuxTCCPrimerShown=nil\`, sets \`cmuxTCCPrimerShown=true\`, and the primer never presents on subsequent launches.

## Impact

On any developer machine with cmux history (i.e. essentially every Stage 11 developer machine, plus every fresh tagged build via \`./scripts/reload.sh --tag <name>\`), the TCC primer is masked. This means:

- C11-15's primer flow cannot be exercised end-to-end on a tagged build without manual workarounds.
- C11-16's auto-continue flow cannot be validated via Codex computer-use without manual workarounds.
- The 'fresh-install' UX path is effectively untestable on dev machines.

A fresh tagged-build domain is supposed to be like a fresh install for testing purposes. The legacy migration is well-intentioned (don't surprise long-time cmux users with a retroactive primer) but it conflates 'returning user on the same domain' with 'fresh-install on a new tagged-build domain'.

## Suggested fix

Either:
1. Skip \`migrateLegacyPreferencesIfNeeded\` entirely when the bundle id is a tagged-build variant (\`com.stage11.c11.debug.<tag>\`). Tagged builds should always behave like fresh installs.
2. Skip \`migrateExistingUserIfNeeded\`'s \`cmuxWelcomeShown→cmuxTCCPrimerShown\` migration on tagged variants for the same reason.
3. Don't migrate \`cmuxWelcomeShown\` from legacy domains specifically — let the welcome workspace assemble fresh on a brand-new tagged build, then the new domain gets its own \`cmuxWelcomeShown=true\` after the user's first welcome.

Option 3 is the lightest touch: targeted skip of one key in \`migrateLegacyPreferencesIfNeeded\`, keeps every other preference migration intact.

## Workaround for re-validation

\`defaults delete com.cmuxterm.app cmuxWelcomeShown\` before launching any tagged build. OR \`defaults write com.stage11.c11.debug.<tag> cmuxTCCPrimerShown -bool NO\` before launch (pre-empts the migration's nil-guard).

## Discovered in

C11-16 overnight delegation. See PR #138 body + Lattice C11-16 comment trail (2026-05-07T02:10:57Z).
