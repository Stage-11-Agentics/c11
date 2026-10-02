# C11-284: Print the bundled skill and a versioned capabilities.features list

## Incident
An installed skill is a one-time copy in `~/.claude/skills/c11/`. The app does not refresh it (`CLAUDE.md`, `scripts/sync-installed-skills.sh`). The copy inside the app bundle matches the running build, and nothing prints it. `system.capabilities` returns a hand-kept `methods` array and no feature flags (`Sources/SocketHandlers/SystemHandlers.swift:287-293`). A skill cannot tell what this build supports. Backlog C6. Base `0ff8887e5e`.

## What is already true
- There is no `guide`, `--skill`, or `rpc` command. `c11 skill` (`CLI/c11.swift:1858`) manages installed copies and returns before the socket connect. It does not print the skill.
- The app build copies `skills/` into the bundle's Resources (`project.pbxproj` shell phase, `SKILLS_DEST="${DEST}/skills"`). The CLI is a separate `c11-cli` tool target, copied into `Contents/Resources/bin/c11` by Copy CLI (`project.pbxproj:532-550,1630-1646`); it is not the GUI executable. `versionSummary()` (`CLI/c11.swift:17498-17512`) already prints `CFBundleShortVersionString`, `CFBundleVersion`, and `CMUXCommit` by walking up to the `.app` plist (`resolvedVersionInfo`, `:17586`). The same build phase writes `C11Commit`. `versionSummary` does not read `C11Commit`; neither does `versionInfo(from:)` (`CLI/c11.swift:17630-17650`). A caller of `resolvedVersionInfo()` therefore cannot recover that key merely by checking its returned dictionary.
- `--version` returns at `:1748` and `version` returns at `:1778`, both before `SocketClient.connect` at `:1901`. Subcommand `--help` returns at `:1796`, also before connect.
- `v2Capabilities` is a snapshot. It is not in `socketWorkerV2Methods`. It does not walk windows. `system.brand` (`:384-427`) has bundle version and build, and no commit.
- The skill frontmatter has `version: 1` (`skills/c11/SKILL.md:3`). The skill teaches three behaviors that are already on origin/main: public names workspace / area / tab with hidden aliases (`LegacyWireAliases.swift:19-22`), `send` / `send-key` requiring a tab (`CLI/c11.swift:2960`), and `c11 events` working with no app (`:1875-1880`).
- `c11 rpc` is C11-285. Do not add it.

## Change
`c11 guide` and `c11 --skill` print the bundled `skills/c11/SKILL.md` and return before `SocketClient.connect`. `--skill` is handled next to `--version` (`:1748`) and returns immediately, so it is not a subcommand flag. `guide` is handled after the `--help` check and before connect, next to `events` (`:1878`). `c11 guide --help` still prints help. A dead `--socket` does not matter.

Resolve the containing bundle with the existing executable/symlink ancestry walk: walk from the executable to the `.app`, then `Contents/Resources/skills/c11/SKILL.md`. If that file is missing, exit non-zero with `cli.guide.missing`. Do not read `~/.claude/skills`, the repo checkout, or `SkillInstaller`.

Use a bundle-only identity reader shared by guide and capabilities: load the containing app's built plist, preserve `C11Commit` and legacy `CMUXCommit`, normalize both, and prefer the available build stamp. Do not use `resolvedVersionInfo`'s project-file/git/environment fallbacks for identity comparisons: those describe the checkout or caller, not necessarily this binary. Reuse its executable/symlink walk only. Human output starts with a version summary from that bundle identity. Then `skill: c11`, `skill_version:` from the frontmatter `version`, `source: bundle`, a blank line, and the file. `--json` prints those fields plus `body`. `c11 guide <page>` prints one bundled page: a single path component, no slash and no `..`, from `skills/c11/<page>.md` or `skills/c11/references/<page>.md`. Anything else is an error that names the page. No argument prints `SKILL.md`.

`c11 capabilities` stays one `system.capabilities` call (`:1961`). The CLI adds its own bundle-only identity beside the server identity using the shared helper below. The JSON gains:

