# Agent usage limits

c11 recognizes two recorded Claude Code terminal errors and shows a red panel
mark, a limit-specific tooltip, and an error row in Feed. The transcript reader
checks on its existing ten-second sweep; detection does not wait for another
turn. A limit remains visible during a retry and clears when a later turn
successfully completes. A normal idle turn produces no limit. User flags keep
their colors and reasons; delegation remains unchanged.

| Harness | Supported evidence | Coverage |
|---|---|---|
| Claude Code 2.1.311, 2.1.312 | Synthetic assistant API error, `isApiErrorMessage=true`, `error=rate_limit`, status 429, terminal `stop_sequence`, monthly-spend prefix with period or middle dot | Monthly spend limit |
| Claude Code 2.1.291 | Same structural error, session-limit sentence, rejected `quotaLimits.rateLimitType=five_hour` | Session usage limit |
| Codex | No recorded terminal usage-limit signal available | Unsupported |
| OpenCode, Grok, Pi, omp, other harnesses | No recorded terminal usage-limit signal available | Unsupported |

The recorded Claude error belongs to the current root prompt in the same
session. Its parent can be the root user record, a subsequent attachment,
an `isMeta=true` user record with the current prompt ID or no prompt ID,
or a tool-result record with the current prompt ID. The reader retains at most
128 context IDs plus the root, resetting them on each new root. A malformed or
mismatched supplied prompt ID is rejected. Monthly-spend wording accepts the
recorded period and middle-dot delimiters after the fixed prefix. Ordinary
assistant prose, user quotations, tool output, sidechains, unrelated synthetic
messages, and generic 429 errors cannot produce a limit. Other Claude limit
shapes are unsupported until recorded. No account quota polling or screen text
classification is used.

Recorded meta-only records that introduce a different prompt ID without a typed
root, and errors whose parent is a system record, remain unsupported. Binding
those shapes requires matching hook evidence; a meta record alone cannot start
a root turn. Attachments and tool results over the one-MiB parse budget register
no context, so an error parented directly on one does not bind.

A future adapter needs a recorded harness/version and terminal error record,
its root session and turn binding, the successful recovery edge, and an ordinary
output negative fixture. Source guesses and a copied error sentence alone are
not evidence.

## Structural contract

The existing journal event `agent.error.reported` carries
`reason_code=usage_limit`, `native_event=turn.failed`,
`adapter=claude_transcript`, and `usage_limit=monthly_spend|session_usage`.
No provider response text enters the journal. `journal.usage_limit` in panel
metadata holds the finite current limit, or null; the journal phase remains
`working` during a retry. Feed exposes `kind=error` and the same `usage_limit`
value in both scopes. A limit row is informational, not a permission request.
The existing `supervisor.turn_interrupted` event uses reason `usage_limit` for
an applied current-turn limit failure, once per turn in either arrival order.
`StopFailure` usually arrives first and announces `provider_error`; the limit
the sweep reads afterward refines that to `usage_limit`. When the limit is read
first, the later `StopFailure` is a duplicate and announces nothing. Duplicates
and errors predating the supervisor are not announced again. These samples do
not distinguish transient rate throttling from quota exhaustion, so they do not
produce `rate_limit`.

A turn with an approved tool stays `blocked` until it ends, because no hook
reports the approval. A limit for that same turn, recorded after the prompt
opened, still applies. A limit from another turn or from before the prompt leaves
the panel waiting. A limit is also rejected while the turn waits on a question
or plan review, since the main loop cannot be sending requests then. c11 cannot
tell a background subagent's open prompt from an answered one, so a root limit on
that same turn replaces its waiting mark with the error mark.

Mail delivery to a limited recipient adds `recipient_usage_limit` to its
`copied` dispatch trace row. The envelope still lands in the inbox, unread.
Detection and display never claim or acknowledge mail. The normal explicit
`mailbox recv --ack`/harness-drain path remains the only consumer. The trace
reports the recipient's state at delivery; Feed reports its current state.
