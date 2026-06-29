# Validation: C11-151 — opencode exact-session resume (OBSERVED live resume)

**Gate:** pr_open is blocked until a live quit+relaunch resumes the exact `ses_`
session. **Result: PASS — observed end-to-end on a tagged build.**

## Fast local tests (SAFE c11-logic scheme)
`xcodebuild -scheme c11-logic ... test -only-testing:c11LogicTests/{OpencodeSessionIdGrammarTests,OpencodeReservedKeyValidationTests,OpencodeStrategyResumeTests,OpencodeScraperTests}`
→ **26 tests, 0 failures, `** TEST SUCCEEDED **`.** Includes the I/L/O/U
base62 regression guard and a real temp-SQLite scraper test.

## Live exact-resume (tagged build `c11-151`, bundle `com.stage11.c11.debug.c11.151`)

Built + launched the tagged app, refreshed the installed plugin
(`~/.config/opencode/plugins/c11-notify.js` now carries the `session.created`
handler — R1 precondition), launched `opencode` (1.17.10) in an isolated
project dir `/Users/atin/c11-151-resume-proj`, sent one message to create a
session, then quit + relaunched with `--qa resume`.

**1. Capture (plugin push rail).** opencode created root session
`ses_0ef1b49a5ffePvUOJN5jYpSdAM` (note the `U` and `O` — a Crockford-base32
alphabet would REJECT this id; base62 accepts it). The plugin's
`session.created` handler pushed it. The tagged store:
```
$ c11 conversation get --surface surface:5
kind=opencode id=ses_0ef1b49a5ffePvUOJN5jYpSdAM state=alive source=hook resumable=true
```

**2. Persist (snapshot).** The clean-shutdown snapshot
`session-com.stage11.c11.debug.c11.151.json` wrote the full ConversationRef:
```json
{ "kind":"opencode", "id":"ses_0ef1b49a5ffePvUOJN5jYpSdAM",
  "cwd":"/Users/atin/c11-151-resume-proj", "state":"alive",
  "capturedVia":"hook", "placeholder":false }
```

**3. Dry-run oracle (`c11 state verify`).** After extending the CLI oracle for
opencode (commit 6d5bd0ddc), `state verify` on the snapshot prints the exact
resume command:
```
[RESUME] kind=opencode id=ses_0ef1b49a5ffePvUOJN5jYpSdAM state=suspended — cd '/Users/atin/c11-151-resume-proj' && opencode -s 'ses_0ef1b49a5ffePvUOJN5jYpSdAM'
1/2 ref-bearing panels would resume
```

**4. Crash-recovery scraper ran in the live restore path.** On relaunch, the
restored surface's conversation store shows:
```
kind=opencode id=ses_0ef1b49a5ffePvUOJN5jYpSdAM state=suspended source=hook resumable=true
reason: crash recovery: transcript verified on disk
```
"transcript verified on disk" = `OpencodeStrategy.transcriptExists` →
`OpencodeScraper.sessionExists` queried `~/.local/share/opencode/opencode.db`,
found the session row, returned `true`, and promoted the ref to `.suspended`
(resumable). The SQLite scraper is exercised by the real app, not just tests.

**5. Restore re-attached the EXACT session.** read-screen of the restored
opencode surface shows the prior conversation history from the same session —
my message "respond with exactly the word READY and nothing else" is present,
proving opencode re-loaded `ses_0ef1b49a5ffePvUOJN5jYpSdAM` rather than
launching a fresh session:
```
  ┃  respond with exactly the word READY and nothing else
  ┃  Insufficient credits. Add more using https://openrouter.ai/settings/credits
     ▣  Build · GLM-5.2
```

## Honest caveat
`session.time_updated` did NOT advance on resume (delta 0). Cause is external:
the OpenRouter model (GLM-5.2) is out of credits ("Insufficient credits"), so
the resumed session could not process a new turn to bump its timestamp. The
exact-session resume is nonetheless conclusively demonstrated by (a) the prior
conversation history rendered in the restored TUI and (b) the conversation
store ref keyed to the same `ses_` id with "transcript verified on disk". The
timestamp-advance was a secondary confirmation, not the proof; the proof is
"opencode re-opened this specific session," which is observed.

## What this exercised that unit tests cannot
Plugin `session.created` → real `c11 conversation push` → store → snapshot →
clean shutdown → resume relaunch → live `transcriptExists` SQLite query →
`OpencodeStrategy.resume` → opencode re-attach. The whole push+restore rail,
end to end, on the actual app.