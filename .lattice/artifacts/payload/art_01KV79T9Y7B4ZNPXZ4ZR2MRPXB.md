# Code Review: C11-143 — Mailbox stable addressing

## ⚠️ Important: the diff embedded in the review prompt is the wrong diff

Before the verdict, a process finding that determines what was actually reviewed:

The "Diff" block in the prompt does **not** contain the C11-143 stable-addressing
work. It contains the changes from **PR #252** ("Mailbox: de-silence cross-workspace
seam — trace/fallback/content_type", commit `5c9cbe70e`): the `content_type` 128-byte
cap, the `verified`-send tuple, and the global `mailbox trace` scan. That commit is
already merged to `origin/main`. None of the prompt's diff touches `mailbox.address`,
`mailbox.role`, a resolver, or the `surface:`/`role:` qualifiers the task is about.

The real C11-143 deliverable is the three commits on the branch on top of `origin/main`:

```
4a31f1733 Mailbox: document stable addressing in c11 skill + mailbox guide
42c0825ff Mailbox: tests for stable-addressing resolution (address > role > title)
26962f335 Mailbox: stable addressing — mailbox.address/role, decouple from mutable title
```

`git diff origin/main..HEAD` (9 files: `MailboxAddress.swift` [new], `MailboxSurfaceResolver.swift`,
`MailboxDispatcher.swift`, `AppDelegate.swift`, `TerminalController.swift`, `project.pbxproj`,
`MailboxSurfaceResolverTests.swift`, `docs/c11-mailbox-guide.md`, `skills/c11/SKILL.md`).
**I reviewed that real diff from the branch directly**, not the prompt's stale diff.
Whoever generates these review prompts should fix the diff range (it appears to have
captured `local-main..HEAD` minus the new commits, or simply the prior PR) — a reviewer
who rubber-stamped the embedded diff would have reviewed already-merged code and let the
actual C11-143 work through unreviewed.

---

### 1. Verdict

**PASS** — The actual stable-addressing implementation is correct, matches the plan,
meets every acceptance criterion, and is well tested (40 mailbox tests, all passing
locally on the `c11-logic` scheme; target compiles clean). Only minor, non-blocking
observations follow.

### 2. Summary

C11-143 introduces a stable, rename-proof addressing layer over the mailbox `to` field
without an envelope schema change. A new pure module (`MailboxAddress` / `MailboxIdentity`
/ `MailboxMatcher`) parses `to` into `surface:<addr>` / `role:<name>` / bare-name forms
and applies **address → role → title** precedence; both the per-workspace dispatcher and
the cross-workspace resolver route through the *same* `MailboxMatcher.select`, so local
delivery and global routing can never disagree on who a `to` resolves to. The quality is
high: clean separation, careful back-compat, an honest empty-payload edge contract, and
comprehensive tests. The headline issue is process, not code — the review prompt shipped
the wrong diff (see above).

### 3. Issues

**[MINOR] Sources/Mailbox/MailboxAddress.swift:35 — `surface:`/`role:` are reserved title prefixes; a surface titled `surface:x` is unreachable by bare name**
`parse` treats *any* `to` beginning with `surface:` or `role:` as a qualifier. A surface
whose **title** literally is `surface:foo` (or `role:bar`) can no longer be reached by a
bare `--to surface:foo` — it parses as a `surface` qualifier and matches `mailbox.address`,
not the title. Realistically rare (titles are names like `builder`/`delegator`/ticket ids,
not colon-prefixed with these two exact schemes), and arguably correct behavior, but it's
an undocumented reserved-namespace carve-out.
**Fix:** Add one line to the Addressing section of `docs/c11-mailbox-guide.md` noting that
`surface:` and `role:` are reserved leading tokens in `--to`. No code change needed; the
test `testParseNameContainingColonIsBareUnlessKnownScheme` already locks in that other
colons stay bare.

**[MINOR] Sources/Mailbox/MailboxSurfaceResolver.swift:39 — `surfaceIds(forName:)` is now dead in the production path**
Recipient routing moved to `MailboxMatcher.select` (in `resolveRecipients`), so
`surfaceIds(forName:)` is referenced only by its own unit tests now (`grep` confirms no
production caller). It predates this change, but this diff is what orphaned it from the
live path.
**Fix:** Optional — delete `surfaceIds(forName:)` and its five tests, or leave a one-line
comment that it's a test-only helper. Not blocking; harmless dead code.

