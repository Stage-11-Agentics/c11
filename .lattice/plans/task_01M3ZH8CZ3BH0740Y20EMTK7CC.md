# C11-327: Logic tests intermittently crash initializing GhosttyApp with nil NSApp

## Why
The Merge Captain's full c11LogicTests run ee9552415cdb43ae8ebce855db07e197 (trial merge f2015ad3, C11-323 + main) crashed 29 test processes at `GhosttyTerminalView.swift:1322`, "Unexpectedly found nil while implicitly unwrapping" (`NSApp.isActive` in `GhosttyApp` init; `NSApp` is nil in the hostless logic bundle). The identical tree then passed clean twice (67442703: 2,469 tests, 0 failures, 0 restarts), and main passed too. So logic tests can intermittently reach `GhosttyApp` initialization, an order- or timing-dependent path, and crash the runner. Crashing classes included TabLivenessDeriverTests, WorkspaceDerivedActivityTests, TabOrdinalDisplayTests and StdinHandlerFormattingTests.

## Scope
Find which logic-test code paths can initialize `GhosttyApp` (a shared singleton touched lazily under some ordering) and make that initialization impossible or nil-safe in the hostless bundle, without changing app behavior. Prove with repeated full-suite runs (e.g. 5 in a row, randomized order if supported) with zero restarts.
