---
name: release
description: "Prepare and ship a c11 release end-to-end: choose the next version, curate user-facing changelog entries, bump versions, open and monitor a release PR, merge, tag, and verify published artifacts. Use when asked to cut, prepare, publish, or tag a new release."
---

# Release

Run this workflow to prepare and publish a c11 release.

## Pre-flight

Surface these four facts in one batch before touching anything else:

1. **Branch state.** `git branch --show-current` + `git status -s`. If HEAD
   isn't on `main`, surface it — the operator may not realize. Wrong-branch
   is easy to miss and load-bearing for every step downstream.
2. **Dirty tree disposition.** Enumerate tracked diffs. For each, surface
   what it does and ask: commit on the release branch, stash, or discard?
   Untracked files are usually fine; tracked code needs an explicit call.
3. **In-flight PRs.** `gh pr list --state open --json number,title,headRefName`.
   Each open PR is an explicit include-or-defer decision.
4. **In-flight sub-agents (c11 only).** `c11 tree --no-layout`; read each
   surface's `role` / `task` / `status` metadata. If another agent has
   unfinished work that belongs in the release, surface it now — not
   after the release branch is cut.

If the operator says "skip pre-flight," skip. Otherwise run all four every time.

## Workflow

1. Determine the version:
- Read `MARKETING_VERSION` from `GhosttyTabs.xcodeproj/project.pbxproj`.
- Default to a minor bump unless the user explicitly requests patch/major/specific version.

2. Create a release branch:
- `git checkout -b release/vX.Y.Z`

3. Gather user-facing changes and contributors since the last tag:
- `git describe --tags --abbrev=0`
- `git log --oneline <last-tag>..HEAD --no-merges`
- Keep only end-user visible changes (features, bug fixes, UX/perf behavior).
- **Collect contributors:** For each PR, get the author with `gh pr view <N> --repo Stage-11-Agentics/c11 --json author --jq '.author.login'`. Also check linked issue reporters with `gh issue view <N> --json author --jq '.author.login'`.
- Build a deduplicated list of all contributor `@handle`s.

4. Update changelogs:
- Update `CHANGELOG.md`.
- Do not edit a separate docs changelog file; `web/app/docs/changelog/page.tsx` renders from `CHANGELOG.md`.
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
git diff "$(git describe --tags --abbrev=0)..HEAD" -- \
  Resources/Info.plist \
  c11.entitlements \
  Resources/c11.sdef \
  Sources/SocketControlSettings.swift \
  'Sources/SocketControl*' \
  Sources/AppDelegate.swift \
  Sources/Panels/BrowserPanel.swift \
  Sources/Panels/BrowserPanelView.swift \
  Sources/BrowserWindowPortal.swift
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
- `./scripts/reloads.sh --tag rel-vX.Y.Z` produces `c11 STAGING rel-vX.Y.Z.app`
  (`com.stage11.c11.staging`), Release configuration, runs side-by-side with
  the operator's prod c11.
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

9. Merge and sync `main`:
- `gh pr merge --squash --delete-branch`
- `git checkout main && git pull --ff-only`

10. Create and push tag:
- `git tag -a vX.Y.Z -m "Release vX.Y.Z"` (annotated; lightweight `git tag vX.Y.Z` is rejected with "no tag message?" by local git config)
- `git push origin vX.Y.Z`

11. Verify release workflow and assets:
- `gh run watch --repo Stage-11-Agentics/c11`
- Confirm release exists in GitHub Releases and includes `c11-macos.dmg`.

## Changelog Rules

- Include only user-visible changes.
- Exclude internal-only changes (CI, tests, docs-only edits, refactors without behavior changes).
- Write concise user-facing bullets in present tense.

## Contributor Credits

Credit the people who made each release happen:

- **Per-entry:** Append `— thanks @user!` for community code contributions. Use `— thanks @user for the report!` for bug reporters (when different from PR author). No callout for core team (`lawrencecchen`, `austinywang`) — core work is the baseline.
- **Summary:** Add a `### Thanks to N contributors!` section at the bottom of each release with an alphabetical list of all `[@handle](https://github.com/handle)` links (including core team).
- **GitHub Release body:** Include the same "Thanks to N contributors!" section with linked handles.

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
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
gh run watch --repo Stage-11-Agentics/c11
```

Use the annotated form (`-a -m`). A lightweight `git tag vX.Y.Z` is rejected with "no tag message?" because of local git config (likely `tag.gpgSign` or equivalent forcing all tags to be annotated).

## Reference

- **Release asset:** `c11-macos.dmg`, attached to the tag
- **Download URL:** `https://github.com/Stage-11-Agentics/c11/releases/latest/download/c11-macos.dmg`
- **Changelog file:** `CHANGELOG.md` (the docs changelog page at `web/app/docs/changelog/page.tsx` renders from it — do not maintain separately)
- **Required GitHub secrets:** `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`
