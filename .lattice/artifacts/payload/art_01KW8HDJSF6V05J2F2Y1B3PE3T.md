# Code Review: C11-154 — omp exact-session resume (OmpScraper + OmpStrategy)

**(own-reviewer fallback)** — the headless `lattice code-review` returned a
vacuous `Error: Diff is empty` because it resolves the diff against
`LATTICE_ROOT` (the main checkout on clean `main`), not this worktree branch
(the MV-flagged systemic tooling gap). This review covers the real range
`git diff origin/main...HEAD` (commit `98b1dae7e`, base `60646a3ac`).

## Verdict: PASS — no Critical or Major findings. Safe to validate + open PR.

## Scope reviewed
7 files, +441/−6: `OmpScraper.swift` (new), `Omp.swift` (new),
`OmpConversationTests.swift` (new, c11LogicTests), three one-line registry/
manifest edits, and the pbxproj wiring.

## Correctness
- **`omp --resume=<id>` is real.** Verified against the installed binary:
  `omp --help` lists `-r, --resume=<value>  Resume a session (by ID prefix,
  path, or picker if omitted)`. `OmpStrategy.resume` emits
  `omp --resume='<id>'` (single-quoted via `conversationShellQuote`), which the
  flag accepts. This is the load-bearing external assumption and it holds.
- **Id parse is robust.** `<ts>_<uuid>.jsonl` → drop `.jsonl`, take substring
  after the *last* `_`. The ISO-ish timestamp uses dashes only, so a single `_`
  separates ts and uuid; "last underscore" survives even a future ts-format
  change. No-`_` filenames are rejected (`lastIndex(of:)` returns nil →
  `compactMap` drops). A trailing-underscore filename (`foo_`) yields an empty
  id → `isValidConversationUUID("")` is false → rejected; no crash, no
  out-of-bounds.
- **UUIDv7 acceptance.** `conversationUUIDPattern` has no version-nibble
  constraint, so the v7 sample (`019f0b94-be86-7000-…`) passes unchanged. No
  grammar edit needed — confirmed against `Strategy.swift`.
- **`.log` siblings excluded for free.** The recursive walker filters on
  `hasSuffix(".jsonl")` + `isRegularFile`; the per-session `*.log` files live in
  a sibling dir with no `.jsonl` extension, so they never reach the scraper.
  Test `testOmpScraperExcludesLogSiblingsViaExtensionFilter` pins it.
- **Strategy is a faithful CodexStrategy clone.** Same cwd+mtime capture filter,
  same `>1 ⇒ state=.unknown ⇒ resume .skip("ambiguous")` policy, same
  placeholder/tombstone/invalid-id guards. Newest-first sort makes the chosen id
  deterministic. Behavior diff vs codex is exactly the resume string and `kind`.

## Safety
- **No wrong-session resume.** The ambiguity policy yields a *missed* resume
  (skip), never a wrong one — the whole point of the inherited primitive.
- **Privacy contract upheld.** Metadata-only walk; `ScrapeCandidate` is
  structurally incapable of carrying transcript bytes. No reads of file content.
- **Shell-injection safe.** Id is validated against the UUID grammar *and*
  single-quoted before interpolation (defence in depth, matching codex).

## Known limitation (documented, accepted, in-scope)
omp encodes cwd in the slug directory, but the codex-mirror walk stamps the
*passed* surface cwd onto every candidate, so the strategy's cwd filter is a
no-op for omp and **mtime is the only cross-project disambiguator**. This is
exactly what the ticket asked for ("walk recursively", "mirror CodexStrategy")
and is safe-by-default. Plan-review resolution (3b) defers cwd-slug-scoped
walking as a lossless future enhancement and (3a) requires the live validation
to run in a clean/dedicated cwd so a single unambiguous candidate exists.

## Wiring / parity
- `OmpStrategy` in `ConversationStrategyRegistry.v1`, `OmpScraper` in
  `ConversationScraperRegistry.v1`, manifest `hasConversationStrategy` flipped
  to `true` — all in one commit. `AgentManifestTests.testConversationStrategy
  PresenceParity` enforces the manifest↔registry agreement and is green.
- pbxproj: 3 file refs + build-file entries + group memberships only (+12
  lines, no gem reformat churn). `xcodebuild -list` unchanged; membership
  verified via the gem (`OmpScraper`/`Omp.swift` → c11; `OmpConversationTests`
  → c11LogicTests).

## Tests
19 c11-logic tests green (`** TEST SUCCEEDED **`): 11 omp (scraper
parse/filter/empty/cwd-stamp; strategy alive/resume-specific-id/ambiguous-skip/
placeholder-skip/invalid-skip/validId-v7; both-registry wiring) + 8 manifest
parity. The earlier red was a *test* bug (MockFS dict keyed by a flat URL vs the
scraper's trailing-slash `appendingPathComponent(isDirectory:true)` key), fixed
by building the test key identically to the scraper — the production code was
never wrong.

## Minor / nits (non-blocking)
- The MockFS-key trailing-slash trap is latent in the existing
  `ConversationScraperTests` (Claude/Codex) too; they're host-bound and not run
  in this loop, so it's invisible there. Not this ticket's fix, but worth an
  upstream note if those ever move to c11-logic.

## Remaining gate
Live exact-resume validation (LOAD-BEARING) is still required before `pr_open`:
quit→resume cycle must be **observed** typing `omp --resume=<exact prior uuid>`,
run in a clean/dedicated cwd per resolution 3a.