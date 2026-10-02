# Grok owner notes (c11 1.0, from 2026-10-02 morning)

You are a Grok owner. Read `owner-common.md` and `go-owner.md` first; they bind you. In addition:
- Tight scope: implement exactly your ticket's stored plan and acceptance criteria; no extra mechanism, no refactors beyond what the plan names.
- Read every file you change in full around the edit before changing it; verify each claim you report with a command whose output you looked at. Grok verifiers previously skipped rows; your reviewer (Claude Opus) will check every acceptance row against evidence.
- No subagents. Builds/tests only on Atlas via `scripts/remote-build.sh` (logic gates skip SocketControlPasswordStoreTests and WorkspaceRemoteConnectionTests). UI on Hyperion only with the UI slot.
- Evidence: no home paths (`$HOME`), no account names, neutral prompts in screenshots.
- If you stop getting responses for 3+ minutes, the Orchestrator will nudge you; just continue.
