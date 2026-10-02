# C11-322: Sandbox agents: run logged-in Claude, Codex and Grok tabs inside the Atlas sandbox for live proofs

Atin, 2026-10-02 (after the C11-257 run): live proofs that need real agents run in an Atlas sandbox guest, not on Hyperion. In C11-257 every live proof (Claude, Codex and Grok tabs receiving mail while waiting and busy) ran in tagged builds on Hyperion. The screen locked twice and stalled them (ghostty cannot create surfaces under a locked screen), tagged apps came to the front once, and the builds loaded the laptop. The C11-244 sandbox (`scripts/sandbox-up.sh`, a headless Tart macOS guest on Atlas) already runs a tagged c11 for clicks, screenshots and tests_v2; it does not yet run logged-in agents.

Goal: an orchestrator or lane owner can launch Claude Code, Codex and Grok agent tabs inside a sandbox guest's c11, drive them through the guest's c11 CLI over SSH, and read their screens, with nothing launched on Hyperion.

Scope:
1. Confirm the guest presents an unlocked Aqua session where c11 creates terminal surfaces (the C11-244 phase 2 probe), if not already recorded.
2. Agent CLIs in the guest: `claude`, `codex`, `grok` installed in the golden image (pinned versions recorded), or installed per clone if the image should stay minimal.
3. Credentials, never baked into the golden image: injected into each clone at `sandbox-up` from a mode-600 store on Atlas and destroyed with the clone. Decision for Atin before building: which identities. Our default is org-owned service identities over personal logins (Stage11 CLAUDE.md); list what each harness accepts headlessly (Claude long-lived token, Codex auth file or API key, Grok API key) and the cost of each.
4. A script, e.g. `scripts/sandbox-agent.sh <run-id> <kind> <brief-file>`, that launches an agent tab in the guest's c11 with the brief delivered as a file pointer, plus a read-screen helper. No focus or activation on the host.
5. Proof: rerun C11-257 sign-off steps 3-8 inside one guest (mail to a waiting and a busy Claude, Codex and Grok; the operator-draft step through the c11 seam), with Hyperion idle throughout.
6. Teach it: c11-hotload / c11-computer-use skills and the orchestrator delivery reference say live agent proofs run in the sandbox, with the command; sync installed skills.

Out of scope: a self-hosted GitHub runner (Atin, 2026-10-02: CI stays on GitHub-hosted runners).
