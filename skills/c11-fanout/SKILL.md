---
name: c11-fanout
version: 1
description: Fan one brief out to several agents in c11 (different models, harnesses, or approaches, each in its own tab and, when they write code, its own git worktree), then fan their results back in to compare, judge, and merge. Load when the operator says "fan out", "race", "try it with N models" or "N approaches", "best of N", "fork this into", or wants several independent attempts or opinions on one task. Requires the c11 skill.
---

# c11 fan-out

One brief, N agents, one area. c11 provides the tabs, labels and signals. The brief, the worktrees and the judgment belong to the workflow. Fan-out is a recipe over shipped commands, not a command.

## 1 · Decide the shape before launching

- **Read-only or write.** Questions, reviews and plans need no isolation, so launch every member in the same cwd. Code changes need one git worktree per member.
- **The axis.** Vary one thing and name it in the brief:
  - model, to learn which model is best at this;
  - approach (one model, N stated strategies), to learn which design is best;
  - effort.

  Approach fan-out often answers the better question.
- **Plan first when building is expensive.** Fan out the plan, then implement only the plan or two you pick.
- **Cold or forked.** A cold member starts from the brief. A forked member starts from a live conversation that already holds the context (section 3).

## 2 · Write one brief

Write one file, identical for every member. Members can't ask follow-up questions, so the brief states:

- the task and the acceptance bar;
- the deliverable:
  - a summary at `<results-dir>/<member>.md`, in a shared directory outside every worktree, covering what the member did, what it chose and why, and what worries it;
  - for write fan-out, the work committed on its branch;
- the receipt: `When done, run: c11 mailbox send --to <parent-address> --body "DONE <member> <branch|na> <head-sha|na>"`;
- isolation: work alone, and don't read, message, or coordinate with other tabs or their worktrees.

Comparability is decided here. Members that answered slightly different questions can't be judged against each other.

## 3 · Launch

**Your own address first.** Receipts come to you by mailbox, so declare where they go before any member launches:

```bash
c11 set-metadata --tab "$C11_TAB_ID" --key mailbox.address --value "<your-handle>" --type string
c11 set-metadata --tab "$C11_TAB_ID" --key mailbox.delivery --value stdin --type string
```

**Worktrees** (write fan-out only). Put them beside the repo, not inside it, so members can't see each other's work. Creating and provisioning them is the project's job (submodules, dependencies, env files), so run the project's own setup.

```bash
git worktree add -b "fanout/$SLUG/$MEMBER" "$ROOT-fanout/$SLUG/$MEMBER" "$BASE"
```

**Cold members**, all into one area:

```bash
TAB=$(c11 launch-agent --type "$HARNESS" --model "$MODEL" --effort "$EFFORT" \
  --area "$AREA" --cwd "$WT" --prompt-file "$BRIEF" --title "$MEMBER $SLUG" --json | jq -r .tab_ref)
c11 set-metadata --tab "$TAB" --json '{"fanout.group":"<slug>","fanout.member":"<member>",
  "fanout.branch":"<branch>","fanout.base":"<sha>","fanout.state":"running"}'
c11 tab-color set --tab "$TAB" "#006B6B"      # one color for the whole group
```

- Lead each title with the member (its model or approach) so siblings stay distinct in the sidebar.
- Give each group one palette color, avoiding purple and magenta, which read as flagged.
- A launch that dies at once (auth, bad model slug) is a launch failure, so fix it and relaunch that member. When you're comparing, a member that ran and produced something weak is a result, not a retry.

**Forked members.** When a conversation has built the context and reached a decision point, fork it instead of briefing N agents from cold. This needs a harness with a fork command (Claude Code, Codex). With any other harness, members start cold.

```bash
SID=$(c11 conversation get --tab "$SOURCE_TAB" --json | jq -r '.active.id // empty')
[ -n "$SID" ] || echo "no captured conversation on $SOURCE_TAB; start this member cold"
TAB=$(c11 new-tab --area "$AREA" --cwd "$WT" \
  --command "claude --dangerously-skip-permissions --resume $SID --fork-session" | awk '{print $2}')
# Codex: --command "codex fork --dangerously-bypass-approvals-and-sandbox -C $WT $SID"
c11 rename-tab --tab "$TAB" "$MEMBER $SLUG"
c11 set-agent --tab "$TAB" --type claude-code --model "$MODEL"   # --type codex for a Codex fork
c11 send --tab "$TAB" "You are a fork. Work only in $WT. Take approach <X>: …"
```

- The fork keeps the source's memory, but its history points at the old directory, so name the new one in the first message.
- A fork stays in its harness: a Claude session can't continue in Codex. Cross-model members start cold from a written handoff.

## 4 · Fan in

- **Receipts.** Each member mails DONE. While you're waiting, each receipt arrives as a new turn. Claude Code and Codex also pick up mail at every turn boundary. In other harnesses, run `c11 mailbox recv --drain` after each turn so nothing waits unread. Set `fanout.state` to `done` on the member's tab as each receipt lands.
- **Quiet members.** Stopping is not finishing. A member that asks a question, crashes or stalls never mails. For the ones you haven't heard from, check:
  - `c11 events tail --filter type=ask.opened`, matching each line's `surface` against your member tabs (blocked on a question);
  - `--filter type=surface.closed` (gone);
  - `c11 read-screen` for anything else.

  Not every harness reports its lifecycle to c11. Where one doesn't, the receipt is the only completion signal.
- **Steering.** Use `c11 send` per member tab. Steering one member and not the others breaks the comparison, so send the same message to all of them or to none.
- **Scoreboard.** The area's tab sheet lists each member's model, its state and how long it has held. The opt-in `turn`, `tools` and `tokens` clocks add effort.
- **Context before code.** Read every summary before any diff. A losing member can still carry findings the winner missed.

## 5 · Merge back

Pick the shape that matches the output:

| Shape | When | Who decides | Integration |
|---|---|---|---|
| Select | N whole answers, one wins | The operator, helped by a judge agent's notes | Merge the winner's branch |
| Oracle | An executable acceptance test exists | The tests | First green, or best score |
| Synthesize | Good parts spread across members | A judge lists the best parts per member; the operator approves | A merge agent re-implements the chosen parts on the winner's branch. Divergent implementations don't cherry-pick |
| Union | Findings or ideas | A dedupe agent | One list, each item counting how many members found it |
| Consensus | Independent diagnoses | Agreement | Agreement raises confidence; disagreement shows where to look |

Judging:

- Compare in this order:
  1. behavior (run each branch);
  2. each summary;
  3. the shape of each diff (files touched, size, test delta);
  4. the diff itself.
- Judge agents favor their own model family. Use a judge from outside the members' families, or one judge per family.
- A blind comparison relabels outputs as letters, and its judge must not have watched the run. Visible tabs leak identity through model chips, the TUI's look and finish order.

## 6 · Clean up

```bash
c11 close-tab --tab "$TAB"
git update-ref "refs/fanout/$SLUG/$MEMBER" "fanout/$SLUG/$MEMBER"   # losers stay as data
git worktree remove --force "$WT"                                   # after the branch holds what matters
git branch -D "fanout/$SLUG/$MEMBER"
```
