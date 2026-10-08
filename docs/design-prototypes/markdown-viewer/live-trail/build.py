#!/usr/bin/env python3
"""Build live-trail/index.html: embed fixtures + the simulated agent edit script.

The live scenario replays an agent writing the C11-184 Lattice plan. We take the
fixture as the *final* state (plus one Mermaid block the agent adds, with a few
task items checked), then walk the edit script backwards to derive the partial
doc the operator first sees. The page replays the steps forwards on a timer.
Every op is asserted to match exactly once, so the replay is byte-exact.
"""
import json, pathlib, re

HERE = pathlib.Path(__file__).resolve().parent
FIX = HERE.parent / "fixtures"

def read(name):
    return (FIX / name).read_text()

PLAN = read("task_01KYMTXQVWCXCF0TGN5ZWG341E.md")
# drop the trailing empty "Reset ..." headings (Lattice noise, no content)
PLAN = re.sub(r"\n## Reset 2026[^\n]*\n(\n## Reset 2026[^\n]*\n)*$", "\n", PLAN)
PLAN = PLAN.rstrip("\n") + "\n"

MERMAID_V1 = """Commit boundary, one serialized pass per mutation:

```mermaid
flowchart LR
  CLI["c11 raise-flag<br/>socket worker"] -->|validate + dedupe| SVC["SurfaceAttentionService<br/>serialized commit"]
  SVC --> META[("SurfaceMetadataStore<br/>flag · suppressed")]
  SVC --> IDX["attention index<br/>render/query cache"]
  SVC --> SIG["signal-eligible<br/>unread indexes"]
  SVC --> EVT["events<br/>flag.raised · flag.lowered"]
  IDX --> MARKS["tab + sidebar marks"]
  SIG --> WAIT["Waiting Agent<br/>count · Option-V"]
```"""

MERMAID_V2 = """Commit boundary, one serialized pass per mutation:

```mermaid
flowchart LR
  CLI["c11 raise-flag<br/>socket worker"] -->|validate + dedupe| SVC["SurfaceAttentionService<br/>serialized commit"]
  SVC --> META[("SurfaceMetadataStore<br/>flag · suppressed")]
  SVC --> IDX["attention index<br/>render/query cache"]
  SVC --> SIG["signal-eligible<br/>unread indexes"]
  SVC --> EVT["events<br/>flag.raised · flag.lowered"]
  SVC -.->|flag raise only,<br/>pierces suppression| SYS["direct system<br/>notification"]
  IDX --> MARKS["tab + sidebar marks"]
  SIG --> WAIT["Waiting Agent<br/>count · Option-V"]
  SVC ==>|after commit is observable| RESP["socket response"]
```"""

ANCHOR_META = "- Metadata remains authoritative; the observable index is a bounded render/query cache, not a second persistence system.\n\n"
FINAL = PLAN.replace(ANCHOR_META + "Mutation semantics:", ANCHOR_META + MERMAID_V2 + "\n\nMutation semantics:")
assert MERMAID_V2 in FINAL

CHECK_1 = ["C11-183 ancestry present", "Flag and suppression are separate canonical"]
CHECK_2 = ["Required reason is validated", "Flags are sticky", "Suppressed unflagged surfaces never present waiting", "Flag raise does not write"]
CHECK_3 = ["No second shortcut is added", "Six locale translations", "Staged skill text lands"]
for item in CHECK_1 + CHECK_2 + CHECK_3:
    assert FINAL.count("- [ ] " + item) == 1, item
    FINAL = FINAL.replace("- [ ] " + item, "- [x] " + item)

def section(title):
    start = FINAL.index("\n## " + title)
    nxt = FINAL.find("\n## ", start + 4)
    return FINAL[start:] if nxt < 0 else FINAL[start:nxt]

res = section("Plan-review cycle 1 resolutions")
res_parts = res.split("\n- Replaced the double tagged launch")
RES_1 = res_parts[0]
RES_2 = "\n- Replaced the double tagged launch" + res_parts[1]
PH3 = section("Operator Phase 3 decision")
VAL = section("Operator validation decision")
NON = section("Explicit non-goals")
assert FINAL.endswith(NON)

def line_starting(prefix):
    i = FINAL.index(prefix)
    return FINAL[i:FINAL.index("\n", i)]

SOCKET_NEW = line_starting("Socket execution contract:")
SOCKET_OLD = "Socket execution contract: parse and validate on the socket worker, then apply the mutation on the main actor and respond. The handlers must not activate c11, raise windows, select workspaces, or mutate in-app focus."

TAGGED_HEAD = "## Tagged runtime, visual, and latency validation\n\n"
op_i = FINAL.index("**Operator decision 2026-07-28:**")
op_j = FINAL.index("Before computer-use automation in any follow-up")
TAGGED_NEW = TAGGED_HEAD + FINAL[op_i:op_j] + "Before computer-use automation in any follow-up, obtain explicit operator"
TAGGED_OLD = TAGGED_HEAD + "Before computer-use automation, obtain explicit operator"

d_i = FINAL.index("- [ ] **DEFERRED by operator decision:** the ten")
d_j = FINAL.index("- [ ] Six locale") if "- [ ] Six locale" in FINAL else FINAL.index("- [x] Six locale")
DEFER_NEW = FINAL[d_i:d_j]
DEFER_OLD = ("- [ ] The ten tagged-build visual scenarios are captured with screenshots and a validation record.\n"
             "- [ ] The 20-agent <=1 ms p95 fleet-latency gate passes, or the chosen fallback rung is recorded.\n")
