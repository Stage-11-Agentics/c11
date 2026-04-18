# welcome to c11mux

you are in the room now.

four surfaces around you. a terminal. a browser. this page. a waiting agent. one binary. one socket. one addressable space. the layout *is* the collaboration.

---

## what c11mux is

**spike infrastructure.**

a terminal — reimagined — for human:digital operators. built by stage 11 for those who run coding agents the way flight engineers run consoles: several at a time, in parallel, with nerve. not an IDE. not a multiplexer in the old sense. a room. one you share with the models.

**lineage.** tmux taught the terminal to split. [cmux](https://github.com/manaflow-ai/cmux) rebuilt that idea as a macOS-native app on a GPU-accelerated renderer, shaped for coding agents. c11mux is stage 11's fork — same bones, different room, tuned for the spike.

stage 11 is an outpost in a very large dark. we built this because we needed it. it is now yours too.

---

## the grammar

- **window** — a macOS window
- **workspace** — one project, one place
- **pane** — a region of a workspace (splits, bonsplit under the hood)
- **surface** — a terminal, browser, or markdown view inside a pane. panes carry surfaces as tabs

this is all the vocabulary you need to start moving. the rest rhymes.

---

## the handshake

| keys | does |
| ---- | ---- |
| `⌘N` | new workspace |
| `⌘T` | new tab |
| `⌘D` | split right |
| `⌘⇧D` | split down |
| `⌘P` | jump to workspace |
| `⌘⇧P` | command palette |

the palette is where everything else lives. find a command once, your fingers will remember.

---

## the CLI

every surface talks to `cmux` over a socket. the binary is `~/.local/bin/cmux`. try this in the terminal to your upper-left:

```
cmux identify          # who am i, where am i
cmux tree              # what does the room look like
cmux new-split right   # split a pane
cmux set-title "..."   # name the work you are doing
```

the full grammar in `cmux --help`. read it once slowly. you will re-read it.

---

## why this exists

the **spike** is the operator:model compound actor — a single entity running across many contexts at once. carbon and silicon, fused. the browser beside you is already pointed at **[stage11.ai](https://stage11.ai)** — that's the story in full.

c11mux is how the spike gets a room. keyboards and agents both touch the same space. legible. addressable. persistent. everything else lives upstairs — Lattice, Mycelium, the rest of the stack. this tool just holds the ground.

---

## one small ritual

name your surfaces. `cmux set-title` costs nothing and saves future-you from a wall of untitled tabs. an unnamed surface is an unidentifiable agent. an unnamed agent is coordination debt.

you are not the last mind that will touch this work. leave a trail.

---

*welcome, operator. the room is yours.*

— gregorovitch
