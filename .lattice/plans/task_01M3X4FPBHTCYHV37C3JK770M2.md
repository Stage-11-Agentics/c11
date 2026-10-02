# C11-293 — consume C11-312 and publish the approved signed bytes

Actor `agent:codex-atlas`. Planning only. Verified base `0ff8887e5e965400b01645ef40b85fd0b2605cf2`. Later branch `c11-1.0/C11-293-release-1.0.0` from then-current origin/main. No code changes, builds/tests, workflow dispatches, pushes, tags or publication now. Audit findings 5–7 govern this release contract.

## Ownership and gates

C11-312 now owns artifact-only signing workflow/helper, proof builds, artifact manifest and Atlas retrieval guidance. It lands early, before C11-307/C11-298 proof and C11-292 rehearsal. This ticket consumes it and owns final release engineering plus deterministic approved-byte promotion in the production release workflow. No signing workflow or early signing slice is owned here. C11-292 does not depend on C11-293 completion.

Atin's option A remains: Apple and Sparkle secrets stay in Actions. The signed candidate comes from C11-312, without publication. C11-293 publishes the exact approved bytes without rebuilding/re-signing/re-stapling. Debug sign-off and approval of signed hashes are separate. Final release preparation waits on C11-292 rehearsal and Atin's named sign-off; publication also waits on his named signed-byte approval, relayed as explicit Orchestrator instruction. Do not merge or cut a release autonomously.

## Verified citations

- #490 refusal already exists in `Sources/Workspace.swift:3118-3130`; `0ff8887e5e` must be an ancestor of final source. C11-290 owns the API reference correction.
- Base marketing version is `0.67.0`, build 131; use `RELEASE_TAG_BUMP=1 scripts/bump-version.sh 1.0.0` and respect the Sparkle floor-fetch failure.
- `release.yml:1-8` currently couples v-tag/manual dispatch to build/sign/upload; upload is at 327–341. `scripts/build-sign-upload.sh` is absent. C11-312 does not change this production behavior; this ticket must amend it before a v1.0.0 tag can trigger publication.
- `scripts/release_asset_guard.js` requires eight immutable assets (DMG/appcast/four daemon binaries/checksums/manifest). Complete names alone do not prove approved bytes; partial sets are failures.
- Release skill/threat model cite deleted BrowserPanel paths. Present files are `Sources/Tabs/BrowserTab.swift`, `Sources/Tabs/BrowserTabView.swift`, `Sources/BrowserWindowPortal.swift`; include `Sources/Workspace.swift` and refresh the AppDelegate open-handler citation on the release SHA.

## Promotion architecture and files

- Modify `.github/workflows/release.yml` with a separate `workflow_dispatch` promotion job accepting C11-312 signing run id, approved full source SHA, DMG hash and appcast hash. Validate successful repository/workflow run, purpose `candidate`, source/version/build/target tag, and complete immutable file set; verify every file against its manifest. No compile/sign/notarize step in promotion.
- Deterministically disable the legacy build-sign-upload job for `v1.0.0` tag pushes before creating that tag. Tag handling may validate or skip but cannot rebuild/upload even for a partial publication. Do not rely on racing `gh run cancel`.
- After signed-byte approval, create annotated `v1.0.0` at the manifest source SHA and verify its peeled target. Create a draft release for that tag, upload complete approved files, download and verify all hashes, and publish as latest only after that verification. A partial draft remains unpublished and reports failure; do not overwrite existing immutable assets. Preserve unrelated release behavior.
- Add executable `scripts/promote_signed_artifact.js` (or equivalent) for candidate/run/manifest validation and promotion, and runtime fixture tests in `tests/`. C11-312's signed manifest contract is authoritative; do not duplicate a signing producer.
- Release PR also edits `CHANGELOG.md`, version fields via the bump script, threat-model paths in `skills/release/SKILL.md` and `docs/security-threat-model.md`. Skill sync only after Orchestrator-confirmed merge and verification of installed content.

## Final release sequence and files

Wait for C11-292's passed Atlas rehearsal and Atin's named sign-off. C11-291's full six-locale pass is mandatory; string changes refresh C11-291 and C11-292. All admitted P0/P1 closure and C11-270 final candidate proof must match the integrated source/submodules; ancestor relation alone is insufficient.