- `features`: array of `{id, version}` for enabled entries only
- `features_version`: `1`. Bump it when an existing id changes meaning. Adding an id does not bump it.
- `server`: `short_version`, `build`, `commit` (built C11Commit, else legacy CMUXCommit), `bundle_identifier`
- `cli`: the same fields from the CLI's containing built bundle, without project/git/environment fallback
- `sha_match`: true, false, or null when either commit is missing; normalize hash lengths so matching short/full prefixes from the same build are not reported as mismatches

`CapabilityFeatures` in new `Sources/CapabilityFeatures.swift` is the only producer of `features`. Compile it into both app and CLI; `v2Capabilities` serializes the registry, and CLI command/option dispatch and socket feature dispatch consult the same typed entries when each consumer lands. For example, the future selection dispatch and its advertised method use the enabled `read_selection.terminal` entry. The registry is executable capability policy, not an unrelated literal list beside a hand-kept methods list. Keep existing method dispatch intact; no general schema migration.

Enabled now, because the skill already teaches them:

- `vocabulary.workspace_area_tab` version 1
- `send.explicit_tab` version 1
- `events.offline` version 1

Registered and omitted until the behavior is in the build:

- `routing.canonical_keys` (C11-279)
- `create.initial_input` (C11-280)
- `send.raw` (C11-281)
- `read_selection.terminal` (C11-282)
- `window.route_without_focus` (C11-283)

