# C11-154: omp exact-session resume (OmpScraper + OmpStrategy)

Phase B omp (oh-my-pi). Lights up exact-session resume for the `omp` TUI on the
live scrape-capture pipeline seam landed by **C11-152**. Mirrors the codex
scrape-primary pattern: a JSONL scraper produces bounded metadata candidates,
and an `OmpStrategy` (cloned from `CodexStrategy`) resolves them to a
`ConversationRef` and emits the resume keystroke `omp --resume='<id>'`.

## Dependency check (DONE)
C11-152's seam is present in this worktree: `ScrapeCandidate` (Strategy.swift),
`applyScrape` (Store.swift), `ConversationScraper` + `ConversationScraperRegistry`
+ `ConversationFilesystem`, and the `ScrapeCapturePipeline`. Build proceeds.

## On-disk reality (verified on this machine)
```
~/.omp/agent/sessions/<cwd-slug>/<ts>_<uuid>.jsonl         ← the session transcript (metadata only is read)
~/.omp/agent/sessions/<cwd-slug>/<ts>_<uuid>/<n>.bash*.log ← per-session log subdir (MUST be skipped)
```
Example filename: `2026-06-28T00-15-25-318Z_019f0b94-be86-7000-bf88-d9b6dcae2616.jsonl`
- The `_` between the ISO-ish timestamp and the UUID is the only underscore;
  the timestamp uses dashes. So "id = substring after the LAST `_`, with
  `.jsonl` stripped" is robust.
- `019f0b94-be86-7000-bf88-d9b6dcae2616` is a UUIDv7 — version nibble `7` — but
  still 8-4-4-4-12 hex, so `isValidConversationUUID` (the shared v4-grammar
  regex) accepts it unchanged. No grammar change needed.
- The `*.log` files live in a sibling directory with **no `.jsonl` extension**,
  so the recursive walker's `extensionFilter: "jsonl"` skips them for free. A
  code comment will pin this so a future reader doesn't add redundant filtering.

## Scope (omp only)

### 1. `OmpScraper` — `Sources/Conversation/Scrapers/OmpScraper.swift` (new)
Mirror `CodexScraper`:
- `kind = "omp"`, `defaultMaxCandidates = 16`.
- `sessionsRoot()` → `<home>/.omp/agent/sessions/`.
- `candidates(cwd:)` → `filesystem.listSessionsRecursivelyByMtime(root, extensionFilter: "jsonl", max:)`.
- Per entry: strip `.jsonl`, take the substring after the **last** `_`; if no
  `_` present, reject. Validate via `isValidConversationUUID`; stamp the passed
  `cwd` onto each `ScrapeCandidate` (mirrors `CodexScraper`).
- Returns `[]` when `~/.omp/agent/sessions/` is absent.
- Privacy contract comment block (metadata only; transcript bytes never opened).

### 2. `OmpStrategy` — `Sources/Conversation/Strategies/Omp.swift` (new)
Clone `CodexStrategy` verbatim except:
- `kind = "omp"`.
- `resume(ref:)` emits `omp --resume=<quoted-id>` (i.e. `omp --resume='<id>'`)
  via `conversationShellQuote`, `submitWithReturn: true`.
- Keep the full capture filter (cwd match + mtime ≥ wrapperClaim + mtime ≥
  lastActivity) and the **ambiguity policy** (>1 candidate ⇒ `state = .unknown`,
  `diagnosticReason = "ambiguous: N candidates; chose newest"`, `resume` ⇒
  `.skip(reason: "ambiguous")`). Same placeholder / tombstone / invalid-id
  guards as codex.
- Doc comment notes omp uses UUIDv7 filenames `<ts>_<uuid>.jsonl` (the scraper
  parses the id; the strategy receives a clean id).

### 3. Registry + manifest wiring (same commit — parity test enforces it)
- `ConversationStrategyRegistry.v1` (`StrategyRegistry.swift`): append `OmpStrategy()`.
- `ConversationScraperRegistry.v1` (`ConversationScraperRegistry.swift`): append
  `OmpScraper(filesystem: filesystem)`.
- `AgentManifest.swift`: flip the omp manifest `hasConversationStrategy` →
  `true`; update the stale comment (`resume: .none` stays — no fixed-command
  fallback; the strategy owns exact resume, exactly like the codex row pairs a
  `.fixed(...)` fallback with its strategy, but omp has no documented fixed
  resume command so `.none` is correct).
- `testConversationStrategyPresenceParity` (AgentManifestTests, in c11LogicTests)
  enforces manifest↔registry agreement; flipping the flag without registering —
  or vice versa — fails it.

### 4. Tests — `c11LogicTests/OmpConversationTests.swift` (new, c11LogicTests target only)
The existing `ConversationScraperTests`/`ConversationStrategyTests` are
**c11Tests-only** (host-bound). To honor the boot directive "validate via
`c11-logic`, never the host scheme", new omp tests go in a fresh file added to
the **c11LogicTests** target (where `ScrapeCapturePipelineTests` and
`AgentManifestTests` already live and run host-free). Reuse the same `MockFS`
shape as `ConversationScraperTests`. Cases:
- Scraper: top-N by mtime; UUIDv7 id parsed from `<ts>_<uuid>.jsonl`; non-`_`
  / non-UUID filenames rejected; `.log` siblings excluded (extension filter);
  empty when dir missing; cwd stamped onto candidates.
