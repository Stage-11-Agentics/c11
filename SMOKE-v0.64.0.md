# v0.64.0 staging smoke

Artifact: **`c11 STAGING rel-v0.64.0.app`** — bundle `com.stage11.c11.staging`, Release
config, WMO (prod parity). Runs side-by-side with your prod c11.

Version 0.64.0, build 125. Sparkle floor is v0.61.0 — the last *published* release, 60
commits back.

## The checks (mirrors PR #419's test plan)

- [ ] **A button** (C11-203) — bare click launches the effective default; a config that
      cannot launch opens the picker with the reason pre-seeded. This was fully dead before:
      left-click resolved an empty command and returned silently.
- [ ] **Picker** — no RECENT section, `Edit Launch Agents` footer, digit shortcuts aligned.
- [ ] **Config editor** — Provider → Model → Effort → Harness; harness filtered by model.
- [ ] **Browser modal** (C11-204) — `c11 browser open http://…` with the window
      **backgrounded** does not freeze the app. This is the big one: four paths used to fall
      back to `NSAlert.runModal()` when no window could host a sheet, holding main for a
      measured median of 8.5 min and a max of 6.8 hours.
- [ ] **Agent launch cwd** (#407) — launch from a linked worktree warns and names the path;
      project `.c11/agents.json` resolves from the launch cwd, not the GUI process.
- [ ] **Sparkle** — update check resolves the appcast, no `SUSparkleErrorDomain(2001)`.

## One thing to avoid during smoke

**Do not run `c11 browser wait` / `eval` against a surface you have not navigated yet.**
That is C11-209, which is *not* fixed in this release: on a `WKWebView` that has never been
asked to load anything, `evaluateJavaScript`'s completion handler never fires and the await
burns its full (uncapped) `timeout_ms` while holding the main queue — freezing the socket
control plane and the UI. It is what took prod down tonight.

Navigating first is enough to stay clear of it — a committed document, a refused connection,
and a hanging server all resolve in ~0.05s. Only the never-navigated case wedges.

If you want to *confirm* the bug rather than avoid it, `tools/await-wedge-repro/run.sh`
reproduces it in isolation without touching the app.

## After smoke passes

```bash
gh pr merge 419 --squash --delete-branch
git checkout main && git fetch origin main && git merge --ff-only origin/main

# gate the tag — never tag blind
test "$(git rev-parse HEAD)" = "<merge-commit-sha>" || echo "STOP: main not at merge commit"
grep -m1 MARKETING_VERSION GhosttyTabs.xcodeproj/project.pbxproj   # must read 0.64.0

git tag -a v0.64.0 -m "Release v0.64.0"
git push origin v0.64.0
gh run watch --repo Stage-11-Agentics/c11
```

Watch for the stale-`nightly`-tag trap: it makes `git pull` exit non-zero on a "would clobber
existing tag" error, which aborts the ff-merge while the fetch line still shows `origin/main`
advancing — leaving `main` on the old commit and tagging the previous release's content.
