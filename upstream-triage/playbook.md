# Playbook

Resolve recipes for recurring conflict shapes. Add an entry whenever a non-obvious resolution might come up again. Skip entries that are obvious or one-shot.

**Entry format:**

```markdown
## <short title>

**When you see:** <conflict pattern>

**Apply:** <the resolution recipe, in steps>

**Why:** <the underlying reason — what about c11 makes this conflict shape recur>

**Last seen:** <PR# / date>
```

---

## cmux → c11 rename

**When you see:** an upstream PR touches `Sources/cmuxApp.swift` or `CLI/cmux.swift`. Direct cherry-pick will fail (file doesn't exist on c11) or recreate stale paths.

**Apply:**

1. Run the probe normally. Note the failure mode (`error: <path>: does not exist in index` is the typical signal).
2. Fetch the diff: `git show <merge-commit> -- Sources/cmuxApp.swift CLI/cmux.swift`
3. Translate paths: re-apply the diff to `Sources/c11App.swift` / `CLI/c11.swift` instead. The simplest approach is `git show <sha> -- <old-path> | sed 's|<old-path>|<new-path>|g' | git apply -3`.
4. If the translated apply succeeds, stage and commit using the original PR's author and message: `git commit --author="$ORIG_AUTHOR" -m "[upstream #<N>] <orig-title>"`.
5. If the translated apply has hunk failures, the upstream change touches code that's been rewritten on c11 — fall back to NEEDS-HUMAN, do not guess.

**Why:** c11 renamed the entry-point files when the project name changed. The code identity is the same; the path is not. This will keep recurring forever — the rename is permanent.

**Last seen:** (none yet — pattern observed during initial divergence map seeding 2026-05-01)

---

## Xcode project file conflicts

**When you see:** any cherry-pick conflict in `GhosttyTabs.xcodeproj/project.pbxproj`.

**Apply:**

1. **Do not** try to hand-merge `pbxproj` content. The format is positional and one-character mistakes break the project.
2. If the upstream change is purely *adding* file references (most common): take ours (`git checkout --ours GhosttyTabs.xcodeproj/project.pbxproj`), then add the new source files manually via Xcode (or the appropriate script), then `git add` and continue.
3. If the upstream change is structural (target settings, build phases): NEEDS-HUMAN. The c11 Stage-11 Sentry config and target IDs are baked in here.
4. Stage the resolution: `git add GhosttyTabs.xcodeproj/project.pbxproj` then `git cherry-pick --continue`.

**Why:** c11 has 48 commits worth of changes here — Stage-11 Sentry config, c11 target rename, additional file references. Most upstream pbxproj changes are file-list additions, which can be replayed by adding the files Xcode-side.

**Last seen:** (pattern from divergence map; not yet exercised)

---

## String catalog merges (`.xcstrings`)

**When you see:** conflict in `Resources/Localizable.xcstrings` or `Resources/InfoPlist.xcstrings`.

**Apply:**

1. These files are JSON; conflicts usually appear as overlapping key additions.
2. Take ours, then re-apply the upstream change: `git checkout --ours <file>`, then `git show <sha> -- <file> | git apply --3way -`.
3. If still conflicting, open the file and manually merge the new keys at the JSON level — the conflicts are almost always *additive*.
4. Run a build locally to confirm the JSON is still valid; if you can't build, at minimum run `python3 -c 'import json; json.load(open("<file>"))'` to validate.

**Why:** Xcode auto-generates these and merges them poorly. The actual content (translated strings) almost never has semantic conflicts; it's the JSON structure that fights.

**Last seen:** (pattern from divergence map; not yet exercised)

---

## Modify/delete conflict — file doesn't exist on c11

**When you see:** probe reports `STATUS=conflict` with `git status` showing `DU <path>` (deleted-by-us, updated-by-them) on a file that c11/main does not contain. Often the only conflicting "file" in an otherwise small PR.

**Diagnose:**

1. `git ls-tree main:<path>` — if it returns nothing, c11/main genuinely doesn't have the file.
2. `git log --all --format='%h %ai %s' -- <path> | head` — find the upstream commit that *introduced* the file. That commit's PR is the dependency.
3. Walk back: `gh search prs --repo manaflow-ai/cmux 'in:title <feature-name>'` to confirm the dependency PR.

**Apply:**

Mark the PR **NEEDS-HUMAN** with a clear note: "Depends on upstream PR #<dep>, which introduced `<path>`. To import, either import #<dep> first, or skip both."

**Do not** auto-import the dependency — that's a judgment call for the operator. A single-file PR that turns into a five-PR import chain is a meaningful scope change.

**Why:** c11 forks the upstream tree at a moment in time and follows selectively. Any upstream PR that modifies a file introduced *after* the merge-base will fail this way. The pattern is going to be very common during catch-up — most upstream PRs after April 2026 modify code that didn't exist at our merge-base.

**Last seen:** PR #3405 (2026-05-01) — modifies `Resources/opencode-plugin.js`, which was introduced upstream in PR #3057 (2026-04-26). c11 doesn't have the file or the Feed sidebar feature.
