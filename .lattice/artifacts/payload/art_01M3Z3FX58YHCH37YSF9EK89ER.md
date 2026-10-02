# C11-261 g60-w2-v1 protocol (prepare, review, seal before collection)

This is a new strict W2 gate. No C11-259 acceptance or calibrated pixels carry over. This directory contains prepared code, not observations. The owner must publish the frozen protocol, script hashes, source/build identity and reviewed calibration specification before collecting one matched pair. Every attempt gets a new immutable directory. Do not reset a failed attempt, adjust thresholds, extend phases, pool phases, or retry a failed metric.

## Artifacts and conditions

Control is a clean tagged `c11-261` build of then-current main containing merged C11-259 and C11-301. Candidate is clean tagged `c11-261`. Both are built before reservation via the authorized remote-build route. Capture source/base/merge-base SHAs, clean-tree attestations, invocation/build options and GUI/dylib/CLI hashes with `seal.py`. It hashes the helpers and this protocol too. Build identity assertions are owner-supplied and independently reviewable; script sealing does not prove Git history or build execution.

Only an explicitly verified Atlas hostname, assigned socket, exact tagged PID/bundle/app path, verified display/window and active leases admit runtime work. No production socket discovery. Both builds use identical display ID/refresh/physical resolution, window dimensions 1320x880, sidebar width, font, theme, scale, input/capture method and ROI geometry. `calibration-spec.example.json` deliberately has unset geometry/content fields; the owner fills and reviews them before sealing. This is a required runtime configuration, not permission to tune after seeing percentiles.

Both frozen current-main and candidate contain folders. They receive identical group populations and mutations. Common scroll semantic labels are the registered top and fixed-offset endpoint. Record actual content separately per role, retain PNG/raw templates and the owner's direct visual-observation record; independent review remains pending. Both negative controls must differ from their target. Include only stable row/name pixels, excluding animated attention badges. A repaint or ACK never counts.

## Quiet window and UI safety

Binding round-1 quiet grant (2026-10-02): the Orchestrator, PID 14629 running
`/tmp/c11-quiet-hold.py`, owns both real slot FDs. `/tmp/c11-quiet-atlas.active`
was created at 15:40:58 Atlas time and expires after 30 minutes. Do NOT acquire
those locks in this run. `quiet_external.py` observes the actual holder's open
FDs, marker inode, deadline, continuous load/process/VM records and eventual FD
release; this overrides the owner-held reservation mechanism described below.
All runtime helpers use the existing `/tmp/c11-259-tools/bin/python` (Python
3.14.5 with PyObjC). Atlas's default Xcode Python 3.9 has process-relative
monotonic clocks and is inadmissible for cross-process leases. Observer-only
attempt-002 was stopped before readiness/UI/samples after observing that clock
mismatch; it is retained. Attempt-003 uses the single global-clock interpreter.
The 18 numeric budgets and load <8 condition are unchanged. Every raw probe
also records its contemporaneous load. Running Tart VMs remain disclosed.
The owner will request early reservation release after both exact-PID UI roles
are dismissed; the observer does not signal the holder or unlink its marker.
Initial observer bootstrap attempt-001 rejected the macOS `/tmp` versus
`/private/tmp` spelling before any UI or sample. That failed bootstrap is
retained; attempt-002 uses the observed canonical slot paths. This is not a
performance retry. Preparation seals 001-004 were unused; seal 005 is binding.

Coordinate non-build work through the Orchestrator. `quiet_window.py hold` uses a separate guardian that alone owns the real slot-1 then slot-2 flock descriptors. It never deletes lock files. Slow process snapshots are taken by its supervisor and cannot delay the guardian. First successful flock starts a 2700-second cap; waiting for slot 2/quiet consumes it. Guardian checks every 100 ms, begins closing before the deadline, closes FDs before writing release evidence, and also closes on supervisor EOF, interrupt, error, atomic release request or contamination. The pre-first-lock wait is bounded too.

