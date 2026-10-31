---
name: release
description: "Prepare and ship a c11 release end-to-end: choose the next version, curate user-facing changelog entries, bump versions, open and monitor a release PR, tag the tested release-branch head, verify published artifacts, and merge the branch back. Use when asked to cut, prepare, publish, or tag a new release."
---

# Release

Run this workflow to prepare and publish a c11 release.

## Pre-flight

Surface these five facts in one batch before touching anything else:

1. **Branch state.** `git branch --show-current` + `git status -s`. If HEAD
   isn't on `main`, surface it — the operator may not realize. Wrong-branch
   is easy to miss and load-bearing for every step downstream.
2. **Dirty tree disposition.** Enumerate tracked diffs. For each, surface
   what it does and ask: commit on the release branch, stash, or discard?
   Untracked files are usually fine; tracked code needs an explicit call.
3. **In-flight PRs.** `gh pr list --state open --json number,title,headRefName`.
   Each open PR is an explicit include-or-defer decision.
4. **In-flight sub-agents (c11 only).** `c11 tree --no-layout`; read each
   panel's `role` / `task` / `status` metadata. If another agent has
   unfinished work that belongs in the release, surface it now — not
   after the release branch is cut.

5. **Previous release merged back.** `git fetch origin main 'refs/tags/v*:refs/tags/v*' && git merge-base --is-ancestor "$(git tag -l 'v*' --sort=-v:refname | head -1)" origin/main` (fetching only `v*` tags avoids the moving `nightly` tag). A silent exit 0 means it merged back. If the newest `v*` tag is not on `main` (exit 1), its merge-back (step 11) is outstanding. That is a blocker: `main` still carries the old version, so the next bump would reuse it, and `git describe` on `main` would skip that tag and widen the changelog range.

If the operator says "skip pre-flight," skip. Otherwise run all five every time.

## Workflow

1. Determine the version:
- Read `MARKETING_VERSION` from `GhosttyTabs.xcodeproj/project.pbxproj`.
- Default to a minor bump unless the user explicitly requests patch/major/specific version.

2. Create a release branch from current `main`:
- `git fetch origin main && git checkout -b release/vX.Y.Z origin/main`

3. Gather user-facing changes and contributors since the last versioned release tag:
- `git describe --tags --abbrev=0 --match 'v*'` (artifact tags such as `nightly` and `xcframework-*` are not releases)
- `git log --oneline <last-tag>..HEAD --no-merges`
- Keep only end-user visible changes (features, bug fixes, UX/perf behavior).
- **Collect contributors:** For each PR, get the author with `gh pr view <N> --repo Stage-11-Agentics/c11 --json author --jq '.author.login'`. Also check linked issue reporters with `gh issue view <N> --json author --jq '.author.login'`.
- Build a deduplicated list of all contributor `@handle`s.

4. Update changelogs:
- Update `CHANGELOG.md`.
- The `## [X.Y.Z] - YYYY-MM-DD` section is the release body; `release.yml` and `release-local.sh` refuse a tag without it.
- Do not edit a separate docs changelog file; `web/app/[locale]/docs/changelog/page.tsx` renders from `CHANGELOG.md`.
- Use categories `Added`, `Changed`, `Fixed`, `Removed`.
- **Credit contributors inline** (see Contributor Credits below).
- If no user-facing changes exist, confirm with the user before continuing.

5. Bump app version metadata:
- Prefer `./scripts/bump-version.sh`:
  - `./scripts/bump-version.sh` (minor)
  - `./scripts/bump-version.sh patch|major|X.Y.Z`
- Ensure both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are updated.

### Security threat-model recheck

Before the version bump lands, look at whether this release moved any
security-sensitive surface. The canonical posture lives in
`docs/security-threat-model.md`; the diff signals below tell you when a
re-read is warranted. Run this grep against the release range and read
the threat-model doc end-to-end if any signal fires:

