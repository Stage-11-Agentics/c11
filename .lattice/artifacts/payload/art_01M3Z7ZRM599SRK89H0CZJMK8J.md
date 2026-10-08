C11-280 validation summary (batch validation, existing runtime evidence)

Merged heads: product PR #522 (squash 1334615d98), test-only fixture fix-forward PR #536 (squash ef36ab8258). Evidence below is pre-merge owner runtime on a tagged Atlas build, the Merge Captain exact-head gates, and the parked validator's passed checks.

Acceptance criteria -> evidence -> result
1. Tagged build: `new-tab`, `new-split`, `new-area --command` print the marker and the shell stays alive (`echo ok` works) -> ev_01M3XVXM0M87HQB5NMH0Z3WE78 (packaged Debug run 1e7e23b4: real new-workspace, new-tab, new-split, new-area queued-command outputs and surviving-shell follow-ups pass; exact tagged window capture, receipt and returned prompt readable), art_01M3XWJ53T62F8V9WCQQBF37FR + art_01M3XWJ57BKY5EPX9SCWX1FQ9V (sanitized JSON and window PNG), ev_01M3YPV4CBW62R0QGMQ9B74JWV (validator re-run of packaged live four-create on batch main 12d4f21a: PASS) -> PASS
2. `--type browser|markdown --command` exits with a usage error and opens nothing -> ev_01M3XVXM0M87HQB5NMH0Z3WE78 (5 CLI rejection shapes and 21 invalid RPC shapes preserve workspace/tab/area id sets; 18 rejection invocations open zero connections), ev_01M3YPV4CBW62R0QGMQ9B74JWV (atomic invalid-type rejection re-run) -> PASS
3. `new-workspace --command` no longer issues `tab.send_text`; slow rc does not lose the command; one run records rc output before the command echo -> ev_01M3XVXM0M87HQB5NMH0Z3WE78 (Unix proxy saw exactly one `workspace.create` carrying `initial_input` and no following `tab.send_text`; native zsh rc delayed 2.106 s: rc-start, rc-ready, initial, follow-up in order, command ran exactly once in the same shell), ev_01M3YM0MKBBPWK64ZSJ2S2XJZ6 / art_01M3YM06ZCRMWS2GWFYPJHCWJP (fixture re-run at fix-forward head: rc 2.1 s, one initial receipt), ev_01M3YPV4CBW62R0QGMQ9B74JWV (repaired fixture PASS on current main ef36ab82, 5.179 s, TEST SUCCEEDED) -> PASS
4. `new-workspace --layout <name> --command` fails naming both flags, no workspace left behind -> ev_01M3XVXM0M87HQB5NMH0Z3WE78 (layout+command rejected before creation; id sets unchanged; error key cli.create.command.withLayout), ev_01M3YPV4CBW62R0QGMQ9B74JWV (atomic layout rejection re-run on batch main) -> PASS
5. Socket `workspace.create` with `initial_command` still replaces the shell -> ev_01M3XVXM0M87HQB5NMH0Z3WE78 (bounded explicit shell program emitted its receipt; a later shell command did not run), ev_01M3YPV4CBW62R0QGMQ9B74JWV (initial_command distinction re-run) -> PASS

Supporting gates
- Reviewer: ev_01M3XW9D57XKYNM5YJ12GPW0N4 (no code defect; sole finding was evidence disclosure, repaired in ev_01M3XWKV11PF9HSJDPNC8F05AT and attested in ev_01M3XWMCZP8Y443RPPEEPZAGXZ). Fix-forward attestation ev_01M3YM1SD3F8WAJEA34NBHJXD1.
- Merge Captain exact-head gates: ev_01M3XX3KP0T5XXGP3T9W42TEWZ (PR #522, 13 tests pass, all hosted checks SUCCESS), ev_01M3XXV86571RASY8C94K2HEFP (merged-main CI SUCCESS), ev_01M3YN67M7YFC1QB3RDF2J7BF9 (PR #536, all hosted checks SUCCESS).
- The earlier fixture failure (ev_01M3YK0NNDYKDA82KC041D079Z) was a test-contract conflict with the C11-295 no-resurrection guard, not a product regression; superseded by the repaired fixture PASS above.

Routed to C11-292 sign-off
- None. The validator's remaining native scene (one-area initial --command marker plus typed follow-up) is covered by the owner's exact-window capture (art_01M3XWJ57BKY5EPX9SCWX1FQ9V) and the screen oracle; no contradicting evidence.

Verdict: COMPLETE. Every criterion is covered by existing runtime evidence and no check contradicts a criterion.