# c11 per-host agent layer contract (draft)

> **DRAFT for review, C11H-70.** Not frozen. It freezes after two reviews from different model families, time-boxed, with Atin as the named decider for the open points at the end (milestones, `m6-contract`; the Lead's retro lesson 5). After the freeze, changes go through the Orchestrator and reach every consumer ticket.

Sources: vision Decided 11 and 14, plan Settled 9 and ticket 14 (the bus agreements, quoted there from `constellation-bus/sequence/research/09-c11-fit.md`), `docs/c11-relay.md`, c11's envelope v1 (`docs/c11-messaging-primitive-design.md`, LOCKED), milestones 2's acceptance. Consumers: C11H-71 (the layer), C11H-73 (away-merge), C11H-74 (session finder); later C11H-72 (bus transport) and C11H-75 (relay retirement). c11 is unchanged by all of it (Decided 13).

**Why.** The bus is off the critical path (Decided 14). c11 builds the agent layer now, on envelope v1 and the bus agreements, and its own link to each host carries what crosses hosts. All host-to-host traffic goes through one named interface, `HostTransport` (A6), and the relay is its first implementation. The bus later becomes a second implementation of the same interface (C11H-72), passing the same proofs: no record format, store, address, CLI verb or UI changes when it does.

**A1 — Terms.** A *host* is a machine whose hc core c11 links to. Its name is hc's machine name (`hc machine ls`); this Mac is the *app host*, where c11.app runs. An agent's *owning host* is the host its terminal runs on (the machine of its `HCTerminalKey` owning core). The *layer* is five kinds of record per agent: **metadata** (title, description, agent fields, custom keys, sidebar status, progress and log), **flags** (raise, lower, delegate, with actor and kind), **mailbox** (envelopes, inboxes, delivery state), **journal** (`agent-event append` events) and **lineage** (which panel created which, and in which workspace). Conversation records stay with lineage's rules today; transcripts and resume are C11H-74's.

**A2 — Ownership.** Every record has exactly one owning host: the agent's. Only that host's layer writes it. The app host keeps a merged *view* of every host's records and is the authority only for its own agents. A record never changes owner. A panel moved or restored onto another host is a new agent there (new records), and its old records stay readable on the old host. Because one host owns each record, two hosts never write the same one, so there is no merge conflict to resolve, only ordering (A7).

**A3 — Store per host.** On a remote host the layer lives in `~/.local/share/c11/agents/<session>/` (c11-only; never c11's state, never tenant config; created and removed by C11H-71's installer, as the relay folder is today). The app host's layer is c11's existing in-app stores, unchanged. A remote store holds:
- `log/<seq>.json`: one record per file, in order. `seq` is a per-host counter starting at 1, taken under an flock on `log/.seq`. Each file is written to a temp name, fsynced and renamed. Records are never edited; current state is the fold of the log. The log is also what that host holds for the app host while it is away (A6 `hold`).
- `mailboxes/<workspace-id>/…` in c11's envelope v1 layout (`_outbox`, `_processing`, `_rejected`, per-panel inboxes) for that host's panels.
- `state.json`: a checkpoint, the fold of every record up to `checkpoint_seq`. It holds each panel's current metadata, its raised flags and delegation, its lineage, and its ownership record (A5). It is written to a temp name, fsynced and renamed. Current state is `state.json` plus the records after `checkpoint_seq`.
- `transport/`: the `HostTransport` implementation's own state (its cursors, acknowledgements, held queue). Only the implementation reads or writes it; no consumer does.
- **Pruning.** A record may be deleted only when all three hold:
  - its `seq` is at or below the `checkpoint_seq` of a `state.json` that is already durable;
  - the app host has acknowledged it;
  - it is older than 7 days (the inbox retention default).

  Pruning never removes the only copy of current state: a flag raised 8 days ago and never lowered lives in `state.json`. A crash between the checkpoint and the prune leaves extra records, which replay over the checkpoint harmlessly, since every application is idempotent by `id` (A6). The app host's merged view is durable in the same way (A7), so it never needs a pruned record.
- **Bounds.** The limit is on the **whole encoded record**, not its `body` field:
  - a record's log file (`log/<seq>.json`: the complete record, UTF-8 JSON, every field and escape included) is at most 4096 bytes;
  - local admission (A5) encodes the record once, measures those exact bytes, and refuses anything larger with `layer_record_too_large` before it writes or answers success;
  - records never use `body_ref`. A store holds at most 64 MiB. A full store refuses new records with `layer_full`, never truncates, and shows it on the host chip.

**A4 — Records.** Each log record is `{"layer": 1, "id", "host", "seq", "ts", "panel", "workspace", "kind", "body"}`. `id` is a ULID assigned once, when the record is written, and never changes. A record crosses hosts as an envelope v1 with that `id`, the reserved address `to: "c11:layer"`, and as its body **the log file's bytes, unchanged**. Nothing re-encodes them, so a record that passed A3's 4096-byte check is exactly an envelope body within A6's bound. A resend dedupes like any envelope (A6). Its `topic`, if any, is opaque like any other (A6). `kind` is one of `metadata.set`, `metadata.clear`, `flag.raise`, `flag.lower`, `flag.delegate`, `flag.undelegate`, `journal.append`, `lineage.create`, `mail.sent`, `mail.read`. `body` carries exactly the params of the socket method that the same `c11` verb sends locally, so local and remote verbs share one validator. Unknown kinds are kept and skipped by an older reader. `layer` bumps only on a breaking change. A journal event names its own panel (the relay's rule). **State-setting records carry a per-panel sequence (Amendment 1).** These are:
- `metadata.set` and `metadata.clear`, covering rename, description, status, progress and custom keys;
- `flag.raise` and `flag.lower`;
- `flag.delegate` and `flag.undelegate`.

