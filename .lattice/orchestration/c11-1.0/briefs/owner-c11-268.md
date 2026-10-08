# Owner: C11-268 (Feed: explicit guarded text replies and answer-bearing flag lowering)

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you (Codex GPT-6-Luna max, fast mode off).

- Worktree: create it from current origin/main after fetching: `git -C /Users/atin/Projects/Stage11/code/c11 worktree add -b c11-1.0/C11-268-feed-answer /Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-268 origin/main`, then provision submodules and GhosttyKit.
- Actor `agent:luna-268`; tab title `C11-268 Luna`. `lattice assign` and link the branch first.
- The ticket (`lattice show C11-268`) is the spec: acceptance 1-5. Dependencies are merged: C11-264 (Feed asks), C11-265 (attention order), C11-267 (send input guard: reuse its inspection and refusal results exactly; do not build a second guard), C11-323 (agents never change the visible workspace: `feed answer` delivers to a background tab without selecting it; its "open the tab" fallback must respect that gate).
- Answer text goes only in the documented local event channel (flag.lowered), never in the body-free analytics journal.
- **Risk list:** this types into agent prompts. Runtime proof before merge on an Atlas-built tagged app (build on Atlas; never upload the app): a real Claude prompt and a real Codex prompt receive one answer each (multiline stays one submission); a draft, a dialog and an unknown/cold tab are refused with nothing typed; a flag reply emits exactly one flag.lowered with the text and the right attribution; a close-before-submit case reports failure without redirecting input.
- Skill and CLI help updated (chain `send && send-key` in any example). Time-box each validation step to 15 minutes. Push only at handoff, then `HANDOFF C11-268 REVIEW <head> <PR> <validation>` to tab:210.
