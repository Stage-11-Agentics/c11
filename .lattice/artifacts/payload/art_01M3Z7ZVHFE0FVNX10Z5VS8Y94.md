C11-297 validation: pre-merge and parked-Validator runtime proof mapped to acceptance criteria

Merged head 1572e20ee8d5958c2a920ddab35c70e377fe81ef (squash e7322a2ad0, PR #516). Evidence reviewed: owner validations and artifacts, Sol/Codex round-1 FAIL and round-2 PASS, Orchestrator merge attestations, Merge Captain gate, parked Validator packaged-run comment. No new runs were made for this comment.

Criterion -> evidence -> result
1. Relaunch restoring several agent terminals: app stays up and commands issued as soon as the socket exists see the restored tabs, not a crash and not an empty tree -> ev_01M3YT4AGRV8GPF3Y7F4A3YAZJ and art_01M3YT4ADGARCVRT9QN01CZCHP (four unchanged shipping prepare/observe/verify runs on the packaged app: exactly 2 windows, 4 workspaces, 8 tabs, all 8 initial shell calls with zero transport retries, 8 correct targeted sentinels; lazy realization 4 shells then 8 after explicit workspace selection; no crash) -> PASS
2. A command during restore gets not-ready or waits; no crash, no wrong-tab action -> ev_01M3YT4AGRV8GPF3Y7F4A3YAZJ (only typed not_ready retried, every successful tree complete); art_01M3XRVVY65BD71DV2YPQW0JMG and art_01M3XSVQMWVH5EWHEZY0KMDCG1 and art_01M3XT5A05JN9ZRHPD5CD27X7J (16 exact-head Atlas tests, 0 failures, including actual bundled bash and zsh senders under readiness=false); ev_01M3XS139WC9ACXGD98S8F1YJH (review PASS of the retained-report repair); ev_01M3YT4AGRV8GPF3Y7F4A3YAZJ (actual zsh TTY registration and same-device foreground PID/PGID/TPGID matched) -> PASS
3. Idle burst does not walk every workspace on main; a new tab is addressable by the next command -> ev_01M3YT4AGRV8GPF3Y7F4A3YAZJ (actual refs and all four normalization controls pass; retained host ref-counter gate passes); host counter test: one initial seed and no further walks across 200 ping/capabilities dispatches and 100 fallback refreshes (ev_01M3XT5A2KACZFWCN6RK7H5EV8, art_01M3XT5A05JN9ZRHPD5CD27X7J) -> PASS
4. Wrapper sees a live socket, or the PR shows the order -> ev_01M3XQAQ1XMDHRCS11WVHYCDX9 (behavior: listener starts before restoration); ev_01M3YT4AGRV8GPF3Y7F4A3YAZJ (verify run: session.restore.begin socket_listening=1 precedes session.restore.ready, zero transport retries on all 8 first calls) -> PASS
Ride-alongs: B004 self-bundle open and B355 empty-window filtering are covered by the four normalization controls and the LaunchServices oracle in ev_01M3YT4AGRV8GPF3Y7F4A3YAZJ (final tree key flags false/false) and by the host tests in art_01M3XQA3E0NB7K7R92H7S7MFSC.
Landing gate: every non-skipped exact-head hosted check SUCCESS (build, compatibility, workflow guards, daemon, web, GhosttyKit) and Orchestrator attestations ev_01M3XSWQZWS76H2EFBB1AKVMMR and ev_01M3XT6EJ24ECP2C0T6WZGS48X (ev_01M3XX98YP581BV4F7J13D73Z7). c11 skill synced and byte-equal.
No failing check was found against any criterion. The Validator noted one unrelated old C11-280 failure in the enclosing host job; it belongs to another ticket and does not touch these criteria.

Routed to C11-292 sign-off (human-visible, not run natively)
- Two restored windows readable and key focus correct after relaunch.
- Clean-save: quit through the app menu, relaunch, same workspaces and tabs restored (second resume).
- Services path with real pasteboard input (self-only, empty and mixed).
- Listener failure and replacement: Restart CLI Listener from the command palette recovers the restore, and a replacement window receives the pending restore.
- Release picker: Resume, Skip, parent-close, listener failure after the picker appears, parent-close before recovery (five paths). The retained older Release build is a different source and is not claimed as current.

Verdict: COMPLETE with sign-off routing: criteria 1 to 4 and both ride-alongs are covered by four packaged-app restore runs, host tests and the landing gate, native save, resume, Services, recovery and picker steps go to C11-292, and no check contradicts a criterion.