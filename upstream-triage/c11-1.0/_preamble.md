# c11 1.0 research brief (shared preamble)

You are one of six research agents scoping **c11 1.0**, a major version in which c11 absorbs the best of what upstream cmux built since the fork. Atin is the operator. He decided on 2026-10-01 that this release takes its time and does a great job, so be thorough rather than fast.

## Orient first

1. Read `~/Projects/Stage11/code/c11/upstream-triage/cmux-landscape-2026-10-01.md` in full. It is the map. Your topic is one section of it.
2. Read `~/Projects/Stage11/code/c11/PHILOSOPHY.md` and the "unopinionated about the terminal" section of `~/Projects/Stage11/code/c11/CLAUDE.md`. c11 is host and primitive, never writes into agent tools' config files (`~/.claude/settings.json`, `~/.codex/*`, ...), and observes agents from outside. The one sanctioned exception is PATH-scoped session-resume wrappers in `Resources/bin/`. Any design you propose has to sit inside that doctrine, or say plainly that it would require changing it and why.
3. Load the `c11` skill. Rename your tab only if your role sharpens; keep the description current (what you are doing now, next gate) and keep its last `Lineage:` line.

## Sources

- **c11 source:** `~/Projects/Stage11/code/c11` (branch `main`). READ ONLY. No edits, branches, commits, builds or test runs.
- **cmux source:** the `upstream` remote in the c11 repo (`manaflow-ai/cmux`). A `git fetch upstream main` was started at about 14:40 today. Check `git -C ~/Projects/Stage11/code/c11 log -1 --format=%cd upstream/main`. If it is older than 2026-09-20 the fetch has not landed; use `gh` meanwhile (`gh pr view <N> -R manaflow-ai/cmux --json title,body,files`, `gh pr diff <N> -R manaflow-ai/cmux`, `gh api repos/manaflow-ai/cmux/contents/<path>`). Read code, not only changelog lines. Never run `git fetch` yourself; one is enough.
- **Installed cmux 0.64.25:** `/Applications/cmux.app`, CLI at `/Applications/cmux.app/Contents/Resources/bin/cmux`. Note that `cmux` on PATH is c11's compatibility shim, not this. `--help` output and bundle contents are fair game. Do not mutate any running app and do not run `cmux hooks setup` or anything else that writes config.

## Machine rules

You are on Hyperion, Atin's laptop, shared with many agents. No heavy work: no builds, no test suites, no local inference. Reading code, `git`, `gh` and greps are fine. Use Agent-tool subagents (Sonnet by default) to fan out reading when that helps; keep the judgment calls yourself.

## Deliverable

Write your report to the path named in your topic brief. Atin's style rules:

- Open with `**Needs you:**` followed by "nothing" or numbered questions. For each question, say what hangs on each answer.
- Plain, short sentences. No em-dashes. No filler. Tables where they help.
- Cite cmux PRs and file paths, and c11 file paths with line numbers, for every factual claim. Mark anything you inferred rather than read.

Sections, in order: **What cmux built** (how it actually works) · **What c11 has today** · **The gap** · **Proposed c11 1.0 shape** (fit to c11 doctrine; alternatives with pros and cons; a recommendation) · **Effort and risk** (S/M/L, what could go wrong) · **Open questions** (numbered).

No Lattice tickets, commits or PRs. Scoping only; the build comes later.

## When you finish

1. Set your tab description to `Report ready at <path>; waiting for Atin.` (keep the Lineage line).
2. Print a summary of 10 lines or fewer in your own terminal, then stop and wait. Atin will come to this tab to talk it through with you. He dictates by voice, so read for intent.
3. Do not message other tabs. The lead watches the reports directory.
