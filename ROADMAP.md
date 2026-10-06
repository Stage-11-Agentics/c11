# c11 Roadmap

Directions we care about. Operational details live in `CLAUDE.md`; the worldview underneath lives in `PHILOSOPHY.md`; this file is where the forward-looking work collects.

This is a minimal placeholder, kept honest on purpose: it names directions, not commitments. Dates and priorities live in the active cycle contracts under `docs/cycles/` and in Lattice, not here.

## Directions

- **Remote and cloud fleets.** Today fleets are one-Mac-only. The interesting frontier is agents running across machines and in the cloud, still composed into one legible workspace.
- **Sharper telemetry truth.** The sidebar should never lie about what an agent is doing — liveness derived from what c11 already observes, decaying gracefully when an agent goes silent.
- **Deeper agent-native primitives.** More of the workspace addressable and scriptable from outside the process, so agents compose their own environment without the operator in the loop for routine moves.
- **A Linux companion.** Mac stays the flagship; a thinner GTK4 shell could speak the same socket protocol, with Ghostty's GTK embed for terminals and WebKitGTK for browser and markdown panels.
- **An open agent-to-agent message format.** The framed message block c11's mailbox delivers is model-native, transport-agnostic and injection-defended; documented as a provider-neutral wire format, other tools could speak it too.

Have a direction to add? Open a discussion or a Lattice ticket rather than expanding this file into a manifesto.
