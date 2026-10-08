# C11-353: Load context on hang precursors and a 10-minute instance health sample

## Why
In a 5.5-day 0.67 session there were 41 `hang.precursor` events (37 swiftui-update), with stalls up to 25.8 s. To ask whether hangs scale with load, the whole log had to be replayed to reconstruct how many tabs were open and how many agents were working at each precursor. The answer: 8.1 per 10 h at 80+ open tabs versus 0.9 per 10 h at 40 to 79 tabs, with a Thursday burst at only 26 tabs. Occlusion and lock state were unknowable. Process cost over the run (65 CPU-hours, about 0.5 core average, 522 MB RSS at the end) had to be read from `ps` at the end, with no curve.

## Deliverable
1. `hang.precursor` payload gains a context block: `tabs_open`, `tabs_by_kind`, `agents_working`, `workspaces_open`, `app_active`, `screen_locked` (from the presence ticket), and `rss_mb`.
2. A new `instance.sample {rss_mb, cpu_s_total, tabs_open, tabs_by_kind, agents_working, workspaces_open, threads}` event every 10 minutes, plus one at clean shutdown.
3. Schema, events reference and skill updated, then synced.

## Performance constraint (hard)
The counts come from counters the EventLog writer keeps off-main, incremented from events it already serializes (panel created and closed, liveness derived, workspace lifecycle). Sampling never reads main-actor state. RSS and CPU come from a single `task_info` / `getrusage` call on the writer queue. That is one timer at 10 minutes (about 150 events a day), and never on the typing path. A test asserts that sampling performs no main-thread hop.

## Acceptance
Over a soak run (C11-270), hang rate per load bucket and the RSS and CPU curves can be computed from the event log alone.
