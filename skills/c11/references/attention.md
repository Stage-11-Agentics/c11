# Attention: flags and delegates

Print this page with `c11 guide attention`. Lifecycle marks, flags (kinds, the registry, attribution), delegates, Feed, and reading attention state. A link to `<page>.md` names another page: `c11 guide <page>`.

## Flags and delegates (the attention model)

Your panel's mark shows your lifecycle — working, needs attention (waiting), idle, cold.
Cold means you are still at your prompt but your next message starts cold. Where c11 knows
the prompt cache, cold follows it: a **dark blue** line once it expires. c11 reads it from
transcripts (Claude Code, Codex, Grok Build, Kimi Code), from its own runtime plugins
(OpenCode, Pi, omp), or exactly from the operator's opt-in Claude statusline tap; Codex,
Grok, Kimi and non-Anthropic providers are estimates, and a `/model` switch, an `/effort`
change or a compaction resets it at once. A journal-backed agent (hooks or plugin
lifecycle) never goes cold without cache data; any other agent goes to a gray line after
the dormancy threshold (10 minutes idle by default). A harness that warms its own cache
(Pi 0.86+, omp 18.3.5+) reports each refresh, so cold comes one lifetime after the last
one. GitHub Copilot exposes no cache data. A waiting agent whose cache expired keeps its
waiting mark and says so in its tooltip and panel sheet row.
Two independent modifiers sit over it. A flag is **attention** priority, not scheduling
priority; delegation reroutes routine attention, it never blocks escalation.

| State | Meaning |
|---|---|
| Normal | Independent agent; routine completion reaches the operator. |
| Delegate | The agent that launched this worker handles its results; routine signals go to that parent, not the operator's sidebar. The usual state for workers an agent launches. |
| Flagged | Operator-designated priority mission, or a running agent now needs human action. Generic flags render violet; named flags use their registered adaptive color token. The flag posts c11's loudest system notification and escalates to the menu bar extra, reaching the operator even when c11 isn't frontmost. |
| Flagged delegate | Supervised priority mission: routine completion stays quiet, escalation still lands at full strength. |

Feed and the configured attention jump use oldest flags first, then oldest eligible open asks (panel UUID, then workspace UUID for ties). The jump continues through oldest eligible unread completions/legacy notices with exact panel targets. The Waiting and Flagged buttons and the jump follow the operator's **Waiting and Flagged Order** setting (Settings, In-App Signals): *Current workspace first* (default) takes the selected workspace's items in that order, flags and asks and unread alike, before any other workspace, so a waiting agent here comes before a flag elsewhere; the Flagged buttons still reach every flag. *Oldest first* ignores the workspace. Either order is a cycle that starts after the panel the operator is on, so repeated jumps walk every flag and ask that stays up.

Show Notifications (default ⌘I; custom bindings preserved) opens the read-only Feed quick view: arrows select, Tab switches Asks/Turns, Return opens that exact panel, Esc restores the originating focus, and Turns shows finished turns without removing attention-jump targets.

Use `c11 feed answer` only for an eligible flag or `turn_end` row; in c11 1.0 it accepts single-line text only, sends one guarded paste to an exact empty/suggestion prompt, and reports whether retry is safe. Text containing a newline is refused as `multiline_unsupported` before typing; nothing is sent. Use `c11 feed open` to answer multiline text in the panel.

### Flag

```bash
c11 raise-flag --panel "$C11_PANEL_ID" "Need a call on schema migration vs dual-write"
c11 raise-flag --panel "$C11_PANEL_ID" --kind chief-of-staff "Need a decision before I can continue"
c11 lower-flag --panel "$C11_PANEL_ID"
c11 launch-agent ... --flag "Watch the migration" --by operator
```

The reason is required — one line, ≤256 chars, surfaced everywhere the flag appears. Write it
as the sentence you would say if the operator walked over. Policy differs by origin:

A flag may have an optional **kind**. Without one, it stays the generic violet flag. Named
kinds are labels, not severity levels: `chief-of-staff` (green) and `merge-issue` (red) are
editable built-ins. Raise with `--kind <slug>` only after it has been registered. A project's
`C11.md` may name the kinds its agents raise and when; check it before passing `--kind`, and
raise the generic flag when no listed kind fits. Manage the
c11-owned registry from Settings or the CLI:

```bash
c11 flag-kind list
c11 flag-kind set --id <slug> --name <name> --color <token> [--emoji <emoji>] [--evaporate-seconds <1-600>] [--sound <sound|path|flag>]
c11 flag-kind set --id <slug> --sound <sound|path|flag>   # only the sound of an existing kind
c11 flag-kind rm --id <slug>
```

A `set` with `--name` and `--color` replaces the kind's name, color, emoji and evaporate seconds, so leaving out `--emoji` or `--evaporate-seconds` clears it; its sound changes only with `--sound`.

**Evaporating kinds.** A kind with `--evaporate-seconds N` lowers its own flags: once the operator has
looked at a flagged panel for N continuous seconds (c11 frontmost, the panel's workspace selected in the
key window, the panel focused), a bar in the kind's color fills along the panel's top edge and the flag
fades. Looking away empties the bar; the next visit starts from zero. Any raise of the flag restarts it,
including one that repeats the same text, so an agent that keeps re-raising keeps it up. Nothing is
persisted. c11 records the lower as `flag.lowered` with `by: c11` and `cause: evaporated`, so a reader
can tell it from an operator's lower; `feed list` and `feed watch` print the last lower with its `by` and
`cause`, and the Feed's status line says "Evaporated". It means the operator saw the flag, not that they
answered it. The setting is read live from the registry, so it also applies to flags of that kind already
up. Settings > Flag Kinds has the same field; `flag-kind list --json` and the `flag.kind.*` socket methods
carry `evaporate_seconds` (null when the kind never evaporates).

`flag-kind list` also shows when each kind was last raised (local time) and how many times; `--json` gives `last_raised_at` (ISO 8601, null if never) and `raise_count`, plus `sound` (the kind's own sound, null when it plays the flag sound) and `effective_sound` (what a raise of it plays now).

Colors come from the fixed adaptive palette: `green`, `red`, `pink`, `teal`, `orange`, `lime`,
`cyan`, `magenta`. Arbitrary hex values and per-raise color or emoji overrides are not supported.
Every kind is flat: one oldest-first queue, the same time-sensitive alert, no priority between kinds;
only its sound may differ (Sounds, below). From a
terminal on another machine, `flag-kind list` and `raise-flag --kind` pass the machine relay;
`flag-kind set` and `rm` run only on c11's own machine. The active flag and its `flag.raised` event retain the resolved
name, color token, and emoji snapshot. Editing or removing a registry entry does not repaint an
existing flag. Editing a flag's reason or kind keeps its original raise time and queue position.
The Feed, sidebar rows, panel mark tooltip/accessibility, menu-bar items, in-surface banner,
system notification, and panel list show the available kind label and reason. The sidebar
shows one flag button per kind with flags up, in that kind's color with its name and count,
stacked above the violet Flagged Agents button, which counts generic flags only. Each button
jumps to its own kind's next flag in that order. The menu-bar glyph and workspace group counts stay generic.

- **At dispatch** (`--flag`): reserved for missions the operator designated as priority. Pass
  it only when relaying explicit operator intent, with `--by operator`.
- **Self-raised** (mid-run): you have stopped on a decision only a human can make, or hit an
  urgent issue whose blast radius crosses other agents. "I finished, please review" is
  waiting, not a flag. If the operator is already in conversation with you, just ask them.
  A delegate also flags when its parent can't or shouldn't judge what it found (see
  Delegates below).

### A flag is the loudest signal

A raised flag is how you reach the operator. It posts c11's loudest system notification: a
time-sensitive alert with its kind's sound, or the **flag sound** when the kind has none (Sounds,
below). It posts while c11 is frontmost too, except when the
flagged panel is the focused panel of the key window and the operator's own last open named it. The
alert stays in Notification Center until the flag is lowered (from any machine, by anyone), its
panel closes, or the operator opens the panel with an input that names it: the alert itself, a
sidebar card or workspace shortcut, a click on its tab (the tab already shown included), keyboard
panel selection, a click in the terminal, a panel link, or returning to c11 on that panel's
window. Opening removes the alert and leaves the flag raised. A focus change alone never removes
it, so your `panel.focus` is not the operator opening it. A second raise or a `--kind` change while raised replaces the
alert; it never stacks. A flag still raised when c11 relaunches keeps its one alert, and an
alert whose flag is gone is cleared at launch.