Each one carries `panel_seq`, taken from that panel's counter on its owning host (kept in `state.json`). It travels in the header `ext.c11h.state = {"panel", "key", "seq"}`.

**Header keys never collide.** They come from disjoint namespaces:
- `metadata.<raw key>` for every metadata key, built-in or custom, so a custom key literally named `delegate` is `metadata.delegate`;
- `flag` for raise and lower;
- `delegate` for delegate and undelegate.

**One record per key (repair of Amendment 1, sol).** The owning host's layer splits every metadata operation that touches several keys before it writes, and the transport never inspects a body to find them:
- a `set` with several keys, or a `merge`, becomes one `metadata.set` per key;
- a `replace` becomes a `metadata.set` per given key, plus a `metadata.clear` tombstone for each key it removes;
- a `clear` of several keys, or of all keys, becomes one `metadata.clear` tombstone per key that was set.

Each of these records gets its own `panel_seq` and its own `metadata.<key>` header. Local admission (A5) validates the whole operation first, then writes all its records in one batch under the log's flock, with consecutive `panel_seq`s. If any record fails, none is written, so the original operation stays all-or-nothing. An operator's multi-key edit is split the same way when the owning host records it. Only the owning host assigns `panel_seq`, so each panel has one sequence. An operator's edit on the app host gets its `panel_seq` when the owning host records it (A7), and until then the app shows it as *pending*. A lineage record may name a creator on another host, except that a box never becomes the parent of a Mac terminal (plan, After M1).

**A5 — Writes are local; admission.** `c11` in a c11 terminal on a remote host writes that host's store directly, never over the link (C11H-71). It works with the app host asleep and returns as soon as the record is renamed into `log/`. Before it writes, the CLI checks its caller: `C11_PANEL_ID` must equal the `c11.panel` label of the live terminal `HC_TERMINAL_ID` names on that host's own core, read through the local `hc get`. Otherwise it refuses with `layer_identity_refused`. **Ownership is durable.** When c11 creates or binds a remote panel, it records `{panel, host, owning core id, terminal address, since}` in the app host's merged store. It is kept for as long as any record of that panel is, including after the terminal exits or the panel closes. The remote host records the same binding in `state.json` with its first admitted write for that panel. When the app host merges a record (A7), it admits it only if the panel's ownership record names the sending host. Whether the terminal is still live does not matter, so an agent that flagged, mailed and exited overnight keeps its records on wake. A record whose panel has no ownership record, or one that names another host, is dropped, logged and reported as `refused(layer_wrong_host)`. **Trust stays same-user prototype** (Settled 9): any process of that user on that host can write the store. That is logged at link-up as the relay does today, and closed or signed off at milestone 3's trust gate. Verbs that need the app host's view (`tree`, `list-*`, `identify` beyond the caller's own panel, cross-host `mailbox.resolve`) go out with `send` (never `hold`) and fail fast within 2 s on `away` or `unreachable` (the relay's rule). Verbs the relay refuses today stay refused.

**A6 — `HostTransport`, the only way between hosts.** Every byte that crosses hosts, whether mail, layer records (A4) or transcript-index entries (C11H-74), is an envelope v1, and it travels only through `HostTransport`. The layer, the per-host log, away-merge (C11H-73) and the transcript index (C11H-74) call this interface and nothing else. None of them reads or writes relay documents, request slots, the spool or `transport/`. **The relay is the first implementation:** hc's per-core documents and `doc` events, as `docs/c11-relay.md` describes. **The bus is a later, second one** (C11H-72, Decided 14).

