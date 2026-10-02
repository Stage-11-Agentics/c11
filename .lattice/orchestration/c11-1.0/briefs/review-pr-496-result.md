# PR496 Review

Verdict: **FAIL** at `c1be8afd15316e1b4dcf928431771d3b35782aea`.

Base: `0ff8887e5e965400b01645ef40b85fd0b2605cf2`. Live PR head/base match these revisions; the detached review checkout is clean. Full diff: only `skills/c11/references/orchestration.md`, four added lines and one removed line.

## Blocking

1. **False unconditional argv claim — `skills/c11/references/orchestration.md:119`.** The new text says "`--prompt-file` sends the file's *contents* through argv." This is true for Codex and other argv-capable kinds, but false for shipped Kimi and GitHub Copilot launches. For example, with a readable brief containing `hello`, `c11 launch-agent --type kimi --prompt-file /tmp/brief.md` produces the factory launch line `kimi --auto` without the brief in argv; c11 subsequently submits `hello` through terminal input.

   Evidence at the reviewed head: `CLI/c11.swift:2394-2407` reads the file into the same prompt string as `--prompt`; `Sources/DefaultAgentResolver.swift:686-698` selects positional argv, flag argv, or a delayed prompt by template. `Sources/AgentManifest.swift:444` and `:492` select post-boot delivery for Kimi and GitHub Copilot. `Sources/SocketHandlers/SocketDispatch.swift:1401-1412` submits that prompt through `sendSubmitFormText` after 2.5 seconds. The existing fixture `c11Tests/DefaultAgentResolverTests.swift:967-970` explicitly expects `kimi --auto` and a separate delayed prompt (read, not executed).

   Smallest fix: replace the unconditional statement with: "`--prompt-file` reads the file's contents and uses the same delivery path as `--prompt`; for argv-capable agents, the full text still rides the launch command." Keep the one-line pointer recommendation.

## Non-blocking

None. The example at lines 114-116 uses accepted flags, including trailing `--json` (`CLI/c11.swift:2468-2501`). The Codex template supports `--model` and renders `--effort high` as `-c model_reasoning_effort=high` (`Sources/AgentManifest.swift:391-398`). Under factory configuration, the source composes:

```text
codex --yolo --model gpt-5.2 -c model_reasoning_effort=high 'Read /abs/path/brief.md and follow it exactly.'
```

This is a source-derived command, not an observed launch. The example assumes the caller creates the readable brief at the placeholder absolute path. The added guidance is present tense, contains no history narration, and uses generic paths with no home paths or private data. Its file-pointer recommendation matches the existing complex-prompt guidance in this reference.

## Runtime proof still required

No Atlas run is required to establish or repair this documentation mismatch. No builds, tests, or agent launches were performed. The claimed long-prompt continuation/stall was not reproduced; the source does confirm that argv-capable launches type the composed command through the PTY (`Sources/SocketHandlers/SocketDispatch.swift:1390`). Runtime reproduction of that symptom would require an Atlas tagged-build launch with a long prompt. This review does not claim that proof.

## Delta re-review: 947eff1a873f85ef36ca1db3ed70263fef9ee2cb

Verdict: **PASS**. This supersedes the original FAIL for the new head.

Scope: only `c1be8afd15316e1b4dcf928431771d3b35782aea..947eff1a873f85ef36ca1db3ed70263fef9ee2cb`, a single sentence change at `skills/c11/references/orchestration.md:119`. Fetched branch and live PR head match the requested SHA; detached checkout is clean.

### Blocking

None. Finding 1 is fixed: the sentence now states that `--prompt-file` reads the file's contents and shares `--prompt`'s delivery path, qualifying launch-command delivery to argv-capable agents. This matches `CLI/c11.swift:2394-2407` and `Sources/DefaultAgentResolver.swift:686-698` at the new head, including the separate post-boot branch. No CLI source or example command changes occur in this delta.

### Non-blocking

None.

### Runtime proof still required

None for this wording correction. Static delta review only; no builds, tests, or agent launches performed. The original runtime-proof limitation remains unchanged.
