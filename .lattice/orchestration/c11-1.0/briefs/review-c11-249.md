# Review: C11-249 (rail tip follow-ups), cycle 1

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `C11-249 Review Astra`. Actor `agent:astra-review-249`. Owner: Claude Sonnet (rolled over from Codex Luna).

- PR https://github.com/Stage-11-Agentics/c11/pull/559, head `c96f5e2062ba00a30b94e45728651e85666ba652`, base = merge-base with origin/main. Four files, including a `vendor/bonsplit` bump 3c1441a3 → 18aa922a (the Orchestrator verified 18aa922a is on the bonsplit fork's main and contains main's 3c1441a3). Review the bonsplit diff between those two commits too.
- Validation: the validation comment on the ticket. TabRailTipPolicyTests 18/18 on Atlas; the owner states there was no post-fix UI pass and wrote a Validator scenario.
- Scope (ticket): Undo copy, count-cell tap, rail-open state after Undo, anchor clear. Check each is actually fixed, with a behavioral test that goes red without it (break it and confirm).
- Strings: any new or changed English strings are localized at the call site (they must land before the translation freeze).
- UI rules: elements never jump (fixed widths for swapped text), typing paths untouched (`TabItemView` equatable rules, `hitTest`, `forceRefresh`).
- The Validator scenario must be concrete enough to run on merged main or in the sign-off script.
- Reply `VERDICT C11-249 PASS|FAIL <head> <artifact>` to tab:210.
