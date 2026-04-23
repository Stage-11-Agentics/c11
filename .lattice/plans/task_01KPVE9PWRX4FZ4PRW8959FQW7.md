# C11-11: Linux companion app (GTK4, agent-driven feature parity)

**Status: DO NOT START.** Filed for future consideration only.

## Shape (if revived)

Thinner Linux companion app with agent-driven feature parity. Mac stays the flagship; Linux is a second shell speaking the same socket protocol.

- **Shell:** GTK4. Ghostty already ships a GTK4 embed on Linux — the terminal surface comes essentially for free. WebKitGTK covers the browser and markdown surfaces.
- **Socket + CLI:** same protocol, same `c11` CLI, same command names. Agents call `c11 split` identically on either OS.
- **Operator profile:** Linux user running c11 on their own desktop (needs UI). Remote-viewer-of-Mac-host is a different discussion and explicitly out of scope for this ticket.

## What ports cleanly
- Ghostty terminal surfaces (GTK4 embed already exists)
- The `c11` CLI (thin socket client)
- The skill, the surface model, addressable handles, agent telemetry
- Markdown + browser surfaces via WebKitGTK

## What gets flattened or cut in v1
- Bonsplit-derived tab chrome → GTK equivalent
- Custom UTType drag-and-drop → GTK D&D model
- Menu bar extra → cut or GTK approximation
- AppKit portal trick for terminal find overlay → cut, replace with SwiftUI-free layering

## Load-bearing prerequisite (the actual reason this is locked)

Socket command handlers currently live inside the Mac app (Swift + AppKit). For a Linux companion not to become a maintenance nightmare, those handlers must first be extracted into a platform-agnostic layer — pure-Swift-on-Linux or a Rust core both shells link against. Otherwise every new command gets implemented twice and drifts.

**That extraction is a significant Mac-side refactor** that would churn the Mac codebase while it lands. Mac is currently stable and shipping; the cost/benefit doesn't pencil out until there's real Linux demand.

## Do not start without

1. Real Linux operator demand from someone running agent fleets.
2. Explicit willingness to pay the Mac-side refactor cost first.
3. Explicit reversal of the do-not-start flag by the operator.

## Context
Scoped in conversation on 2026-04-22. Option B (thinner Linux companion) chosen over (A) cross-platform rewrite or (C) don't port. Filed immediately as do-not-start to preserve the thinking without committing engineering.
