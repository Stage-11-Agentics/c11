# Validation plan — Exact-session resume (opencode / pi / omp)

Authored Phase 2 (Architect), while context is fresh. The Phase-4 Result Validator walks each row: pull the named PR, inspect the artifact, run the verification, record pass/fail/partial.

| # | Acceptance criterion | Ticket / PR | How to verify | Artifact to inspect |
|---|---|---|---|---|
| 1 | opencode resumes the **exact** prior session after quit+relaunch | C11-151 | In a tagged build: launch opencode, note its `ses_` id (`opencode session list`), quit c11, relaunch; confirm the restored surface types `opencode … -s <same ses_id>` and the session's `time_updated` advances. `c11 state verify` shows the opencode panel resolving to that id. | C11-151 PR diff + the live-validation `--role validation` artifact on the ticket |
| 2 | opencode id grammar accepts real base62 ids, rejects garbage | C11-151 | Unit test: `isValidOpencodeSessionId("ses_0fda89a49ffeLHwJXtrxnn4X6g")` (has `L`) == true; UUID + empty + shell-metachar == false. | `SurfaceMetadataStoreTests` / new opencode key tests, c11-logic green |
| 3 | opencode `session.created` plugin handler captures the id | C11-151 | Plugin test (bun) asserts the handler emits `c11 conversation push --kind opencode --id ses_… --cwd …` on a synthetic `session.created` event. | `skills/opencode-plugins/c11-notify.js` + its test |
| 4 | Live scrape→capture→resume pipeline works end-to-end | C11-152 | Integration test: a scraped `ScrapeCandidate` for a kind flows through `strategy.capture` → `store.applyScrape` → becomes a ref whose `strategy.resume` returns a `.typeCommand`. | C11-152 PR diff + test |
| 5 | No regression to claude/codex resume | C11-152 | Full `c11-logic` suite green (1044+); existing `ConversationStrategyTests` / `ConversationCrashRecoveryTests` unchanged-green. | CI on C11-152 PR |
| 6 | pi resumes the exact session after relaunch | C11-153 | Tagged build: launch `pi`, quit, relaunch; restored surface types `pi --session <uuid>` matching the most-recent `~/.pi/agent/sessions/<slug>/<ts>_<uuid>.jsonl`. | C11-153 PR + live-validation artifact |
| 7 | omp resumes the exact session after relaunch | C11-154 | Tagged build: launch `omp`, quit, relaunch; restored surface types `omp --resume=<uuid>` matching the most-recent `~/.omp/agent/sessions/<slug>/<ts>_<uuid>.jsonl` (scraper ignored the per-session `*.log` subdir). | C11-154 PR + live-validation artifact |
| 8 | Manifest/strategy invariant holds | C11-151,153,154 | `AgentManifestTests.testConversationStrategyPresenceParity` green: each manifest's `hasConversationStrategy` matches `StrategyRegistry.v1` after the new strategies register. | c11-logic on each PR |
| 9 | All four PRs merged to main (auto-merge policy) | all | `git log origin/main` shows the four squash-merges; `lattice list` shows C11-151..154 `done`. | main history + Lattice board |

**Overall pass condition:** rows 1–9 pass. The load-bearing rows are 1, 6, 7 — *observed* exact-session resume in a live build, not just green units. A green unit suite with no live resume evidence is **partial**, not pass.
