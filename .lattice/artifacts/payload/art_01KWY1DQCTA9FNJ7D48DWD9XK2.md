# C11-162 — Code review (own-reviewer fallback) + triage

`lattice code-review` saw an empty diff (it reads the parent checkout, on `main`; commits are on the worktree branch), so per the boot's fallback clause I ran two parallel reviewers on the real worktree diff (`git diff origin/main`): a correctness/concurrency/hot-path lens and a spec-conformance/quality lens.

**Verified clean by both:** no CRITICAL. Concurrency (off-main derive, main-hop publish, per-store serial queues — no `main.sync` added, no data race, no deadlock), precedence (`activity` writes strictly at `.derived`, never clobbers explicit; `.unknown` clears), snapshot exclusion of derived keys, projector boundary logic, retain cycles, dlog gating, and the typing hot-paths (hitTest/forceRefresh/TabItemView `==` untouched; decay clock only in child subviews). Localization complete; tests genuinely behavioral.

## Findings & triage

| # | Sev (corr / conf) | Finding | Decision |
|---|---|---|---|
| MAJOR-1 | MAJOR / minor | Idempotent status re-report freezes `SidebarStatusEntry.timestamp` → a *live* agent heartbeating an unchanged status decays to stale/expired and is overridden by the derived pill. Decay measures "last changed", should be "last reported". | **FIX** — refresh the sidebar entry timestamp on every accepted re-report (heartbeat). Store `ts` stays "last changed" for the manifest. Doc updated. |
| MAJOR-2 | minor / MAJOR | `SidebarProgressState.timestamp` not persisted (`SessionProgressSnapshot` lacks it) → restored progress renders fully fresh — the exact freshness-lie this cycle targets. | **FIX** — persist + restore the progress timestamp; round-trip test. |
| m3 | minor / minor | No `expiry >= stale` ordering guard → non-monotonic staging (skips `.stale`). | **FIX** — clamp ordering; test. |
| conf-m4 | — / minor | Empty/whitespace status substituted with the key name, defeating the projector's empty→derived handling. | **FIX** — pass trimmed value through. |
| conf-m1 | — / minor | Takeover is additive (grayed tombstone + derived pill both show); TEL-4 says derived "takes over THE pill". | **FIX** — suppress the expired explicit row when derived takeover is active (single pill). |
| corr-m1 | minor / — | Workspace projection mirrors the *intended* derived value, not the post-write store truth. | **FIX** — mirror post-write `after`. |
| corr-m4 | minor / — | `SidebarDecayClock` adds a Timer to `RunLoop.main` during lazy init assuming main-thread first access. | **FIX** — main-safe init. |
| corr-m5 | minor / — | Realtime vs reconcile transition detection not atomic (different queues); harmless until the EVT hook (DEBUG no-op today). | **FIX (comment)** — flag for C11-163. |
| conf-m5 | — / minor | Invalidation-only `@AppStorage` props look unused (fragile to "cleanup"). | **FIX (harden)** — comment at each site. |
| o1 | obs | Gold hairline uses `BrandColors.gold` (#c9a84c) not the doc's literal `#F5C518`. | **DECLINE** — brand token is correct per the doc's own "use existing brand tokens"; doc self-contradicts. |

Both reviewers' bottom line: **ship-worthy at pr_open after the two MAJORs.** All fixes above applied in a single fix pass; rebuild + full c11-logic suite re-run before push.
