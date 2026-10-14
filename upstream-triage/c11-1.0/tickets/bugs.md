| Backlog id | Ticket id | Title | Tier | Size | Deps (backlog ids) | Created or updated |
|---|---|---|---|---|---|---|
| B065, B010 (Ghostty), B031, B013, B047, B072, B204, B062, B022; ride B015, B020, B021, B034, B036, B037, B045, B166 | C11-294 | Make Ghostty mailbox waits abortable and ship the 1.0 terminal patch set | P0 | L | F1, F2 | created |
| B010 (app), B086, B003; ride B042, B066, B068, B089, B175, B180, B189, B257 | C11-295 | Stop autosave and screen reads from stalling main, and start cold terminals | P0 | L | B065, B087, F1, F2 | created |
| B087 | C11-296 | Start a cold terminal when an agent reads its screen | P1 | S | F1 | created |
| B007, B246; ride B004, B355 | C11-297 | Keep the control socket ready before restored agents call it | P1 | M | F1 | created |
| B005; ride B025 | C11-298 | A second copy of c11 must not kill the running fleet | P1 | S | F1 | created |
| B024 | C11-299 | Restore a session that contains a duplicate tab id | P1 | S | — | created |
| B019 | C11-300 | Refuse to close a workspace from the wrong window | P1 | S | F1 | created |
| B012 | C11-301 | Cap how many background workspaces mount at once | P1 | S | F1 | created |
| B030; ride B033 | C11-302 | Coalesce terminal wakeups so streaming output cannot flood main | P1 | S | B065, F1, F2 | created |
| B056; ride B067 | C11-303 | Stop scroll updates from laying out every window | P1 | S | F1, F2 | created |
| B061 | C11-304 | Ignore spinner-only terminal titles | P1 | S | F1 | created |
| B023, B094 | C11-305 | Stop shell helpers from outliving the shell and locking git | P1 | S | F1 | created |
| B028 | C11-306 | Bound the Claude Stop hook so it does not reread the whole transcript | P1 | S | — | created |
| B200 | C11-307 | Bump Sparkle so macOS 26 can install updates | P1 | S | F1, X3 | created |
| B002; ride B266 | C11-308 | Encode send-key ctrl+letter so agents can interrupt a TUI | P1 | S | F1 | created |
| B058 | C11-309 | Tell agents that tab numbers do not survive a restart | P1 | S | — | created |
| B059; ride only if convicted: B001, B029, B043, B060, B188 | C11-310 | Measure the sidebar before changing it | P2 | L | F1, F2 | created |
| B006, B018, B069, B046, B075, B193, B050, B247, B248, B032, B093, B114, B049, B160, B078, B080, B083, B137, B148, B064 | C11-311 | Tier-2 bug sweep | P2 | M | F1, F2 | created |
| B074, B014; ride B113, B120, B162 | C11-287 | Replace a crashed web view on the next turn and stop forced layout | P1 | S-M | — | updated |
| B044 | C11-231 | Expose journal-backed agent snapshots, waiting reasons, clocks and restore candidates | P1 | M | — | updated |

`B065` in the deps column is the C11-294 patch set. Inside `ws:bugs`, C11-295 depends on C11-294 and C11-296, and C11-302 depends on C11-294. F1, F2, and X3 are named for the lead and are not lattice-linked from this workstream. C11-311's wait for the P0s is an ordering note, not a link.

C11-287 stayed on `ws:cli-browser-release`. A ledger section was appended. The `ws:bugs` tag was not added. B044 was not filed: the comment is on C11-231, and the same note is on C11-273, which is not a third update. Tier 3 was not filed. B058 does not change ordinal allocation.
