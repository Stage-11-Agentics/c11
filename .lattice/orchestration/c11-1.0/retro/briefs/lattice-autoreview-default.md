# Second Lattice PR: auto-review off by default, kept as opt-in

Atin decided (2026-10-05): the orchestrator triggers reviews and Lattice records them. Do this only after your first PR (review lifecycle) has merged, as its own PR and LAT ticket, same rules as your first brief, branched from `origin/v2` with PR base `v2`.

- New boards start with auto-review off. A board can still turn it on in config (solo use, no orchestrator, where Lattice firing a reviewer is the only review).
- Existing boards keep whatever they have set explicitly. A board that only inherited the old default: say in the PR what happens to it and why; prefer leaving its behavior unchanged and printing a one-line notice from `lattice doctor` (or the nearest existing check) recommending the new default.
- The Lattice skill and docs say, timelessly: reviews are triggered by whoever orchestrates the work; Lattice records verdicts and evidence and shows them; auto-review is an opt-in for unorchestrated use.
- Tests go red on main and green on your branch. Hand off to Cairn the same way as before.
