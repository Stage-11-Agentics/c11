# Plan Review: C11-204

## 1. Verdict

**FAIL (plan-level)**

## 2. Summary

The submitted plan is a verbatim copy of the task description with a title line prepended: FOUND BY / EVIDENCE / MECHANISM / WHY IT BITES / FIX DIRECTIONS / ACCEPTANCE / RELATED, word for word, nothing added. It contains no implementation steps, no files-to-modify list, no choice among the three mutually exclusive fix directions the ticket offers, no test strategy, and no plan for verifying the acceptance criterion. The diagnosis it restates is correct and unusually well evidenced (I confirmed the mechanism at `Sources/Panels/BrowserPanel.swift:3940`), but a restatement of the bug is not a plan for fixing it, and the design decisions this fix actually requires (provenance plumbing from the socket, the socket reply contract, the sibling popup call site) are exactly the ones left unmade.

## 3. Issues

**[CRITICAL] Whole plan — The plan is the task description, not a plan**

Lines 34-49 of the plan are byte-identical to lines 14-29 of the task description. The only added content is the `# C11-204: ...` heading. There is no "Approach", no "Steps", no "Files", no "Tests", no "Risks". Nothing here constrains what the implementer will build, so the plan-review gate cannot do its job: any implementation, including a wrong one, is consistent with this document.

**Recommendation:** Return to `in_planning` and author a real plan. At minimum it needs: (a) the chosen fix direction with a one-paragraph rationale for rejecting the others; (b) the exact call sites to change, by file and line; (c) new/changed types and function signatures; (d) the test plan naming target and scheme; (e) the acceptance-verification procedure; (f) a risk section.

---

**[CRITICAL] FIX DIRECTIONS — Three mutually exclusive designs offered, none chosen**

The ticket deliberately offers alternatives, and they differ by roughly an order of magnitude in plumbing cost:

1. *Non-blocking present + default-deny on timeout* — local to `presentInsecureHTTPAlert`; no new plumbing; changes human-visible behavior (an operator who alt-tabs mid-prompt now gets a silent deny).
2. *Route the prompt to the requesting surface* — needs a surface-addressing and prompt-delivery path that does not exist today.
3. *Socket-provenance policy resolution, no prompt at all* — needs a provenance flag threaded through four navigation entry points plus a caller-reply contract.

Choosing between these is the plan's central job, and the plan does not perform it. Note also that the ticket's third bullet ("the decisionHandler must always be invoked") is a constraint on all three, not a fourth option.

**Recommendation:** Pick one and say why. My read of the evidence favors a combination: make direction 3 the primary (socket-initiated navigation resolves from the allowlist policy, no prompt, decision reported back), with direction 1 as the backstop for any remaining windowless human-initiated case. Whatever is chosen, state explicitly what happens to a *human*-initiated http:// navigation when no window is available.

---

**[CRITICAL] FIX DIRECTIONS bullet 2 — Socket provenance does not exist and the plan does not design it**

"When the navigation was initiated over the socket rather than by a human, do not prompt at all" is not implementable against the current code without new plumbing. The socket entry points are:

- `Sources/SocketHandlers/BrowserHandlers.swift:775` → `browserPanel.navigateSmart(url)`
- `Sources/SocketHandlers/BrowserQueryHandlers.swift:1571` → `browserPanel.navigate(to: parsed)`
- `Sources/TerminalController.swift:6868` → `browserPanel.navigateSmart(urlStr)`

None of `navigate(to:recordTypedNavigation:)` (`BrowserPanel.swift:3726`), `navigateSmart` (`:3866`), `requestNavigation` (`:3891`), or `presentInsecureHTTPAlert` (`:3905`) carries any notion of who initiated the navigation. Separately, "report the decision back to the caller" is an unspecified protocol change: which commands gain a response field, what shape it takes, whether a policy-denied navigation is an `ok` with a `blocked` reason or an error, and whether existing agent scripts break on the new shape. Per the repo's own rule, a socket-protocol change is also incomplete until `skills/c11/SKILL.md` documents it.