Guardian records load at 1 Hz continuously across both roles and the interval. Supervisor captures host process CPU/RSS every 10 seconds with a bounded subprocess. No role starts unless 1-minute load <8. Once quiet readiness is declared, any load >=8 stops/revokes the attempt and retains the raw sample. Classify from process/host evidence: unrelated work or uncertain attribution is INCOMPLETE; product-attributable sustained load is a regression to diagnose. No automated resampling. Budget failures also remain failures.

`ui_slot.py take` now reserves the shared UI lock before launch. It verifies the assigned stopped app's exact sealed bundle/executable hashes and rejects an existing tagged process/socket. It creates a permanent once-role claim, then starts a detached supervisor. The supervisor forks the exact bundle executable behind a **closed launch pipe**, records its PID, and publishes readiness before the parent can send launch permission. The supervisor owns/reaps that child for its entire lifetime, so PID reuse cannot redirect cleanup; no kqueue/ps/bootstrap AppKit call sits in the deadline path. The 1200-second cap starts at reservation, including bootstrap and launch. Both roles exec with identical QA-fresh/automation/tagged-socket/log environment isolation, recorded in the lease. This replaces unbounded prelaunch via LaunchServices.

Initial state reads, fork, readiness writes and all later checks are inside supervised cleanup. Before launch permission, parent failure closes the gate without executing an app. Between launch and acknowledged handoff, parent EOF/exception requests cleanup. Later, the independent supervisor enforces its cap and pair revocation. Cleanup kills only its unreaped owned child; no PID rediscovery. File/write/Popen/readiness errors roll back only inode-and-token-owned reservations after cleanup is proven. Preserve partial role evidence by archiving it; the permanent role claim forbids a retry in the same attempt. A foreign lock is never deleted. If exact-child cleanup is unproven, leave the reservation occupied and fail closed. A forced dismissal is failed evidence, never synthesized-dismissal proof.

Normal release requires saved, reviewed synthesized Command-Q/dialog evidence for the exact child PID and the supervisor's successful reap. Release removes only the owned UI lock. Candidate reservation requires control's successful normal dismissal. No `open`, old shell-wrapper launch, prelaunched PID adoption, or app launch outside this reservation belongs in the measurement runbook.

The four appearance settings are **observations**, not spec values. Before template capture, require an externally reviewed record of actual theme, font, scale and sidebar width, tied to the immutable `setup-config.json` SHA, `setup.png` SHA, exact PID/window/display/artifact identity and observation evidence references. Calibrate compares observations to the sealed specification before populating measurement config. Run admission and comparison revalidate that same evidence. Intended baseline geometry (200-point sidebar, display 9 at 1920x1080, window 1320x880) alone is insufficient.

## Fixture and prime gate

Both roles use the same six groups, metadata, member order and pins. Exactly 60 workspaces, one tab each: 56 terminals, browsers w04/w33, markdown w05/w34. Pinned workspaces: w01,w02,w29,w30,w31,w32. Canonical initial order is these six pins followed by remaining labels numerically.

Folders: Pinned Fleet w01-w08 (pinned); Collapsed Flag w09-w14 (collapsed); Empty Pinned (pinned); Empty Collapsed (collapsed); Tail w15-w24; Move Lane w25-w28. Other workspaces remain ungrouped. Initial flags: w10 plain terminal flagged and suppressed. Exact unread tab notifications on w11 and w45 create real waiting; they are also declared synthetic codex tabs, without starting an agent. These are synthetic attention signals, not claims about agent work. Notification identities/read states must remain unchanged through measurement.

Before calibration, dismiss only the app-owned optional notification setup sheet with its exact "Not Now" action if present, recording its presence and action. This does not alter OS notification preferences. Set each owned shell's prompt to `$ ` and clear its prior screen before evidence capture; no shell configuration files are changed.

