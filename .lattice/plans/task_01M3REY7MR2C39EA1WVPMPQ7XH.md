# C11-244 plan

Phase 1 is research only. Compare three ways to give computer-use validation its own display and cursor: a Virtualization.framework macOS guest (Tart, with Lume and UTM as the same substrate), a second local login over Screen Sharing's virtual display, and an in-session virtual display. Evidence is local probes plus vendor and Apple docs. No image download, no install, no product code.

Deliverable: `docs/c11-sandbox-research.md` on `c11-244-sandbox`, pushed, no PR. Stop for the orchestrator's go.

Phase 2, after that go: `scripts/sandbox-up.sh`, `scripts/sandbox-exec.sh`, `scripts/sandbox-shot.sh`, `scripts/sandbox-down.sh`, and a `skills/c11-computer-use` update. The script's first real run is a Ghostty-in-guest probe. Golden-image creation stays an operator step because it downloads about 25 GB. No local `xcodebuild` unless a build slot is granted.