**Recommendation:** If direction 2 or 3 is chosen, the plan must specify the provenance type (e.g. a `BrowserNavigationOrigin` enum threaded as a defaulted parameter so existing call sites compile unchanged), each signature that gains it, the exact socket response shape for a policy-resolved decision, whether an opt-in flag (e.g. `--allow-insecure`) is added to `c11 browser open`, and the skill-doc update. Also note the socket-command threading policy in `CLAUDE.md`: this path must not acquire a `DispatchQueue.main.sync`.

---

**[MAJOR] MECHANISM — The identical bug exists at a second call site the plan never mentions**

`Sources/Panels/BrowserPopupWindowController.swift:366` ends with the same `handleResponse(alert.runModal())` fallback, presenting the same three-button insecure-HTTP alert (`:322-366`). It is worse there than in `BrowserPanel`: that closure owns a `decisionHandler: @escaping (WKNavigationActionPolicy) -> Void` from WebKit, so it is precisely the case the ticket's third bullet is about. Fixing only `BrowserPanel.swift:3940` leaves a live wedge path, and a naive fix there that introduces a timeout without invoking the handler leaks a never-called WebKit decision handler.

**Recommendation:** Bring `BrowserPopupWindowController.presentInsecureHTTPAlert` into scope explicitly. Better: factor the alert construction and the "present without ever going app-modal" policy into one shared helper both sites call, so the duplicated 20-line alert body (currently copy-pasted, including the localized keys) stops being two places to fix.

---

**[MAJOR] MECHANISM — The window provider has an inconsistency that is probably the proximate trigger, and the plan doesn't notice it**

The production default at `BrowserPanel.swift:2255` is:

```swift
private var insecureHTTPAlertWindowProvider: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }
```

but the test-reset variant at `:5571-5574` is:

```swift
insecureHTTPAlertWindowProvider = { [weak self] in
    self?.webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
}
```

`NSApp.keyWindow` and `NSApp.mainWindow` are both nil when the app is not active, which is exactly the backgrounded-window scenario in the ACCEPTANCE clause. The production provider therefore returns nil and takes the `runModal` branch in precisely the case that produced the 6.8-hour episode, while the test path would have found `webView.window` and sheeted correctly. This means the currently shipped code and the code exercised by the test hooks disagree on the branch under test.

**Recommendation:** The plan should call this out, state whether adding `webView.window` to the production provider is part of the fix, and be explicit that it is *not* sufficient on its own: `webView.window` is nil for hibernated or not-yet-rendered panels (`pendingHibernate`, `shouldRenderWebView == false`), so the `runModal` fallback must still be removed. Also flag that any test written against the current hooks may pass while production still hangs.

---

**[MAJOR] Plan — No test strategy, despite good existing seams**

The plan proposes no tests. The code already offers `setInsecureHTTPAlertHooksForTesting` / `resetInsecureHTTPAlertHooksForTesting` / `presentInsecureHTTPAlertForTesting` (`BrowserPanel.swift:5565-5586`), and existing insecure-HTTP coverage lives in `c11Tests/BrowserConfigTests.swift` (the host-required target). Nothing states which target new tests land in, whether the pure-policy half (allowlist resolution for socket-origin navigations) can be covered in `c11LogicTests` for the fast loop, or how the two central invariants get asserted.

**Recommendation:** Specify: (a) logic-target tests for the policy decision function (given origin × URL × allowlist → allow/deny), which needs the decision extracted as a pure function; (b) a host-target test asserting the completion/decisionHandler is invoked exactly once on every path including timeout and programmatic dismissal; (c) an assertion that no path calls `runModal` — a behavioral one (the call returns before the decision resolves), not a source-text grep, per the repo test-quality policy. Follow the local-testing rules in `CLAUDE.md`: defer `xcodebuild` runs to CI.

---

**[MAJOR] ACCEPTANCE — The criterion is stated but not mechanized**

