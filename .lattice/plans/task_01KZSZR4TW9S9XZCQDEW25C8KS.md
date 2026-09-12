# C11-207: Socket-driven browser navigation fails silently when it cannot prompt

FOUND BY. Reviewing PR #417 (C11-204), which removed the app-modal runModal fallback from the browser insecure-HTTP prompt and the JS dialog paths.

CONTEXT. Before #417, 'c11 browser open http://...' behind a backgrounded window put up an app-modal alert nobody could see and wedged every surface in the app, for up to 6.8 hours in the measured worst case. #417 correctly replaced that with a safe default: with no window available to host the sheet, the insecure-HTTP navigation is denied without prompting.

THE GAP. That is strictly better than a hang, but it is silent from the caller's side. An agent that runs 'c11 browser open http://example.com' while the window is backgrounded now gets a navigation that simply does not happen. The only trace is an NSLog line in the app's stderr, which the calling agent cannot see. The agent has no way to distinguish 'the page failed to load' from 'c11 refused an insecure navigation because no human was available to approve it', and no way to consent to the navigation on its own authority.

This matters because socket-driven browser navigation is a routine c11 workflow: it is how agents validate web work (see the c11-browser skill), and doing it against a local http:// dev server behind an unfocused window is the common case, not the edge case.

WORK. Give the caller an actionable answer. Two pieces, either or both:
1. The socket command should return a structured error naming the reason, so the agent sees 'insecure HTTP navigation blocked: no window available to prompt' rather than a silent no-op.
2. Provide an explicit opt-in so an agent can consent without a human: a flag on the open verb, or a socket verb to add a host to the insecure-HTTP allowlist. Prefer scoping it narrowly (localhost and private-range hosts are the realistic need for dev-server validation).

Whatever the shape, the c11-browser skill must be updated to match, per the CLAUDE.md rule that a CLI or socket change is incomplete until the skill teaches it.

RELATION. Follow-up to C11-204 / PR #417. Not a blocker for that PR: the hang fix is worth landing on its own, and this is additive.

---

# Implementation Plan (C11-207 delegator, 2026-09-11)

## Findings from the code

- `BrowserPanel.navigate(to:)` / `navigateSmart(_:)` / `requestNavigation(_:intent:)` are **fire-and-forget** (`-> Void`). Every socket navigation path therefore discards the block decision.
- `presentInsecureHTTPAlert` (`Sources/Panels/BrowserPanel.swift:4010`) has exactly two terminal shapes:
  - a window exists: `alert.beginSheetModal(for:)` and return immediately (a human will answer later);
  - no window exists: `NSLog(...)` plus `handleResponse(BrowserInsecureHTTPPromptPolicy.unpromptedResponse)`, i.e. Cancel. **This is the silent no-op the ticket is about.**
- **Loopback is already default-allowed.** `BrowserInsecureHTTPSettings.defaultAllowlistPatterns` = `localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me`, and `normalizedAllowlistPatterns` falls back to that list whenever the `browserInsecureHTTPAllowlist` default is unset or empty (verified: `defaults read com.stage11.c11 browserInsecureHTTPAllowlist` -> does not exist on this machine).
- `Workspace.newBrowserSurface(inPane:...)` already accepts `bypassInsecureHTTPHostOnce`; `newBrowserSplit(from:...)` does not.
- CLI renders v2 errors as `"\(code): \(message)"` and **drops `data`** (`CLI/c11.swift:1320-1333`). Anything an operator/agent must read has to be in `message`, or the CLI must be taught to append it.
- `CLI/c11.swift` is a member of the `c11-cli` target only, so its argument parsing is **not reachable from `c11LogicTests`**. CLI-level proof comes from the phase-4 socket run.

## Decision: loopback default-allow

**Keep the existing loopback default-allow; do not widen it to private ranges.** Justification:

1. The ticket's stated common case (`http://127.0.0.1:<port>` dev server) is **already allowed** without a prompt, so the loopback question is settled in the shipped code and needs documenting, not changing.
2. The residual silent-block surface is non-loopback plain HTTP: LAN/private-range hosts (`192.168.x.x`, `10.x.x.x`), tailnet hostnames (`atlas:8737`), and public HTTP. Those are genuinely readable/modifiable on a shared network, so a blanket default-allow would weaken the guard the allowlist exists to provide, for every c11 user, to save agents one flag.
3. The agent's need is served precisely by an **explicit per-navigation opt-in**: the socket caller is already fully privileged (it can run arbitrary JS via `browser.eval`), so letting it consent for one navigation adds no new authority, while keeping the default posture intact and leaving no persistent state behind.