```bash
git diff "$(git describe --tags --abbrev=0 --match 'v*')..HEAD" -- \
  Resources/Info.plist \
  c11.entitlements \
  Resources/c11.sdef \
  Sources/SocketControlSettings.swift \
  'Sources/SocketControl*' \
  Sources/AppDelegate.swift \
  Sources/Panels/BrowserPanel.swift \
  Sources/Panels/BrowserPanelView.swift \
  Sources/BrowserWindowPortal.swift \
  Sources/Panels/MarkdownWebRenderer.swift \
  Sources/UntrustedRepositoryGit.swift \
  Sources/MarkdownAssetPolicy.swift \
  Sources/MarkdownCorpusIndex.swift \
  Sources/SocketHandlers/MarkdownFeedbackHandlers.swift \
  Resources/markdown-viewer/ \
  Sources/Events/EventLog.swift \
  Sources/PanelLinkActivation.swift
```

The URL handler around `Sources/AppDelegate.swift:2301` (`application(_:open:)`)
and any new `WKWebViewConfiguration` / `WKContentController` configuration
are the highest-attention sub-targets — they are the chief untrusted-input
vectors into the app. If a signal fires, update
`docs/security-threat-model.md` to match the new posture and surface
the change in the release notes so reviewers can see the security
posture moved. Benign diffs (NSUsageDescription string tweaks, version
bumps that touch the plist incidentally) do not require an update —
acknowledge the diff and continue.

This is a checklist trigger, not a CI gate.

6. Commit and push branch:
- Stage release files (changelog + version updates).
- Commit with `Bump version to X.Y.Z`.
- `git push -u origin release/vX.Y.Z`.

6.5. Build the tagged staging artifact:
- Build from a clean, pushed tree (`git status -s` empty), because `remote-build.sh` also ships dirty files. Write `git rev-parse HEAD` into the release PR body as the tested head; a shell variable does not survive until the tag. Every later fix or merge on the branch replaces it, and staging, the smoke and CI then run again on the new head.
- `./scripts/reloads.sh --tag rel-vX.Y.Z` produces `c11 STAGING rel-vX.Y.Z.app`
  (`com.stage11.c11.staging`), Release configuration, runs side-by-side with
  the operator's prod c11.
- To keep the Release build off the laptop, run it on Atlas instead:
  `./scripts/remote-build.sh --tag rel-vX.Y.Z --mode release` runs the same
  `reloads.sh` there and returns the STAGING app (about 3 min on a fresh tag for
  v1.4.0). A fresh release worktree needs `git submodule update --init ghostty
  vendor/bonsplit` first, or remote-build refuses with "ghostty must be provisioned".
  Launch it with `open --env C11_QA_LAUNCH=fresh <app>` so the startup dialogs
  stay closed; prune both Atlas caches for the tag afterwards (c11-hotload, Tag hygiene).
- Before handing off, screenshot the staging window and inspect every surface
  the changelog touches (sheets, titlebar, sidebar, new or redesigned modals).
  Release-only layout regressions have shipped past Debug builds before.
- Hand off to the operator for a smoke pass against the changelog's
  user-facing bullets. The smoke list should mirror what goes in the PR's
  test plan.

6.6. When staging surfaces a bug:
- Fix on the release branch. Commit. Push.
- Then choose explicitly:
  - **Rebuild staging** (default when the fix touches anything timing- or
    layout-sensitive — SwiftUI layout, animation, focus, paste, anything
    Release-mode could behave differently from Debug). The 0.47.0 New
    Workspace dialog regression was exactly this shape: dev/staging Debug
    masked a prod-only bug.
  - **Ship without re-test** (acceptable only for trivial cosmetic / doc /
    build-script changes AND only with explicit operator accept-the-risk).
- Don't drift past this decision. Default is rebuild; deviating is explicit.

7. Create release PR:
- `gh pr create --title "Release vX.Y.Z" --body "..."`
- Include a concise changelog summary in the PR body.

8. Watch CI and resolve failures:
- `gh pr checks --watch`
- Fix failing checks, push, and wait for green.
- A conflicting PR gets no `pull_request` CI. If the release PR conflicts with `main` before tagging, merge `origin/main` into the branch, push, and repeat 6.5 through 8 on the new head.