Landing order is binding: C11-284 merges first, then C11-279 → C11-283 → C11-280 → C11-282 → C11-281, followed by the bug/docs queue and admitted P2 work. Each command PR flips its own typed registry entry to enabled in the same commit that implements the behavior, and uses that entry at its dispatch seam. No absent-registry fallback or PR-only note is sufficient. C11-285/286 add enabled `cli.rpc`/`window.resize` only if those optional commands land. The integrated artifact must advertise exactly the features whose runtime scenarios pass; omission of a P2 command means omission of its flag. The hand-kept `methods` array stays as it is. This PR does not rebuild it from dispatch (cmux #16460). C11-282 may add the string `tab.read_selection` in that array; leave that line alone.

Add a short "Ask the running build" note to `skills/c11/SKILL.md`: `c11 guide` prints the skill shipped in this binary, and an installed copy can be older than that. One capabilities paragraph in `skills/c11/references/api.md`. Do not run the skill through the locale catalog.

## Files
- `Sources/CapabilityFeatures.swift` — registry, executable support queries and payload; app sources phase `A5001051` and CLI phase `B9000006A1B2C3D4E5F60719`. Hand-edit `project.pbxproj`; no xcodeproj gem.
- `Sources/BundledSkill.swift` — load one bundled page from a root directory, parse `skill_version`, reject `..` and slashes. Compile into both the app and CLI source phases above; this helper is called by the standalone CLI and tested through the app's logic module. Bundle identity loading may live in this Foundation-only helper.
- `Sources/SocketHandlers/SystemHandlers.swift` — the return dictionary at `:287-293`, plus a server identity read of `Bundle.main`. Do not reorder `methods`.
- `CLI/c11.swift` — `--skill` next to `:1748`, `guide` before `:1901`, capabilities merge at `:1961`, help at the `capabilities` case `:8502`, one usage line near `:17940`.
- `c11Tests/CapabilityFeaturesTests.swift` and `c11Tests/BundledSkillTests.swift` in c11LogicTests sources phase `37DDE3B0A6A70E75A7B2BEDF`. Hand-edit.
- `tests_v2/test_guide_and_features.py`.
- `skills/c11/SKILL.md` and `skills/c11/references/api.md`.

No `rpc`. No write under `~/.claude`. No `deliverSocketSendText`.

## Acceptance
1. `c11 --socket /tmp/c11-guide-no-such.sock guide` prints the bundled skill, a version line, and exits 0. `c11 --skill` prints the same body. The socket path is never connected. This is the no-app case.
2. The printed skill contains `rename-tab`. `c11 --help` also contains `rename-tab`. The printed skill says there is no `c11 list`. `c11 list` exits non-zero.
3. Against a tagged build, `c11 capabilities` JSON has `features`, `features_version`, `server`, `cli`, and `sha_match`. On the C11-284-only artifact the three existing ids are present and the five pending ids are absent. On each later artifact its newly implemented feature is present, with the others still absent. At integrated sign-off run the actual routing, create, selection, window scope and send scenarios and compare them with `capabilities.features`; the five enabled ids must all be present then. Check optional rpc/resize only when admitted and merged. If the commits differ, `sha_match` is false and both commits are in the JSON.
4. c11-logic exercises the production support-query/dispatch seam with an enabled and a disabled fixture registry: an unsupported feature is rejected by that seam and omitted from serialization; enabling it admits the command and advertises its version. Do not add a test that merely compares a serializer to the literal it reads or greps dispatch source. The C11-284-only tagged behavioral proof establishes the pending-feature absence; later command proofs establish presence. A bundle fixture containing only `C11Commit` must produce that commit, while a missing stamp yields unknown rather than the test checkout's HEAD. A temp-directory `BundledSkill` load reads `version: 7` from a fixture file and rejects a page named `../SKILL`. This is not a grep of the repo skill.
5. `stat` the mtime of `~/.claude/skills/c11` before and after `c11 guide`. Unchanged. If the directory is absent, it stays absent.

## Hot path
None. Guide is offline. Capabilities remains the snapshot it is. Do not move it onto the worker and do not walk windows.

## Strings
English only. `cli.guide.missing` = "This build has no bundled c11 skill." `cli.guide.unknown_page` = "No bundled skill page '%@'." The skill body is the English source. C11-291 translates the two keys, not the skill.

## Cut
No `c11 rpc` (C11-285). No `config doctor`. No per-method schemas. No rewrite of the installed skill and no launch-time sync. No fork-walkthrough agent. Do not retune `c11 version` or rebuild the `methods` list. Do not advertise a pending flag.

## Dependencies
Audit finding 8 is applied: this ticket lands before every CLI feature consumer. Consumers branch from current origin/main after this merge, enable their own registry entry with implementation, and record integrated feature verification on the final artifact. C11-292's final capabilities check is an integration gate, not a C11-284-only absence assertion.

`SystemHandlers.swift` methods list is the hunk C11-282 edits (one string near `:113`). This PR edits the return at `:287`. `CLI/c11.swift` `--window` parse at `:1732` and the focus prelude at `:1950` belong to C11-283. `--skill` sits next to `--version` (`:1748`), and the capabilities merge is the `case "capabilities"` arm (`:1961`), not the prelude. Guide's early return does not touch `send` (C11-281) or `new-*` (C11-280). C11-257: no send or mailbox files.

## Decisions
None. `features` entries are `{id, version}`. `features_version` starts at 1 and bumps only when an id's meaning changes. The three enabled ids are the ones the skill already teaches. Pending ids ship disabled only in this foundation PR, then their command PRs enable them atomically with behavior.

## Build
Branch `c11-1.0/C11-284-guide-features` from origin/main. Atlas: c11-logic for the registry and bundled-skill tests, then a tagged build with `C11_QA_LAUNCH` for the script. The guide check uses a bogus `--socket` so a running app is not required. Attribute any implementation commit to its actual author/model, not the previous planning owner. Sync the skill on the landing machine. Do not merge.

## Codex takeover verification
Owner: agent:codex-cli. Verified ticket, stored plan and cited code on intake origin/main 0ff8887e5e965400b01645ef40b85fd0b2605cf2. All behavioral checks above are planned, unperformed. Planning hold remains: no builds, tests, product-code commits or pushes until explicit BUILD MODE. Branch from current origin/main when this ticket starts, retaining predecessor merges and previous local commits.


## Build-mode validation adaptation (2026-10-01)
The go-owner brief supersedes the planning hold: implement now, with GitHub draft-PR CI until the Orchestrator sends ATLAS BUILDS LIVE. No local compilation/test/app launch. The implementation keeps the named file cut and wires tests_v2/test_guide_and_features.py --offline into BundledSkillTests in the existing c11-logic gate, so CI exercises the actual copied bundle CLI/resources with a bogus socket and verifies no installed-skill mutation. That smoke additionally uses synthetic Unix socket peers to exercise the real CLI's matching, mismatched and missing server identity handling. These fixture peers do not constitute live tagged server proof. The live --foundation-only smoke remains an Atlas tagged-build gate when enabled by the Orchestrator. Source skill edits are synced and compared locally under the repository's explicit installed-skill hard rule; guide itself never syncs or writes the install.

## Reset 2026-10-02 by agent:codex-cli
