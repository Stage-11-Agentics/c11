# Sparkle `SUSparkleErrorDomain(4005)` auto-update failure — root-cause investigation

**Date:** 2026-06-30
**Investigator:** Claude (Opus 4.8, max reasoning), c11 surface "Sparkle 4005 Debug"
**Installed app under investigation:** `/Applications/c11.app` — c11 0.53.0 (build 110), bundle `com.stage11.c11`, signed Authentic Technologies `UKQ4QALWD4`
**Update log:** `~/Library/Logs/cmux-update.log`

---

## TL;DR

- **Headline (Q1): This is LOCAL corruption on this one machine, NOT a release-process defect.** Every published DMG I could test — 0.53.0 (the version the operator is on), 0.54.0, 0.55.0, 0.56.0 — has a **structurally intact** `Sparkle.framework` (all symlinks present, `Versions/Current → B`, passes `codesign --verify --deep --strict`). The release pipeline is **not** flattening symlinks. Other 0.53 users are fine.
- **Mechanism of the failure (proven):** the *installed copy's* `Sparkle.framework` **and** `Sentry.framework` had **all of their symlinks deleted in place at 2026-06-29 20:51:33 EDT**. That makes the framework bundle wrappers invalid, so macOS cannot launch Sparkle's bundled installer (Autoupdate / Installer.xpc) → Sparkle reports **4005 ("An error occurred while launching the installer")** at the extraction→install handoff. This matches the log exactly: download 100% → EdDSA OK → `extracting(0%)` → instant 4005.
- **Actor (best-supported, not literally pid-attributable):** a **Finder file operation** (copy/move/merge) over the existing `/Applications/c11.app` that failed to recreate the framework symlinks. **Ruled out:** the release pipeline, a Sparkle install (none ran that day — the appcast only offered 0.53.0), and any Claude/Codex agent command or interactive shell command (exhaustive transcript + history search found nothing touching `/Applications/c11.app` with a mutating verb).
- **Q3:** the bundle id changed `com.stage11.c11mux` → `com.stage11.c11` at **v0.38.0** (2026-04-20, #37). Anyone still running a **pre-0.38.0 Stage 11 build** (`com.stage11.c11mux`, or older `com.cmuxterm.app` / `ai.manaflow.cmuxterm`) is **permanently stranded** on auto-update by a Sparkle bundle-id mismatch and needs a one-time manual reinstall. The operator's 0.53 is `com.stage11.c11`, so this is **not** the operator's problem — it's a separate cohort risk.
- **Q4:** `cmux-update.log` is a cosmetic rename leftover (`Sources/Update/UpdateLogStore.swift:18`). The actual update config (`SUFeedURL`, `SUPublicEDKey`, bundle id) is all correct. Not a functional issue.
- **Q5:** the app already maps 4005 to **"c11 needs to live in Applications" / "Move c11 into Applications and relaunch."** That message is **wrong for this failure mode** (the app is already in /Applications) and offers no escape hatch. Add a "Download latest manually" action and broaden the 4005 copy.

---

## Q1 — Release-process defect (all users) vs local corruption (this machine)?

### VERDICT: Local, post-install corruption on this machine. Confidence: **very high.**

I downloaded all four candidate DMGs from `Stage-11-Agentics/c11` releases, mounted each read-only (`hdiutil attach -nobrowse -noautoopen`), and inspected the framework structure + signature:

| DMG | top-level Sparkle symlinks | `Versions/Current → B` | `codesign --verify --deep --strict` | bundle id |
|-----|---------------------------|------------------------|-------------------------------------|-----------|
| **0.53.0** (operator's version) | all present (Autoupdate, Resources, Sparkle, Updater.app, XPCServices) | present | **valid on disk / satisfies DR** | com.stage11.c11 |
| 0.54.0 | all present | present | valid on disk / satisfies DR | com.stage11.c11 |
| 0.55.0 | all present | present | valid on disk / satisfies DR | com.stage11.c11 |
| 0.56.0 | all present | present | valid on disk / satisfies DR | com.stage11.c11 |

The **published 0.53.0 DMG that the operator originally installed from is intact.** Therefore the pipeline did not ship a broken framework, and the corruption happened **after** install, on this machine only.

Corroborating evidence from the release workflow (`.github/workflows/release.yml`): the app is signed `codesign --force --options runtime --timestamp --deep` and then **verified with `codesign --verify --deep --strict --verbose=2` (line 252)** *before* DMG packaging. A framework missing its `Versions/Current` symlink fails that exact check (we see it fail on the corrupted local copy). So a symlink-stripped framework could not have passed CI. The DMG is then built by `create-dmg` (which uses `hdiutil` on an HFS+ image — symlink-preserving), notarized, and stapled. Nothing in that chain flattens symlinks, and the mounted artifacts prove it empirically.

---

## The proven mechanism of 4005

`SUSparkleErrorDomain` code **4005** = "An error occurred while launching the installer." Sparkle throws it when it cannot spawn its bundled installer (the `Autoupdate` helper / `Installer.xpc` that live inside `Sparkle.framework/Versions/B`). The download and EdDSA signature checks happen *before* this point — which is why the log shows a full 100% download, signature acceptance, `show extraction started`, then an immediate 4005 (`~/Library/Logs/cmux-update.log` tail, 2026-06-30T23:08:40Z).

The installed framework is malformed:

```
/Applications/c11.app/Contents/Frameworks/Sparkle.framework/
  └── Versions/            (only this — NO Autoupdate/Resources/Sparkle/Updater.app/XPCServices symlinks)
        └── B/             (intact payload, Jun 16)
        (NO  Current → B  symlink)
```

`Sentry.framework` is damaged identically (only `Versions/A`, no `Current`, no top-level symlinks). These are the **only two** frameworks in the bundle; **both** are stripped.

- `codesign --verify --deep --strict /Applications/c11.app` →
  `bundle format unrecognized, invalid, or unsuitable` in subcomponent `Sparkle.framework`.
- The **payloads are fine**: e.g. `Sparkle.framework/Versions/B/Updater.app` is still correctly signed —
  `Identifier=org.sparkle-project.Sparkle.Updater`, `Authority=Developer ID Application: Authentic Technologies Inc. (UKQ4QALWD4)`, `TeamIdentifier=UKQ4QALWD4`.

So macOS can't validate/launch the framework's installer because the **bundle wrapper** is invalid (missing `Versions/Current` + top-level symlinks), even though the helper binaries inside are intact and validly signed. → 4005.

This also confirms **proven fact #1** from the brief (the signer/team is a red herring): 0.54/0.55/0.56 fail identically regardless of signing team because the failure is on the *receiving* (installed) side, before the new bundle's signature is ever relevant.

---

## Q2 — What stripped the symlinks (and when)?

### When: 2026-06-29 20:51:33 EDT. Confidence: **very high (exact, from two independent sources).**

**Filesystem timestamps** (`stat`):

| path | mtime |
|------|-------|
| `/Applications/c11.app` | Jun 16 13:31 (install/move time) |
| `…/Contents` | Jun 16 01:50 |
| `…/Contents/Frameworks` | **Jun 16 01:50 (UNCHANGED)** |
| `…/Sparkle.framework` | **Jun 29 20:51:32** |
| `…/Sparkle.framework/Versions` | **Jun 29 20:51:32** |
| `…/Sparkle.framework/Versions/B` | Jun 16 01:50 (unchanged) |
| (Sentry.framework / its Versions) | **Jun 29 20:51:32** |

**Unified log** (`log show`), the smoking gun at the same instant:

```
2026-06-29 20:51:33.142  UserEventAgent  [com.apple.fsevents.matching:All]
   Received FSEvent about …/Sparkle.framework/Resources
   Received FSEvent about …/Sparkle.framework/Versions/Current
   Received FSEvent about …/Sparkle.framework/Autoupdate
   Received FSEvent about …/Sparkle.framework/Updater.app
   Received FSEvent about …/Sparkle.framework/XPCServices
   Received FSEvent about …/Sparkle.framework/Sparkle
   Received FSEvent about …/Sentry.framework/Resources
   Received FSEvent about …/Sentry.framework/Versions/Current
   Received FSEvent about …/Sentry.framework/Sentry
```

The FSEvent set is **exactly the symlink nodes** of both frameworks — nothing else.

### The fingerprint: a pure symlink deletion

The mtime pattern is decisive. `Contents/Frameworks` (the parent of the `.framework` dirs) is **untouched**, so the frameworks were **not** deleted-and-recreated as units (that would bump `Frameworks`). Only the **entries inside each `.framework` dir and inside each `Versions/` dir** changed, and the real payloads (`Versions/A`, `Versions/B`) kept their Jun-16 mtime. That is the precise signature of **"all symlinks removed in place, nothing added"** — equivalent to a `find … -type l -delete` over the app, or a copy/sync that dropped symlinks rather than recreating them.

### What it was NOT (ruled out)

- **Not the release pipeline** (Q1: every DMG intact).
- **Not a Sparkle self-update.** On Jun 29 the appcast only offered 0.53.0; the update log shows repeated `no update found (reason=onLatestVersion, latest=0.53.0)` all day. 0.54.0 wasn't published until Jun 30. No installer ran on Jun 29. (Also: the corruption predates the first 4005 attempt by ~26h, so the failed update attempts didn't cause it.)
- **Not a c11 reload/QA/build script.** `scripts/reload.sh` writes its CLI shim into PATH dirs (`/opt/homebrew/bin`, `~/.local/bin`, …) and explicitly **breaks at the `/Applications/c11.app/.../bin` boundary** (`select_cli_shim_target`, lines 76-78) — it never writes into the installed app's frameworks. `scripts/reloads.sh` copies the built app to a *staging* path in DerivedData, not `/Applications`. No repo script does `find -type l -delete`, `rsync --delete`, or `ditto`/`cp` into `/Applications/c11.app`. Confirmed: `bin/c11` in the installed app is still the **real Mach-O binary** (Jun 16), not a shim — so reload never touched it.
- **Not an AI agent or an interactive shell command.** I searched every Claude transcript under `~/.claude/projects` and `~/.codex` for a Bash command containing `/Applications/c11.app` with any mutating verb (`rm`, `cp`, `rsync`, `ditto`, `find -delete`, `codesign --force`, `xattr`): **none**. The two c11-project sessions and the `c11-151`/`c11-153` worktree sessions that were live in the 20:30–21:05 window contain **no** such command. `~/.zsh_history` / `~/.zsh_sessions` for Jun 28–30 contain **nothing** touching the installed app. The brief's hypothesis "was a reload/QA script pointed at /Applications?" is answered: **no.**

### What it most likely WAS: a Finder file operation. Confidence: **moderate-high.**

At the corruption instant the **only** userland process doing a file/disk operation was **Finder [pid 684]**. From 20:50:30 to ~20:51:40 Finder created/removed a `diskarbitrationd` session every ~2 seconds — the classic free-space-polling cadence Finder runs **during an in-progress copy/move** (to drive the progress bar). The symlink deletion lands in the middle of that activity (20:51:33), and the polling tapers off right after (~20:51:40, around when the prod c11 app was relaunched via Dock).

The honest caveat: macOS's unified log / FSEvents records the path of each change and the **observer** (`UserEventAgent`), but **not the pid that performed the unlink**. So "Finder did it" is established by temporal co-occurrence + process-of-elimination (no shell, no agent, no script, no Sparkle, no pipeline), not by a literal "Finder unlinked X" line.

Best-supported story: someone (or an automation acting through Finder) **dragged/copied a `c11.app` over the existing `/Applications/c11.app`** — a manual "reinstall by drag," possibly **interrupted/merged** — and that operation removed the framework symlinks without recreating them. The unchanged top-level bundle/`Contents`/`Frameworks` mtimes mean it was **not** a clean full replace (that would have rewritten them and bumped the version off 0.53); it was a partial touch confined to the framework interiors. A normal completed Finder copy preserves symlinks, so the most consistent variants are a **merge** or an **interrupted/aborted copy** that deleted the old symlinks in the framework dirs before (re)writing them and never finished.

**What would upgrade this to certain:** the operator's recollection of a manual drag-install of c11 around 20:51 on Jun 29, or a live `fs_usage`/EndpointSecurity capture (not retroactively available). The "external media mounted ~8h" note in the log is just the iOS Simulator's `simdiskimaged`, not a c11 DMG, so I can't tie it to a specific mounted installer image.

> Side note that initially looked suspicious but is benign: from 20:45–20:51 the log shows `loginwindow` repeatedly registering `…/Resources/bin/c11` and `appDeath` for it. That is **LaunchServices noticing each short-lived `c11` CLI invocation** (an agent/Overwatch loop hammering the CLI), not the bundle being rewritten. It probes `bin/c11` for a `_MASReceipt` and logs "Not a directory" because `bin/c11` is a Mach-O, not a bundle. Unrelated to the symlink strip.

---

## Q3 — Bundle-identifier continuity across the rename

### Bundle id DID change. A pre-0.38.0 cohort is permanently stranded. Confidence: **high.**

`PRODUCT_BUNDLE_IDENTIFIER` history (from `git log -p` on `GhosttyTabs.xcodeproj/project.pbxproj` + CHANGELOG):

1. `com.ghosttytabs.app` (origin)
2. `com.cmux.app` / `com.cmuxterm.app` (cmux era; upstream also `ai.manaflow.cmuxterm`)
3. **`com.stage11.c11mux`** — Stage 11 fork brand pass (~0.36–0.37, #36). Display name became "c11" but the **bundle id was still `com.stage11.c11mux`**.
4. **`com.stage11.c11`** — first shipped in **v0.38.0** (commit `6d0bc1a84`, 2026-04-20, #37 "Collapse cmux/c11mux → c11 across all structural surfaces").

Sparkle matches an update to the running app by `CFBundleIdentifier`. All current DMGs (0.53–0.56) are `com.stage11.c11`, and the appcast feed (`…/releases/latest/download/appcast.xml`) is shared across all builds. Consequences:

- **Pre-0.38.0 Stage 11 users** running `com.stage11.c11mux` (or older `com.cmuxterm.app` / `ai.manaflow.cmuxterm`) pull the same appcast, see a `com.stage11.c11` item, and Sparkle treats it as a *different app* → silently never updates. **Permanently stranded; requires a one-time manual reinstall.** This is independent of the symlink bug and is not auto-recoverable by any future build.
- **0.38.0+ users** (including the operator on 0.53) are all `com.stage11.c11` → no bundle-id discontinuity among them.

The operator's 4005 is **not** a bundle-id problem (their installed app and every candidate update are all `com.stage11.c11`). But the c11mux cohort is a real "handle existing users gracefully" gap worth a deliberate decision.

---

## Q4 — Why does a `com.stage11.c11` app log to `cmux-update.log`?

### Harmless rename leftover. Confidence: **very high.**

`Sources/Update/UpdateLogStore.swift:18` hardcodes the path:

```swift
logURL = logsDir.appendingPathComponent("Logs/cmux-update.log")
```

(plus a cosmetic dispatch-queue label `cmux.update.log:7`, and a sibling `cmux-focus.log:81`). It is purely the **log filename** — it does not touch the update mechanism. The actual updater config is correct and verified on the installed app:

- `SUFeedURL = https://github.com/Stage-11-Agentics/c11/releases/latest/download/appcast.xml` ✓ (the c11 repo)
- `SUPublicEDKey = naW2p9Qixxto6tuJUi+NgmJU8EOx2vdRazhi0jwBALk=` ✓ (EdDSA validates — the log reaches extraction)
- `CFBundleIdentifier = com.stage11.c11` ✓

`UpdateDelegate.swift` resolves the feed correctly with a sane fallback. So `cmux-update.log` is a cosmetic straggler from the `cmux`→`c11` rename, not a symptom of a broken update path. (Worth renaming to `c11-update.log` for hygiene — but migrate/keep the old path readable, since support muscle-memory and existing logs point at the old name.)

---

## Q5 — Graceful handling for existing users (ranked)

### Layer A — Release-process hardening
**Not required for a defect** (Q1: the pipeline is healthy). But cheap insurance, **future builds only:**

1. **(low effort, high value) Post-DMG verification gate.** After `create-dmg`, mount the produced DMG in CI and run `codesign --verify --deep --strict` on the app *inside the mounted image* (not just the pre-package app). This catches any future symlink-flattening regression at the source instead of in the field. *(future builds only)*
2. **(optional) Ship Sparkle delta/patch updates** so a future update can repair an app whose framework wrapper is damaged. Lower priority.

### Layer B — In-app graceful failure (highest leverage for "don't dead-end users")
The app already routes 4005 through `UpdateViewModel.swift` (titles ~L249, messages ~L306) — but the current copy is **wrong for this case**:

- Title: **"c11 needs to live in Applications"**
- Body: **"Move c11 into Applications and relaunch to enable updates."**

The operator's app **is** in `/Applications`, so this is a confusing dead end. 4005 has *multiple* causes (app not in /Applications, Gatekeeper path-translocation, **or a damaged Sparkle.framework/installer that can't launch** — this case). Recommended, **future builds only** (cannot help an already-broken install, since the fix ships *in* the update that can't install):

1. **(med effort, high value) Rewrite the 4005 path to offer a manual escape hatch.** Replace the dead-end message with: "c11 couldn't launch its installer. Download the latest version manually to continue." + a primary button **"Download Latest"** → `https://github.com/Stage-11-Agentics/c11/releases/latest` (and a secondary "Show in Finder / Open Applications"). A manual DMG reinstall fixes both the not-in-Applications cause *and* the damaged-framework cause. The releases page works for every cause of 4005.
2. **(med effort) Self-diagnose before blaming location.** On 4005, check whether the app is already in `/Applications`; if so, suppress the "move me" copy and show the damaged-installer + manual-download path instead. Optionally verify own `Sparkle.framework` integrity (e.g., `Versions/Current` exists) and label the error accurately.
3. **(low effort) Rename `cmux-update.log` → `c11-update.log`** (keep reading the old path if present). Hygiene; aids support. *(future builds only)*

### Layer C — Communication (only lever that helps ALREADY-broken installs)
4. **(low effort, helps current broken installs) Tell affected users to reinstall once.** A release note / pinned announcement: *"If c11 auto-update fails with error 4005, download the latest DMG from the releases page and drag it over c11 in Applications once; auto-update resumes afterward."* This is the **only** remedy that reaches an install already on a broken build (the operator's machine included) — the in-app fixes can't, because they'd have to arrive via the update that can't install.
5. **(low effort, separate cohort) Address the c11mux bundle-id cohort (Q3).** Anyone still on `com.stage11.c11mux`/`com.cmuxterm.app` will never auto-update. If any such installs are suspected in the wild, a one-time "please reinstall from releases" notice (Homebrew cask note, README, Discord/Zulip) is the only fix; no future `com.stage11.c11` build can reach them automatically.

### The operator's immediate fix (this machine)
**Re-download the latest DMG and reinstall** (replace `/Applications/c11.app` from the intact 0.56.0 DMG, or drag-replace). The published artifacts are verified intact; a clean install restores the framework symlinks and auto-update will work again. (A surgical alternative — manually recreating the `Versions/Current → B` and top-level symlinks in both frameworks and re-signing — would also work but a clean reinstall is simpler and lower-risk, and re-signing isn't possible without the Developer ID identity.)

---

## Confidence summary

| Claim | Confidence |
|-------|-----------|
| Q1: local corruption, not a pipeline defect (all DMGs intact + codesign-valid) | very high |
| 4005 caused by stripped framework symlinks (invalid bundle wrapper → installer won't launch) | very high |
| Both Sparkle + Sentry frameworks stripped at 2026-06-29 20:51:33 EDT | very high (stat + unified-log FSEvents agree) |
| Not pipeline / not Sparkle-install / not a c11 script / not an agent or shell command | high (exhaustive elimination) |
| Actor = a Finder copy/move/merge over the install that dropped symlinks | moderate-high (only active file-op process; pid not log-attributable) |
| Q3: bundle id flipped to com.stage11.c11 at v0.38.0; pre-0.38.0 cohort permanently stranded | high |
| Q4: cmux-update.log is a harmless rename leftover; update config otherwise correct | very high |

## Reproduction / evidence commands
- DMG checks: `gh release download v0.53.0 … --pattern c11-macos.dmg`; `hdiutil attach -nobrowse -noautoopen`; `codesign --verify --deep --strict --verbose=2`; `ls -la …/Sparkle.framework{,/Versions}`.
- Installed-app forensics: `stat -f '%Sm %N' …`; `xattr -l /Applications/c11.app`.
- Timeline: `log show --info --debug --start "2026-06-29 20:50:30" --end "2026-06-29 20:53:30" --style compact` (FSEvents at 20:51:33.142; Finder diskarbitration polling).
- Elimination: grep of `~/.claude/projects` + `~/.codex` transcripts and `~/.zsh_history` for `/Applications/c11.app` + mutating verbs (none).
- Bundle-id history: `git log -p -- GhosttyTabs.xcodeproj/project.pbxproj | grep PRODUCT_BUNDLE_IDENTIFIER`; first `com.stage11.c11` = `6d0bc1a84` (v0.38.0).
