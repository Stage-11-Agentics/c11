# Plan Review: C11-207 — Socket-driven browser navigation fails silently when it cannot prompt

Reviewer: Claude Fable 5.1 (plan review, 2026-09-11). Every claim below was checked against `main` at `6b551c0ea` (v0.65.0).

## 1. Verdict

**FAIL (plan-level)**

The plan is well-researched and the shape (disposition enum + structured socket error + per-navigation `--allow-insecure-http` opt-in + skill update) is the right one. It fails on two points that would make the shipped opt-in not work and the shipped error message describe the wrong scenario. Both are small to fix in the plan, but they must be fixed before implementation or the delegator will build the wrong thing and only find out in the phase-4 socket run.

## 2. Summary

Reviewed the C11-207 implementation plan against the task description and the actual code in `Sources/Panels/BrowserPanel.swift`, `Sources/SocketHandlers/BrowserHandlers.swift`, `Sources/Workspace.swift`, `CLI/c11.swift`, the test targets, and the `c11-browser` skill. The code findings in the plan are accurate (fire-and-forget navigation, loopback default-allow, `newBrowserSplit` lacking the bypass parameter, CLI dropping `data`, `BrowserCompanionPolicyTests.swift` in `c11LogicTests`). The key concern is that the plan's opt-in rides the one-time bypass through `navigate(to:)`, which **consumes** the bypass before WebKit's `decidePolicyFor` re-runs the same check, so the navigation would be re-blocked; and the plan mischaracterizes when the silent block actually happens (only when no visible window exists, not merely when the window is backgrounded), which changes what the CLI, the error text, and the skill must say.

## 3. Issues

**[CRITICAL] §1 Changes / `navigateSmart(_:allowInsecureHTTP:)` and §2 `open_split` bypass — The one-time bypass is consumed twice on the planned path, so the opt-in re-blocks**

The bypass mechanism is checked in two places for one navigation:

1. `BrowserPanel.navigate(to:)` (`BrowserPanel.swift:3832`) calls `shouldBlockInsecureHTTPNavigation(to:)`, which calls `browserShouldConsumeOneTimeInsecureHTTPBypass` and **clears** `insecureHTTPBypassHostOnce` on match.
2. WebKit then fires `BrowserNavigationDelegate.decidePolicyFor` (`BrowserPanel.swift:6270-6288`) for the same main-frame load, which calls the same `shouldBlockInsecureHTTPNavigation` closure. The bypass is now nil, `browserShouldBlockInsecureHTTPURL` returns true, and the delegate calls `handleBlockedInsecureHTTPNavigation` and cancels the load. Result: the prompt (or the silent block) fires anyway.

