# C11-159 tests_v2 parity BASELINE

- **Base commit:** 8a98f0f7e (== origin/main at run time)
- **Tagged build:** `dx-baseline` → socket `/tmp/c11-debug-dx-baseline.sock`, CLI `c11 DEV dx-baseline.app/.../bin/c11`
- **Env:** operator actively using this host; single tagged instance (prod c11 untouched, different socket).
- **Full log:** `tests_v2-baseline-8a98f0f7e.log`

## Method (host-safe, flagged deviation — see note)

The canonical `scripts/run-tests-v2.sh` is VM-only: it `pkill`s c11 and relaunches an untagged
`c11 DEV.app` per test — prohibited on the operator's host (would kill their live session). The c11-vm
is not reachable from this machine, and CI runs only a mailbox-parity subset. So the full 158-file
tests_v2 suite cannot be run cleanly on the host mid-session. It is CI/VM territory and the orchestrator
/ CI exercises it on the PR.

For a **host-safe, reproducible parity oracle** the run targets a single tagged instance's socket
(no pkill, no prod disruption) over a **dispatch-representative subset**. Many suite tests need the
runner's per-test fresh-workspace bootstrap and a key/focused window; on a shared instance with the
operator holding focus they fail **environmentally** (not product regressions — this is CI-green
origin/main). Parity is therefore asserted as: **identical pass/fail set and identical error strings,
same environment, before vs after.** A mechanical routing regression would flip a green→red or change
a wire/error string.

## Baseline result (14-test dispatch subset)

- **PASS (4):** test_metadata_persistence, test_send_requires_surface, test_rename_tab_cli_parity, test_doctor_command
- **ENV-FAIL (10):** test_cli_global_flags_and_v1_error_contract, test_mailbox_parity, test_pane_metadata,
  test_pane_metadata_persistence, test_notifications, test_m7_title_read_write, test_m7_description_read_write,
  test_m7_precedence_ladder, test_cli_sidebar_metadata_commands, test_browser_api_p0
  - Root causes (env, not product): `pane_not_found` (no per-test split bootstrap), window-not-key
    (focus-suppression/flash tests), envelope-timeout (mailbox timing on shared instance),
    capabilities method-list check (M2/M7).

## Primary parity gate

Full **`c11-logic`** suite (hermetic, deterministic, CLAUDE.md-sanctioned safe local loop) is the
authoritative DX-2 behavior-parity oracle, run in full **post-change**, alongside **CI green** on the PR.
The tests_v2 subset above is the secondary same-environment before/after check.
