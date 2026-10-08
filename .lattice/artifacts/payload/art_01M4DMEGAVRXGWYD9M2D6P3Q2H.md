MERGED c37ced9d784b1a3b36ac7f5100af629a2004cad3

PR: #620 https://github.com/Stage-11-Agentics/c11/pull/620
Reviewed head: 8ad5469beff72dc937714906695ae8117a107767
Base: main. Squash merge verified in origin/main.

Checks at the exact head: workflow-guard-tests SUCCESS; remote-daemon-tests SUCCESS; web-typecheck SUCCESS. Drawbridge checks were SKIPPED. The PR was clean and mergeable.

Review PASS at the exact head: ev_01M4DK7XE05D4GKPG4M24XMZRA and ev_01M4DK51S5FZVHTW4ZWQBW4HMD.
Validation: ev_01M4DJ9J9BDN56XPJ02TXM1DJ3 records the hermetic file-loaded Playwright harness, 31 scenarios passing, zero console errors, and zero network requests, including mutation RED/GREEN evidence. Atlas tagged-build proof is N/A for this web-only ticket; it arrives with C11-359.

No mechanical conflict change. PR #621 still targets md-viewer/C11-358-web-renderer at verification time. The head branch was preserved; merge used no --delete-branch.