"Driving a c11 browser surface to an http:// URL over the socket, with the window backgrounded, does not block the main thread: other panes stay interactive and the hang watchdog records no episode with `presentInsecureHTTPAlert` on the stack." The plan gives no procedure. There is no named repro (which URL — note `localhost`, `127.0.0.1`, `::1`, `0.0.0.0`, `*.localtest.me` are default-allowlisted at `BrowserPanel.swift:664-671`, so the obvious agent target does *not* reproduce the bug and a non-loopback http:// host is required), no statement of how the window gets backgrounded, no reference to which hang log is inspected or how C11-198's classifier is queried, and no artifact expectation.

**Recommendation:** Write the repro as numbered steps: tagged build via `./scripts/reload.sh --tag c11-204` and `launch-tagged-automation.sh --qa fresh`; a specific non-allowlisted http:// host; background the window; `c11 browser open <url>`; then two positive checks (another pane accepts keystrokes; the socket answers a query within N ms) and one negative (the hang log shows no episode naming this frame). Per `CLAUDE.md`, a UI-touching milestone needs a real-artifact smoke pass as a hard gate, not an afterthought.

---

**[MAJOR] Plan — Unstated user-visible behavior decisions**

A default-deny-on-timeout or no-prompt-for-socket policy changes what a human sees, and the plan takes no position on: what the surface displays after a denied navigation (silent blank page is a bad outcome and is itself the kind of thing that gets filed as a new bug); whether the operator is told why; whether an allowlist-suppression choice ("Always allow this host") is still reachable when the prompt is skipped; and whether a human who backgrounds the app mid-prompt loses their pending decision.

**Recommendation:** Add a short "User-visible behavior" section fixing each of these. At minimum, a denied navigation should leave a visible, non-modal explanation on the surface and, for socket callers, a machine-readable reason.

---

**[MINOR] Plan — Localization pass not mentioned**

Any new user-facing copy (timeout notice, denial explanation, socket-blocked message) must use `String(localized:)` at the call site and then sync `Resources/Localizable.xcstrings` across the six locales, validated with `jq`, per `CLAUDE.md`.

**Recommendation:** Add it as an explicit step conditional on new strings being introduced.

---

**[MINOR] MECHANISM — A third instance of the same anti-pattern, worth an explicit in/out-of-scope line**

`BrowserUIDelegate.presentDialog` at `Sources/Panels/BrowserPanel.swift:6310-6320` uses the identical `if let window { beginSheetModal } else { completion(alert.runModal()) }` shape for JavaScript `alert()` / `confirm()` / `prompt()`. That is the same wedge class on an agent-driven page and would be equally invisible behind a backgrounded window.

**Recommendation:** State explicitly whether it is in scope. If out, say so and file a follow-up ticket rather than leaving it undiscovered — a fix that hardens one of three identical patterns invites the next 6-hour episode.

---

**[MINOR] Plan — No files-to-modify list and no interaction check with C11-198 (#413)**

The plan names one file:line in prose (`BrowserPanel.swift:3936-3940`) but never lists what the change set touches. It also inherits the RELATED note about #413 without checking whether that work's classifier expectations or fixtures reference this stack, so a regression there could go unnoticed.

**Recommendation:** Add an explicit file list, and one line confirming whether #413's classification logic or tests need updating once this frame stops appearing in hang captures.

## 4. Positive Observations

The underlying **task description is excellent** and deserves saying so: 4,747 captures across 6 episodes with a median and a max, the exact file and line, a correct mechanical account of why `runModal` spins a nested run loop, a plausible causal story tying it to agent-driven socket navigation behind a backgrounded window, and an acceptance clause that is genuinely falsifiable. I verified the mechanism independently and it holds. The three fix directions are all reasonable, and the invariant in the third bullet (decisionHandler always invoked, never from a nested run loop) is exactly the right way to state the constraint.

The codebase is also well set up for this fix: `insecureHTTPAlertFactory` and `insecureHTTPAlertWindowProvider` are already injectable, `presentInsecureHTTPAlertForTesting` exists, and `BrowserInsecureHTTPSettings` already provides the allowlist that a "resolve from policy" path would consult. A good plan here has short odds.

The gap is entirely at the plan layer: none of that thinking was carried forward into an implementation design. Once the fix direction is chosen and the provenance and popup call sites are addressed, this should convert to a PASS quickly.