1. Branch `c11-1.0/C11-293-release-1.0.0` from current origin/main; follow `skills/release/SKILL.md` pre-flight within this run's authority. Record include/defer choices from the Orchestrator. No new feature admission.
2. Edit `CHANGELOG.md` (Added/Changed/Fixed/Removed, sourced contributor handles). One Fixed bullet states commands from a `c11 ssh` shell do not run on the Mac. The docs page renders this file; do not create another changelog.
3. Update `skills/release/SKILL.md` threat-model paths and `docs/security-threat-model.md` to actual files/posture after reading the release-range diff. Neutral public wording, no transcripts. Attribute commits to actual authors; no Grok co-author trailer on Codex work.
4. Run `RELEASE_TAG_BUMP=1 scripts/bump-version.sh 1.0.0`, commit, push, open the release PR with rehearsal SHA/tag and changed installable skills listed. Do not merge. No tag push.
5. After Orchestrator-confirmed merge, run `scripts/sync-installed-skills.sh` for the changed installed skills and verify live copies. Never sync during planning. No tenant hooks/config writes.
6. If useful, run an ad-hoc Release compile/smoke on Atlas through C11-216; it is not the signed candidate. Build/test/UI work remains off Hyperion.
7. Stage the merged versioned candidate through C11-312 artifact-only Actions signing, verify signatures/notarization and hashes, and drive its real packaged path on Atlas. Record full SHA, submodule SHAs, build/version, run URL, manifest and hashes. C11-292's Debug pass does not prove the signed Release app. Material product changes refresh impacted gates; metadata-only differences must be documented and checked.
8. Send DECISION with the concrete candidate DMG/appcast hashes and artifact link; use `lattice needs-human`. Wait for Atin's named approval of those bytes. Approval of a source SHA or Debug tag is not signed-byte approval.
9. Only under the Orchestrator's explicit publication instruction relaying that approval, create/verify the exact annotated tag, dispatch promotion, and verify downloaded release bytes and `releases/latest = v1.0.0`, including `appcast.xml`. Check no nightly, xcframework or proof artifact took latest. No rebuilding the approved candidate.

## Acceptance → incident/fixture → proof

1. SSH refusal ships. Existing #490 behavior → changelog inspection and `0ff8887e5e` ancestor check on final source; do not fake a source-text regression test.
2. Signed bytes preexist approval/publication. Base tag rebuild/upload coupling and prior cancellation race → C11-312 candidate run manifest/hashes and Atin's named approval recorded on this ticket. Verify real signed Release artifact on Atlas before approval; Debug rehearsal alone is not Release proof.
3. Promotion behavior. Fixtures with real candidate files and synthetic GitHub run metadata on Atlas: matching candidate promotes recorded bytes; altered DMG/appcast/daemon hash, purpose proof, wrong source/workflow/run, and incomplete set refuse without publication. Mock dispatch/tag job admission, not workflow-source text; no real publishing workflow as a smoke test.
4. Skill freshness. One-time installed copies → sync after confirmed merge, compare installed content and report changed installable skill names. Never sync during planning.
5. Published identity/feed. Only after explicit publication instruction: verify annotated tag source, complete asset hashes, `releases/latest = v1.0.0`, and `appcast.xml` presence. Proof, nightly and xcframework assets never take latest. Do not call unsigned staging a release.

## Dependencies and impact

C11-312 producer; C11-307/C11-298 signed proof; C11-292's passed Atlas rehearsal and Atin's pass; mandatory C11-291 locale evidence and C11-270 final candidate proof matching integrated source/submodules. C11-216 supplies Atlas build/validation path. No new feature/P2 admission. No input/sidebar/socket changes, new localized strings, session migration, tenant config or certificate copying. No signing on Atlas. C11-312 owns the signing path; C11-293 owns production promotion only.

CUA runs on Atlas with verified display, hard timer, readable areas and synthesized-input dismissal. Tests/builds stay off Hyperion. Evidence stays on this ticket; HANDOFF only to Orchestrator. Three review cycles maximum; no owner merge/release.

## Decisions

No new planning decision. Option A stands. At publication, the concrete C11-312 candidate must receive Atin's named hash approval, then Orchestrator instruction; no inferred approval from elapsed time, source SHA, or Debug tag.