## Changes

### 1. Navigation reports a disposition (`Sources/Panels/BrowserPanel.swift`)

- New AppKit-free types near `BrowserInsecureHTTPPromptPolicy`:
  - `enum BrowserInsecureHTTPBlockReason: String { case noWindowToPrompt = "no_window_to_prompt" }`
  - `enum BrowserNavigationDisposition: Equatable { case proceeded; case prompting(host: String); case blocked(host: String, reason: BrowserInsecureHTTPBlockReason) }`
  - `func browserInsecureHTTPBlockedError(host:urlString:reason:) -> (code: String, message: String, data: [String: Any])` — pure, returns code `insecure_http_blocked`, a message naming the reason **and** the remedy, and `data` with `host` / `url` / `reason` / `hint`.
- `navigate(to:recordTypedNavigation:)`, `navigateSmart(_:)`, `presentInsecureHTTPAlert(...)`, `requestNavigation(...)` become `@discardableResult` returning `BrowserNavigationDisposition`; every existing call site is unchanged.
- `private(set) var lastNavigationDisposition: BrowserNavigationDisposition?` records the most recent decision, so `browser.open_split` (whose navigation happens inside `BrowserPanel.init`) can read it back synchronously after panel construction.
- `navigateSmart(_:allowInsecureHTTP:)` overload: when `allowInsecureHTTP` is true and the resolved URL is `http://`, seed `insecureHTTPBypassHostOnce` with that host before navigating, reusing the existing one-time-bypass mechanism (non-persistent, single navigation, nothing written to the allowlist).
- The no-window branch keeps the existing NSLog and the Cancel default. **No new modal, nothing app-modal, `browserPresentModalAlert`/`beginSheetModal` untouched.**

*Observable:* a `BrowserPanel` whose window provider returns nil and which is asked to navigate to a non-allowlisted `http://` URL reports `.blocked(host:reason:.noWindowToPrompt)` and still does not load.

### 2. Socket handlers return the structured error (`Sources/SocketHandlers/BrowserHandlers.swift`)

