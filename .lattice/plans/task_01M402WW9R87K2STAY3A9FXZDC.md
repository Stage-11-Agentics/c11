# C11-328: Feed answer: submit multiline text to Codex and Claude prompts

## Why
C11-268 ships `c11 feed answer` for single-line text only. On a real Codex 0.159.3 prompt, multiline answers paste but do not submit (`pasted_not_submitted`, the text left as an unsent draft) even with a 550 ms settle. Evidence: C11-268 validation ev_01M402VH3XEEGH6TWGH2PS0Z57. For 1.0, multiline is refused before paste.

## Scope
Find how Codex (and Claude) accept a multiline submission (bracketed paste then Return, a submit key, or a composer-specific sequence), implement it behind the same C11-267 guard, and prove it on real agents: one submission, nothing redirected, a draft still refused.