**[MINOR / process] skills/c11/SKILL.md — installed-skill copy must be synced or agents keep loading the old guidance**
Per this repo's HARD RULE (CLAUDE.md: "Editing a skill source is incomplete until the
installed copy is synced"), the new "Stable addressing" section in `skills/c11/SKILL.md`
does nothing for any machine where the `c11` skill is already installed until someone runs
`scripts/sync-installed-skills.sh c11`. This can't land in a commit, so it won't show in a
diff — but it's a required step for the "agents declare a stable address once at orientation"
half of the deliverable to actually reach agents.
**Fix:** Maintainer runs `scripts/sync-installed-skills.sh c11` on their machine and the
change is noted on the release/landing checklist.

**[OBSERVATION — not a defect] Inbox delivery is still keyed on the recipient's title**
`MailboxDispatcher.copyToInbox` keys the inbox directory on `recipient.name` (the title),
which is correct and in-scope: the deliverable explicitly keeps the inbox title-keyed and
makes *resolution* rename-proof, and that is exactly what the acceptance criterion ("send
to a stable address survives a recipient tab-rename") tests. Worth stating plainly so the
feature isn't over-read as fully rename-proof *delivery*: a recipient that renames its tab
in the window between an envelope landing in its title-keyed inbox and draining it can still
orphan that message in the old-title directory. That race is pre-existing, untouched by this
change, and squarely outside the "identity, not a routing rewrite" scope guard — flagging
only so it isn't mistaken for something this PR closed.

### 4. Positive Observations

- **One matcher, two callers — no routing drift.** The single biggest correctness win:
  `MailboxDispatcher` (local delivery), `MailboxGlobalResolver` (cross-workspace), and the
  `mailbox.resolve` socket handler in `TerminalController` all run the *same*
  `MailboxMatcher.select`. Local and global routing are structurally incapable of
  disagreeing on who `to` resolves to. The file-level doc comment on `MailboxAddress` calls
  this out explicitly. Exactly the right shape for a "foundation" mutation that everything
  else sits on.
- **Generic, pure selector.** `MailboxMatcher.select<Item>(_:from:identity:)` with an
  `identity` closure keeps the precedence logic in one tested place and lets each resolver
  supply its own candidate type. Pure, no store, trivially testable.
- **Back-compat handled deliberately, not accidentally.** Defaulted `address`/`role` in
  `MailboxGlobalResolver.Surface.init` (existing call sites compile untouched),
  `MailboxIdentity.nonEmpty` normalization so blank metadata never matches a blank query,
  and the intentional decision that `mailbox.role` does **not** fall back to the canonical
  `role` key — with `testSurfaceMetadataRoleDoesNotFallBackToCanonicalRole` locking that in
  so a future refactor can't silently re-partition title-only surfaces.
- **Honest empty-payload contract.** `surface:` / `role:` with an empty payload resolves to
  "matches nothing" rather than degrading to a bare name that could hit a real title —
  documented in code and covered by `testParseEmptyPayloadAfterPrefixIsHonored` /
  `testMatcherEmptyPayloadMatchesNothing`.
- **Test coverage maps cleanly onto the acceptance criteria.** 40 passing tests covering
  precedence (`testBareNamePrefersAddressOverTitle`, `…PrefersRoleOverTitle`, `…AddressBeatsRole`),
  qualifier isolation (`testSurfaceQualifierMatchesAddressOnly`, `testRoleQualifierMatchesRoleOnly`),
  preserved local-first/ambiguity (`testRoleAddressLocalFirstWins`,
  `testSurfaceQualifierAcrossWorkspaceIsAmbiguousWhenSplit`), back-compat
  (`testBareNameFallsBackToTitleWhenNoStableIdentity`), and edge cases. I ran them:
  `Executed 40 tests, with 0 failures` → `** TEST SUCCEEDED **`.
- **Docs + skill earn their keep.** The Addressing precedence table, the orientation
  `set-metadata` snippet, and the orthogonal-axis framing (`surface:`/`role:` select *which
  surfaces*, `--to-workspace` selects *which workspace*) are clear and match the code. The
  "no schema change — `to` stays opaque" claim is verified: `MailboxEnvelope` validates `to`
  only for non-empty + 256-byte cap, so the colon forms pass without any envelope change.

---

**Bottom line:** Approve the C11-143 branch work as implemented. The code is clean,
correctly scoped to identity-not-routing, fully back-compatible, and well tested. Address
the two MINOR doc/dead-code notes at leisure, run the skill-sync step before relying on the
new orientation guidance, and — most importantly — fix the review-prompt diff generator so
the next reviewer isn't handed the previous PR's diff.
