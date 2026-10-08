# Owner: C11-320 (README for 1.0)

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you (Codex GPT-6-Luna max, fast mode off).

- Worktree from current origin/main (fetch first): `git -C /Users/atin/Projects/Stage11/code/c11 worktree add -b c11-1.0/C11-320-readme /Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-320 origin/main`. Docs only: no submodules, no build.
- Actor `agent:luna-320`; tab title `C11-320 README`. `lattice show C11-320` is the spec (scope 1-5).
- **Ground every claim in the code and docs on main** (`skills/c11/SKILL.md` and its references, `docs/`, the CLI's `--help`). Vocabulary is window → workspace → area → tab. No claim the 1.0 build does not ship. Voice per `docs/c11-voice.md` and `/Users/atin/Projects/Stage11/company/brand/brand-voice.md`; no em-dashes; short sentences.
- **Phase 1 (now):** write the text. Put image placeholders as `<!-- SCREENSHOT: <what it shows> -->` and a walkthrough-video slot for C11-124.
- **Phase 2 (only after the Orchestrator sends `VM OK 320`; until then, no VM):** capture 3 to 5 screenshots from the existing tagged build `signoff-1-1` on Atlas (`~/c11-builds/signoff-1-1`; do NOT build) in one Atlas-local guest (`C11_SANDBOX_HOST=local scripts/sandbox-up.sh` run on Atlas from `~/c11-builds/signoff-1-1/source`, guest `c11-sb-c11-320-01`). Synthetic content only, no credentials, nothing personal on screen. Optimise PNGs (each under 400 KB) into `docs/images/readme/`. Never use Hyperion's screen.
- Time-box: text 60 minutes; screenshots 45. Over either: send BLOCKED.
- Open a PR at handoff (docs only; no product change). `c11 send --workspace workspace:11 --tab tab:210 "HANDOFF C11-320 REVIEW <head> <PR>" && c11 send-key --workspace workspace:11 --tab tab:210 enter`. If phase 1 is done before VM OK arrives, hand off the text-only PR and say screenshots follow.
