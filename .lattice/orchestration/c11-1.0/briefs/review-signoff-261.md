# Review: C11-261 sign-off fix (groups runner vs C11-323)

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `Signoff 261 Review`. Actor `agent:astra-review-261s`.

- PR https://github.com/Stage-11-Agentics/c11/pull/580, head `29948932da915aeae57cd510c00bfdb211bd7a20`, base = merge-base with origin/main (main is frozen at 9c9cf4ba44 for sign-off; this is a sign-off fix). Validation ev_01M40FAPC98TSCTTV5ZAJ3Z2R0; evidence /tmp/c11-261-signoff-fix-20261003T083805Z (A1-A9 and A12-A13 PASS; A10 and A11 UNVERIFIED; C1-C6 pending).
- Context: the C11-292 rehearsal's run of scripts/groups-signoff.sh exited on `workspace_switch_blocked` because C11-323 blocks every socket workspace switch (hard block, no override).
- Check: the harness no longer needs agent visible-workspace switching, and no product gate was weakened or bypassed (no hidden override, no DEBUG seam that ships); checks moved to the human chapter are concrete; every assertion still verifies what it did before or is explicitly re-scoped with a reason; the A10 and A11 UNVERIFIED states are honest and explained (what would discharge each), not a regression this PR introduced; nothing touches the operator's real c11.
- Reply `VERDICT C11-261 PASS|FAIL <head> <artifact>` to tab:210.