The interface has three operations:

1. **`send(envelope, to: host) -> SendResult`.** Deliver now. This is for calls that must fail fast instead of waiting, such as the A5 verbs that need the app host's view. It answers within 2 s.
2. **`receive(from: host) -> stream of envelopes`.** Envelopes arrive in the order that host sent them, **at least once**. After a reconnect, the transport redelivers unacknowledged envelopes in order, before anything newer. Once an acknowledgement for an `id` is recorded, the transport never delivers that `id` again (it remembers acknowledged ids for the 7-day retention). An envelope applied but not yet acknowledged can arrive again.

   Every consumer therefore **applies idempotently by `id`**:
   - The applied `id` is recorded in the same atomic write as the effect (the merged view's store, or the recipient's inbox file name, which is the `id`).
   - Then the consumer acknowledges.
   - A redelivered `id` that is already recorded is acknowledged again and changes nothing.

   So a crash between apply and acknowledge repeats a delivery, never an effect.

   **Stale state is dropped (Amendment 1).** Every implementation's `receive` keeps, for each `(panel, key)`, the highest `seq` it has delivered and that envelope's `id`. An envelope is acknowledged and never handed to the consumer when its `ext.c11h.state.seq` is lower than that, or equal to it under a different `id`. The same `id` redelivered before its acknowledgement still comes again (at least once). A late old write is therefore dropped, and so is a late raise that arrives after a lower. The consumer applies the same rule inside its atomic write, so a check that is missed or restarted still never lets an older write undo a newer one. Envelopes without `ext.c11h.state` (mail, journal events, lineage, transcript entries) stay at least once and deduped by `id`.
3. **`hold(envelope, for: host) -> HoldResult`.** Keep it for a host that is away, and deliver it on that host's return, in order, before anything sent after the return. The holding side is the sender's: the app host holds for a remote host, and a remote host holds for the app host in its own log (A3). Mail, layer records and operator actions are held. A send that must fail fast is not.

**Failure results.** Every operation returns one of these, and nothing else:

| Result | Meaning | What the caller does |
|---|---|---|
| `delivered` | The peer's transport accepted it; it will reach `receive` there. | Nothing more. |
| `held(since)` | The host is away; the envelope is kept and goes on return. `hold` only. | Show *queued* / *pending* (A9). |
| `away(since)` | The host is known to be down (its link is down); nothing was kept. `send` only. | Fail fast, or call `hold`. |
| `unreachable(reason, delivery)` | No answer within the deadline. `delivery` is `none` or `unknown`: **`none`** means the implementation cancelled the envelope at the deadline and guarantees it will never be applied (the relay does this with its compare-and-set claim/cancel race: exactly one side wins); **`unknown`** means it may still be applied later, once, because of the `id`. | `none`: report "nothing ran". `unknown`: report "delivery unknown; it may still apply, and a newer call wins", exit nonzero, and never automatically re-run an action under a new `id`. A resend or `hold` of the **same** `id` is safe. "Nothing ran" is reserved for `none` (Amendment 1). |
| `refused(code)` | Never deliverable: over a bound, invalid envelope, identity or policy (`relay_not_allowed`, `layer_identity_refused`), or a full hold queue (`transport_hold_full`). | Report it. Never retry it automatically. |

On the `receive` side, an incoming envelope that fails validation (of its headers and lengths only, never its body or topic) is quarantined to the receiver's `_rejected`, reported to the consumer as `refused(id, code)` and never applied. While its host is away, a `receive` stream is suspended and invents nothing.

**Opaque body and topic.** `HostTransport` treats an envelope's `body` and `topic` (its subject) as opaque bytes:
- **Routing, ordering, holding and dedupe** use only `to`, `from`, `id`, `reply_to` / `in_reply_to`, and the sending and receiving host.
- **One more header the transport reads (Amendment 1):** `ext.c11h.state`'s `panel`, `key` and `seq`, for the stale-state check below. It names a key and a number, never a value.
- **Other header fields** (`ts`, `urgent`, `ttl_seconds`, `content_type`, `ext`) pass through unchanged. The transport may add its own `ext.c11h` stamps.
- **The only check on `body` and `topic`** is their length, against the bounds below.
- **"In transit"** means inside any implementation: its documents, slots or messages, its hold queue, and `transport/`. Nothing in transit parses, indexes, logs or validates a body or topic, and the per-host layer, away-merge (C11H-73) and the transcript index (C11H-74) never read one there. A consumer reads a body only after `receive` has handed the envelope over on the recipient host.