The tag goes on the tested release-branch head, never on a merge into `main`. `main` keeps moving while a release is in flight: a commit that lands after the cut ships in the next release, and nothing forces a re-cut or a merge hold.

9. Tag the tested head, after the operator's named go:
- **Gate the tag on the exact tested commit.** The tested commit is the head the staging app was built from, the smoke ran on, and `c11/pr-swift` passed on. Verify first:
  ```bash
  git fetch origin release/vX.Y.Z
  SHA=<full tested head sha from the release PR body>
  test -n "$SHA" || { echo "STOP: no tested head"; exit 1; }
  test "$(git rev-parse origin/release/vX.Y.Z)" = "$SHA" || { echo "STOP: branch moved since it was tested"; exit 1; }
  git show "$SHA:GhosttyTabs.xcodeproj/project.pbxproj" | grep -m1 MARKETING_VERSION   # must read X.Y.Z
  git show "$SHA:CHANGELOG.md" | grep -m1 '^## \[X.Y.Z\]'                             # release.yml needs it
  gh api "repos/Stage-11-Agentics/c11/commits/$SHA/status" --jq '[.statuses[]|select(.context=="c11/pr-swift")|.state]|first' | grep -qx success || { echo "STOP: c11/pr-swift is not success at $SHA"; exit 1; }
  gh pr checks <release PR> || { echo "STOP: a PR check is failing or pending"; exit 1; }
  ```
  Run the gate as a script or in an agent's shell: `exit` closes an interactive terminal.
  A stale local tag (notably `nightly`) makes `git fetch` fail with "would clobber existing tag" and can leave refs unmoved: prune it (`git tag -d nightly` or `git fetch --prune --prune-tags origin`) and re-check.
- `git tag -a vX.Y.Z -m "Release vX.Y.Z" "$SHA"` (annotated; local git config rejects a lightweight `git tag vX.Y.Z` with "no tag message?")
- `git push origin vX.Y.Z`
- **If you tagged the wrong commit and the release run already started:** run `gh run cancel <id>`. Release runs take 33 to 41 minutes, about 30 of them before signing, so a quick catch publishes nothing. Delete the tag in both places (`git push origin :refs/tags/vX.Y.Z && git tag -d vX.Y.Z`), re-verify the gate, then re-tag and push.

10. Verify release workflow and assets:
- `gh run watch <run id> --exit-status`
- Confirm the release exists in GitHub Releases, is neither a draft nor a prerelease, and includes `c11-macos.dmg`.
- `gh api repos/Stage-11-Agentics/c11/releases/latest --jq .tag_name` prints `vX.Y.Z`, and `releases/latest/download/appcast.xml` serves `X.Y.Z` with the new build number.

11. Merge the release branch back into `main`, right after step 10 succeeds:
- `gh pr merge <release PR> --merge`. Use a merge commit, never a squash: the tag must stay an ancestor of `main`, and a squash leaves the shipped commit off `main`'s history.
- Never rebase, amend or force-push the branch after tagging. If the PR conflicts, merge `origin/main` into the release branch, push, then merge the PR. Usually only `CHANGELOG.md` conflicts. The result is `## [Unreleased]` holding the entries `main` added, followed by the `## [X.Y.Z]` section.
- Delete the remote branch (`git push origin --delete release/vX.Y.Z`).
- Confirm with `git fetch origin main && git merge-base --is-ancestor vX.Y.Z origin/main`.

12. Lift a skill-sync hold:
- If `CLAUDE.md` carries a "Hold until c11 1.0 is installed" line under the skill-sync hard rule, wait until the maintainer has installed this release, then run `scripts/sync-installed-skills.sh` and check one live copy (`~/.claude/skills/c11/SKILL.md` matches `skills/c11/SKILL.md`).
- Delete the hold line from `CLAUDE.md` and the matching "(until 1.0 is installed, follow the sync hold in the repo's CLAUDE.md)" clause from `skills/c11/SKILL.md` (Editing this skill) in one PR; after it merges, sync `c11` again.

## Hotfix

A hotfix branches from the shipped tag, not from `main`:

- `git checkout -b release/vX.Y.(Z+1) vX.Y.Z`, then `git cherry-pick -x` each fix from `main`.
- Then run the normal flow on that branch: a patch bump, a changelog section, staging, checks, the tag gate on the tested head, and the merge back.
- A hotfix is valid only while `vX.Y.Z` is the newest shipped release. A hotfix tag takes `releases/latest` and gets a higher build number, so Sparkle would offer it to users already on a newer release. If a newer release has shipped, stop and ask the operator.
- On the merge back, `main`'s `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` win in `project.pbxproj`. Place the hotfix's changelog section by date, below `[Unreleased]` and any newer release sections.

## Changelog Rules

- Include only user-visible changes.
- Exclude internal-only changes (CI, tests, docs-only edits, refactors without behavior changes).
- Write concise user-facing bullets in present tense.

## Contributor Credits

Credit the people who made each release happen:

- **Per-entry:** Append `— thanks @user!` for code contributions, including c11 maintainers when they made the change. Use `— thanks @user for the report!` for bug reporters (when different from PR author). When a release imports an upstream commit, preserve its original authorship and credit that contributor; do not credit manaflow-ai's core team by default.
- **Summary:** Add a `### Thanks to N contributors!` section at the bottom of each release with an alphabetical list of linked handles for people who contributed to that release, including c11 maintainers and authors of imported upstream commits.
- **GitHub Release body:** The release workflow automatically uses the changelog section, including its "Thanks to N contributors!" section with linked handles.

## Version bumping

Prefer `./scripts/bump-version.sh`:

```bash
./scripts/bump-version.sh          # bump minor (0.15.0 → 0.16.0)
./scripts/bump-version.sh patch    # bump patch (0.15.0 → 0.15.1)
./scripts/bump-version.sh major    # bump major (0.15.0 → 1.0.0)
./scripts/bump-version.sh 1.0.0    # set specific version
```

Updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number). The build number is auto-incremented and is required for Sparkle auto-update to work.

**Default policy:** bump the minor version unless the user explicitly asks for patch or major.

## Manual release (fallback)

If not using the `/release` command:

```bash
git tag -a vX.Y.Z -m "Release vX.Y.Z" "$SHA"   # the tested head, after the step 9 gate
git push origin vX.Y.Z
gh run watch --repo Stage-11-Agentics/c11
```

Use the annotated form (`-a -m`). A lightweight `git tag vX.Y.Z` is rejected with "no tag message?" because of local git config (likely `tag.gpgSign` or equivalent forcing all tags to be annotated).

## Local release (Actions unavailable)

When `release.yml` cannot run (runner billing, outage), `scripts/release-local.sh vX.Y.Z` performs the same job: the Release build runs on Atlas through `scripts/remote-build.sh`, and the rest (daemon assets, Sparkle keys, codesign, notarize, staple, DMG, appcast, `gh release`) runs on this Mac. Walkthrough: `.claude/commands/release-local.md`.

- Tag first (step 9). Cancel the `release.yml` run the tag push starts; the script refuses to publish while one is active.
- Run `--dry-run` first. It stops before notarization, rehearses the DMG and appcast with a throwaway Sparkle key, and publishes nothing.
- A real run needs the `c11-notary` notarytool keychain profile. It also needs an Atlas build whose `DTXcode` matches the script's `RELEASE_DTXCODE` pin. It shows one keychain dialog the first time it reads the `c11mux` Sparkle key, so someone has to be at the Mac.
- The guards match CI's: existing release assets are never overwritten (`scripts/release_asset_guard.js`). The release stays a draft until every asset is verified, so the `latest` slot always carries `appcast.xml`.

## Reference

- **Release asset:** `c11-macos.dmg`, attached to the tag
- **Download URL:** `https://github.com/Stage-11-Agentics/c11/releases/latest/download/c11-macos.dmg`
- **Changelog file:** `CHANGELOG.md` (the docs changelog page at `web/app/[locale]/docs/changelog/page.tsx` renders from it — do not maintain separately)
- **Required GitHub secrets:** `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`