- Strategy: single candidate after claim ⇒ `.alive`; resume emits
  `omp --resume='<id>'` with the specific id (not a `--last`-style flag);
  ambiguous (>1) ⇒ `.unknown` + `resume` `.skip`; placeholder ⇒ skip; invalid
  id ⇒ skip; `isValidId` accepts a UUIDv7.
- Registry: `ConversationStrategyRegistry.v1.contains("omp")` and
  `ConversationScraperRegistry.v1().contains("omp")` both true.

### 5. pbxproj
Add the two new `Sources/` files to the **c11** target and
`OmpConversationTests.swift` to the **c11LogicTests** target via the `xcodeproj`
Ruby gem (hand-editing pbxproj is error-prone). Gate on `xcodebuild -list` +
membership/ref counts, NOT line-by-line diff (the gem reformats; expect churn).

## Build / test / validation
- Local logic loop: `xcodebuild -scheme c11-logic ... test
  -only-testing:c11LogicTests/OmpConversationTests` and
  `-only-testing:c11LogicTests/AgentManifestTests`. NEVER the host scheme locally.
- Live exact-resume (LOAD-BEARING, gates pr_open): tagged build `reload.sh
  --tag c11-154`, launch `omp`, capture the newest
  `~/.omp/agent/sessions/<slug>/<ts>_<uuid>.jsonl` UUID (NOT the `.log` subdir),
  quit, relaunch `launch-tagged-automation.sh c11-154 --qa resume`, confirm the
  restored surface types `omp --resume=<same uuid>`. `c11 state verify` is the
  dry-run oracle.

## Review-tooling caveat (from MV, authoritative)
Headless `lattice code-review` resolves its diff against `LATTICE_ROOT` (main
checkout on clean `main`) → vacuous "Diff is empty" PASS. Do NOT trust it.
Review the real range `git -C <worktree> diff origin/main...HEAD` (own-reviewer
fallback) and attach that.

## pbxproj serial-conflict caveat (from MV)
Each exact-resume ticket adds Swift files to project.pbxproj; after a sibling
PR merges to main this branch will conflict there. Rebase onto origin/main and
re-add files via the gem rather than hand-merging. Note in PR body: branched on
C11-152's pipeline; merge after C11-152, will rebase.

## Out of scope
pi (C11-153, sibling), the shared pipeline (C11-152, dependency), any change to
`isValidConversationUUID`, any persistent writes to `~/.omp/`.

## Acceptance
- `OmpScraper` + `OmpStrategy` land, registered in both v1 registries, manifest
  flag flipped, parity test green.
- New c11-logic tests pass.
- Observed live: a quit→resume cycle types `omp --resume=<exact prior uuid>`.

## Plan-Review Cycle 1 Resolutions (AUTHORITATIVE)
Plan-review verdict: **PASS** (art_01KW8GMYD3V3FTNPGF6KMWFBZK). Three MINOR
findings, folded here:

1. **Registry membership label.** Membership checks are `contains(kind:)` (not
   positional). Already used correctly in the impl/tests — pinned so no one
   copies an unlabeled form. No change.
2. **CodexScraper source location.** The `CodexScraper` reference implementation
   (and the `ConversationFilesystem` protocol) live **inside
   `Sources/Conversation/Scrapers/ClaudeCodeScraper.swift`** (struct at line 73),
   not a `CodexScraper.swift`. `CodexStrategy` is in `Strategies/Codex.swift`.
   Documentation pointer only; new `OmpScraper.swift` / `Omp.swift` are correct.
3. **Cross-project ambiguity (cwd in slug, discarded by the codex mirror).** omp
   stores `~/.omp/agent/sessions/<cwd-slug>/<ts>_<uuid>.jsonl`, so cwd is in the
   path; the codex-mirror walk stamps the *passed* surface cwd onto every
   candidate, making the strategy's cwd filter a no-op for omp — **mtime is the
   only cross-project disambiguator**. This is *safe by default* (the inherited
   `>1 ⇒ .unknown ⇒ resume .skip("ambiguous")` policy yields a MISSED resume,
   never a WRONG one) and is exactly what the ticket asked for ("walk
   recursively", "mirror CodexStrategy"). RESOLUTIONS:
   - **(a) LOAD-BEARING for validation:** run the live exact-resume check in a
     **clean/dedicated cwd** (a fresh slug with exactly one recent omp session)
     so a single unambiguous candidate survives the mtime floor — otherwise the
     safe-by-default skip can make a correct implementation *look* broken.
   - **(b)** Note in the PR body that scoping the recursive walk to the
     surface's cwd-slug subdirectory is a lossless future precision enhancement
     unique to omp's layout, deliberately deferred to stay in "mirror codex"
     scope. No code change this ticket.
