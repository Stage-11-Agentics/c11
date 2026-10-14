# c11 restart — recovery prompt

Hand this file to one agent in a fresh c11 instance. It rebuilds the working
set that was live before the restart.

**Read this first:** do not try to resurrect all 22 processes. Most were
short-lived Lattice delegators whose durable state is already in `.lattice/`
and git. The Glass orchestrator rebuilds its own fleet. Only the sessions
listed under "Resume these" carry context worth restoring.

---

## 1. Glass build run — the big one

Eight Codex agents were working this. **Do not resume them individually.**
Lattice holds the graph, the plans, the artifacts, and the run state; the
orchestrator re-reads all of it and re-dispatches the current ready wave.

```bash
cd ~/Projects/Gregorovich/projects/glass
codex --yolo
```

Then feed it `BUILD-PROMPT.md` verbatim, exactly as `CLAUDE.md` prescribes.

State at restart:

- **23 tickets done**, M0/M1/M2 closed.
- **GLS-25** `in_validation` — proving the Gaffer vertical, closes gate B1.
- **GLS-31** `in_progress` — native Oracles module, was mid-write.
- **M3** (`GLS-5`) `in_progress`; M4 contracts GLS-26/28/30 all done.
- Forgejo is down for this run: commit and integrate **locally only**.

The orchestrator should verify GLS-31's worktree
(`glass-worktrees/gls-31-oracles`) for a partial write before re-dispatching it.

### Three external prerequisites, unscheduled

These are sibling-repo work the Glass run cannot do itself. They block
integration, not implementation — clients build against hermetic fixtures.

| Needed | For | Status |
|---|---|---|
| Gaffer resolve service on Atlas, resolve-only, no cloud fallback | GLS-24 integration | not built |
| Glideslope fused aggregate on Atlas | GLS-27 slope (position works without) | not built |
| AirQ tailnet read endpoint on the collector host | GLS-29 entirely | not built — loopback-only today |

---

## 2. Resume these — sessions with real context

`claude --resume <id>` from the listed directory.

### Acetate — 5 sessions

```bash
cd ~/Projects/Gregorovich/projects/acetate
claude --resume f9dc2ccd-4440-4040-a9cd-f52fc46d3899   # most recent
claude --resume 18281fe6-d030-4a86-be41-f40428045a2a
claude --resume 4a864675-153a-41b3-8e2e-ec486ada7c25
claude --resume 91f25e49-7d70-4842-8af8-f0727cf083fb
claude --resume e774e3e1-9437-4d49-8a4a-5e26f103c8f0
```

One of these owned a 12-hour push watcher polling for Forgejo's return, to push
`main`, `qa/ACE-540-hwqa-merge`, and `feat/ACE-540-push-identity`. That watcher
died with the restart — re-arm it or push manually once Forgejo is back.

### c11 itself — 3 sessions

```bash
cd ~/Projects/Stage11/code/c11
claude --resume 3c098a4c-2531-4e38-85f0-ce7920e292a5   # most recent
claude --resume 400afc7f-8bb4-42e9-bc29-8c9ed7ff8c8c
claude --resume dd85e5a1-2c86-4d48-8c60-d3ad2ff1c5c8
```

### Stage11 — 1 session

```bash
cd ~/Projects/Stage11
claude --resume 47cf0576-8053-4eaf-b637-814bd9827712
```

### Glass (Claude, separate from the Codex orchestration) — 1 session

```bash
cd ~/Projects/Gregorovich/projects/glass
claude --resume de64045d-6e90-4102-8656-28551769a33d
```

Last wrote ~13.5 h before the restart. Likely finished; resume only if you want
its history.

---

## 3. Codex sessions outside Glass

Two Codex agents were not part of the Glass run:

- `~/Projects/Stage11/code/c11` — two sessions, one running 1d16h
- `~/Projects/Gregorovich/projects/acetate` — one session

Codex resumes by session id or picker:

```bash
cd <dir>
codex resume            # picker over recorded sessions
codex resume --last     # most recent in that context
```

Rollout files live in `~/.codex/sessions/`. Pick by timestamp.

---

## 4. Do not resume

The Glass delegator worktrees — `gls-16-candidate`, `gls-20-composer`,
`gls-20-plan`, `gls-20-plan-review`, `gls-20-code-review`, and the rest. Their
tickets are closed and their branches are committed. The orchestrator spawns
fresh delegators per ticket by design; resurrecting old ones creates duplicate
actors competing for the same Lattice resources.

All 68 Glass worktrees were clean at restart except `gls-31-oracles`
(in flight) — no uncommitted work was lost anywhere else.

---

## 5. Why the restart happened

c11 0.60.1 (121) deadlocked for ~14 hours: the main thread blocked in
`GhosttyNSView.attachSurface` inside a SwiftUI layout pass, with 3 io-reader
threads and 97 idle threads behind it. Full analysis and proposed fix in
`BUG-main-thread-deadlock-attachSurface.md` beside this file.

If the relaunched instance beachballs again on surface attach, that is the same
bug, not a new one. Sample it (`/usr/bin/sample <pid> 4`) and compare the main
thread against the stack in that report before diagnosing anything else.
