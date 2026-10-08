# C11-351: Self-describing panel.closed summary so tab analytics need no replay

## Why
To learn what a tab was (its final title, role, agent, model, how long it lived and worked), an analyzer has to replay every `metadata.changed` and `liveness.derived` event since the tab's creation. Once rotation drops the start of the log (C11-232), that history is gone. In a 5.5-day session, 59% of metadata events were spinner title frames, and getting a usable final title meant stripping spinner glyphs by regex.

## Deliverable
`panel.closed` gains a summary payload: `kind`, `created_at`, `lifetime_s`, final explicit/declared `title` (falling back to the spinner-stripped OSC title), final `description`, `agent_type`, `model`, `conversation_id` when known, `working_s` (summed derived-working time), and counts (`title_changes`, `inputs_sent`). Any body text is length-capped. A matching summary is written for each live tab at clean shutdown (`panel.snapshot` or a final `log.closed` marker), so a restart does not orphan open tabs.

## Performance constraint (hard)
The summary is assembled from state c11 already holds at close time. Per-tab counters live off-main, in the EventLog writer, which already sees every event for the tab. Nothing is computed per keystroke. Close is not a hot path.

## Acceptance
An analyzer can produce the per-tab table (title, model, lifetime, working time) from `panel.closed` lines alone, with no replay. Verified by a test through the real EventLog path.