CI_NEW = "- [ ] PR CI test actions are green at the final head SHA; CI is the sole remaining gate by\n      operator decision."
CI_OLD = "- [ ] PR CI test actions are green at the final head SHA."

c_i = FINAL.index("The operator explicitly forbids every local")
c_j = FINAL.index("\n\n", c_i)
COMPILE_NEW = FINAL[c_i:c_j]
COMPILE_OLD = ("Iterate locally on the safe `c11-logic` scheme for pure-model work; leave host-bound\n"
               "`c11Tests` to PR CI, which remains the gate for every assertion.")
PBX = "- **pbxproj normalization noise:** prefer existing project tooling and verify semantic membership/build settings.\n"
STALE = "- **Local test flakiness:** iterate on `c11-logic` locally and push only once green.\n"

ROW_NEW = "| yes | yes | true lifecycle, violet | flag priority | flag raise direct delivery |"
ROW_OLD = "| yes | yes | true lifecycle, violet | flag priority | none (suppressed) |"

def checks(items):
    return [["sub", "- [ ] " + it, "- [x] " + it] for it in items]

# Forward edit script. delay = simulated seconds after the previous write.
STEPS = [
    {"delay": 50,  "ops": checks(CHECK_1)},
    {"delay": 70,  "ops": [["append", RES_1]]},
    {"delay": 55,  "ops": [["append", RES_2]]},
    {"delay": 90,  "ops": [["sub", ANCHOR_META + "Mutation semantics:", ANCHOR_META + MERMAID_V1 + "\n\nMutation semantics:"]]},
    {"delay": 80,  "ops": [["sub", SOCKET_OLD, SOCKET_NEW]]},
    {"delay": 120, "ops": [["append", PH3]]},
    {"delay": 40,  "ops": [["sub", ROW_OLD, ROW_NEW]]},
    {"delay": 50,  "ops": [["sub", MERMAID_V1, MERMAID_V2]]},
    {"delay": 100, "ops": checks(CHECK_2)},
    {"delay": 110, "ops": [["sub", TAGGED_OLD, TAGGED_NEW], ["sub", DEFER_OLD, DEFER_NEW], ["sub", CI_OLD, CI_NEW]]},
    {"delay": 70,  "ops": [["append", VAL]]},
    {"delay": 90,  "ops": [["sub", COMPILE_OLD, COMPILE_NEW], ["sub", PBX + STALE, PBX]]},
    {"delay": 80,  "ops": [["append", NON]]},
    {"delay": 60,  "ops": checks(CHECK_3)},
]

def fwd(doc, op):
    if op[0] == "append":
        return doc + op[1]
    _, before, after = op
    assert doc.count(before) == 1, ("fwd", before[:80], doc.count(before))
    return doc.replace(before, after)

def rev(doc, op):
    if op[0] == "append":
        assert doc.endswith(op[1]), ("rev append", op[1][:60])
        return doc[: -len(op[1])]
    _, before, after = op
    assert doc.count(after) == 1, ("rev", after[:80], doc.count(after))
    return doc.replace(after, before)

doc = FINAL
for step in reversed(STEPS):
    for op in reversed(step["ops"]):
        doc = rev(doc, op)
INITIAL = doc
replay = INITIAL
for step in STEPS:
    for op in step["ops"]:
        replay = fwd(replay, op)
assert replay == FINAL, "replay mismatch"

DOCS = [
    {"id": "plan", "live": True, "tab": "c11-184 plan", "num": 12,
     "path": ".lattice/plans/task_01KYMTXQVWCXCF0TGN5ZWG341E.md",
     "desc": "C11-184 flagged + suppressed agents: executable plan",
     "writer": "codex · c11-184 delegator", "src": INITIAL},
    {"id": "messaging", "live": False, "tab": "messaging design", "num": 14,
     "path": "docs/c11-messaging-primitive-design.md", "desc": "c11 messaging primitive: design",
     "src": read("c11-messaging-primitive-design.md")},
    {"id": "mailbox", "live": False, "tab": "mailbox guide", "num": 15,
     "path": "docs/c11-mailbox-guide.md", "desc": "c11 mailbox guide",
     "src": read("c11-mailbox-guide.md")},
    {"id": "browser", "live": False, "tab": "browser port spec", "num": 16,
     "path": "docs/agent-browser-port-spec.md", "desc": "agent-browser port spec",
     "src": read("agent-browser-port-spec.md")},
    {"id": "skill", "live": False, "tab": "c11-markdown skill", "num": 17,
     "path": "skills/c11-markdown/SKILL.md", "desc": "c11-markdown skill",
     "src": read("c11-markdown-SKILL.md")},
]

data = {"docs": DOCS, "steps": STEPS}
blob = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
tpl = (HERE / "template.html").read_text()
assert "/*__DATA__*/" in tpl
(HERE / "index.html").write_text(tpl.replace("/*__DATA__*/", blob))
print(f"ok: initial {INITIAL.count(chr(10))} lines -> final {FINAL.count(chr(10))} lines, {len(STEPS)} writes")
