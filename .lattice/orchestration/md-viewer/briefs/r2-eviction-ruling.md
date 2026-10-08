# Orchestrator ruling for C11-359: bounded web view eviction, in this ticket

The brief's weight bar is "operators keep many markdown panels open; keep it reasonable". 25 retained WebContent processes and about 2.9 GB more after visiting 20 panels does not meet it. Lazy creation stays; add bounded eviction now, in C11-359.

1. **Policy.** Keep a live WKWebView for every markdown panel that is currently visible (the selected panel of any area in any window), plus an LRU of at most 4 recently hidden panels across the app. Evict the rest: tear the web view down so its WebContent process can exit. Put the cap in one named constant.
2. **What survives eviction.** Before teardown, capture the reading position from the bridge (`visible()`: first visible source line plus the intra-line offset), mode (read/source), and the open find query. The model state (theme, typeface, scale, outline) already lives natively. On re-show, recreate, `load`, `setSettings`, then restore the position with the bridge's explicit scroll (`scrollToLine`, plus offset if you need one; ask me if the bridge lacks it), and restore mode and find. The reader must land on the same line. A live reload of an evicted panel's file just updates content; it renders on the next show.
3. **Never evict** a panel while an agent query is in flight against it, and never in a way that steals focus or flashes. An evicted panel queried by `markdown.get_content` still answers from the model.
4. **Measure honestly.** Repeat the 20-panel scenario with physical footprint, not RSS sums: `footprint -p <pid>` or `vmmap --summary` per process, summed for c11 plus its WebKit processes, same guest and document, origin/main baseline vs this build. Record: after 20 never shown, after visiting all 20, the process count after visiting, and the re-show latency of an evicted panel (median over 10). Report the load average.
5. **Prove it.** A behavioural test of the LRU policy (model level), plus the runtime scenario: scroll panel A mid-document, visit enough panels to evict A, return to A, and see the same line (screenshot pair).

This is ticket-local repair, not a new ticket. Record it in your plan and validation comment.
