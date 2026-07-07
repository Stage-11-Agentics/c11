# C11-160 — Repo hygiene (Wave 1, fast-track)

Delegator: `agent:ts-hyg-delegator` · branch `ts/hyg-repo-hygiene` · worktree `hyg-repo-hygiene`.
Stops at `pr_open`; Orchestrator merges the branch PR. HYG-2 dependabot merges land directly on `main` (contract authority) — that is expected and separate from this branch's PR.

## HYG-1 — untrack node_modules

**Provenance (checked cold):**
- 4943 tracked files, all under the repo-root `node_modules/` (none under `web/node_modules`, which is already ignored via `web/.gitignore:/node_modules`).
- Root `node_modules/` is a single dependency: `vercel: ^50.9.5` (root `package.json`). It was committed in `e620ec734 Update app and tooling` **before** the ignore rule existed.
- `.gitignore:41` already contains `node_modules/`, so once untracked it stays ignored — no gitignore edit needed.
- `.vercelignore` already excludes `node_modules/` from Vercel uploads.
- No CI workflow references root `node_modules/`; it is not part of the Swift/Xcode build. It exists only so `vercel` CLI is runnable at repo root.

**Action:** `git rm -r --cached node_modules/` (keeps files on disk, drops from index). Verify `git ls-files | grep -c node_modules == 0`. Document the install step (`npm install` at repo root restores the `vercel` CLI) — root `package.json` already declares the dep, so the restore path is standard; add a one-line note where a reader would look.

## HYG-2 — dependabot queue (7 open)

All 7 are `MERGEABLE / CLEAN` with green CI at boot. Triage table:

| PR | Bump | Area | Risk | Decision |
|----|------|------|------|----------|
| #279 | claude-code-action 1.0.140->1.0.159 | .github | patch, CI green | merge --squash |
| #278 | actions/setup-python 6.2.0->6.3.0 | .github | patch, CI green | merge --squash |
| #277 | actions/cache 5.0.5->6.1.0 | .github | major action, CI green | merge --squash |
| #260 | actions/checkout 6.0.3->7.0.0 | .github | major action, CI green | merge --squash |
| #259 | action-gh-release 3.0.0->3.0.1 | .github | patch, CI green | merge --squash |
| #308 | web-minor-and-patch group (8 updates) | web/ | grouped minor+patch, web-typecheck green | merge --squash |
| #250 | eslint 9.39.2->10.5.0 in /web | web/ | major, but dev-only linter; web-typecheck green | merge --squash |

Order: merge the 5 `.github/` action bumps first (independent, no cross-conflict), then the 2 web PRs (#308 group, then #250 eslint). If merging one web PR makes the other conflict, comment `@dependabot rebase` and let it re-open clean, or close with reason if it goes stale. Re-check `gh pr checks` immediately before each merge (CI runs are old; CLEAN state confirms still-current). Goal: `gh pr list` shows zero open dependabot PRs.

## HYG-3 — stale-branch inventory

Method: `git fetch origin --prune`, then for every local + remote branch collect last-commit date, author, ahead/behind vs `origin/main`, and merged-status (`git branch --merged origin/main`). Emit a markdown table to `docs/cycles/2026-07-truth-and-stability/branch-inventory.md` on this branch, and attach a copy to the ticket. **No deletions** — operator-assisted.

## Build proof

After the node_modules untrack, run the `c11-logic` suite once (under the xcodebuild resource lock) to prove the build is unaffected. Untracking a root-only vercel CLI dir cannot touch the Swift build, but the contract asks for the proof — provide it.

## Validation & PR

Evidence bundle: HYG-1 grep at PR head, `gh pr list` empty of dependabot, inventory artifact, c11-logic result. Tagged-build screenshot is N/A (no UI surface touched) — record the N/A justification. Push branch, open PR `--base main`, attach URL, bump `pr_open`, STOP (no self-merge).
