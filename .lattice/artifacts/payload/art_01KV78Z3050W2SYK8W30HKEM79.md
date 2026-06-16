# C11-143 — Mailbox stable addressing — Plan

## Goal
Decouple the mailbox recipient address from the mutable `title`. Add `mailbox.address` /
`mailbox.role` metadata keys and `surface:<addr>` / `role:<name>` qualifier forms.
Resolution precedence: **address > role > title** (title stays the fallback). No envelope
schema change (`to` is already an opaque string). Local-first / ambiguity routing unchanged.

## Design

### Addressing model (new, shared by both resolvers)
A `to` string parses into one of:
- `surface:<addr>` → match **only** `mailbox.address == addr`
- `role:<name>`    → match **only** `mailbox.role == name`
- bare `<x>`       → precedence: surfaces with `mailbox.address == x`; else `mailbox.role == x`;
  else `title == x`

Both the cross-workspace resolver (`MailboxGlobalResolver`, CLI-side via `mailbox.resolve`)
and the per-workspace dispatcher (`MailboxSurfaceResolver` + `MailboxDispatcher`) run the
**same** selection function so global routing and local delivery agree.

### Role source decision (back-compat)
Role matching reads **`mailbox.role` only** — NOT the canonical `role` key. This keeps
bare-name resolution identical for the huge population of existing surfaces that set
`title` + canonical `role` but no `mailbox.*` identity: address/role are both absent →
precedence falls straight through to title. Role-addressing is opt-in via an explicit
`mailbox.role`. This exactly satisfies "same behavior when only titles are set."

### Inbox keying decision (scope guard)
The inbox dir stays keyed on the recipient surface's `title` (always present; it is the
inbox key on both deliver and recv sides). Stable addressing changes only *which surface*
is selected as recipient, not the on-disk inbox layout — so `recv` is untouched and a
title-only send works unchanged. A surface remains addressable iff it has a `title`
(the inbox key); `mailbox.address`/`mailbox.role` are *additional match keys*. This honors
"identity, not a routing rewrite." The headline rename-survival case (stdin delivery to a
stable address) is fully covered because stdin delivery bypasses the inbox entirely.

## Files touched
1. **`Sources/Mailbox/MailboxAddress.swift`** (new) — `MailboxAddress` (parse) +
   `MailboxIdentity` + `MailboxMatcher.select(_:from:identity:)` precedence selector.
2. **`Sources/Mailbox/MailboxSurfaceResolver.swift`** — add `address`/`role` accessors to
   `SurfaceMetadata`; add `address`/`role` (default nil) to `MailboxGlobalResolver.Surface`;
   route `resolve(name:…)` through `MailboxMatcher.select` (param keeps `name:` label, now
   accepts qualifier forms — bare names preserve exact prior behavior).
3. **`Sources/Mailbox/MailboxDispatcher.swift`** — `resolveRecipients` uses
   `MailboxMatcher.select(MailboxAddress.parse(to), …)`.
4. **`Sources/AppDelegate.swift`** — `mailboxAddressableSurfaces()` populates the new
   `address`/`role` fields from metadata.
5. **`Sources/TerminalController.swift`** — `v2MailboxResolve` candidate payload computed via
   the matcher so error candidates reflect the actual matched set.
6. **`skills/c11/SKILL.md`** — mailbox section: declare a stable `mailbox.address` once at
   orientation; document `surface:`/`role:` forms + precedence. Then
   `scripts/sync-installed-skills.sh c11` (HARD RULE).
7. **`docs/c11-mailbox-guide.md`** — addressing/precedence + qualifier forms.

## Test plan (c11LogicTests — pure logic, runs under `c11-logic`)
New `MailboxAddressTests` (parse) + extend `MailboxSurfaceResolverTests` /
`MailboxGlobalResolverTests`:
- parse: `surface:X` / `role:X` / bare / empty-after-prefix.
- precedence address > role > title (and that an explicit `surface:`/`role:` does NOT fall back).
- `surface:` matches `mailbox.address`; `role:` matches `mailbox.role`.
- bare name still matches title when no address/role set (back-compat).
- dispatcher `resolveRecipients` selects by address/role/title.
- global resolver: local-first + ambiguity still hold when matching by address/role.
Run: `xcodebuild -scheme c11-logic … test -only-testing:c11LogicTests/MailboxSurfaceResolverTests
-only-testing:c11LogicTests/MailboxGlobalResolverTests -only-testing:c11LogicTests/MailboxAddressTests`
Build CLI: `xcodebuild -scheme c11-cli build`.

## Validation
Tagged build from this worktree (`./scripts/reload.sh --tag c11-143`); two surfaces, set
`mailbox.address` on the recipient (stdin delivery), send to it, rename the recipient's
title, send again, confirm both land. Tear down tagged build after.