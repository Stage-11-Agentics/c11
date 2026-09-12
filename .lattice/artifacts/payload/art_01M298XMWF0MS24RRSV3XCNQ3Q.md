# Plan Review: C11-207 (second pass, post-resolutions)

Reviewed against `main` at `9aa097457` (the `c11-207-insecure-http-silent` worktree sits on the same commit). Every claim below was checked in the source, not taken from the plan.

## 1. Verdict

**FAIL (plan-level)** — narrowly. The plan is thorough, its code findings are accurate, and all six prior resolutions hold up. Two design points still need amending before implementation, because both change the shape of the deliverable rather than its internals: the one-navigation bypass does not survive a same-host redirect (which breaks the opt-in for the dev-server case the ticket names), and the `browser.open_split` blocked result as designed makes the created surface unrecoverable from the CLI. Both are small amendments to §1/§2/§3; the rest of the plan stands as written.

## 2. Summary

The plan turns a silent no-op into a reported outcome (`.proceeded` / `.prompting` / `.blocked`) on both socket verbs, adds a per-navigation `--allow-insecure-http` opt-in that rides the existing one-time bypass, fixes the double-consumption bug that would otherwise defeat that opt-in, and updates the skill. Code claims verified: `navigate(to:)` and `requestNavigation` both call the consuming `shouldBlockInsecureHTTPNavigation(to:)` (`BrowserPanel.swift:3834`, `:3999`) and the delegate calls it again at `:6272`; `browserSelectModalHostWindowIndex` accepts any visible non-miniaturized window; `BrowserCompanionPolicyTests.swift` is in the `c11LogicTests` Sources phase (`37DDE3B0A6A70E75A7B2BEDF`); the CLI `browser <surface> open` alias early-returns at `CLI/c11.swift:6875`; `sendV2` drops error `data` at `:1333`; `open_split` navigation is synchronous inside `BrowserPanel.init` (`:2902`). The key remaining concern is that the bypass is consumed per WebKit navigation *action*, not per navigation, so the first redirect re-triggers the guard.

## 3. Issues

**[MAJOR] §1 / R5 — The opt-in is consumed on the first `decidePolicyFor`, so a same-host redirect re-blocks or re-prompts**
With the R1 fix, the flow is: `navigate(to:)` peeks (non-consuming) → `webView.load` → `decidePolicyFor` consumes the bypass and allows → server answers 302 → WebKit calls `decidePolicyFor` again for the redirect target → bypass is now nil → `browserShouldBlockInsecureHTTPURL` returns true → `presentInsecureHTTPAlert` runs: a sheet if a window exists, silent Cancel if not. R5 only covers redirects to a *different* host; the same-host case has the same outcome. That is the common dev-server shape (`/` → `/login`, trailing-slash redirects, Next/Rails auth bounces), so `c11 browser open http://192.168.1.5:3000 --allow-insecure-http` would still fail on exactly the servers the ticket describes. The human "Proceed in c11" path has the same pre-existing behavior, which is worth fixing at the same time since it is the same mechanism.
**Recommendation:** Scope the bypass to the *navigation*, not the navigation action. Keep the delegate as the single gate but do not clear `insecureHTTPBypassHostOnce` there; clear it in the delegate's `didFinish` / `didFail` / `didFailProvisionalNavigation` for the main frame (or when a navigation to a non-matching host is allowed). Redirects to a different host still hit `browserShouldBlockInsecureHTTPURL` and still block. Add one logic test that the peek/consume pair tolerates two consecutive same-host checks before the clear, and state the redirect semantics in the skill as "one navigation including its same-host redirects".

