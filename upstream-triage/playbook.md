# Playbook

Adaptation patterns the agent uses when bringing upstream cmux PRs into c11. Add an entry whenever a non-obvious pattern comes up that's likely to recur. Skip entries that are obvious or one-shot.

These are not conflict-resolution recipes. They're knowledge the agent carries about *how upstream changes typically land in c11*. The agent reads these every run.

**Entry format:**

```markdown
## <short title>

**When you see:** <upstream change shape that triggers this pattern>

**Adapt by:** <how to land the change on c11 — written as agent guidance, not a script>

**Why:** <what about c11 makes this pattern recur — the underlying divergence>

**Last seen:** <PR# / date>
```

---

## cmux → c11 entry-point rename

**When you see:** an upstream PR touches `Sources/cmuxApp.swift` or `CLI/cmux.swift`. These files don't exist on c11 — they were renamed to `Sources/c11App.swift` and `CLI/c11.swift` during the fork's identity change.

**Adapt by:**

1. Read the upstream diff against the cmux file. Understand what it changes — a new SwiftUI scene, a new command, a config refactor, etc.
2. Apply the same change to the c11 equivalent (`Sources/c11App.swift` / `CLI/c11.swift`). The class/struct names already differ (`c11App` vs `cmuxApp`); preserve c11's naming throughout.
3. If the upstream change references other identifiers that have been renamed (e.g., a method name that changed), translate those references too.
4. Cherry-pick will fail here — don't try to coerce it. Rewrite is the right path.

**Why:** c11 renamed the entry-point files when the project name changed. The code identity is the same; the path and a few identifiers are not. Permanent divergence, not catch-up-able.

**Last seen:** —

---

## Xcode project file (`pbxproj`) changes

**When you see:** an upstream PR adds, removes, or moves entries in `GhosttyTabs.xcodeproj/project.pbxproj`.

**Adapt by:**

- **If upstream is just adding new source files:** identify the new files. In c11, the simplest reliable path is to add them via Xcode (or its scripting equivalent) so the file references and build phase memberships are wired correctly. Don't hand-edit `pbxproj` JSON-style — its format is positional and brittle.
- **If upstream is changing target settings, signing, build configurations:** stop. c11 has Stage-11 Sentry, c11 target rename, and signing identity baked into its pbxproj. These are intentional divergence. Surface to the operator before touching.
- **If upstream is moving file groups around:** judge whether c11's organization should follow. Often it shouldn't — c11 has its own sub-organization (Panels/, Theme/, etc.). Do the file additions, skip the reorganization.

**Why:** 48 of c11's unique commits touch this file. Most are c11-specific (Sentry, target renames, additional source files for c11-only features). Upstream pbxproj churn is mostly file-list additions, which can be replayed by adding the files Xcode-side without merging the pbxproj diff.

**Last seen:** —

---

## String catalog (`.xcstrings`) changes

**When you see:** an upstream PR adds or modifies entries in `Resources/Localizable.xcstrings` or `Resources/InfoPlist.xcstrings`.

**Adapt by:**

1. These files are JSON; the change is almost always *additive* (new keys for new strings).
2. If the strings are for upstream-only features (Feed sidebar, OpenCode plugin, etc.) and c11 isn't importing those features → skip the string additions.
3. If the strings are for shared features (theme picker, settings) → take ours, then merge in the new keys at the JSON level. Validate with `python3 -c 'import json; json.load(open("<file>"))'`.
4. Don't try to merge with `git checkout --ours` followed by `git apply` — the JSON structure conflicts more than the actual key contents do, and the apply will spuriously fail.

**Why:** Xcode auto-generates these and they merge poorly. The semantic content (the localized strings themselves) is rarely in real conflict — only the surrounding JSON structure is.

**Last seen:** —

---

## Modify/delete — file doesn't exist on c11

**When you see:** the upstream PR modifies a file that c11/main does not contain. The probe reports `STATUS=conflict` with `git status` showing `DU <path>` (deleted-by-us, updated-by-them).

**Diagnose:**

1. `git ls-tree main:<path>` — confirms c11/main doesn't have it.
2. `git log --all --format='%h %ai %s' -- <path> | head` — find the upstream commit that *introduced* the file. That commit's PR is the dependency.
3. Read the introducing PR's title — that names the upstream feature this PR builds on.

**Adapt by:**

In almost every case, this is a **NEEDS-HUMAN** call. The upstream PR depends on a feature c11 hasn't imported. Importing this PR alone leaves a dangling reference; importing the whole feature chain is a meaningful scope expansion.

The agent should:
1. Surface the dependency clearly: "PR #<N> modifies `<file>`, introduced upstream in PR #<dep> (<feature>). c11 doesn't have this feature. To import, import #<dep> first or skip both."
2. **Not** silently bring the file over. That makes c11 carry orphan code with no caller, and obscures the dependency from the operator.
3. If the operator chooses to import the feature chain, that becomes a separate triage session with its own scope.

**Why:** c11 selectively follows upstream; it never sees most upstream PRs at the time they're merged. Any upstream PR that builds on a post-merge-base feature will fail this way. Going to be common during catch-up.

**Last seen:** PR #3405 (2026-05-01) — modified `Resources/opencode-plugin.js`, introduced in PR #3057 (2026-04-26).

---

## Submodule pointer changes

**When you see:** an upstream PR bumps `vendor/bonsplit`, `ghostty`, or another submodule, often via `.gitmodules` changes.

**Adapt by:**

1. Check whether c11 tracks the same submodule remote. If c11 has its own fork of the submodule (e.g., `homebrew-c11` instead of `homebrew-cmux`), the URL change doesn't apply.
2. If the remote is shared, the bump is usually safe — but verify via `git submodule update --remote --merge` after applying.
3. Don't import upstream's `.gitmodules` wholesale; c11 has divergence in submodule URLs that must be preserved.

**Why:** c11 maintains its own homebrew tap (`homebrew-c11`) and may track different submodule revisions for vendored deps. `.gitmodules` is on the divergence map's skip list for this reason.

**Last seen:** —
