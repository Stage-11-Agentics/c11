# C11-253 / C11-256

Current main: c3dc4a8bc2. C11-315 moved native tests to ci-hourly.yml; cheap PR CI stays Ubuntu-only. Latest hourly run 37044770017 (bc915d0509) reports 43 failures, plus scraper crashes in its log. The old count/location are historical.

1. Inventory every failing method from the latest hourly log and compare its fixture/expectation with current implementation. Repair stale fixtures/assertions; delete obsolete/flaky cases per Atin's rule. Fix small real defects in scope; route larger product defects to their owning ticket with DECISION rather than silently hiding them.
2. Make the host step in .github/workflows/ci-hourly.yml gating. Keep only individually named, commented environment exclusions, including the existing seven C11-109 class skips, with reasons and ownership. Document triage in notes/c11-253-host-test-triage.md. No growth-baseline workaround.
3. Add executable Codex resume and peer agent-wrapper checks to .github/workflows/ci.yml on Ubuntu, without secrets, privileged triggers, remote hosts, or fork restrictions. Run these lightweight synthetic checks locally.
4. Provision both submodules and SHA-keyed GhosttyKit; run host baseline and the final retained host suite on Atlas only using tag c11-253. Run targeted repaired classes as needed; record actual TEST SUCCEEDED/FAILED and exact source/overlay identity. Do not launch a laptop app.

Acceptance: the observed masked host failures are individually accounted for; retained host tests pass and the workflow propagates xcodebuild failure. The observed Codex argv-check drift is covered by a normal fork-safe PR check. Native proof is the Atlas XCTest action, plus exact-head cheap GitHub CI. Validator scenario: manually run CI hourly at merged main; host step must succeed, and an injected failing retained assertion must make the run red (in an isolated validation branch, no release workflow).

No new runtime behavior planned: no hot-path/threading, localization, persistence, schema, skill, release, submodule-pointer or production change. One branch/draft PR covers both tickets. No open decisions yet. Independent review and merge belong to Orchestrator/Merge Captain. Push only at handoff.
