# C11-318: Session-resume wrappers gate on C11_TAB_ID instead of legacy CMUX_SURFACE_ID

## Why
Every session-resume wrapper in Resources/bin gates on the legacy CMUX_SURFACE_ID env var (codex also falls back to C11_SURFACE_ID). CLAUDE.md names C11_TAB_ID as the c11 tab identity, and the c11 naming rule says residual cmux names are bugs except the deliberate cmux CLI alias.

## Scope
claude, codex, grok, opencode, pi, copilot, omp under Resources/bin: gate on C11_TAB_ID (the hidden-alias layer keeps old env names readable, so keep a fallback read of the legacy var for older running sessions if the alias layer does not already export it). Update the wrapper header comments. Update CLAUDE.md's host-and-primitive bullet once landed (it currently notes the residual).

## Acceptance
1. Inside a c11 terminal each wrapper still captures resume identity; outside c11 or with no live socket it falls through to the real binary unchanged.
2. No wrapper references CMUX_SURFACE_ID except a documented fallback, if one is kept.
3. CLAUDE.md residual note removed.