Normalize only the owned welcome workspace's extra tabs before capturing IDs. Create all 59 additional workspaces with focus=false, then observe every backgroundPrime start/finish and final selected-only ws.mount.reconcile before selecting another workspace. Reject a stalled/incomplete queue or missing queue entries, and enforce creation mounts <=2. Record every finish reason/duration, including C11-301's normal bounded per-workspace timeout fallback (browser/markdown members may have no terminal). A recorded bounded fallback is accepted only once the full queue finishes and mounts settle; it is never hidden by arbitrary sleep. Terminal readiness/identities are independently checked by PID capture and visible probe markers. This fallback interpretation requires the owner's explicit preregistration clarification. Retain this raw creation log. The subsequent gate rereads the whole recorded log, permits live handoff <=3, requires selected always mounted and final single selected w01. Debug mount retention must be disabled. Only after observed settlement/calibration does the fixed matched 60-second idle warmup begin. No arbitrary sleep substitutes for a missing prime event.

Save initial workspace/tab UUIDs, tab types, six group records, pins, membership, attention/notification records, window ID and all 56 shell PID/start identities. Shell probe commands preserve their parent shells. w01/w02 present G60-PROBE-ONE/TWO and raw a/b glyphs in a fixed cell. The same terminal script is used in both roles.

## Primary measurements and deterministic mutations

Three fixed 60-second phases: no-churn, churn, quiescence. Each schedules 105 typing, 42 switch, 42 real HID sidebar scroll probes in the first 58 seconds: repeat [typing x5, switch x2, scroll x2] 21 times at index*58/189. Trial timeout is one second, with capture-end minus posted-input time and no overhead subtraction. Retain every failed/precondition/timeout/setup-exception row, setup/capture overhead, all monotonic timestamps, templates and crop evidence. No implicit stop/recalibration after three failed probes. Minimum valid counts per metric per phase: 100/40/40.

Churn schedules exactly 600 mutation RPCs at start+n/10 (n=0...599), one in flight, and joins by the 60-second boundary. Repeat categories reorder, transfer, flag, waiting_suppression. Exactly 150 per category. Reorders alternate w25/w26 across w60 using absolute final indices. Transfers alternate w27/w28 between Move Lane and ungrouped, appending in the matching pin segment. Flags alternate w10/w46 and toggle flag state: 75 raises, 75 lowers. Waiting updates alternate w11/w45 and toggle suppression over the fixed exact unread notifications: 76 suppressions and 74 unsuppressions. This exercises collapsed and offscreen members while keeping w01/w02 and the first 24 unpinned workspace identities in place.

Per-operation records include intended time, start/end, method/category/params, response/errors, independent expected canonical order/membership/attention, and selected workspace before/after. The worker's non-focus selection observations and the real UI switch trial are serialized by one in-process lock, so an explicit switch cannot masquerade as focus theft. Both roles use this same synchronization and the same additional read queries; they are part of the declared workload. Each successful visible switch also queries and records its actual selected ID. Read RPC overhead is retained and may make a rate shortfall visible; never silently reduce checks or extend the phase.

At phase boundaries verify exact complete unique workspace/tab identities, pin bits, membership, canonical order, attention, notification state, shell identities, selection, group metadata/order and derived member counts. Retain raw trees and resource snapshots (CPU/RSS/VSZ/footprint, including footprint/IOSurface output). The worker must be joined with no pending work before quiescence. Capture existing tagged hang telemetry and any available header recomputation observations separately; do not invent missing instruments.

## Acceptance and separate functional evidence

Nearest-rank percentiles from valid raw samples, per metric/per phase. All 18 must pass: candidate p95 <= max(control*1.20, control+5ms), candidate p99 <= max(control*1.25, control+15ms). At 42 samples p99 is the maximum. Keep prior failed trials even when valid minima pass. Malformed/missing evidence or count/rate/phase overrun is INCOMPLETE. Late starts are reported, not a new per-operation budget.

