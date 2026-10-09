# Local activity history privacy

Settings → Data & Privacy → Local activity history applies immediately to new
records. It is separate from Send anonymous telemetry.

- **Record usage analytics**, on by default, controls presence, workspace and
  app-health edges. It does not stop mailbox receipts or the activity log's
  other structural records.
- **Keep message and input text**, on by default, controls new `panel.input_sent`
  text, `mailbox.accepted` bodies, and feed-answer text. When off, those event records contain byte
  counts and `text_recorded: false`, with no text, body or body reference.
  Feed answers retain `answer_bytes` instead of `answer`. Messages view shows “text not recorded.” Existing history is unchanged.
- **Keep history for** selects 7, 14 or 30 days for the activity-log generations,
  subject to the byte cap for that build label. Dead debug/tag history also expires after fourteen days idle. This does not delete local mailbox delivery
  files, agent transcripts, or other tenant state.

Mailbox delivery still needs the local message body or body reference. c11 marks
accepted mailbox envelopes with `ext.c11_activity_text_recorded: false` so
Messages view does not recover that body from inbox/read/quarantine artifacts
after the accepted event leaves the retained log or recording text is re-enabled.
Recipients still receive the original body; this preference does not redact the
message being delivered. Delivery extension fields are otherwise preserved. Sender-supplied reserved markers are normalized to c11’s acceptance decision. Outbox and processing text is hidden until acceptance. If a required marker cannot be persisted, the undelivered processing envelope remains for manual recovery; c11 records a metadata-only failure and does not automatically retry.

The full log kill switch remains a defaults key, documented in the
[events reference](events.md). There is no full kill-switch Settings control.
These controls do not change an agent's transcript storage or the independent
anonymous-telemetry preference.
