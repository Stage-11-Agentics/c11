C11-320 validation: screenshot phase, completing the ticket (batch fast rule)

Merged: PR #584, squash b3de329fa0ea982ac5cbb76e4b7e701c543220ec, landing head 2ac13ee42a658f67a75fda8f0b97a46b04d16c02. Merge Captain receipt ev_01M40ZKKXQ7SH9NFQP031JC66V: all three images viewed, synthetic sandbox content only, metadata clean. Orchestrator visual review PASS. Owner Phase 2 validation ev_01M40ZEHM8840BVDXGKENDCQDY: captured from the signoff-1-1 build in an authorized Atlas guest, which was deleted after capture. The text phase was validated earlier in ev_01M40PQK3K7NV438VV5TZW9HD2 (scope items 1, 2, 4 and 5 PASS).

Scope item 3 (screenshots from the sign-off build) -> Validator checks now, read-only on main:
- The README as rendered by the GitHub API carries three <img> elements: docs/images/readme/workspace-overview.png, workspace-folders.png and browser-profile-control.png. Each file exists at main, and no `SCREENSHOT` placeholder remains.
- I viewed all three. Workspace overview: one workspace with four areas (terminal "4 tabs in 4 areas", browser, Markdown showing "Build: signoff-1-1", and `c11 config` saved configurations). Folders: a pinned, collapsed "C11 1.0" folder and an expanded "Research" folder with their count slots. Browser: an embedded browser tab beside a terminal, with the profile control in the toolbar.
- The content is synthetic (generic guest prompt, loopback sample page). No personal names, real paths or tokens.
- The alt text matches each image.
-> PASS.

Scope notes, stated plainly:
- The Feed and A-button picker shots were not captured, and their markers were removed rather than left as placeholders. The README text still describes both.
- The browser image shows the profile control, not the open menu.
- The Captain's non-blocking note stands for any later copy pass: the sample content in two images says "room" where c11 copy prefers "workspace".
- When 1.0 publishes, the Homebrew cask moves from 0.67.0 (release work).

No check contradicts the scope.

Verdict: COMPLETE.