- `browser.navigate`: read `allow_insecure_http` (bool, default false); call the new `navigateSmart` overload; on `.blocked` return `.err(code: "insecure_http_blocked", message:, data:)` from the pure builder; on `.prompting` return `.ok` with an added `insecure_http` object `{status: "prompted", host: ...}` so the caller knows a human still has to answer; on `.proceeded` the payload is byte-identical to today.
- `browser.open_split`: read the same param; pass the URL's host as `bypassInsecureHTTPHostOnce` into `newBrowserSurface` / `newBrowserSplit` when opted in; after creation read `lastNavigationDisposition` and, when blocked, return the same structured error with the **surface/pane refs included in `data`** (the split really was created; the navigation is what failed).
- `Sources/Workspace.swift`: add `bypassInsecureHTTPHostOnce: String? = nil` to `newBrowserSplit(from:...)`, forwarded to `BrowserPanel.init` (the sibling `newBrowserSurface` already has it).
- Scope guard honoured: **no edits to `v2AwaitCallback` or the JS-eval await path** (C11-209's territory).

*Observable:* `c11 --json browser open http://<lan-ip>:<port>` against a backgrounded window exits non-zero with `insecure_http_blocked: ...`, instead of exiting 0 with a blank page.

### 3. CLI (`CLI/c11.swift`)

- `browser open|open-split|new` and `browser goto|navigate`: parse `--allow-insecure-http` **before** the URL is assembled from the remaining args (the current code joins every non-consumed arg into the URL, so an unparsed flag would corrupt the URL), and send `allow_insecure_http: true`.
- `sendV2` error path: when the error `data` carries a `hint` string, append it to the `CLIError` message. Generic, one line, and it is what makes the remedy visible at the terminal since `data` is otherwise dropped.

*Observable:* `c11 browser <surface> goto http://<lan-ip>:<port> --allow-insecure-http` navigates and `c11 browser <surface> get title` returns the served page's title.

### 4. Tests (`c11Tests/BrowserCompanionPolicyTests.swift`, `c11LogicTests` target)

Added to the existing file that already owns `BrowserInsecureHTTPPromptPolicy` coverage, so **no `project.pbxproj` edit** (and none of the gem-normalisation diff bloat CLAUDE.md warns about).

- Default allowlist allows `127.0.0.1`, `localhost`, `::1` and blocks `192.168.1.5` and `example.com` via `browserShouldBlockInsecureHTTPURL(_:rawAllowlist:)` — pins the loopback decision above as executable behaviour.
- `browserInsecureHTTPBlockedError` returns code `insecure_http_blocked`, a message naming both the reason and the opt-in, and `data` carrying `host`/`url`/`reason`/`hint`.
- One-time bypass consumption (`browserShouldConsumeOneTimeInsecureHTTPBypass`) fires once for the opted-in host and is cleared afterwards — the mechanism the `--allow-insecure-http` flag rides on.

Not practical to unit-test locally: the `BrowserPanel` disposition itself lives in the host-app target (`c11Tests`) and constructing a panel needs `NSApp`; the existing `BrowserInsecureHTTPAlertPresentationTests` in that file already covers the no-window branch and runs in CI. CLI flag parsing is not reachable from any unit target (see Findings) and is proven in phase 4. Stated explicitly per the test-quality policy rather than faked with a source-grep test.

### 5. Skill (`skills/c11-browser/SKILL.md`)

New short section "Plain `http://` navigation": loopback/`*.localtest.me` allowed by default; any other plain-HTTP host prompts the operator; behind a backgrounded window there is nobody to prompt, so the call fails with `insecure_http_blocked`; pass `--allow-insecure-http` to consent for that one navigation. Then `scripts/sync-installed-skills.sh c11-browser` (HARD RULE in CLAUDE.md).

### 6. Localization

No new **UI** strings: the added text is socket-protocol error/hint text read by agents, consistent with every other unlocalized socket error in these handlers (`"TabManager not available"` etc.). The insecure-HTTP alert's own strings are untouched. **No translator sub-agent needed.**

## Order of work

1. Rebase on `origin/main`.
2. BrowserPanel types + dispositions + pure error builder (1).
3. Workspace + socket handlers (2).
4. CLI flag + hint surfacing (3).
5. Logic tests (4).
6. Skill + sync (5).
7. `./scripts/reload.sh --tag c11-207`, commit, push, PR.

## Risks

- **Collision with C11-209** in `BrowserHandlers.swift`: my diff is confined to `v2BrowserNavigate` / `v2BrowserOpenSplit`; theirs is in `v2AwaitCallback`. Rebase before PR and again before merge.
- **Behaviour change for existing callers**: a script that today gets a silent ok for a blocked non-loopback HTTP open now gets a non-zero exit. That is the ticket's intent, and loopback (the overwhelmingly common automation case) is unaffected.

---

# Plan-Review Resolutions (authoritative — supersedes the plan above where they conflict)

Reviewer artifact: `art_01M298K9FC5BCRAZGGKR7BYT0D` (verdict FAIL, plan-level). Every finding was re-checked against the worktree before triage.

## R1 [CRITICAL] Double-consumption of the one-time bypass — **ACCEPTED, plan changed**

Verified in the code: `navDelegate.shouldBlockInsecureHTTPNavigation` (`Sources/Panels/BrowserPanel.swift:2753`) calls the same `shouldBlockInsecureHTTPNavigation(to:)` that `navigate(to:)` calls at `:3834`, and that helper **consumes** the bypass. WebKit's `decidePolicyFor` (`:6272`) therefore re-checks a URL whose bypass has already been cleared and cancels the load. The reviewer is right that seeding the bypass and then calling `navigate(to:)` would re-block.

**Change:** the pre-checks in `navigate(to:)` and `requestNavigation(_:intent:)` become **non-consuming peeks**; `decidePolicyFor` stays the single consuming gate.

- Add `func browserMatchesOneTimeInsecureHTTPBypass(_ url: URL, bypassHost: String?) -> Bool` (pure, non-mutating) beside the existing consuming helper, and use it from `shouldBlockInsecureHTTPNavigation(to:)`'s caller-side pre-check.
- Keep `browserShouldConsumeOneTimeInsecureHTTPBypass` exactly as it is, called only from the delegate path.
- This also fixes the **pre-existing** new-tab bug the reviewer flagged: `openLinkInNewTab(url:bypassInsecureHTTPHostOnce:)` → `newBrowserSurface` → `BrowserPanel.init` → `navigate(to:)` consumes the bypass in the pre-check, so "Proceed in c11" on a `target=_blank`/cmd-click insecure link re-prompts in the new tab. Same one-line root cause, same fix, covered by a host-target regression test. In scope: it is the exact mechanism this ticket's opt-in rides on.

## R2 [MAJOR] "Backgrounded" produces `.prompting`, not `.blocked` — **ACCEPTED, plan changed**

Verified: `browserSelectModalHostWindowIndex` accepts any visible, non-miniaturized, non-sheet window regardless of key/main status, and `testBackgroundedAppStillFindsAnOrdinaryWindow` pins it. So a merely unfocused window still sheets a prompt.

**Changes:**

1. **`.prompting` is a first-class reported outcome**, in both `browser.navigate` and `browser.open_split`: payload gains `insecure_http: {status: "prompted", host: ..., hint: ...}`.
2. **The non-JSON CLI fallback says so**, for both verbs: `OK ... insecure-http prompt pending for <host>; pass --allow-insecure-http to navigate without waiting for a human`. Without this the common case stays as silent at the terminal as it is today.
3. **Corrected observables.** Blocked branch reproduces only with **no usable window**: app hidden (Cmd+H), window miniaturized, or all windows closed. Backgrounded-but-visible reproduces `.prompting`. Phase 4 must show both.
4. **The skill teaches both outcomes** and leads with the opt-in, rather than claiming a backgrounded window fails.
5. **Decision — keep the sheet for socket-originated navigation.** Not switching socket navigations to error-without-prompting: a human often *is* present, the sheet is the only consent path for an operator watching an agent work, and removing it would regress that flow. The agent's escape hatch is the explicit flag, and `.prompting` is now reported, so nothing is silent either way.

## R3 [MINOR] Two of three proposed logic tests already exist — **ACCEPTED, plan changed**

Verified: `BrowserInsecureHTTPSettingsTests` (in `c11Tests/UpdatePillReleaseVisibilityTests.swift`, target `c11Tests`) already covers default-allowlist membership, `browserShouldBlockInsecureHTTPURL` both ways, and one-time-bypass consumption. `BrowserInsecureHTTPAlertPresentationTests` live in `c11Tests/BrowserConfigTests.swift`, **not** in `BrowserCompanionPolicyTests.swift` as §4 said.

**Revised test plan:**

- `c11Tests/BrowserCompanionPolicyTests.swift` (**`c11LogicTests`** target, fast): (a) the `browserInsecureHTTPBlockedError` builder — code, message names reason *and* remedy, `data` carries `host`/`url`/`reason`/`hint`; (b) one assertion that `192.168.1.5` is blocked under the default allowlist (the LAN case the shipped suite does not pin); (c) `browserMatchesOneTimeInsecureHTTPBypass` peeks without clearing, while `browserShouldConsumeOneTimeInsecureHTTPBypass` still consumes.
- `c11Tests/BrowserConfigTests.swift` (**`c11Tests`** target, CI): navigate with `allowInsecureHTTP: true` to a non-allowlisted http URL and assert the alert factory is never invoked, the disposition is `.proceeded`, and the bypass survives the pre-check (the R1 regression).

## R4 [MINOR] CLI help text and the `browser <surface> open <url>` alias — **ACCEPTED, plan changed**

Verified: `browser <surface> open <url>` early-returns to `browser.navigate` at `CLI/c11.swift:6875-6883`, before the `open_split` params are built. The flag must be parsed before that early return. Help text updated in both `c11 browser --help` and the top-level help, on the `open|open-split|new` and `goto|navigate` usage lines. Use `parseFlag`/`hasFlag` (order-independent) rather than the positional `urlArgs.last == "--snapshot-after"` pattern, so `--allow-insecure-http --snapshot-after` works in either order.

## R5 [MINOR] Redirect after an opted-in navigation — **ACCEPTED, plan changed**

The bypass is one host, one navigation. A redirect to plain http on a *different* host is blocked by the delegate asynchronously, after the socket call returned. **Changes:** the delegate's blocked branch records `lastNavigationDisposition`, so a later query can expose it; and the skill states the "one navigation, one host" scope explicitly.

## R6 [MINOR] State the opt-in scope choice explicitly — **ACCEPTED, plan changed**

Adding to the Decision section: **per-navigation consent is chosen over host-range scoping.** A host-range scope (loopback + RFC1918 only) would leave the tailnet-hostname and public-HTTP cases exactly as silent as today while adding a second policy surface to maintain. Per-navigation consent covers every host, grants no authority the socket caller lacks (it can already run arbitrary JS via `browser.eval`), persists nothing, and expires after one navigation. The default allowlist is unchanged for humans.

## Net effect on the change list

§1 gains the non-consuming peek helper and the delegate-side disposition record; §2 gains `.prompting` reporting on both verbs; §3 gains the alias path, `parseFlag`, and two help-text edits; §4 is re-pointed at the correct files and trimmed to genuinely new coverage plus one host-target regression test; §5 gains the both-outcomes framing and the redirect scope note. The loopback decision (R6) and the no-localization call are unchanged.

---

# Plan-Review Resolutions, second pass (authoritative)

Reviewer artifact: `art_01M298XMWF0MS24RRSV3XCNQ3Q` (verdict FAIL, narrowly), auto-fired on the `→ planned` transition. Both MAJOR findings were verified in the code and accepted; the change list below is what shipped.

## S1 [MAJOR] The consent must survive a **same-host redirect** — **ACCEPTED**

Correct and load-bearing: WebKit runs `decidePolicyFor` once per navigation *action*, so a dev server answering `/` with a 302 to `/login` re-checks the guard and a consumed grant would block the redirect. That is exactly the dev-server shape the ticket names.

**Shipped:** the grant is scoped to one **navigation**, not one navigation action. Nothing consumes it; `browserShouldConsumeOneTimeInsecureHTTPBypass` is deleted and replaced by three pure helpers — `browserMatchesOneTimeInsecureHTTPBypass` (peek, used by both the caller-side pre-check and the delegate), `browserShouldClearInsecureHTTPConsent(settledURL:consentHost:)` (release when *that host's* navigation settles), and `browserShouldSupersedeInsecureHTTPConsent(requestedURL:consentHost:)` (a navigation elsewhere drops an unused grant). Release is driven by a new synchronous `didSettleNavigation` hook on `BrowserNavigationDelegate`, fired from `didFinish` and from both failure callbacks **after** their cancelled/download early-returns — so a load that supersedes an in-flight one cannot release the grant just seeded for it. This also fixes the same pre-existing defect on the human "Proceed in c11" path.

## S2 [MAJOR] `browser.open_split` must not hide the created surface behind an error — **ACCEPTED**

Verified: `sendV2` throws `CLIError("code: message")` and prints no JSON envelope on the error path, so refs in error `data` are unreachable from the CLI.

**Shipped (the reviewer's preferred option):** `browser.open_split` returns `.ok` with its normal payload plus `insecure_http: {status: "blocked"|"prompted", host, reason, hint}` — the verb's promise is that a surface exists, and it does. The `insecure_http_blocked` **error** is reserved for `browser.navigate`, whose whole promise is the navigation. The non-JSON fallback prints the surface/pane refs and the blocked/prompted note on one line. The skill documents both shapes.

## S3 [MINOR] `lastNavigationDisposition` must be readable — **ACCEPTED**

`browser.url.get` now carries the same `insecure_http` fragment when the last disposition was blocked or prompted. That is the query agents already poll after navigating, so an asynchronously blocked redirect is visible there.

## S4 [MINOR] `references/commands.md` — **ACCEPTED**, both command lines carry the flag plus a one-paragraph note; the sync step covers the whole skill directory.

## S5 [MINOR] Host-target test issues a real load — **ACCEPTED**, switched to `http://192.0.2.1:8000/` (TEST-NET-1, RFC 5737, unroutable) so WebKit's load fails fast; every assertion is synchronous and independent of it.

## S6 [MINOR] A seeded grant that never reaches the delegate lingers — **ACCEPTED**, covered by S1's supersede + settle-release pair. `consentToInsecureHTTP(for:)` is called only after `resolveNavigableURL` succeeds and only for an `http` scheme.