`compare.py` checks raw samples/PNGs/templates, phase schedule, frozen mutation replay and matched semantic fixture, attention/identity assertions, required source/artifact/harness provenance, observed prime logs, matched warmup, continuous quiet load and normal bounded UI dismissal. Its PASS covers this primary performance evidence only. Real pointer drag bursts, menu/focus/mount scenarios, screenshots, keyboard/accessibility and all ticket UI acceptance remain separate required evidence. Run `pointer_burst.py` once per role only after all three primary phases complete, under the same exact tagged PID, window/display and active perf role/quiet/build leases. The burst has a 90-second timer and permanent per-role claim; no automatic retry, launch, quit, activation or global keys. Snapshot first, collapse all six groups through non-focus RPC while checking selection, then send one guarded real sidebar scroll to top. Resolve w29/w30 by their unique combined AX row names (`g60-wNN, workspace N of 60`) joined to manifest UUIDs because these rows expose no UUID AXIdentifier; retain native identifiers and geometry. Drag pinned ungrouped w29 below w30, then above it, using actual visible row geometry and checking exact order change plus restored order. Candidate additionally drags w29 into the UUID-identified Empty Pinned header body, snapshots the new membership, expands that group through recorded non-focus RPC to expose the member, then drags w29 to the `WorkspaceGroupNew` root drop lane (visibly Move to Ungrouped during drag). Missing/ambiguous/offscreen targets fail rather than guessing. Every mouse point requires exact frontmost PID/window/display and actual AX hit ownership; interrupted drag mouse-up cleanup is PID-directed. Each stage records full model/shell identity snapshots, cropped sidebar PNGs, AX metadata and raw monotonic action/capture times. All 60 workspace/tab identities, pins, 56 shell PID/start identities, group properties/projections, attention and notifications remain checked; only declared collapse/expand, reorder and membership changes are allowed. Collapse preserves selection on both roles; candidate structural drags preserve selection, while control drag selection is recorded without imposing candidate behavior. The primary stable prefix restriction ends for this post-phase burst only. Candidate-only folder drags are functional evidence with no control percentile. This helper does not prove the remaining menu/focus/mount or ticket UI scenarios.

Release both build-slot FDs immediately when the matched pair, post-phase drag capture and dismissal finish, or immediately on failure. Verify guardian release evidence; never delete a lock as cleanup. Attach every attempt, even incomplete/failed, all raw samples/PNG/templates, operation logs, priming/mount logs, source/artifact/protocol hashes, load/process series, dismissal records and comparison output.

Font provenance: native default with no font-family/font-size overrides, observed from loaded configuration files and common pinned engine SHA. Do not claim an exposed resolved family name. Verify matching glyph/marker pixels across roles and retain context. Theme stage11/Dark, NSScreen backing scale 2 verified before collection (logical 1920x1080, physical 3840x2160), sidebar 200 points. Nominal-resolution captures remain one pixel per logical point. No tag-specific font file is introduced.

Round-1 adaptation before samples: one build tag c11-261 for both roles. Control and candidate bundles are retained in separate explicit role paths; they launch sequentially under the same bundle ID/socket. C11_PERF_ROLE selects the role lease explicitly. Current-main control SHA and candidate SHA, invocations and artifact hashes are sealed before collection. Normal bounded C11-301 prime timeouts are accepted only after the entire queue has completed and mounted bodies settle. The separate pointer burst is deferred to C3; it is not one of the 18 measured budgets. No old measurements or approvals carry into this run. Capture/setup noise, RSS/footprint and existing hang telemetry are reported alongside the pair.
# Binding Orchestrator interleaving ruling (2026-10-02 19:50 UTC)

