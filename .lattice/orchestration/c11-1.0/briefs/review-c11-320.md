# Review: C11-320 README for 1.0 (text pass)

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `README Review`. Actor `agent:astra-review-320`.

- PR https://github.com/Stage-11-Agentics/c11/pull/583, head `24519272f4219cad7a3131a28952d2ef1acdcc00`, base = merge-base with origin/main. README.md only (+35 / -159). Validation ev_01M40NZG4DS1W6A1CKDMFCMWGG; owner self-review ev_01M40NZGAGAMKTDWKED8606Y7X. Screenshots follow in a later commit.
- Spec: `lattice show C11-320` scope 1-5.
- Focus: every feature claim is true of main at cde01d15 (check it against the code, the CLI `--help`, and `skills/c11/`); nothing that shipped and matters to a new user was dropped in the -159 (the install path, the hardware note, the license and attribution to cmux/Ghostty/Bonsplit, links that resolve); vocabulary is window → workspace → area → tab; voice per docs/c11-voice.md, short sentences, no em-dashes. Docs-only, so no build and no test run; read it rendered (`gh pr view 583 --web` is not needed; a local markdown preview is fine).
- Time-box 30 minutes. Reply `VERDICT C11-320 PASS|FAIL <head> <artifact>` to tab:210.
