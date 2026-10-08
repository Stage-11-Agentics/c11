# Review: C11-251 (bare-shell clear/list sidebar commands act on the selected workspace), cycle 1

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `C11-251 Review Astra`. Actor `agent:astra-review-251`. Owner: Claude Sonnet (rolled over from Codex Luna).

- PR https://github.com/Stage-11-Agentics/c11/pull/563, head `b91976533900747690c2324403a5ef8c3db74ef4`, base = merge-base with origin/main.
- Validation: the validation comment on C11-251 (Atlas build c512a7a1; tests_v2/test_cli_sidebar_metadata_commands.py passed in a guest at this head; SocketTabRefValidatorTests 11/11).
- Focus: from a bare shell (no `C11_WORKSPACE_ID`), `clear-*` and `list` sidebar commands refuse without an explicit target, with a clear error, and never act on the operator's selected workspace; inside c11 they resolve from `$C11_WORKSPACE_ID` as before; explicit `--workspace` works everywhere. Check every sidebar write and list command, v1 and v2 socket paths, not only the ones the PR touched. CLI help and the c11 skill updated to match. Tests behavioral and red without the fix (break one and confirm).
- Reply `VERDICT C11-251 PASS|FAIL <head> <artifact>` to tab:210.