This amendment overrides the earlier sequential load-below-8 protocol. The
Orchestrator explicitly authorized fresh admission after native signoff exited,
using the SAME already-built candidate a2e448b74 and control dedc6007a, admitting
at 1-minute load below 15. Foreign VMs remain running. No previous attempt
collected a latency sample. Seal 013 binds this adaptation before new collection.
Attempt009 had complete creation-queue settlement with NO fallback timeouts,
max2 during priming, and final selected-only mount. The historical whole-log gate
rejected six empty mount transitions on each role during rapid setup selection,
before any metric sample. It terminated both apps. Seal013 records these empty
transitions while still rejecting nonempty selected-body mismatch or >3 mounts,
and still requires final selected-only mount plus complete start/finish queues.
No empty transition at the final readiness endpoint can pass. Attempt009 and all
provisional calibration evidence are retained. The artifact pair is unchanged.
Owner calibration inspection rejected the provisional scroll-down crop: it was
blank gradient, not the registered stable text. Before ANY metric sample, the
shared scroll crop moves to [32,140,112,18], showing g60-w01 at top and g60-w03
after the fixed 300-pixel downward input. Both provisional templates/configs
are retained. This is premeasurement calibration failure, not metric resampling.
Seal 010 corrected a premeasurement upload/seal race; all helpers verified before
launch. The Orchestrator granted a final 10-minute extension via successor holder
PID 37420 taking both slots from 14629 at 16:11 Atlas time. Observer records any
gap, verifies successor FDs/new marker, and accepts only that named handover.
No helper acquires slots. Final cap is 16:21; UI lease still hard-caps at 20 min.
The ruling's below-15 criterion applies to admission. Later load is recorded,
not silently dropped or resampled; background equality is assessed from A/B
per-pair loads/deltas/noise. A threshold excursion does not erase a sample.
Attempt 006 never launched because attempt 005 forced cleanup left unbound Unix
socket dentries. Exact no-process/no-FD checks authorize removing only those
two owned stale sockets before a fresh bootstrap. No latency samples existed.
Seal 007 bootstrap verified role sockets, then provisioning stopped before any
workspace creation because Bonsplit reads CMUX_DEBUG_LOG (literal upstream env),
not C11_DEBUG_LOG. Seal 008 supplies BOTH identically for each role. This is an
evidence-path correction; attempts 004/005 remain failed premeasurement setup.
Seal 006 bootstrap observed the shipped tagged socket override guard: without
the explicit C11_ALLOW_SOCKET_OVERRIDE=1 option, separate role sockets were not
bound. Both exact children were terminated and no fixture or latency sample ran.
Seal 007 records that existing supported launch option equally for both roles,
and waits for both actual role sockets before admitting setup. Attempt 004 is
retained as failed bootstrap, not excluded latency data.

One owned display lease supervises both exact retained tagged executables with
distinct role-specific runtime sockets/logs, NOT distinct build tags. Activation
is targeted by exact PID/path/window on verified display 9. Samples are strictly
control A, candidate B, A, B with equal counts, never simultaneous input. Each
sample records actual uptime/load BEFORE and AFTER outside the latency interval.
Continuous load and tart VM/process snapshots remain recorded. Both native apps
remain alive to permit immediate per-sample alternation; paired overhead is
disclosed, not subtracted. Hard UI cap remains 20 minutes.

Each role gets observed priming settlement, six owner-visually-reviewed distinct
templates, identical appearance and 60-second common warmup. Interleaved phases
are fixed 180 seconds each (not the superseded 60-second sequential phases),
105 typing, 42 switch, 42 scroll trials PER ROLE per phase, scheduled as 189 A/B
pairs over 178 seconds. Churn runs 1,800 operations at 10 Hz PER ROLE throughout
the 180-second churn phase, 450 each reorder/transfer/flag/suppression; exact
response/model/PID checks remain. This is the explicit interleaving adaptation,
not a claim to have executed the superseded g60-w2-v1 protocol unchanged.

All original 18 p95/p99 numeric limits remain. Report nearest-rank raw percentiles,
each A/B delta, paired delta distribution, pre-capture/setup/capture noise,
invalids, load, VMs, memory/hang availability. Any invalid observation remains;
no retry or changed ROI after a metric sample. Publish INCOMPLETE if collection
or minimum valid counts fail. QUIET DONE is sent immediately after capture;
analysis/writing does not retain slots. Extra time needs explicit QUIET EXTEND
(maximum 15 minutes). This ruling changes method, not the two frozen artifacts.
