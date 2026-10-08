# C11-269 validation: claude-teams SIGPIPE reset and no persistent OpenCode plugin

Basis: owner exact-head runs, parked validator's packaged passes, review and Merge Captain gates. No new native run in this pass.

## Criterion -> evidence -> result

1. Fake Claude sees default SIGPIPE on both exec routes; c11 CLI still exits cleanly with closed readers -> native sigaction observer on the built CLI (calibrated IGN/DFL), resolved-path and PATH-lookup routes inherit SIG_DFL, failed execs return error status, help/version survive closed readers: ev_01M3XQNKY2D4RX95VKF1R95ZHE (art_01M3XQNKVSQFQRGECP3678SVRS); repeated on the packaged CLI: ev_01M3YNC568R3CVJ5DNVPKQJMEV (art_01M3YNC53WW59TW4NTHCZY18GD) -> PASS
2. Installing/updating OpenCode skills leaves an absent plugins dir absent and existing plugin/tenant files byte-identical; ordinary skills still install -> SkillInstallerPluginBoundaryTests (5) in ev_01M3XQNKY2D4RX95VKF1R95ZHE; real CLI installer, 4 isolated cases x install/force-refresh/remove (12 operations), plugin, sidecar, config and unrelated bytes identical, ev_01M3YNC568R3CVJ5DNVPKQJMEV -> PASS (CLI path); Settings UI path routed below
3. OpenCode wrapper loads the bundled plugin per process through a free slot; occupied slots obey documented fallback -> executable fake-OpenCode wrapper tests (ev_01M3XQNKY2D4RX95VKF1R95ZHE); packaged wrapper matrix (free inline slot, occupied inline falls back to fd-backed config); a real OpenCode TUI session raised `session.created` from the bundled plugin and matched the journal sequence and tab metadata, with no persistent plugin directory, ev_01M3YNC568R3CVJ5DNVPKQJMEV -> PASS
4. Transparent outside c11 or with unreachable socket; both slots occupied keeps the fallback with no persistent plugin written -> packaged wrapper matrix (both slots occupied, outside instance, unreachable socket, informational commands), ev_01M3YNC568R3CVJ5DNVPKQJMEV; fake-executable tests, ev_01M3XQNKY2D4RX95VKF1R95ZHE -> PASS
5. Docs/help no longer instruct persisting c11-notify.js; older copies' treatment is explicit and non-destructive -> review PASS ev_01M3XQZ0YBN7GKBXGFN7BX62HE; docs-conflict repair retained the guidance, ev_01M3XSXQZJJDNEBFG124QYNZVE; bundled guide old-copy/double-load warning source-reviewed, ev_01M3YNC568R3CVJ5DNVPKQJMEV -> PASS

Notes: exact-head hosted checks all SUCCESS per Merge Captain receipt ev_01M3XVEDP2CFB6BH6A3406XPHG; no model request, credential copy or tenant write occurred in any run.

## Routed to C11-292 sign-off

- Settings > Agent Skills install/update/remove for OpenCode (native UI): the disposable guest could not hold app focus; no Settings action was sent. Accepted environment exclusion.
- Notification Command environment fields and originating-tab clearing from a real OS notification (scenario added from C11-263 text): not exercised; needs a real notification delivery.

## Verdict

COMPLETE with sign-off gaps routed to C11-292; no check contradicts any criterion.