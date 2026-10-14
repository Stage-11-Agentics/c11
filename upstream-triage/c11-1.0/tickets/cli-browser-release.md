| Backlog id | Ticket id | Title | Tier | Size | Deps (backlog ids) | Created or updated |
|---|---|---|---|---|---|---|
| C1 | C11-279 | Reject misspelled routing keys instead of hitting the focused tab | P1 | S-M | — | created |
| C2 | C11-280 | Type --command into a new terminal via Ghostty initial_input | P1 | S | — | created |
| C3 | C11-281 | Document send delivery and add --raw, stdin, and unknown-flag errors | P1 | S-M | — | created |
| C4 | C11-282 | Read a terminal selection off the main thread | P1 | S | — | created |
| C5 | C11-283 | Scope --window without focusing that window | P1 | S-M | — | created |
| C6 | C11-284 | Print the bundled skill and a versioned capabilities.features list | P1 | S-M | — | created |
| C7 | C11-285 | Add c11 rpc as a local raw socket call | P2 | S | — | created |
| C7 | C11-286 | Add resize-window that keeps the top-left and does not focus | P2 | S | — | created |
| B1 | C11-287 | Replace a crashed web view on the next turn and stop forced layout | P1 | S-M | — | created |
| B2 | C11-288 | Smoke Chrome, Arc, and Safari import on a tagged build | P1 | S | — | created |
| B3 | C11-289 | Add browser profile list, add, rename, clear, delete, and --profile | P2 | S-M | — | created |
| R1 | C11-290 | Smoke c11 ssh atlas and correct the API reference | P1 | S | F1 | created |
| X1 | C11-291 | Translate new 1.0 strings into the six locales | P1 | M | C1, C2, C3, C5, B1, F1, W2, A2, A4 | created |
| X2 | C11-292 | One sign-off build and a numbered script for Atin | P1 | M | C1, C2, C3, C4, C5, C6, B1, B2, R1, X1, F1, F2, W3 | created |
| X3 | C11-293 | Release 1.0.0 only after Atin names the sign-off build | P1 | M | X2, F1 | created |

C7 is two tickets because `c11 rpc` and `resize-window` are unrelated PRs. C11-140 was commented, not rewritten or retagged: its section B unknown-flag bullet is owned by C3 (C11-281). Cross-workstream deps (F1, F2, W2, W3, A2, A4) are named here and left for the lead to link.
