# C11-112: c11 skill: defer surface titling on bootstrap-only first user messages

## Problem

c11's agent launcher pre-prompt currently fires as the agent's first user message — a friendly variant of "you are running inside c11, load the c11 skill." The c11 skill's `Orient first` flow then mandates titling the surface from the first user message. Result: every freshly launched surface ends up titled after the bootstrap directive ("Load c11 skill" or similar), not the operator's real work. The operator's actual first query — the one that defines what this surface is *for* — arrives one turn later, and the title rarely gets refreshed to match.

UX/AX cost: the sidebar fills with identically-titled bootstrap tabs, defeating the whole point of surface titling as a navigable index of in-flight work.

## Why a skill-side fix (not c11-side, not pre-prompt-side)

Two alternatives were considered and rejected:

1. **Move bootstrap out of the user-message stream** (SessionStart hook, system context, c11 launcher rework). Cleanest structurally but requires c11 changes and may not be portable across agent types. Not necessary if the agent can just do the right thing.
2. **Edit the launcher pre-prompt to be more deferral-aware.** Pushes responsibility into operator-facing config and is fragile (every variant phrasing needs to do the right thing). Worse, the friendlier phrasing already in the launcher is desirable on its own terms — we don't want to compromise its tone for titling logic.

Skill-side wins: agent recognizes bootstrap-shaped first messages, defers titling, and titles correctly on the next real user message. No c11 diff, no timers, no monitoring, no new flags. The rule is phrased by principle so it's robust across phrasing variants of the launcher prompt.

## Solution

Extend `skills/c11/SKILL.md`'s `Orient first` section with one rule:

> **If the first user message is bootstrap-only — a directive to load skill context or otherwise orient the agent toward c11 with no actionable work payload — defer surface titling/description to the next real user message.**

Bootstrap-only first messages are context-acquisition directives. Examples:

- `"load the c11 skill"`
- `"you are running inside c11, load the c11 skill"` (current launcher style)
- `"load the c11 and lattice skills"`
- Any phrasing whose payload is "hydrate context" rather than "do this work"

While deferring:

- Run **agent-identity orientation immediately**: `c11 identify`, `c11 tree`, `c11 set-agent`. These declare *who the agent is*, independent of what work it's doing — safe to fire now.
- Set a placeholder title + description honestly reflecting the orienting state:
  - title: `"Awaiting first task"`
  - description: `"c11 skill loaded. Send your first task to name this surface."`
- Do **not** `c11 rename-tab` / `set-description` based on the bootstrap text.

On the **next** user message (the operator's real first query), run full orientation as the skill already documents — proper title and description derived from that message. Same flow, one turn later.

### Scope refinement (narrow on purpose)

The rule covers **skill-load / context-hydration** patterns only. It does *not* cover:

- `"read /path/to/X and follow instructions"` — the work payload is inside the file. Agent reads the file, identifies the work, titles from that. Normal orientation, no deferral needed.
- Slash commands (`/some-skill`) — the skill takes over and does work; title from what the skill does. Not bootstrap.

Casting the bootstrap net too wide leaves agents stuck on `"Awaiting first task"` when they actually had work to do. Narrow is safer.

### Edge cases

- **Compound first message** (`"load the c11 skill, then plan ticket LAT-42"`): title from the work clause; bootstrap clause is noise. No deferral.
- **No follow-up message** (operator launched a pane just to validate skill loading): placeholder persists. Operator renames via Bonsplit tab UI or a direct `"rename this tab to X"` instruction. No timer-based promotion, no c11 monitoring.
- **Bootstrap-on-context-reset** (`/clear` followed by a fresh bootstrap directive): treat identically — defer titling to the next real user message.

## Known limitation

The rule lives in the skill. The skill is loaded *by* the bootstrap prompt. So the agent only knows the deferral rule after it has loaded the skill in response to the bootstrap message — which is exactly when the rule needs to apply. This works for any agent that reads SKILL.md before titling (the current shape), but is structurally fragile if a future harness ever titles preemptively before loading the skill. Acceptable for now; flag if that constraint changes.

## Acceptance criteria

1. `skills/c11/SKILL.md` `Orient first` section updated with the bootstrap deferral rule, placed right after the existing "absent or ambiguous → ask before orienting" paragraph (same family of guidance).
2. Bootstrap-pattern principle stated, with 2–3 examples covering current and prior launcher phrasings. Phrased so future variants of the launcher tone don't break the rule.
3. Placeholder title/description convention specified verbatim:
   - title: `"Awaiting first task"`
   - description: `"c11 skill loaded. Send your first task to name this surface."`
4. Identity orientation (`c11 identify`, `c11 tree`, `c11 set-agent`) explicitly called out as still running immediately during deferral — it's only titling that defers.
5. Scope-narrowing note: rule does **not** apply to "read X and follow" or slash-command first turns.
6. Edge cases documented: compound first message (work clause wins), no follow-up (placeholder persists), bootstrap-on-`/clear` (treat the same).
7. Known limitation noted (rule loaded by the prompt it governs).
8. No c11 source changes. Skill-only diff.

## Touch points

- `skills/c11/SKILL.md` — primary edit (Orient first section)
- `skills/c11/references/orchestration.md` — light review for consistency with sub-agent launch prompt templates
