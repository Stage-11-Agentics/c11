# C11-241: c11: CLI for New Workspace recents and pins (list, pin, unpin, remove, open by fuzzy name)

Follow-up to C11-240; start after it merges (it owns the recents and pins model).

Make the recents and pins agent-drivable over the socket and CLI, using the same model and fuzzy ranking as the sheet:
- c11 workspace recents list [--json] [--pinned]: path, lastOpenedAt, openCount, pinned, pin index, open-in-c11 and exists flags.
- c11 workspace recents pin|unpin|remove <path>; pin --at <n> sets the pin order.
- c11 workspace new --dir <path-or-fuzzy-query> [--layout <blueprint id>] [--name <n>]: resolves a fuzzy query with the sheet's ranking (fails loudly and lists candidates when the top two tie), records the open in recents like the sheet does.
- An open sheet updates live when an agent changes pins.
Document it in skills/c11/references/api.md. Atin: nice to have, not critical.
