# Local activity history privacy

Settings → Data & Privacy → Local activity history applies immediately to new
records. It is separate from Send anonymous telemetry.

- **Record usage analytics**, on by default, controls presence, workspace and
  app-health edges. It does not stop mailbox receipts or the activity log's
  other structural records.
- **Keep message and input text**, on by default, controls new `panel.input_sent`
  text and `mailbox.accepted` bodies. When off, those event records contain byte
  counts and `text_recorded: false`, with no text, body or body reference.
  Messages view shows “text not recorded.” Existing history is unchanged.
- **Keep history for** selects 7, 14 or 30 days for the activity-log generations,
  subject to the shared byte cap. This does not delete local mailbox delivery
  files, agent transcripts, or other tenant state.

Mailbox delivery still needs the local message body or body reference. c11 marks
accepted mailbox envelopes with `ext.c11_activity_text_recorded: false` so
Messages view does not recover that body from inbox/read/quarantine artifacts
after the accepted event leaves the retained log or recording text is re-enabled.
Recipients still receive the original body; this preference does not redact the
message being delivered. Delivery extension fields are otherwise preserved.

The full log kill switch remains a defaults key, documented in the
[events reference](events.md). There is no full kill-switch Settings control.
These controls do not change an agent's transcript storage or the independent
anonymous-telemetry preference.