**[MAJOR] §2 + §3 — `browser.open_split` returning an error after creating the surface leaves the surface unrecoverable from the CLI**
§2 puts the created `surface_ref`/`pane_ref` into error `data`, but `sendV2` throws `CLIError("\(code): \(message)")` and the plan's §3 change only appends `hint`. With `--json` the CLI still prints no envelope on the error path. So the caller exits non-zero, cannot learn which surface was created, and cannot clean it up or reuse it for a retry with `--allow-insecure-http`. Existing automation (`tests_v2/test_browser_open_split_reuse_policy.py`, `test_cli_browser_console_errors_text.py`) reads `surface_id` from a successful `open_split`; a mixed "created but errored" contract is also awkward for those callers.
**Recommendation:** Pick one, and state it in the plan. Preferred: `browser.open_split` returns `.ok` with the normal payload plus `insecure_http: {status: "blocked"|"prompted", host, reason, hint}` (the verb's promise is "a surface exists", which is true), and reserve the `insecure_http_blocked` error for `browser.navigate`, whose whole promise is the navigation. The non-JSON fallback for `open_split` then prints the surface/pane refs *and* the blocked/prompted note on one line. Alternative if you keep the error: make `--json` print the full error envelope including `data`, not just `hint`, so agents can recover the refs. Either way the skill must show the exact output shape for both verbs.

**[MINOR] R5 — "a later query can expose it" names no query**
`lastNavigationDisposition` recorded by the delegate is only useful if something reads it. The plan does not name the verb.
**Recommendation:** Either add `insecure_http` (last disposition) to the `browser.url.get` payload, which agents already poll after navigation, or drop the claim and rely on the redirect fix above. Do not leave the field write-only.

**[MINOR] §5 — The skill's `references/commands.md` also documents `browser open` and `goto`**
`skills/c11-browser/references/commands.md:7-25` lists `c11 browser open <url>` and `c11 browser <surface> goto <url>`; the plan only updates `SKILL.md`. `docs/socket-api-reference.md` is a method list only, so it does not need params added.
**Recommendation:** Add the flag to the two command lines in `references/commands.md` and include it in the `sync-installed-skills.sh c11-browser` step.

**[MINOR] R3 — The host-target opt-in test issues a real network load**
Navigating a live `BrowserPanel` to a non-allowlisted `http://` URL with the opt-in set means WebKit actually attempts the load in CI. The assertions (alert factory not invoked, disposition `.proceeded`, bypass intact after the pre-check) are all synchronous, so the test does not depend on the load, but a hanging DNS lookup on teardown is a flake vector.
**Recommendation:** Use an RFC 2606 host (`http://example.invalid`) or `http://192.0.2.1` (TEST-NET, unroutable) so the load fails fast, and say so in the test comment. Keep the assertions synchronous.

**[MINOR] §1 — A seeded bypass that never reaches the delegate lingers**
If `navigateSmart(_:allowInsecureHTTP:)` seeds the host but the load never reaches `decidePolicyFor` (unparseable URL, `pendingHibernate`, remote proxy not ready), the one-time grant stays on the panel and silently applies to the next `http://` navigation to that host. Pre-existing semantics, but the flag makes it reachable from a script.
**Recommendation:** Seed the bypass only after `resolveNavigableURL` succeeds and the scheme is `http`, and clear it in the same `didFail` path recommended above.

## 4. Positive Observations

- **Code findings are exact.** Every line reference in the plan and in the R1–R6 resolutions matched the source, including the subtle one (the delegate and the caller both consuming the same bypass). The plan reads the code, not the ticket.
- **The R1 fix is the right shape.** Making the caller-side check a non-consuming peek and keeping `decidePolicyFor` as the single gate is the minimal change, and it fixes the pre-existing new-tab "Proceed in c11" re-prompt with no extra surface. Correctly scoped as in-scope rather than creep.
- **R2 is the correct reading of "backgrounded".** Distinguishing `.prompting` from `.blocked`, reporting both, and keeping the sheet for socket navigation preserves the operator-watching-an-agent consent path instead of trading one silence for another.
- **R6 is a good decision, well argued.** Per-navigation consent covers tailnet and public HTTP that a host-range scope would leave silent, grants nothing the socket caller lacks (`browser.eval` already exists), and persists nothing. The loopback default is left alone for humans.
- **Testing discipline.** Tests go where the target already is (no pbxproj churn), duplicated coverage was found and removed, and what cannot be unit-tested is stated plainly rather than faked with a source-grep test, per the repo policy.
- **Collision awareness.** C11-209's worktree has no commits ahead of main and no PR yet, so the `BrowserHandlers.swift` overlap is currently theoretical, but flagging it with a rebase-before-merge rule is the right reflex.
- **Localization call is right.** Socket error text is agent-facing protocol, consistent with every other unlocalized handler error; the alert's UI strings are untouched.
