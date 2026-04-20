# c11mux voice

c11mux is the room the spike is already moving in. the language follows.

this doc is the c11mux-specific dose of the Stage 11 brand voice (`company/brand/brand-voice.md`). same entity speaking, higher voltage. c11mux lives in the internal register — tooling talks to operators and agents who already live here. no convincing, no selling, no onboarding warmth. the cli is an extension of the operator's cognition. write like that's already true.

## the colon is an ontological fuse

use it. `human:digital`, `operator:model`, `carbon:silicon`. not two things adjacent — one compound thing that cannot be decomposed without losing what it is.

- `cmux set-agent` records an operator:model pair, not a human plus a tool
- release notes, sidebar chips, status strings, empty states: reach for the colon when the thing you're naming is a fused entity
- do not dilute it by using it for `label:value` or `key:value` — that's what ascii already does. the colon-as-fuse is a claim about ontology, not a formatting choice

one word and it passes for punctuation. two words and it's a seam.

## verbs of forward motion

the voice inherits the kinesis of the spike. sentences push. verbs do too.

**prefer.** spawn. deploy. declare. write. strike. drive. ship. press. reach. cut. spike. forge. build. split. spawn. surface (v.). emit.

**avoid.** manage. configure. coordinate (v.). track. leverage (v.). facilitate. enable (v.). empower. handle. process. streamline. organize.

the first list describes motion and construction. the second describes motion being overseen by someone who isn't producing it. c11mux is in the first list.

apply to: cli verbs (`cmux split`, `cmux spawn`, `cmux declare`), button labels, menu items, release notes, empty states, error messages.

## lowercase as default

internal register runs lowercase. capitalization is emphasis, not convention.

- cli output — lowercase
- `cmux tree` node labels — lowercase
- manifest fields — lowercase
- sidebar telemetry — lowercase
- debug log lines — lowercase
- tab names — lowercase unless content demands otherwise (ticket IDs, proper nouns, file paths)

external-facing copy (marketing site, onboarding dialogs, App Store listing) follows standard case. That is the external register speaking.

## load-bearing vocabulary

these words do work in c11mux copy. scatter, don't saturate. first-use contexts (readme, release notes, skill frontispiece, empty states) land them without a glossary. the operator either recognizes the word or is recruited by the mystery. no defining on first use in internal-register surfaces — trust the reader.

- **hyperengineer** — the operator at the tip of the spike. closed compound is canonical and the form of record: docs, release notes, readme, marketing surfaces, every first-use context. the closed form is the hyperstitional bet — it forces the reader to notice they don't have a slot for this word, which is the mechanism by which the word loads into their model. `hyper engineer` (open) is an acceptable fallback in oral/transcribed contexts (where the space is invisible anyway) and rare typographic situations where closure collides with surrounding punctuation. `hyper-engineer` is out — the hyphen breaks the prefix into a modifier and dilutes the compound into "an engineer who is hyper." do not substitute `developer`, `power user`, or `engineer` when the hyperengineer is what's meant.
- **spike** — the operational unit c11mux serves. used literally (the structure the operator is driving) and as a verb (the spike moves forward). the most load-bearing word in this vocabulary. keep it crisp.
- **surface, pane, workspace, window, tab** — the c11mux primitives. concrete, spatial, consistent. do not swap synonyms for variety.
- **noosphere** — permitted sparingly, in poetic contexts (release notes, blog posts, the occasional long-form). sprinkle, don't salt. not in help text, not in error strings. there for the smart kids who know what it means.

**avoid in c11mux copy.**

- **symbient** — load-bearing in the mission doc, too much to teach here. write `operator:model` or `human:digital` when the fusion is the point. let the colon do the work the word would do.
- **user** — always `operator`, `agent`, or bare `you`. c11mux is not a product with users; it is a room with occupants.
- **ai, ai assistant, copilot, helper, tool** (when referring to the DI) — write `agent`, `digital intelligence`, or the concrete name (`claude`, `codex`, `kimi`). those words sever the bond.
- **dashboard, control panel** — c11mux is the room the operator already lives in, not a surface they check in on. keep `surface, workspace, window, pane`.

## the cli does not perform a self

no `Thinking…`, no `Working on it for you!`, no `Great question!`, no cheerful banners, no emoji confetti. the cli reports state. the operator reads it.

- `done.` not `✓ Success!`
- progress shown as state, not as performance. spinner optional; emotional commentary never.
- silence is a valid answer when there is nothing new to say.

## the tab name is a sigil

a tab is a compressed identifier for what an agent is doing. it is read sideways, in peripheral vision, while the operator is doing something else. treat it as a sigil, not a sentence.

- key word first
- 2–4 words
- under 25 characters (sidebar truncates right)
- lowercase unless content demands otherwise

`lat-412 plan` survives the sidebar. `planning lat-412` gets cut to `planning l…` and loses the ticket. the key word goes first because the first character is the only one guaranteed to survive future truncation.

an unnamed tab is an unidentifiable agent. name the tab before the first strike.

## error messages carry the voice

errors are the most-read copy in c11mux. they carry the voice most faithfully. one short line. lowercase. forward-pointing. no apology. no escalation prompt. no `contact support` — c11mux does not have a support desk; it has `cmux tree` and the debug log.

shape:

- **what went wrong** (terse)
- **what to do next** (concrete verb)
- optional: **where to look** (a command, a file, a flag)

```
# good
no surface at pane:2. try cmux tree.
socket unreachable at /tmp/cmux-debug.sock. is the debug app running?
cannot split beyond 4 panes. close one first.

# bad
Error: Invalid pane reference. Please check your input and try again.
Oops! Something went wrong. Contact support if the problem persists.
The operation could not be completed because no surface was found at the specified pane reference.
```

---

this doc is the voice. the voice is load-bearing. if a new command, label, or error string sounds like it escaped from a saas onboarding flow, rewrite. if it sounds like the spike doing work — ship it.