The existing "Proceed in c11" path avoids this by design: `handleInsecureHTTPAlertResponse` seeds the bypass and then calls `navigateWithoutInsecureHTTPPrompt(request:)` directly (`BrowserPanel.swift:4075-4078`), so only the delegate consumes it. The plan instead says "seed `insecureHTTPBypassHostOnce` with that host before navigating" and then calls the normal `navigate` path, which hits both checks. The `open_split` variant has the same problem: `BrowserPanel.init` navigates via `navigate(to: url)` (`BrowserPanel.swift:2902`), so the `bypassInsecureHTTPHostOnce` init parameter is consumed in the pre-check and gone by the time the delegate runs. (This suggests the existing new-tab "Proceed in c11" path via `openLinkInNewTab(url:bypassInsecureHTTPHostOnce:)` → `newBrowserSurface` → `init` → `navigate(to:)` may already be broken the same way; the delegator should verify that with a tagged build and fix it in the same PR if so, since it is the exact mechanism the ticket's opt-in relies on.)

**Recommendation:** Make the delegate the single consuming gate. In `navigate(to:)` and `requestNavigation(_:intent:)`, *peek* at the bypass without consuming it (a non-mutating sibling of `browserShouldConsumeOneTimeInsecureHTTPBypass`, or check `insecureHTTPBypassHostOnce == normalizedHost` inline) and let `decidePolicyFor` do the consumption. Alternatively, have the opt-in path mirror the `.alertSecondButtonReturn` branch exactly: run `browserShouldBlockInsecureHTTPURL` for the disposition, then seed the bypass and call `navigateWithoutInsecureHTTPPrompt(request:recordTypedNavigation:)`. Either way, add a host-target test (in `c11Tests`, alongside `BrowserInsecureHTTPAlertPresentationTests`) that seeds the bypass, navigates, and asserts the alert factory is never invoked and `shouldRenderWebView` is true. The phase-4 socket run should include `--allow-insecure-http` against a non-loopback http host and assert `get title` returns the served title; a plain "OK" exit is not proof.

**[MAJOR] §2 Observable, §5 Skill, and the error text — "Backgrounded window" does not produce the block; it produces a sheet the agent cannot see**

`presentInsecureHTTPAlert` uses `insecureHTTPAlertWindowProvider`, whose default is `browserModalHostWindow(preferring: webView.window)` (`BrowserPanel.swift:5684`). That selector deliberately accepts any visible, non-miniaturized, non-sheet window even when the app is not active; the test `testBackgroundedAppStillFindsAnOrdinaryWindow` (`BrowserCompanionPolicyTests.swift:484`) pins exactly this. So in the ticket's headline scenario (window open but backgrounded/unfocused), the outcome is `.prompting`: a sheet appears on the unfocused window, the socket call returns, and the agent waits on a human who may not be looking. The `.blocked` branch only fires when the app is hidden (Cmd+H), the window is miniaturized, or every window is closed.

Three consequences the plan does not handle:

- The plan's phase-2 observable ("`c11 --json browser open http://<lan-ip>:<port>` against a backgrounded window exits non-zero with `insecure_http_blocked`") is wrong as written; that command would exit 0 with `insecure_http: {status: "prompted"}`.
- The proposed skill text ("behind a backgrounded window there is nobody to prompt, so the call fails with `insecure_http_blocked`") would teach agents the wrong model. The accurate lesson is: any non-allowlisted plain-http navigation from the socket either sheets a prompt to a human or, with no usable window, fails with `insecure_http_blocked`; in **both** cases the agent should have passed `--allow-insecure-http`.
- For a non-`--json` caller, the plan's `.prompting` handling is invisible: the CLI prints the `"OK"` fallback for `browser.navigate`, and `browser.open_split` has no `.prompting` handling at all in the plan. That leaves the common case as silent as today from the terminal, just with a different root cause.

**Recommendation:** (a) Treat `.prompting` as a first-class reported outcome in both handlers, and make the CLI's non-JSON fallback say so (e.g. `OK (insecure HTTP prompt pending for <host>; pass --allow-insecure-http to skip)`), reusing the same `hint` string the blocked error carries. (b) Rewrite the observable and the skill section to describe both outcomes accurately and lead with the opt-in. (c) Add `hidden app / miniaturized window` as the reproduction condition for the blocked branch in the phase-4 run notes, since a merely backgrounded window will not reproduce it. Optionally consider whether a *socket-originated* navigation should skip the sheet entirely and return the structured error, given the caller now has an explicit consent path; the plan should make that a stated decision either way (keeping the sheet is defensible, since a human may well be present).

**[MINOR] §4 Tests — Two of the three proposed logic tests already exist**

`BrowserInsecureHTTPSettingsTests` in `c11Tests/UpdatePillReleaseVisibilityTests.swift` (target `c11Tests`) already covers default allowlist membership, `browserShouldBlockInsecureHTTPURL` with allowlisted vs. non-allowlisted http and https, and `testOneTimeBypassIsConsumedAfterFirstNavigation`. The plan also says the existing `BrowserInsecureHTTPAlertPresentationTests` live in `BrowserCompanionPolicyTests.swift`; they are in `c11Tests/BrowserConfigTests.swift` (target `c11Tests`).

**Recommendation:** Keep only the genuinely new logic test (`browserInsecureHTTPBlockedError` builder: code, message contains reason and remedy, `data` keys). If the delegator wants the allowlist decision pinned in `c11LogicTests` for the LAN/private-range case (`192.168.1.5` blocked), add just that one assertion rather than re-deriving the existing suite. Correct the file reference.

**[MINOR] §3 CLI — Help text and the `browser <surface> open <url>` alias are not called out**

`c11 browser --help` (`CLI/c11.swift:9811`) and the top-level help (`CLI/c11.swift:17410`) list `goto|navigate <url> [--snapshot-after]`; the new flag needs to appear in both, and in the `open|open-split|new` usage line. Also note that `browser <surface> open <url>` is routed to `browser.navigate` (`CLI/c11.swift:6875-6883`) inside the open branch, so the flag must be stripped before that early return as well, not only before the `open_split` params are built. Existing bool flags use `parseFlag`/`hasFlag` (`CLI/c11.swift:11315`, `11383`); use those rather than the `urlArgs.last == "--snapshot-after"` positional pattern, so `--allow-insecure-http --snapshot-after` in either order works.

**Recommendation:** Add the two help-text edits and the alias path to §3, and specify `parseFlag` for the removal.

**[MINOR] §1 / §5 — Redirect after an opted-in navigation is a known gap worth stating**

The one-time bypass is host-scoped and single-use. If the opted-in http page redirects to plain http on a different host, the delegate blocks that redirect asynchronously, after the socket call has already returned `.proceeded`, and the agent gets no signal. That is acceptable for this ticket, but the skill should say "one navigation, one host" so an agent that sees a blank page after a redirect knows to re-issue with the flag against the redirect target, and `lastNavigationDisposition` should be updated from the delegate's blocked path too so a later `browser get` / diagnostic can expose it.

**Recommendation:** One sentence in the skill section and one line in the delegate's blocked branch. No new API.

**[MINOR] Decision section — Opt-in scope vs. the ticket's "prefer scoping narrowly"**

The ticket says "prefer scoping it narrowly (localhost and private-range hosts are the realistic need)". The plan's flag is unscoped: it consents to any http host, including public ones. The justification (the socket caller already runs arbitrary JS via `browser.eval`, the bypass is single-use and non-persistent) is sound and I agree with it, but the plan should state explicitly that it is choosing per-navigation consent over host-range scoping and why, so a reviewer of the PR does not reopen the question.

**Recommendation:** Add one sentence to the Decision section making the scope choice explicit; no code change.

## 4. Positive Observations

- **Code findings are accurate and specific.** Every claim I could check held: `navigate`/`navigateSmart`/`requestNavigation` are `-> Void`; the loopback default-allow and empty-default fallback are real; `newBrowserSplit` lacks the bypass parameter that `newBrowserSurface` has; the CLI does drop `data`; `BrowserCompanionPolicyTests.swift` is genuinely a `c11LogicTests` member despite living in `c11Tests/`. The `.lattice` line references match the file.
- **Loopback decision is well-argued.** Keeping the shipped default and documenting it, rather than widening the allowlist to private ranges for everyone, is the right call and the reasoning (agents are already fully privileged on the socket; a persistent allowlist change would affect every human user) is exactly the argument to make.
- **Pure, testable error builder** with `data` carrying `host`/`url`/`reason`/`hint`, plus the small generic CLI change to surface `hint`, is a clean way to get the remedy to the terminal without special-casing one error code.
- **Scope discipline.** Explicitly staying out of `v2AwaitCallback` (C11-209 territory), no `project.pbxproj` edit, no new modal, no localization pass needed, and the HARD RULE skill sync step is present. The C11-209 collision risk is real but currently empty (that branch has no commits yet), and the plan's rebase-twice mitigation is adequate.
- **Order of work and risks section** are concrete, including the honest note that existing scripts relying on a silent ok for blocked non-loopback http will now exit non-zero.
