# hc transport and inventory (part 2B)

`HCLiveConnectionFactory` implements the frozen `HCConnectionFactory` interface.
Its required `HCServingBuildVerifier` runs after hello, status, and kernel peer
checks and before `connect` returns, under the same monotonic two-second budget.
Read-only RPC and inventory-refresh deadlines return pending without declaring
the peer dead or closing existing attachments. DATA has no elapsed-latency timeout;
actual EOF/socket failure, protocol/bounds invalidation, or ambiguous run/restart
expiry closes the connection. The returned connection retains `HCVerifiedPeer`; an attested foreign build may
only answer status or receive the planned server restart. Terminal operations
require `isPinnedBuild`. Launch, recovery and lifecycle policy remain in 2A.

`registerChannel(_:attachmentGeneration:sink:)` returns a dormant bounded channel.
After native input is bound, `HCChannel.activate()` begins delivery and waits
for buffered early output consumption. Failed activation closes and retires the
channel; inventory explicitly activates its channel before reporting readiness.

`HCLiveInventorySource` installs one unfiltered snapshot before consuming early
channel events. Its externally readable snapshot remains pending through that
drain. UI observers get their initial state followed by coalesced consistent
snapshots; admission reads the reducer without waiting for a UI tick. Missing
or invalid events revoke readiness and resubscribe. If refresh times out or fails
without losing the connection, one retry is scheduled with 0.5 s, 1 s, then
2 s capped backoff. A consistent subscription resets the backoff; invalidation
or a connection/identity failure stops retries. No external refresh is needed
after a transient stall. The live-session factory
provides components for 2C's composition; it does not activate panels.

The wire writer owns the only input reservation budget. A batch contains
ordered frames; `submitReturnAfter(Data, delayNanoseconds: UInt64)` holds its
DATA position and reservation during paste settle, while independent controls
can drain. `cancel(reservation)` also applies after transmission starts: it
removes the remaining frames and Return, and returns the actual byte receipt.
`HCWriteBatch.init(operationID:attachmentGeneration:frames:beforeReturn:)` adds
an optional `@Sendable () async -> Bool` predicate (default nil). The writer
runs this pure target/composer check after paste settle and before each Return,
retaining the same reservation. Controls may pass; other DATA cannot interleave.
False discards all remaining frames and returns the actual body receipt.
Cancel or connection retirement resolves the write without waiting for a
suspended predicate. A late predicate result cannot revive the retired batch.
The predicate may finish independently; it must not perform side effects.

Cancellation within a partially written frame closes the connection, because
another frame cannot safely follow its truncated header or payload. A Return
already written is reported as written and cannot be recalled.

## Debug fault injection

The one configuration variable is `C11_HC_FAULTS`, containing JSON. Debug app
composition calls `try HCLiveConnectionFactory(environment: environment)`;
Release has neither this initializer nor the fault type. Invalid fields or
values fail explicitly. With the variable absent or empty, the factory has no
faults. Pass the required 2A verifier to `connect(request, verify: verifier)`.

```json
{
  "hello_trickle_ms": 500,
  "drop_events_ms": 10000,
  "delay_ms": {"terminal.list": 8000},
  "fail": {"terminal.attach": {"kind": "not_found", "count": 1}},
  "drop_reply": {"terminal.run": 1},
  "sever_after_bytes": 4096,
  "sever_after_ms": 1000,
  "throttle_bps": 1024
}
```

Every key is optional. Select the relevant fault for a proof; the example shows
the syntax of all controls, not a recommended combined scenario.

- `hello_trickle_ms`: delay each byte of the real core's hello. The same total
  two-second deadline still applies, including verification.
- `drop_events_ms`: consume/drop event channel DATA for this many milliseconds
  from the first event subscription. Credit is returned for deliberately dropped
  bytes so the next real sequence exposes the gap. Snapshot replies are intact.
- `delay_ms`: delay each named method's reply, with a bounded retained buffer;
  the client RPC deadline continues to run. Other channels remain independent.
- `fail`: reject the next `count` calls of each method before transmission with
  the supplied error kind (`count` defaults to one). This does not execute the
  failed method on the real core.
- `drop_reply`: discard the next N replies to a method after that method really
  executes. Its normal deadline reports ambiguity; an ambiguous run/restart
  closes its transmitting connection. Read-only timeouts retain other attachments.
- `sever_after_bytes`: disconnect at N total socket bytes sent plus received,
  counted from connection establishment, including hello and framing.
- `sever_after_ms`: disconnect this many milliseconds after connection.
- `throttle_bps`: cap client-to-core socket write bandwidth. Reads stay normal;
  DATA saturation can exercise the independent control lane. It includes hello,
  so select a rate that permits the intended setup within its deadline.

Counts and timers reset per connection. Durations range from zero through
600000 ms; other counts are nonnegative and at most 1000000000, with throttle
strictly positive. Method maps are bounded to 256 entries. No terminal text or
credentials belong in this configuration or diagnostics.

These faults operate on the real owned socket. They never replace its kernel
peer, redirect the launch or holder tuple, bypass serving-build verification,
autostart a core, or signal a process. The proof kit's external Unix proxy must
not be inserted between this connection and hc: that would replace the kernel
peer and correctly fail L2. 2C owns the Debug app/guest-helper wiring for this
factory; the proof owner maps its scenarios to the JSON above.

Full-app proof rows T2.14, T2.19 and T2.22 remain pending until the assembled
2C runtime is available and a bounded guest lease is approved. Component tests alone do not
satisfy those rows.

## Diagnostic delivery

Composition supplies `diagnostics: @escaping HCTransportReport` to either
`HCLiveConnectionFactory(faults:diagnostics:)`,
`try HCLiveConnectionFactory(environment:diagnostics:)` (Debug), or
`HCLiveConnectionFactory(diagnostics:)` (Release). Inventory accepts the same
`diagnostics:` argument in addition to its existing reason-only `report:`.
`HCTransportReport` is `@Sendable (String, UInt64, UInt64?) -> Void`: fixed
event token, connection generation, optional elapsed nanoseconds. The default
is a no-op. The callback receives no bytes, method arguments, environment values,
paths, credentials or terminal contents. Recording belongs to observability.

Delivery is serial on an independent utility queue, with at most 64 pending
facts per reporter; overflow discards the oldest pending diagnostic. Canonical
socket, inventory, admission and lifecycle state never waits for a recorder.
Tokens are `hc_hello_start`, `hc_hello_complete`, `hc_hello_deadline`,
`hc_hello_failed`; `hc_inventory_resnapshot_start`,
`hc_inventory_resnapshot_complete`, `hc_inventory_gap`, `hc_inventory_missed`,
`hc_inventory_malformed`, `hc_inventory_timeout`. Hello completion/deadline/failure
carries elapsed time from handshake start; use that duration for proof even if
recording is delayed.

Actual Debug fault activation emits `hc_wire_fault_` plus `hello_trickle`,
`drop_events`, `delay_reply`, `fail_method`, `drop_reply`, `sever_bytes`,
`sever_timer`, or `throttle`, once per fault kind per connection. Configuring a
fault does not claim it fired. The proof kit converts its flags to
`C11_HC_FAULTS` JSON and observes these tokens through composition's recorder.