**Consequences:**
- An envelope that crosses hosts must carry `to`. The relay refuses a topic-only envelope with `refused(topic_only_cross_host)`, because a publish without `to` could only be routed by reading its topic. Topic subscriptions (`mailbox.subscribe`) fan out on the publishing host only.
- Layer records and transcript-index entries are addressed to the reserved recipients `c11:layer` and `c11:transcripts`. The `c11:` prefix is refused as a panel's `mailbox.address`.

**Why.** The bus (milestone 3, with Atin) will seal cross-machine bodies and subjects so that only the sender's, the recipient's, the parent's and Atin's machines can read them, and the hosted copy cannot. Because the interface is opaque, sealing drops into the bus implementation with no change to this contract or to any consumer.

**Bounds** (every implementation):
- an envelope that crosses hosts is self-contained: its body is inline and at most 4096 bytes, measured on the body as the sender gave it;
- an implementation's own framing, encoding, stamps or sealing overhead is not counted. Every implementation must carry any envelope within that bound, so a record admitted under A3 is always deliverable;
- the whole original envelope, header and `ext` included, is at most 65,536 bytes, checked at original admission (Amendment 2);
- an envelope with `body_ref` is refused with `refused(body_ref_cross_host)`, because a file path on the sender's machine means nothing on the receiver's (the relay refuses it today). Moving large bodies between hosts is a later transport feature, not part of this contract;
- the app host holds at most 4096 envelopes or 16 MiB per host;
- a remote host's hold is its own log, bounded as in A3;
- going over a bound is `refused`, never a truncation.

**Stamps.** The implementation adds `ext.c11h.origin_host` and `ext.c11h.machine` to every envelope it carries (A8). The relay also adds `ext.c11h.relay: true`, and the bus does not. No implementation writes `ext.cbus` for c11.

**Proofs against the interface.** C11H-71 writes these once (T1–T9), as one conformance suite that takes any `HostTransport`. It runs against an in-memory reference implementation, against the relay with injected link faults (in tests and in a guest), and later against the bus with no change to the suite:

| # | What it proves |
|---|---|
| T1 | **Order:** 1,000 envelopes from one host arrive in send order. Two senders interleave freely, but each keeps its own order. |
| T2 | **At least once, applied once:** the link is dropped, and the consumer crashed, at every step of a send → apply → acknowledge cycle, including after the apply and before the acknowledgement. Each `id`'s durable effect is then counted exactly once. A redelivery happens only before its acknowledgement was recorded, and never after. |
| T3 | **Hold and return:** envelopes held while a host is away arrive on its return, in order, before any envelope sent after the return. A restart of either side while envelopes are held loses none. |
| T4 | **Away vs unreachable, and the late accept:**<ul><li>A host whose link is known down answers `away` within 2 s and is never delivered to later.</li><li>A silent peer answers `unreachable` at its deadline.</li><li>A peer that accepts just after the deadline: an implementation that answered `delivery: none` must not apply it there.</li><li>An implementation that answered `delivery: unknown` may apply it, exactly once. The caller showed "uncertain", and a resend of the same `id` applies nothing new.</li></ul>The relay implementation must answer `none`. The bus (C11H-72, SPEC 12.5) answers only `delivered`, `away(since)` or `unknown`. With T9, a late `unknown` may still run, but it never undoes a newer write. |
| T5 | **Refused:** each of these answers `refused` with its code, and none is ever delivered or retried:<ul><li>a 4 KiB + 1 body;</li><li>an original envelope of 65,537 bytes, padded in `ext` under a small body, while 65,536 bytes is delivered (Amendment 2);</li><li>a lowercase `id`, or a `from`, `to` or `reply_to` of 257 characters, while 256 is delivered (Amendment 2's header rules);</li><li>an envelope with `body_ref`;</li><li>an invalid envelope;</li><li>an identity failure;</li><li>a full hold queue.</li></ul> |
| T6 | **Stamps:** every carried envelope has `origin_host` and `machine`. `relay: true` appears only on the relay implementation, and `ext.cbus` never. |
| T7 | **Consumers see only the interface:** the layer's, away-merge's and the transcript index's own tests run against the in-memory implementation with no relay present, and they pass. This is a behavioral check, not a source scan. |
| T8 | **Opaque body and topic:**<ul><li>Two envelopes that agree on every routing field but differ in body and topic route, order, hold and dedupe identically. The same `id` with a different body is deduped as the same envelope.</li><li>Changing body or topic bytes in transit (fault injection inside the implementation) changes neither the destination nor the dedupe decision.</li><li>In sealed mode, the reference implementation and the relay carry bodies and topics encrypted with a key that only the two test endpoints hold. T1–T7 and the consumers' tests still pass, so no component in transit reads them.</li><li>A topic-only cross-host envelope answers `refused(topic_only_cross_host)`.</li></ul> |
| T9 | **Stale state is dropped (Amendment 1):**<ul><li>A write with `seq` 5 ends `unknown` and is accepted late, after `seq` 6 for the same panel and key was delivered. It is never handed to the consumer, and the value stays at `seq` 6.</li><li>A `flag.raise` with `seq` 7 delayed past a `flag.lower` with `seq` 8 is dropped, and the flag stays lowered.</li><li>**Mixed batch:** a clear of `title` and `description` (split into tombstones at `seq` 5 and 6) is delayed past a `title` set at `seq` 7. The stale `title` tombstone is dropped, and the `description` tombstone still applies. With the roles reversed the result is the same, each key on its own.</li><li>**No collision:** an `undelegate` (`delegate`, `seq` 7) delayed past a custom `metadata.set {delegate: "reviewer"}` (`metadata.delegate`, `seq` 8) still applies.</li><li>An equal `seq` under a different `id` is dropped. The same `id` redelivered before its acknowledgement is delivered again.</li><li>Other keys and other panels are unaffected.</li><li>Mail, which has no `ext.c11h.state`, is still delivered at least once and deduped by `id`.</li><li>Every implementation passes this: the relay with its check in milestone 2, and the bus.</li></ul> |

**A7 — Merge and order.** The app host merges each host's records from `receive(from: host)`. On a host's return, what that host held is delivered first, before any live request from it (the relay's spool rule, now T3). Within a host, order is the sending order, which is `seq` for layer records. **The merged view is durable:** for each host it stores the folded state, the ownership records (A5) and the applied ids in one atomic write per applied envelope, so a restart rebuilds nothing from the remote log. Across hosts nothing is ordered except for display, where `ts` is used and the host is shown. The sidebar, Feed and the menu bar extra read the merged view, so turns, status and flags from a night with the lid closed appear in `seq` order on wake (C11H-73). A flag raised while the app host was away stays raised until someone lowers it. An operator's action on a remote agent (lower a flag, edit its description) becomes a record for the owning host. It goes out with `hold` (so it waits while that host is away) and shows as *pending* until that host's log returns it through `receive`. The view never invents remote state.

**A8 — Mail.** Envelope v1 is the on-host format on every host, unchanged.
- **Stamps:** c11 writes only under `ext.c11h`, stamping `origin_host` and `machine` on every envelope that crosses hosts. While c11's link is the transport it also stamps `relay: true`, and the bus later drops that flag. `ext.cbus` is reserved for the bus and never written.
- **Addresses:** an address is the panel's `mailbox.address`, else `id:<uuid>`. It never carries a host, machine or session name; the host is shown as a badge. A `--to` with a host prefix is refused (`relay_host_prefix`).
- **Sender:** the sender stamp keeps `ext.c11_sender_panel_id`, and the origin host sits beside it.
- **Bodies:** mail to an agent on another host has an inline body of at most 4 KiB. `mailbox send` refuses `--body-ref`, or a larger body, for such a recipient with `body_ref_cross_host` before anything is written. Between two agents on the same host, `body_ref` works as it does in c11.
- **Mail between two agents on one remote host:** the sending `c11` writes the envelope, resolves recipients from that host's own metadata, copies it into their inboxes and runs their delivery modes there. The `stdin` mode goes through that host's hc (`terminal.send` when idle). This works overnight with the app host asleep, and a `mail.sent` record goes to `log/`.
- **Mail across hosts:** the sender's host writes it to `_outbox` and `log/`. The app host takes it from `receive` and forwards it with `hold` to the recipient's owning host, which dispatches it there. Mail to a host that is away answers `held` and shows as *queued*; nothing is dropped for being offline. Mail between two app-host agents is unchanged.

**A9 — An unreachable host.** Its agents keep working and keep writing locally. c11 shows:
- its panels' last merged state, with the host chip marked *away since <time>*;
- its flags still raised;
- operator actions and mail for it as *pending* / *queued* (they were answered `held`);
- a full store or a refused record on the chip.

c11 never ends, re-launches or "recovers" an agent because its host is away (plan Settled 7 and 10 still hold). On return, held envelopes in both directions are delivered before anything live (T3).

**A10 — Out of scope.** Claude login in remote panels (C11H-71 owns the fix, which must move no credential). The transcript index and resume (C11H-74). The bus core, its host runtime and receipts (C11H-72). Removing the relay (C11H-75). Authentication (milestone 3). Any change to c11.

| Owner | Clauses |
|---|---|
| C11H-71 | A3 store, checkpoint, pruning and bounds; A5 durable ownership; A4 record writer and validator; A5 local writes and admission; A6 the `HostTransport` interface, its relay implementation, the in-memory reference implementation, the T1–T9 suite and L1–L4; A8 on-host and cross-host mail; A9 chip states |
| C11H-73 | A7 merge from `receive`, order and pending view; the overnight proof. It calls `HostTransport` only. |
| C11H-74 | transcript records beside lineage (A1), sent with `hold` / `receive`; resume on the owning host. It calls `HostTransport` only. |
| C11H-72 / C11H-75 | the bus as a second `HostTransport` implementation, passing T1–T9 unchanged (sealing included), plus receipts; then the relay implementation and its spool retired |

**Layer proofs (C11H-71/73).** These run against the in-memory `HostTransport`; L4 also runs on the relay, and L3 and L4 run in the guest:

| # | What it proves |
|---|---|
| L1 | **Pruning keeps state:** a flag raised and metadata set 8 days ago (injected clock), never changed, survive a prune and a restart of both the remote layer and the app host. A crash injected between writing `state.json` and pruning loses nothing and applies nothing twice. |
| L2 | **Exited panels keep their history:** records from a panel whose remote terminal exited before the app host woke are admitted from its ownership record. The same records claiming a panel owned by another host are refused with `layer_wrong_host`. |
| L3 | **Large bodies:** a 5 KiB `mailbox send` to an agent on another host is refused with `body_ref_cross_host`, and nothing is written or held. The same body sent with `body_ref` to an agent on the same host is delivered. |
| L4 | **Every accepted record is deliverable:**<ul><li>A record whose encoded log file is exactly 4096 bytes is accepted, then delivered through the relay and the reference implementation, including sealed mode (T8). Its params are full of quotes, backslashes, control characters that encode as `\u00XX`, and multi-byte UTF-8.</li><li>The same record one byte longer is refused at write with `layer_record_too_large`, with nothing written and no success answered.</li><li>In a randomized batch of 1,000 admitted records of varied sizes, none is refused on drain.</li></ul> |

**Acceptance (layer, C11H-71/73).** With the app host asleep for an hour:
- two build-host agents mail each other, and each gets the other's mail through its delivery mode;
- A build-host agent raises a flag and sets its status.

On wake, every record appears once, in order: the flag waits in the sidebar and the menu bar extra, and Feed shows the turns. A forced link drop during the drain duplicates nothing (T2). An envelope that crossed hosts carries `ext.c11h.origin_host`, `machine` and `relay: true`, and no `ext.cbus` (T6). The relay implementation passes T1–T9, the consumers' own tests pass against the in-memory implementation (T7), and L1–L4 pass. One overnight agent exits before wake and its flag still waits (L2).

## Open points for the decider

1. **Store medium.** Proposed: files (A3), since hc's documents are a poor fit (no list call, 1 MiB each, an fsync under the typing lock, per core). The alternative is SQLite like c11's journal; files keep "any process can write" (envelope v1's filesystem contract).
2. **Operator edits to a remote agent** become records for the owning host (A7). The alternative is app-host-only overlays that never reach the host, which is simpler but means a remote agent never sees an operator's lowered flag.
3. **Retention** of confirmed records: 7 days (A3).
4. **The relay implementation's poll interval** when no `doc` event arrives: 30 s. This is an implementation detail behind `HostTransport`; the bus will have its own.

## Repair 1 (terra FAIL at dbed9959)

| # | Finding | Repair |
|---|---|---|
| 1 | Pruning removed the only source of current state | A3: a durable `state.json` checkpoint; a record is pruned only at or below a durable checkpoint, once acknowledged, and after 7 days. A7: the merged view is durable. Proof: L1. |
| 2 | A host-local `body_ref` cannot cross hosts | A3, A6 bounds and A8: cross-host envelopes and all layer records are self-contained (inline, at most 4 KiB). `body_ref` across hosts is `refused(body_ref_cross_host)` before anything is written. Proofs: T5, L3. |
| 3 | "Exactly once" contradicted redelivery before acknowledgement | A6 `receive`: delivery is at least once, and every consumer applies idempotently by `id` in the same atomic write as the effect. Proof: T2, rewritten to count each durable effect once, including a crash between apply and acknowledge. |
| 4 | Timeout semantics allowed a late action after a reported failure | A6: `unreachable(reason, delivery: none or unknown)`. `none` means cancelled at the deadline and never applied (the relay's compare-and-set race). `unknown` is reported as uncertain and is safe to resend only under the same `id`. Proof: T4 adds the late-accept case. |
| 5 | Merge admission by live inventory dropped an exited panel's history | A5: a durable ownership record (`panel`, host, core id, address) on both sides, kept after the terminal exits; admission reads it, and a wrong host is `refused(layer_wrong_host)`. Proof: L2. |

## Amendment (the Lead 16:03): opaque body and topic

`HostTransport` treats `body` and `topic` as opaque bytes. It routes, orders, holds and dedupes only on `to`, `from`, `id`, `reply_to` / `in_reply_to` and the hosts. Nothing in transit, and neither the layer, away-merge nor the transcript index, reads a body or topic there; a consumer reads a body only on the recipient host, after `receive` (A6, "Opaque body and topic"). As a result, cross-host envelopes carry `to`; topic-only cross-host envelopes are refused (`topic_only_cross_host`); and layer records and index entries go to the reserved recipients `c11:layer` and `c11:transcripts` instead of a topic (A4, A6). Proof: T8, including a sealed mode. The bus's sealing then drops in with no rework.

## Repair 2 (terra verification FAIL at 8650fb2e)

| # | Finding | Repair |
|---|---|---|
| 1 | A record with a 4 KiB `body` could be accepted, yet its whole encoded record was over the 4 KiB envelope cap, so it was refused on drain | A3: the bound is on the whole encoded record (its log file bytes, at most 4096), checked at local admission before success. A4: the log file's bytes are the envelope body, unchanged. A6: the bound is measured on the body as sent, and implementation overhead (framing, stamps, sealing) is not counted. Proof: L4 (an escaping-heavy record of exactly 4096 bytes is delivered, including sealed; 4097 is refused at write; a random batch of 1,000 is never refused on drain). |

## A6 Amendment 1 (the c11 M1 M2 Lead 17:58, after the Bus Lead's SPEC 12.5, constellation-bus a2b6664)

The bus becomes A6's second implementation, and it can answer only `delivered`, `away(since)` or `unknown` at 2 s. It has no `none`. So:

- **(a) Mail stays at least once,** deduped by envelope `id` (A6 `receive`).
- **(b) Every state-setting verb carries a per-panel sequence from its origin host, one record per key.** These are rename, description, metadata, status, progress, flag raise and lower, and delegation. The origin is the panel's owning host, which assigns `panel_seq`. The sequence travels as `ext.c11h.state = {panel, key, seq}`, with keys from disjoint namespaces: `metadata.<raw key>`, `flag` and `delegate`. Multi-key set, merge, replace, clear and clear-all are split by the owning host into one atomically written record per key, with tombstones for removed keys. The receiver applies it only if it is newer than the last one applied for that panel and key, so a late old write, or a late raise after a lower, is dropped (A4; A6 "Stale state is dropped").
- **(c) A call that ends `unknown`** tells the caller "delivery unknown; it may still apply, and a newer call wins". "Nothing ran" is reserved for `none` (A6 results).
- **(d) Repair 1's finding 4, restated:** `none` never runs later. `unknown` may run later, but it never undoes a newer write.
- **(e) Three operations:** `send`, `receive` with acknowledgement, and `hold` (A6).

The relay implements the sequence check in milestone 2, so both implementations pass the same proofs, T1–T9. T9 is the new row: a delayed old write that arrives after a newer one is dropped. The check is part of C11H-71 part A's conformance suite and its in-memory reference implementation.

### Amendment 1, repair 1 (sol FAIL at 19e84276)

| # | Finding | Repair |
|---|---|---|
| 1 | One header key could not cover a multi-key set, merge, replace, clear or clear-all | A4: the owning host splits each such operation into one record per key, each with its own `panel_seq` and header, plus tombstones for keys a replace or clear removes. They are written as one atomic batch, so the operation stays all-or-nothing, and the transport never reads a body. T9 adds the mixed stale/current batch, in both orders. |
| 2 | The `delegate` ordering key collided with a legal custom metadata key | A4: header keys come from disjoint namespaces, `metadata.<raw key>`, `flag` and `delegate`. T9 adds an undelegate delayed past a custom `metadata.delegate` set; the undelegate still applies. |
| n1 | T9 should name the equal-seq and same-id cases | T9: an equal `seq` under a different `id` is dropped, and the same `id` redelivered before its acknowledgement is delivered. |

## A6 Amendment 2 (the c11 M1 M2 Lead 23:56, after CBUS-19 finding 3)

A6 bounded only the body and the topic, so an envelope with a 70,000-byte `ext` was admitted. A6 now also bounds the whole envelope, at the bus's line bound:

- **The bound.** An envelope that crosses hosts is at most **65,536 bytes**, measured on the original envelope.
- **The one measure** (agreed with the bus, C11H-72). **The size of an envelope is the byte length of its body plus the byte length of its topic, each as the sender gave it and less any sealing overhead, plus the UTF-8 byte length of the RFC 8785 (JCS) serialization of the rest of its original envelope v1 object, with `body` set to `""`, `topic` left out, `version` counted as `1` when absent, every implementation-owned `ext.c11h` key (`origin_host`, `machine`, `relay`, `encoding`, `body_overhead`, `ts_added`) and a `ts` the bus adapter synthesized taken out, and then any empty `ext.c11h` or `ext`, whether the sender sent it empty or that removal emptied it, taken out; every number in those headers must be a safe integer (an integer literal from -(2^53-1) to 2^53-1), or the envelope is `refused(invalid_envelope)`.**
  - **JCS, as used here.** Compact, with no whitespace. Strings are raw UTF-8, escaping only `"`, `\` and U+0000–U+001F (`\b \t \n \f \r`, others `\u00xx`), and `/` is not escaped. Key order never changes the length, so the sender's spacing, key order and escaping choices never change the size. Object keys are compared as written: two keys that differ only by Unicode normalization (`é` and `e` + U+0301) are two keys, and both count.
  - **Numbers.** Only safe integers are allowed, and every implementation prints them as the same decimal digits that JCS gives. A fraction, an exponent, or an integer outside ±(2^53−1) would be printed differently by different implementations, so it is `refused(invalid_envelope)` at admission. The same limit applies to `ext.c11h.state`'s `seq`.
  - **The rest of the object.** `id`, `from`, `to`, `reply_to`, `in_reply_to`, `ts`, `urgent`, `ttl_seconds`, `content_type` and all of `ext`, including the sender's own `ext.c11h.state`. An empty `ext` or `ext.c11h` never counts, whether the sender sent it empty or a removal emptied it, so the number is the same before and after any hop. Any key an implementation adds later is implementation-owned too.
  - **Body and topic** are counted as bytes and never scanned or escaped (A6, opaque body and topic).
- **What is not counted.** Everything an implementation adds: the `ext.c11h` keys above, transport encoding (base64 is undone first), sealing overhead (nonce, tag) and framing (line endings, length prefixes, documents, slots).
- **Where it is enforced.** At original admission, the first time an envelope enters any transport, on `send` and `hold`, by every implementation: the relay, the in-memory reference implementation, the bus adapter and the bus daemon. No size is carried with the envelope or declared by a sender. Each side computes it from what it holds, and a later hop that re-checks, sealed or not, gets the same number, because everything a hop adds is excluded.
- **`passthrough`.** An implementation that carries the other headers as one value carries them as the JSON object of those v1 fields (`version`, `ts`, `urgent`, `ttl_seconds`, `content_type`, `ext`). Anything else, such as raw bytes, an array, a routing field or an unknown key, is `refused(invalid_envelope)`.
- **The refusal.** `refused(envelope_too_large)`, never a truncation. A refused envelope is never delivered, held or retried.
- **The bus's header rules, at the same admission** (Lead 00:39, CBUS-19 repair-1 check):
  - `id` is an UPPERCASE ULID: exactly 26 characters of Crockford base32 (`0-9A-HJKMNP-TV-Z`), envelope v1's own pattern. A lowercase id is invalid.
  - `from`, `to` and `reply_to` are each at most 256 characters, counted in Unicode code points, not bytes.
  - Breaking either rule is `refused(invalid_envelope)`, on `send` and `hold`, and the envelope is never delivered, held or retried. A missing `to` is still `topic_only_cross_host`.

The 4096-byte body bound and the 256-byte topic bound still apply on their own.

**Proof:**
- **T5, the size row.** Its fixtures are independently encoded envelope v1 JSON of exactly 65,536 and 65,537 bytes, padded inside `ext` under a small body. The first is delivered. The second is refused by `send` and `hold`, and nothing is delivered or retried after a late accept, a reconnect or a restart of either side.
- **T5, the numbers row.** An `ext` number of 9999999999999999999 or 1.5, under a near-bound pad, is refused `invalid_envelope` on `send` and `hold`; 9007199254740991 is delivered.
- **The bus's own examples.** `schema/hosttransport-examples-large.ndjson` from constellation-bus `944fc14` is vendored under `c11Tests/Fixtures/hosttransport/`. Each envelope in it, decoded as the receiving adapter would, gets the bus's outcome, refusal code and every byte count the bus states.
- **T5, the header row.** A lowercase `id`, or a 257-character `from`, `to` or `reply_to`, is refused on `send` and `hold`; 256 characters is delivered.

In code, `HostEnvelopeMeasure` is the measure and `HostEnvelope.originalBytes` its result.