Every host is the same: a `raise-flag` from a terminal on another machine gives the identical
alert, with or without `--kind`. Each alert writes one `notification.flag` event (`c11 events
tail --filter type=notification.flag`) and one `notification.flag` log line: `action`
(`posted`, `replaced`, `skipped_operator_looking`, `failed`, `removed`), `cause` (`raised`,
`revised`, `lowered`, `opened`, `closed`, `stale_at_launch`), the panel, `kind` (when it has
one), `level` (`time_sensitive`), `sound` (the sound actually played), `sound_source` (`kind`,
`flag`, or `fallback`), `sound_requested` and `sound_fallback` when a chosen file could not
play, and `source_host` (`local` or the machine's name; `unknown` for an alert an older build left).

**Where the operator lands.** Opening a flag's alert, a Flagged or Done button, Feed's Return,
the menu-bar list or a panel link brings the panel's window to the display of the c11 window the
operator was working in, at its own size (shrunk to fit; on a display smaller than c11's minimum
its title bar and left edge stay visible), and from another Space to the active one. A jump
within one display only raises it. A window in full screen elsewhere is raised there, with a
notice naming its display. Your own socket calls never move or raise a window. A jump that cannot
land (the panel or workspace closed) says so in a short notice: at the pointer when the pointer is
on the operator's display, else in the upper middle of that display. A Flagged button or jump to
latest unread tries its targets in turn and shows one notice only when every one fails. Each
target tried writes one `event=operator_jump` line to `~/Library/Logs/c11/hc-diagnostics.log`:
`source` (`notification`, `attention`, `panel_link`), `outcome` (`opened`, `refused`,
`missing_workspace`, `missing_panel`, `missing_window`, `focus_failed`), `placement`
(`in_place`, `moved_display`, `fullscreen_elsewhere`; absent when no window was raised),
`space_moved`, `window_id`, `from_display` and `to_display` (display ids), `workspace_id` (absent
for a closed panel's link) and `panel_id`.

**Focus modes.** c11 asks for time-sensitive delivery, but this build has no Time Sensitive
entitlement, so macOS delivers a flag at the normal level. A Focus mode lets a flag through
only when the operator has added c11 to that Focus mode's Allowed Apps (System Settings ▸
Focus ▸ the mode ▸ Allowed Apps). That also lets routine banners through, which the dial below
governs.

### The notification dial (routine notifications only)

The operator sets how loud routine notifications are: turn ends, asks and mail. A flag is
never dialed; at every stop it posts time-sensitive with its sound.

| Stop | Routine notifications |
|---|---|
| `silent` | Feed and sidebar only; no banner, no sound. |
| `quiet` | A banner, no sound. |
| `normal` | Banners with the turn-end or needs-you sound (the default). |
| `chatty` | Normal, plus a banner per delivered mail and a delegate's turn ends. |

```bash
c11 notify-level            # prints the current stop
c11 notify-level quiet      # sets it (also Settings ▸ Notifications ▸ Notification Level)
```

The dial is the operator's. Change it only when the operator asks you to; never turn it down
to quiet your own notifications or up to be heard. To be heard, raise a flag. From a
terminal on another machine `notify-level` is refused (`relay_not_allowed`).

### Sounds

Every notification plays exactly one sound: its channel's, or for a flag, its kind's own sound
when the kind has one. Each channel is its own setting (Settings ▸ Notifications ▸ Sound, or
`c11 notify-sound`):

| Channel | When | Default |
|---|---|---|
| `turn-end` | An agent finished its turn, and every other routine notice | Bottle |
| `needs-you` | An agent stopped on the operator: a permission prompt, a question or plan dialog, an ask | Glass |
| `flag` | A raised flag whose kind has no sound of its own | Hero |

```bash
c11 notify-sound                          # the three sounds
c11 notify-sound needs-you Ping           # sets one (the operator's call, like the dial)
c11 notify-sound flag ~/Sounds/gong.m4a   # an audio file
```

A sound is `default`, `none` (not for `flag`: a flag always sounds; a kind may be `none`), a
macOS sound (Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi,
Submarine, Tink), or a path to an audio file: `.aiff`, `.wav` and `.caf` in a codec
notifications play (PCM, IMA4, µLaw, aLaw) are kept as they are, anything else Core Audio
reads (`.m4a`, `.mp3`, `.aac`, compressed `.caf`) is converted to PCM `.caf`, and 30 seconds is
the limit. From the CLI a bare name such as `bell.wav` counts as a path when that file is in
the current directory. c11 copies the
file into its own store (`~/Library/Application Support/c11/sounds/`), so moving or deleting the
original changes nothing. macOS plays a notification's own sound only from the app's bundle,
the system sound folders and `~/Library/Sounds`, so while a channel or kind uses an imported
sound, c11 keeps one playback copy of it in `~/Library/Sounds`,
`c11-<id>.<ext>`; it replaces or removes that copy when the sound changes or is unset, and
touches nothing else in that folder. The system plays it, so Focus and the per-app sound
switch still apply. If a
stored file goes missing or stops playing, the alert falls back (a kind to the flag sound, the
flag sound to Hero, a routine channel to its default) and its event names `sound_requested`
and `sound_fallback`: never silence, never a dialog.

The dial governs `turn-end` and `needs-you`; a flag is never dialed. Claude's permission
prompts, questions and plan approvals reach `needs-you` on their own, one sound per ask. The same
ask arriving again (Claude's own Notification for a question or plan it already posted) posts no
banner and no sound, whether or not the operator has read the first; its newer text replaces the
panel's record. Anything else is a new ask and sounds: another question, another session, a second
permission prompt, or any ask after the agent resumes. Any
other agent marks an ask with `c11 notify --needs-you --title "<what you need>"`; each such call
is its own ask and sounds. Each routine system notification
writes one `notification.routine` event (`c11 events tail --filter type=notification.routine`):
`action` (`posted`, `failed`), `channel` (`turn_end`, `needs_you`), the panel, `sound`,
`sound_source` (`channel`, `fallback`, or `level` for a Quiet banner with no sound), and the
fallback fields. A kind's sound is this Mac's setting: a flag raised from another machine plays
the sound this Mac gives its kind.

A flag is **sticky** — it holds until dismissed or lowered, and if you are also stopped the
mark strobes in its flag color, the strongest signal c11 has; generic flags keep violet.
**Expect at least nine in ten agents to never
carry one**; the tier's power is its scarcity. Typing into the flagged panel lowers the
flag immediately — an operator's first keystroke of a reply is the answer arriving — so a
flag that vanishes mid-conversation was answered, not lost. Otherwise a dismissed flag was
*seen*: `flag.lowered` carries `by`, and operator dismissal without an answer means seen
and deferred — re-raise only if the blocker still stands and you can say why the deferral
doesn't. All four attention verbs accept `--by agent|operator`, defaulting to `agent`; pass
`--by operator` only when acting on the operator's instruction, so the event trail stays
honest.

Every raise sent from inside c11 also records the calling panel UUID as
`flag_caller_panel_id`; agent-originated raises are rejected when c11 cannot identify that
caller. An operator-originated raise outside c11 may omit it. This is attribution, not a copied
display identity: resolve the UUID against current panel metadata or conversation state, and
fall back to the raw UUID after the caller closes. `flag.raised` events carry the same
`caller_panel_id` plus `by`; named events also carry the resolved `kind` snapshot. Generic
events omit that optional field, so older event records remain valid. `flag.list` and Feed JSON
include the optional active kind snapshot.

### Delegates: workers that report to their parent

A **delegate** is an agent you launched whose results you will handle. Its routine stops go to
you, not the operator: on stop its mark reads idle, and it stays out of waiting counts, ⌥V and
routine notifications (the record still lands in the store). Its mark sits on a **baseline**: one
thin rule under the mark per delegate hop, two for a delegate of a delegate (the display stops at
two; the tooltip and panel list give the true depth). The baseline is the only delegate cue; color
still means attention (the lifecycle colour, blue cache-cold, violet generic flag, or a named flag
token), so a cold delegate is gray or blue like any agent. Working is yellow, waiting is white
(near-black on a light theme), done stays gray. **The waiting colour and shape mean waiting on the
operator, nothing else:** a stopped delegate shows idle, and the only waiting-shaped delegate is a
flagged one, in its flag color, with its baseline kept. The operator hears that *you* are waiting,
never that your worker finished.
Parent/child is a creation fact: every delegate is a child, but not every child is a delegate.
Use the delegate vocabulary for new work; `--suppressed`, `suppress`/`unsuppress`, and reads
of `suppressed` remain aliases for compatibility:

```bash
c11 launch-agent ... --delegated             # launch as your delegate
c11 config launch <saved> --delegated --title "role"   # saved config; you are the parent and the delegate owner
c11 delegate --panel <child>                 # manual launch: right after creating the panel
c11 undelegate --panel <child>               # release it back to the operator
```

**Launch the workers you'll manage as delegates.** The canonical case is an implementation
worker whose output you will review and act on. Launch normal when the operator will deal with
the child directly (they asked for an instance they can watch or drive), or when you are
handing the work off for good. A delegate is yours in three ways:

- **Completion.** Opt into the mailbox doorbell (`mailbox.delivery=stdin`) and tell the
  delegate to finish with `c11 mailbox send --to-parent`. Its report becomes your next turn.
- **Escalation.** Put this in its prompt: *"Report results and recoverable blockers to your
  parent by mailbox. If something needs the operator, or your parent can't or shouldn't judge
  it, raise a c11 flag."*
- **Visibility.** The baseline under its mark distinguishes a quiet worker from an ordinary
  idle panel; a generic flag turns the mark and its baseline violet, while a named flag uses its
  registered color token.

c11 releases a delegate when its owner panel closes. A re-tasked delegate releases itself with
`c11 undelegate --panel "$C11_PANEL_ID"`.

**If you are a delegate,** report to your parent. A flag goes straight to the operator, past
your parent, at full strength. Raise one when you hit something that needs a human, looks
dangerous, affects other agents, contradicts what the operator asked for, or when your parent
itself seems wrong. If the operator gives you a new mission directly, you are no longer a
delegate: `c11 undelegate --panel "$C11_PANEL_ID"`. Never make yourself a delegate.

### Reading attention state

```bash
c11 get-metadata --panel panel:12    # flag, delegated + delegated_by, and suppressed state, when set
```

`tree` and `get-titlebar-state` do not carry attention state; `get-metadata` is the read.
`flag` and its caller UUID are absent rather than empty when unset. Parent-side monitoring patterns:
[references/orchestration.md](orchestration.md).
