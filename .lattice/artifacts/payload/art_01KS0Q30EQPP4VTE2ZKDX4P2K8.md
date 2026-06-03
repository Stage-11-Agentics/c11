Skill-only edit landed in d27284216 on main.

What changed:
- skills/c11/SKILL.md: added a new paragraph + sub-block to the "Orient first" section, placed right after the existing "absent or ambiguous → ask before orienting" rule (same family of guidance).
- New rule: bootstrap-only first messages defer titling to the next user message. Placeholder title "Awaiting first task" and description "c11 skill loaded. Send your first task to name this surface." set during the deferral window.
- Identity orientation (c11 identify / c11 tree / c11 set-agent) explicitly carved out as still running immediately during deferral.
- Scope narrowed on purpose: rule does NOT cover "read X and follow" first turns (work lives in the file; read it, then title) or slash-command first turns (slash skill titles for its own work).
- Edge cases inline: compound first message (work clause wins), no follow-up (placeholder persists; operator-driven rename), bootstrap-on-/clear (treat the same).

Acceptance criteria (from ticket description):
1. SKILL.md Orient first section updated with rule placed right after the absent/ambiguous paragraph — done.
2. Principle stated with examples covering current and prior launcher phrasings — done; phrased by principle ("hydrate context vs do work"), with three example phrasings.
3. Placeholder title/description specified verbatim — done.
4. Identity orientation explicitly still runs immediately — done.
5. Scope-narrowing note (no read-X-and-follow, no slash commands) — done.
6. Edge cases documented (compound, no follow-up, bootstrap-on-/clear) — done.
7. Known limitation about the rule loaded by the prompt it governs — captured in the ticket description; intentionally not duplicated in SKILL.md to keep the skill terse.
8. No c11 source changes — confirmed; diff is 1 file, +16 lines, skills only.

Touch points:
- skills/c11/SKILL.md — edited.
- skills/c11/references/orchestration.md — reviewed; no edit needed. Orchestrator-spawned sub-agents receive task assignments via the "read X and follow" pattern, which the new rule explicitly excludes from deferral. Sub-agents launched via the c11 Agent Launcher button (and thus hit by the launcher pre-prompt) will pick up the new rule from SKILL.md the same way any agent does. No inconsistency to reconcile.

Not done (out of scope, per ticket):
- c11 launcher changes. Skill-side fix is sufficient.
- Tests. SKILL.md is documentation; no executable seam to assert against.